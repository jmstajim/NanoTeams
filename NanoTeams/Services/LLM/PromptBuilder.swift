import Foundation

/// Builds chat messages and prompts for LLM interactions.
struct PromptBuilder {

    /// Context required for building prompts.
    struct Context {
        let task: NTMSTask
        let step: StepExecution
        let stepIndex: Int
        let run: Run
        let workFolder: WorkFolderProjection?
        let artifactReader: (Artifact) -> String?
        let activeTeam: Team?
        let roleDefinition: TeamRoleDefinition?
    }

    /// Builds the system prompt and initial chat messages for a step.
    /// - Parameters:
    ///   - context: The prompt building context.
    ///   - tools: The available tools for this step.
    /// - Returns: An array of chat messages to send to the LLM.
    static func buildChatMessages(
        context: Context,
        tools: [ToolSchema]
    ) -> [ChatMessage] {
        let step = context.step
        let run = context.run
        let stepIndex = context.stepIndex
        let toolNames = tools.map { $0.name }.sorted()
        let toolList = toolNames.isEmpty ? "No tools are available for this step." : ""

        // Build role guidance
        let roleGuidance = rolePrompt(for: step.role, roleDefinition: context.roleDefinition)

        // Build team roles line and context
        let teamRolesLine = buildTeamRolesLine(team: context.activeTeam, run: run)
        let teamDescriptionLine = buildTeamDescriptionLine(team: context.activeTeam)
        let positionContext = buildPositionContext(roleDefinition: context.roleDefinition, team: context.activeTeam)

        // Build artifact instructions
        let (expectedArtifactsLine, artifactInstructionsBlock) = buildArtifactInstructions(
            step: step,
            teamArtifacts: context.activeTeam?.artifacts ?? []
        )

        // Build context awareness guidance. The resource-tracking sentence is
        // only emitted when the role can actually produce tagged tool results.
        let toolNameSet = Set(toolNames)
        let hasFileReadTools = !toolNameSet.isDisjoint(with: ToolHandlerRegistry.fileReadTools)
        let contextAwareness = buildContextAwarenessGuidance(hasFileReadTools: hasFileReadTools)

        // Resolve system prompt from team template
        let template = context.activeTeam?.systemPromptTemplate ?? SystemTemplates.genericTemplate
        let workFolderContext = buildWorkFolderContextMessage(workFolder: context.workFolder) ?? ""
        let placeholders: [String: String] = [
            "roleName": context.roleDefinition?.name ?? step.role.displayName,
            "teamName": context.activeTeam?.name ?? "(unknown team)",
            "teamDescription": teamDescriptionLine,
            "teamRoles": teamRolesLine,
            "stepInfo": "You are step \(stepIndex + 1) of \(run.steps.count).",
            "positionContext": positionContext,
            "roleGuidance": roleGuidance,
            "contextAwareness": contextAwareness,
            "workFolderContext": workFolderContext,
            "toolList": toolList,
            "expectedArtifacts": expectedArtifactsLine,
            "artifactInstructions": artifactInstructionsBlock,
        ]

        var system = TemplateResolver.resolve(template, placeholders: placeholders)

        // Tool schemas are sent via the API request — no need to duplicate in system prompt

        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: system)
        ]

        // 1. Supervisor Task FIRST
        if let supervisorTaskSection = buildSupervisorTaskSection(task: context.task) {
            messages.append(ChatMessage(role: .user, content: supervisorTaskSection))
        }

        // 2. Required Artifacts (based on role dependencies, with full content)
        let requiredNames = getRequiredArtifactNames(
            role: step.role,
            team: context.activeTeam
        )
        let requiredArtifacts = findArtifactsMatchingNames(
            names: requiredNames,
            run: run,
            upToStepIndex: stepIndex
        )

        if !requiredArtifacts.isEmpty,
            let requiredSection = buildRequiredArtifactsSection(
                artifacts: requiredArtifacts,
                artifactReader: context.artifactReader
            )
        {
            messages.append(ChatMessage(role: .user, content: requiredSection))
        }

        // Work folder context is now in the system prompt (see `{workFolderContext}`
        // placeholder) so it persists in the stateful response chain instead of
        // being re-broadcast to every role as a user message.

        // 4. Pipeline context from prior steps (excluding already-shown required artifacts)
        if stepIndex > 0 {
            let excludeNames = Set(requiredArtifacts.map { $0.name })
            let pipelineContext = buildPipelineContext(
                run: run,
                upToStepIndex: stepIndex,
                artifactReader: context.artifactReader,
                excludeArtifactNames: excludeNames
            )
            if !pipelineContext.isEmpty {
                messages.append(ChatMessage(role: .user, content: pipelineContext))
            }
        }

        // 5. Supervisor Q/A context — inject as assistant tool call + tool result pair
        // so the LLM recognizes it already asked and continues from the answer.
        let hasAnsweredSupervisorQuestion =
            (step.supervisorQuestion?.isEmpty == false)
            && (step.effectiveSupervisorAnswer?.isEmpty == false)
        if hasAnsweredSupervisorQuestion,
           let question = step.supervisorQuestion,
           let answer = step.effectiveSupervisorAnswer {
            messages.append(ChatMessage(
                role: .assistant,
                content: "ask_supervisor: \(question)"))
            messages.append(ChatMessage(
                role: .user,
                content: "Supervisor answer: \(answer)"))
        } else if let question = step.supervisorQuestion, !question.isEmpty {
            messages.append(ChatMessage(
                role: .user,
                content: "Supervisor question (pending): \(question)"))
        }

        // 6. Step messages as conversation history.
        for message in step.messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            let messageRole = (message.role == .supervisor) ? "user" : "assistant"
            messages.append(ChatMessage(role: MessageRole(rawValue: messageRole) ?? .user, content: message.content))
        }

        // Add minimal prompt if no messages
        if messages.count == 1 {
            messages.append(ChatMessage(role: .user, content: "Start the step."))
        }

        // Note: Scratchpad planning phase is now handled in LLMExecutionService.runOneLLMToolIteration()

        return messages
    }

    // MARK: - Private Helpers

    private static func rolePrompt(for role: Role, roleDefinition: TeamRoleDefinition?) -> String {
        if let roleDefinition {
            let trimmed = roleDefinition.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        // Fallback to default prompt for built-in roles
        return SystemTemplates.roles[role.baseID]?.prompt ?? ""
    }

    /// Builds context-awareness guidance for the system prompt. Kept short on
    /// purpose — verbose self-help rules are ignored by small models and waste
    /// tokens across every fresh chain. The resource-tracking half is only
    /// injected when the role actually has file-read tools that produce tags.
    static func buildContextAwarenessGuidance(hasFileReadTools: Bool) -> String {
        var parts = [
            "The Supervisor Task and upstream artifacts are already in the conversation — act on them directly, don't re-search or re-summarize.",
        ]
        if hasFileReadTools {
            parts.append(
                "Tool results carry tags: <§R1§> reads, <§E1§> edits, <§W1§> writes, <§B1§> builds, <§G1§> git, <§P1§> plans. The MEMORIES index at the end of the conversation marks stale entries — trust CURRENT tags, don't re-read unchanged content."
            )
        }
        return parts.joined(separator: "\n")
    }

}
