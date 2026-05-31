import Foundation

/// Builds chat messages and prompts for LLM interactions.
nonisolated struct PromptBuilder {

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
        /// App-wide instruction appended to the resolved system prompt.
        /// Default `""` keeps existing test call sites compiling.
        let globalContext: String

        init(
            task: NTMSTask,
            step: StepExecution,
            stepIndex: Int,
            run: Run,
            workFolder: WorkFolderProjection?,
            artifactReader: @escaping (Artifact) -> String?,
            activeTeam: Team?,
            roleDefinition: TeamRoleDefinition?,
            globalContext: String = ""
        ) {
            self.task = task
            self.step = step
            self.stepIndex = stepIndex
            self.run = run
            self.workFolder = workFolder
            self.artifactReader = artifactReader
            self.activeTeam = activeTeam
            self.roleDefinition = roleDefinition
            self.globalContext = globalContext
        }
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
        let toolList = renderToolListPlaceholder(toolNames: toolNames)

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

        // Build conversation-mechanics guidance. The resource-tracking sentence is
        // only emitted when the role can actually produce tagged tool results.
        let toolNameSet = Set(toolNames)
        let hasFileReadTools = !toolNameSet.isDisjoint(with: ToolHandlerRegistry.fileReadTools)
        let conversationMechanics = buildConversationMechanicsGuidance(hasFileReadTools: hasFileReadTools)

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
            "conversationMechanics": conversationMechanics,
            // Backwards-compat alias for stored team templates created before the
            // 2026-05 rename. Stored teams.json files round-trip user-edited
            // `systemPromptTemplate` text — renaming the placeholder without an
            // alias would leave a literal `{contextAwareness}` token in the
            // rendered prompt of every pre-existing team.
            "contextAwareness": conversationMechanics,
            "workFolderContext": workFolderContext,
            "toolList": toolList,
            "expectedArtifacts": expectedArtifactsLine,
            "artifactInstructions": artifactInstructionsBlock,
            "globalContext": formatGlobalContext(context.globalContext),
            // Merged tool block: when role has tools → Harmony format spec + per-tool
            // entries; when role has none → "no tools" notice. One section in the
            // template covers both cases, so the `## Tool Calling` header is never
            // orphan-stripped and the editor's `{toolCalling}` chip always ships
            // meaningful content.
            "toolCalling": Self.formatToolCallingBlock(tools: tools),
            // Backwards-compat alias for stored templates created before the
            // 2026-05 rename (was `{toolCallingBlock}`).
            "toolCallingBlock": Self.formatToolCallingBlock(tools: tools),
        ]

        let system = TemplateResolver.resolveSystemPrompt(
            template,
            placeholders: placeholders,
            globalContext: context.globalContext
        )

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

        // 4. Pipeline context from prior steps (excluding already-shown required artifacts,
        //    and skipping in-progress parallel branches that aren't dependencies for this role).
        if stepIndex > 0 {
            let excludeNames = Set(requiredArtifacts.map { $0.name })
            let pipelineContext = buildPipelineContext(
                run: run,
                upToStepIndex: stepIndex,
                artifactReader: context.artifactReader,
                excludeArtifactNames: excludeNames,
                requiredArtifactNames: excludeNames
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

    /// `{toolList}` is deprecated as of 2026-05 — the no-tools notice and the
    /// Harmony tool catalog were merged into a single `{toolCalling}` chip
    /// (see `PromptBuilder.buildChatMessages` placeholders dict; the legacy
    /// `{toolCallingBlock}` placeholder name resolves to the same value for
    /// backwards-compat with stored teams.json files). Returns "" so any
    /// legacy stored template with `## Tools\n{toolList}` gets stripped
    /// quietly via `TemplateResolver.stripOrphanHeaders`. Kept on the
    /// placeholder list so legacy chips don't render as a literal `{toolList}`
    /// token in the editor / wire payload.
    static func renderToolListPlaceholder(toolNames _: [String]) -> String {
        ""
    }

    /// Returns the bare trimmed `globalContext` value (no `## Global guidance`
    /// wrap). The `## Global guidance` header lives in the template — author
    /// renames / repositions it there. Empty input returns `""` so the
    /// surrounding template header gets stripped by
    /// `TemplateResolver.stripOrphanHeaders`.
    static func formatGlobalContext(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Single source of truth for the merged `{toolCalling}` chip value.
    /// Returns the Harmony format spec + per-tool entries when the role has
    /// tools; returns the "no tools available" notice otherwise. Same value
    /// powers the deprecated `{toolCallingBlock}` alias for stored templates.
    ///
    /// Function name retains `Block` suffix from the pre-rename era (was
    /// `formatToolCallingBlock` when `{toolCallingBlock}` was the primary
    /// chip name). The PRIMARY chip is now `{toolCalling}`; the function
    /// name stayed to minimise churn at the call sites.
    static func formatToolCallingBlock(tools: [ToolSchema]) -> String {
        tools.isEmpty
            ? "None available — respond directly without tool calls."
            : NativeLMStudioClient.buildToolSchemaBody(tools: tools)
    }

    /// Returns the bare body of the conversation-mechanics section (no
    /// `## Conversation mechanics` wrap). The header lives in the template
    /// — author controls naming and position. NOT role guidance: the content
    /// is invariant across roles. The resource-tracking sentence is only
    /// emitted when the role actually has file-read tools that produce tags.
    static func buildConversationMechanicsGuidance(hasFileReadTools: Bool) -> String {
        var parts = [
            "The Supervisor Task and upstream artifacts are already in the conversation — act on them directly, don't re-search or re-summarize.",
        ]
        if hasFileReadTools {
            // The rolling `## Memories vN` index injection stays gated off
            // (`LLMExecutionService.isMemoriesInjectionEnabled` in
            // `LLMExecutionService+ToolLoopState.swift`). Per-result tag emission +
            // the `{"status":"unchanged","ref":…,"_hint":…}` envelope are still
            // active; this sentence only teaches the tag legend and steers reuse.
            // The unchanged envelope is NOT pre-explained here — its own `_hint`
            // ("Do NOT re-read. See <§R1§> above.") carries that instruction at
            // point of use, so re-stating it in the cached system prompt would be
            // pure duplication.
            // Scope note: only the listed result kinds carry tags — `list_files`
            // / `search` / `git_log` results are untagged, so don't claim "every"
            // tool result is tagged (the legend's enumeration is the boundary).
            parts.append(
                "Tool results may carry a tag: <§R1§> read, <§E1§> edit, <§W1§> write, <§B1§> build, <§G1§> git, <§P1§> plan. Reference a tag in your reasoning instead of re-quoting that result."
            )
        }
        return parts.joined(separator: "\n")
    }

}
