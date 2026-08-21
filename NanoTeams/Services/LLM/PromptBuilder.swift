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
        /// Auto-discovered agent instruction files (CLAUDE.md, AGENTS.md, …).
        /// The main file's content + the other paths ride the
        /// `{workFolderContext}` placeholder alongside `settings.context`.
        /// Default `nil` keeps existing test call sites compiling and renders
        /// byte-identically to the legacy work-folder-context output.
        let agentInstructions: AgentInstructionsSnapshot?
        /// Agent skills the ROLE carries permanently (`TeamRoleDefinition.attachedSkillIDs`
        /// resolved against the orchestrator's snapshot). Order is the user's, and it is
        /// the order of the rendered `### Skill:` sections. Default `[]` keeps existing
        /// call sites compiling and renders byte-identically to the pre-skills prompt.
        let attachedSkills: [ResolvedRoleSkill]

        init(
            task: NTMSTask,
            step: StepExecution,
            stepIndex: Int,
            run: Run,
            workFolder: WorkFolderProjection?,
            artifactReader: @escaping (Artifact) -> String?,
            activeTeam: Team?,
            roleDefinition: TeamRoleDefinition?,
            globalContext: String = "",
            agentInstructions: AgentInstructionsSnapshot? = nil,
            attachedSkills: [ResolvedRoleSkill] = []
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
            self.agentInstructions = agentInstructions
            self.attachedSkills = attachedSkills
        }
    }

    /// Step messages in conversation order, on a TOTAL order: timestamp first, then the
    /// persisted array index.
    ///
    /// The index tiebreak is not cosmetic. `sorted(by:)` is documented as NOT guaranteed stable,
    /// so a comparator on `createdAt` alone leaves the order of tied messages up to the sort
    /// implementation — and this builder is re-run on every rebuild path (`restartRole`,
    /// `correctRole` branch B). On a stateless transport, the same inputs rendering different
    /// bytes is a prompt-prefix miss whose cause the reader can never locate. Today's Swift sort
    /// happens to preserve order for tied elements, which is exactly what makes the dependency
    /// dangerous: it is an undocumented implementation detail that a toolchain update may drop
    /// silently.
    ///
    /// The tiebreak is the ARRAY INDEX rather than a UUID because `step.messages` is persisted
    /// and decoded in append order, so when the timestamps tie the array order is the only
    /// honest chronology. `MonotonicClock` makes in-process ties impossible, so ties arrive from
    /// legacy or imported data — the one case where that matters.
    static func chronologicallyOrdered(_ messages: [StepMessage]) -> [StepMessage] {
        messages.enumerated()
            .sorted { precedes($0, $1) }
            .map(\.element)
    }

    /// The strict weak ordering behind `chronologicallyOrdered`. Exposed so a test can assert it
    /// is TOTAL — that no two distinct entries are mutually incomparable, which is the property
    /// the stability of the sort would otherwise have to supply.
    static func precedes(
        _ lhs: (offset: Int, element: StepMessage),
        _ rhs: (offset: Int, element: StepMessage)
    ) -> Bool {
        lhs.element.createdAt == rhs.element.createdAt
            ? lhs.offset < rhs.offset
            : lhs.element.createdAt < rhs.element.createdAt
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
        // only emitted when the role can actually produce tagged tool results —
        // gated on the tag store's own set, not on file-read tools alone, so a
        // bash- or git-only role still gets the legend for the tags it will see.
        let toolNameSet = Set(toolNames)
        let hasTagProducingTools = !toolNameSet.isDisjoint(with: MemoryTagStore.tagProducingTools)
        let conversationMechanics = buildConversationMechanicsGuidance(hasTagProducingTools: hasTagProducingTools)

        // Resolve system prompt from team template
        let template = context.activeTeam?.systemPromptTemplate ?? SystemTemplates.genericTemplate
        let workFolderContext = buildWorkFolderContextMessage(
            workFolder: context.workFolder,
            agentInstructions: context.agentInstructions
        ) ?? ""
        let placeholders: [String: String] = [
            "roleName": context.roleDefinition?.name ?? step.role.displayName,
            "teamName": context.activeTeam?.name ?? "(unknown team)",
            "teamDescription": teamDescriptionLine,
            "teamRoles": teamRolesLine,
            // `{stepInfo}` retired from the built-in templates (2026-07): the
            // "step N of M" counter sat in the cache-critical FIRST line while
            // `run.steps.count` grows lazily as parallel roles start — a
            // mid-step stateless rebuild re-rendered line 1 with a different M
            // (kills the KV prefix, and "step 2 of 3" was simply wrong for a
            // run that ends up with 8 steps). `{positionContext}` carries the
            // real position semantics (Receives/Feeds into). The chip resolves
            // empty for user templates that still carry it.
            "stepInfo": "",
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
            "roleSkills": formatRoleSkills(context.attachedSkills),
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
            globalContext: context.globalContext,
            // Chip-less fallback for custom teams — see `resolveSystemPrompt`.
            // Same value the `{roleSkills}` placeholder carries, so opting in or
            // out of the chip ships the same section.
            roleSkills: placeholders["roleSkills"] ?? ""
        )

        // Tool schemas are sent via the API request — no need to duplicate in system prompt

        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: system)
        ]

        // 1. Supervisor Task FIRST. The Autovisor renders it as "Supervisor
        //    Goal" — its brief IS its goal (kept in sync with settings.autovisorGoal).
        let supervisorHeader = context.activeTeam?.templateID == AutovisorConstants.teamTemplateID
            ? "Supervisor Goal" : "Supervisor Task"
        if let supervisorTaskSection = buildSupervisorTaskSection(task: context.task, header: supervisorHeader) {
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

        // 5. Supervisor Q/A context — replay the ask as the SAME Harmony envelope
        // the `## Tool Calling` block teaches. The conversation acts as few-shot:
        // the pre-fix plain-text `ask_supervisor: <question>` replay taught a
        // format `HarmonyToolCallParser` cannot see, and small models imitate the
        // most recent call shape (Sclar2024/Lu2022 — format drift teaches drift).
        let hasAnsweredSupervisorQuestion =
            (step.supervisorQuestion?.isEmpty == false)
                && (step.effectiveSupervisorAnswer?.isEmpty == false)
        if hasAnsweredSupervisorQuestion,
           let question = step.supervisorQuestion,
           let answer = step.effectiveSupervisorAnswer {
            messages.append(ChatMessage(
                role: .assistant,
                content: replayedAskSupervisorEnvelope(question: question)))
            messages.append(ChatMessage(
                role: .user,
                content: "\(MessageSourceContext.supervisorAnswerPrefix)\(answer)"))
        } else if let question = step.supervisorQuestion, !question.isEmpty {
            messages.append(ChatMessage(
                role: .user,
                content: "Supervisor question (pending): \(question)"))
        }

        // 6. Step messages as conversation history.
        for message in chronologicallyOrdered(step.messages) {
            let messageRole = (message.role == .supervisor) ? "user" : "assistant"
            messages.append(ChatMessage(role: MessageRole(rawValue: messageRole) ?? .user, content: message.content))
        }

        // 7. Closing turn — restate the deliverable contract at the TRUE end of
        // the context [Liu2024]: on artifact-heavy steps the system prompt's
        // `## Final reminder` ends up buried under tens of KB of injected
        // artifacts, and the mid-context slot is the worst recall zone. The
        // restatement is wire-only (never persisted) and sits in the variant
        // tail, so it costs nothing in prefix-cache stability.
        let expectedForContract = step.expectedArtifacts
            .filter { $0 != ArtifactConstants.buildDiagnosticsName }
        var closing = messages.count == 1 ? "Start the step." : ""
        if !expectedForContract.isEmpty, step.revisionComment == nil {
            let quoted = expectedForContract.map { "\"\($0)\"" }.joined(separator: ", ")
            closing += (closing.isEmpty ? "" : " ")
                + "Submit via create_artifact when ready: \(quoted)."
        }
        if !closing.isEmpty {
            messages.append(ChatMessage(role: .user, content: closing))
        }

        // Note: the planning phase is applied in `runOneLLMToolIteration` via
        // `applyPlanningPhase` — it appends a brief to the WIRE and never touches
        // this composed prompt.

        return messages
    }

    // MARK: - Private Helpers

    /// Renders a replayed `ask_supervisor` call in the exact Harmony envelope
    /// shape the wire teaches (`<|call|>{"name":…,"arguments":…}<|end|>`), with
    /// the question JSON-encoded so quotes/newlines can't break the envelope.
    /// Internal (not private) for test pinning.
    static func replayedAskSupervisorEnvelope(question: String) -> String {
        let envelope: [String: Any] = [
            "name": ToolNames.askSupervisor,
            "arguments": ["question": question],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"arguments":{"question":""},"name":"ask_supervisor"}"#
        return "<|call|>\(json)<|end|>"
    }

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

    /// Returns the bare body of the `## Skills` section — one `### Skill: <name>`
    /// block per attached skill, in the ROLE'S ORDER. The `## Skills` header lives
    /// in the template, so a role with no skills resolves this to `""` and
    /// `TemplateResolver.stripOrphanHeaders` removes the section entirely — the
    /// prompt is then byte-identical to the pre-skills build.
    ///
    /// Bodies are injected in full (no cap, no truncation — chat parity), but
    /// re-levelled by `SkillConstants.nestedBody` so a third-party skill's own
    /// `#`/`##` headings nest under its `### Skill:` header instead of reading as
    /// prompt-level sections. Empty-bodied entries never reach here — resolution
    /// drops them (see `RoleSkillsSnapshot.resolve`) so an empty header can't ship.
    static func formatRoleSkills(_ skills: [ResolvedRoleSkill]) -> String {
        skills.compactMap { skill -> String? in
            let body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return SkillConstants.systemPromptHeader(name: skill.name)
                + "\n\n"
                + SkillConstants.nestedBody(body, under: SkillConstants.systemPromptHeaderLevel)
        }
        .joined(separator: "\n\n")
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
    /// emitted when the role actually has tools that produce tagged results
    /// (`MemoryTagStore.tagProducingTools`).
    static func buildConversationMechanicsGuidance(hasTagProducingTools: Bool) -> String {
        var parts = [
            "The Supervisor Task and upstream artifacts are already in the conversation — act on them directly, don't re-search or re-summarize.",
        ]
        if hasTagProducingTools {
            // This sentence only teaches the tag legend and steers reuse: every
            // supported result gets a fresh tag, and referencing the tag beats
            // re-quoting the content.
            // Scope note: only the listed result kinds carry tags — `list_files`
            // / `search` / `git_log` / `delete_file` results are untagged, so
            // don't claim "every" tool result is tagged. The enumeration must
            // cover every live `TagType`; it drifted once (a dead `<§P1§>` was
            // advertised while the live `<§S1§>` was not).
            parts.append(
                "Tool results may carry a tag: <§R1§> read, <§E1§> edit, <§W1§> write, <§B1§> build, <§G1§> git, <§S1§> shell. Reference a tag in your reasoning instead of re-quoting that result."
            )
        }
        return parts.joined(separator: "\n")
    }

}
