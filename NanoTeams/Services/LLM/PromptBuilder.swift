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

        // Build context awareness guidance (prevent wasteful searches)
        let contextAwareness = buildContextAwarenessGuidance()

        // Resolve system prompt from team template
        let template = context.activeTeam?.systemPromptTemplate ?? SystemTemplates.genericTemplate
        let placeholders: [String: String] = [
            "roleName": context.roleDefinition?.name ?? step.role.displayName,
            "teamName": context.activeTeam?.name ?? "(unknown team)",
            "teamDescription": teamDescriptionLine,
            "teamRoles": teamRolesLine,
            "stepInfo": "You are step \(stepIndex + 1) of \(run.steps.count).",
            "positionContext": positionContext,
            "roleGuidance": roleGuidance,
            "contextAwareness": contextAwareness,
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

        // 3. Work folder context
        if let projectContext = buildWorkFolderContextMessage(workFolder: context.workFolder),
            !projectContext.isEmpty
        {
            messages.append(ChatMessage(role: .user, content: projectContext))
        }

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
        if let question = step.supervisorQuestion, !question.isEmpty,
           let answer = step.effectiveSupervisorAnswer, !answer.isEmpty {
            // Simulate the ask_supervisor tool call + result pattern
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

        // 6. Step messages as conversation history
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

    /// Builds context awareness guidance to prevent wasteful file searches
    static func buildContextAwarenessGuidance() -> String {
        return """
CONTEXT AWARENESS:
- Supervisor Task: Provided in this message above — do NOT search work folder files for it
- Prior artifacts: Provided in 'Context from previous steps' — do NOT re-read these files
- Team context: Other roles' work is injected — do NOT search for team information
- Use search/read_lines ONLY to find SPECIFIC implementation files or code patterns mentioned in requirements
- NEVER do exploratory searches for requirements, tasks, or team context you already have

RESOURCE TRACKING:
Tool results get tags (<§R1§>, <§E3§>, <§B1§>) to avoid re-reading unchanged content.
- Unchanged repeat read → compact ref {"status":"unchanged","ref":"<§R1§>"} — content is at that tag earlier in conversation. Do NOT re-read.
- Changed file → full new content with new tag. Old tag becomes OUTDATED.
- "=== MEMORIES ===" at end of conversation = freshness index. CURRENT = valid, OUTDATED = stale.
- If a tag is CURRENT, trust it. Do NOT re-read "just to confirm".

EFFICIENCY RULES (to avoid thinking overhead):
1. If Supervisor task is clear and specific, act on it directly — do NOT overthink scope or ask "should I do X?"
2. If you have all the context you need, proceed immediately — do NOT debate with yourself
3. Do NOT re-read or re-summarize prior artifacts you already have inline
4. Avoid meta-analysis of your own role — e.g., "Should I write a PRD?" → just write appropriately
5. If previous role already made a decision, build on it — do NOT second-guess or redo their work
6. Ask clarifying questions ONLY if genuinely ambiguous, not to avoid responsibility
"""
    }

}
