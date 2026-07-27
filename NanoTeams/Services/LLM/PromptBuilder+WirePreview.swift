import AppKit
import Foundation

/// LLM call site whose system prompt the preview reproduces.
///
/// - `.stepExecution`: step run loop. Full `resolveToolSchemas` pipeline,
///   Harmony tool-calling block appended.
/// - `.consultation`: `ask_teammate` flow. Runtime passes `tools: []` — no
///   Harmony block.
/// - `.meeting`: meeting turn. Tool pipeline filtered through
///   `MeetingCoordinator.filterMeetingTools`.
nonisolated enum WirePromptKind: Sendable {
    case stepExecution
    case consultation
    case meeting
}

nonisolated extension PromptBuilder {

    /// Two-way state encoding "where the project lives" for the wire-preview's
    /// tool-resolution pipeline. Replaces the previous `(workFolderRoot: URL?,
    /// isDefaultStorage: Bool)` pair which encoded 4 combinations for 2 valid
    /// states (two of which silently lied about the project's git status /
    /// write permissions).
    ///
    /// - `.defaultStorage`: no real folder selected — the orchestrator routes
    ///   writes to its internal default-storage directory, so write / git /
    ///   xcode tools get stripped via `filterForDefaultStorage`.
    /// - `.realFolder(root:)`: a user-chosen project folder. Git tools survive
    ///   iff `root/.git` exists (checked by `filterForGitAvailability`).
    enum WireWorkFolder: Hashable, Sendable {
        case defaultStorage
        case realFolder(root: URL)

        /// Bridge from the orchestrator's `workFolderURL` state. `nil` URL or
        /// a URL equal to `NTMSOrchestrator.defaultStorageURL` collapse to
        /// `.defaultStorage`. Centralizes the rule that previously lived
        /// inline in both `PromptPreviewSheet` and `TemplatePreviewSheet`.
        @MainActor
        static func from(orchestratorURL: URL?) -> WireWorkFolder {
            guard let url = orchestratorURL, url != NTMSOrchestrator.defaultStorageURL else {
                return .defaultStorage
            }
            return .realFolder(root: url)
        }
    }

    /// Inputs for the wire-preview renderer — bundled so the renderer never
    /// touches orchestrator state. Callers thread these explicitly.
    struct WirePreviewInputs: Sendable {
        let role: TeamRoleDefinition
        let team: Team?
        let allTeams: [Team]
        let workFolder: WorkFolderProjection?
        /// Replaces the previous `(workFolderRoot: URL?, isDefaultStorage: Bool)`
        /// pair — see `WorkFolderState`.
        let workFolderState: WireWorkFolder
        let selectedScheme: String?
        let isVisionConfigured: Bool
        /// `ComputerUsePolicy.isEnabled` — mirrors `isVisionConfigured` threading
        /// (strip semantics live at `resolveToolSchemas` step 3.2-bis).
        let isComputerUseEnabled: Bool
        let globalContext: String
        /// `.meeting` kind only: preview the prompt the **coordinator** would
        /// see at turn 1 (mid- and late-meeting branches are runtime-dynamic
        /// and not previewable in this single-turn model). UI surfaces can
        /// toggle this; default `false` matches the non-coordinator branch.
        /// Ignored for `.stepExecution` / `.consultation`.
        let isCoordinator: Bool
        /// Auto-discovered agent instruction files — mirrors the runtime
        /// `PromptBuilder.Context.agentInstructions` so the `{workFolderContext}`
        /// preview is byte-identical to the wire. Default `nil` keeps existing
        /// call sites compiling and renders as the legacy work-folder-context.
        let agentInstructions: AgentInstructionsSnapshot?

        init(
            role: TeamRoleDefinition,
            team: Team?,
            allTeams: [Team],
            workFolder: WorkFolderProjection?,
            workFolderState: WireWorkFolder,
            selectedScheme: String?,
            isVisionConfigured: Bool,
            isComputerUseEnabled: Bool,
            globalContext: String,
            isCoordinator: Bool = false,
            agentInstructions: AgentInstructionsSnapshot? = nil
        ) {
            self.role = role
            self.team = team
            self.allTeams = allTeams
            self.workFolder = workFolder
            self.workFolderState = workFolderState
            self.selectedScheme = selectedScheme
            self.isVisionConfigured = isVisionConfigured
            self.isComputerUseEnabled = isComputerUseEnabled
            self.globalContext = globalContext
            self.isCoordinator = isCoordinator
            self.agentInstructions = agentInstructions
        }
    }

    /// Errors surfaced by the wire-preview renderer.
    enum WirePreviewError: Error, CustomStringConvertible, Equatable {
        /// Generated Team placeholder cannot be previewed — its real team is
        /// built by an LLM call at run time, so the first wire payload doesn't
        /// exist before the run.
        case generatedTeamNotRenderable

        /// Selected role id is not in the team — typically a stale selection
        /// when the sheet is open and the role got deleted from another
        /// surface. Without this, `TemplatePreviewSheet` falls through to an
        /// empty `WirePreviewRender` and the user sees a blank pane with no
        /// diagnostic.
        case roleNotFoundInTeam(roleID: String, teamName: String)

        var description: String {
            switch self {
            case .generatedTeamNotRenderable:
                return "This team uses the Generated Team placeholder; the real team is built by an LLM call at run time, so the first wire payload cannot be previewed before the run."
            case .roleNotFoundInTeam(let roleID, let teamName):
                return "Role \(roleID) is not in team '\(teamName)'. The role may have been deleted — pick another role to preview."
            }
        }
    }

    // MARK: - Public API

    /// Returns the resolved system_prompt string for the chosen call site.
    /// `.stepExecution` is byte-identity-tested against the production wire
    /// payload (`NativeChatRequest.systemPrompt` from
    /// `NativeLMStudioClient.buildRequest(...)`). `.consultation`
    /// / `.meeting` share the same `TemplateResolver.resolveSystemPrompt`
    /// pipeline as their runtime, so body parity is structural; the meeting
    /// Harmony block is appended via the same builder the runtime uses.
    static func buildWirePromptPreview(
        kind: WirePromptKind,
        inputs: WirePreviewInputs
    ) throws(WirePreviewError) -> String {
        try guardRenderable(team: inputs.team)
        let tools = resolveWirePreviewTools(kind: kind, inputs: inputs)
        let body = resolveWirePreviewBody(kind: kind, inputs: inputs)
        return appendingToolBlock(to: body, tools: tools)
    }

    /// Same payload as `buildWirePromptPreview`, but rendered as an
    /// `NSAttributedString` with category-colored runs for resolved placeholders.
    /// The trailing global-context separator and Harmony tool-schema block are
    /// emitted as plain monospaced runs.
    ///
    /// No `PlaceholderAttachment` chips materialize — every placeholder is
    /// resolved (synthetic preview values for runtime-only slots like
    /// `meetingTopic`), so the body matches the plain string verbatim.
    static func buildWirePromptPreviewAttributed(
        kind: WirePromptKind,
        inputs: WirePreviewInputs
    ) throws(WirePreviewError) -> NSAttributedString {
        try guardRenderable(team: inputs.team)

        let tools = resolveWirePreviewTools(kind: kind, inputs: inputs)
        let (template, definitions) = wirePreviewTemplateAndDefs(kind: kind, team: inputs.team)
        let values = wirePreviewValues(kind: kind, inputs: inputs)

        let body = PlaceholderParser.attributedString(
            from: template,
            placeholders: definitions,
            resolvedValues: values
        )
        let result = NSMutableAttributedString(attributedString: body)
        // Mirror plain-path `TemplateResolver.resolveSystemPrompt` ordering:
        // strip orphan `Team purpose:` labels BEFORE collapsing blank lines so
        // the removed line's neighbouring newlines collapse correctly.
        stripOrphanInlineLabelsInAttributed(result)
        collapseAttributedBlankLines(result)
        // Mirror plain-path orphan-header strip so the attributed and plain
        // renderers stay byte-equivalent when chips resolve to empty values.
        stripOrphanHeadersInAttributed(result)
        trimAttributedLeadingTrailingWhitespace(result)

        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let plainAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: Colors.nsTextPrimary,
        ]

        // Auto-append only when the template DOESN'T already place the chip
        // (backwards-compat for templates created before the chip was exposed).
        // Format mirrors `TemplateResolver.appendingSeparator` (`\n\n## Global
        // guidance\n\n<value>`) so opting in or out of the chip ships the same
        // shape.
        let bodyTrimmed = result.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGlobal = inputs.globalContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let templateHasGlobalContextChip = template.contains("{globalContext}")
        if !trimmedGlobal.isEmpty && !templateHasGlobalContextChip && !bodyTrimmed.isEmpty {
            result.append(NSAttributedString(
                string: "\n\n## Global guidance\n\n" + trimmedGlobal,
                attributes: plainAttrs
            ))
        }

        // Harmony `## Tool Calling` block is the resolved tools surface — same
        // semantic category as the inline `{toolList}` placeholder ("tools"
        // → orange). Coloring the whole block matches the chip palette in the
        // template editor so users see one consistent visual language for
        // tools across all surfaces.
        //
        // Self-detection: anchor on the resolved Harmony body marker in the
        // already-resolved attributed body, mirroring the plain path's
        // `appendingToolBlock` and the runtime's `buildRequest`. This is more
        // robust than checking the source-template substring (which would
        // miss legacy `{toolCallingBlock}` resolutions and could be fooled by
        // commented-out chip text).
        let templateHasToolCallingChip = result.string.contains(
            NativeLMStudioClient.harmonyBodyMarker)
        if !tools.isEmpty && !templateHasToolCallingChip {
            let separator = result.length > 0 ? "\n\n" : ""
            let toolsAttrs: [NSAttributedString.Key: Any] = [
                .font: monoFont,
                .foregroundColor: PlaceholderAttachment.color(for: "tools"),
            ]
            result.append(NSAttributedString(
                string: separator + NativeLMStudioClient.buildToolSchemaSection(tools: tools),
                attributes: toolsAttrs
            ))
        }

        return result
    }

    // MARK: - Internal (test-visible) helpers

    /// Per-kind template + placeholder definitions. Internal visibility for
    /// the renderer's test surface.
    static func wirePreviewTemplateAndDefs(
        kind: WirePromptKind,
        team: Team?
    ) -> (template: String, definitions: [(key: String, label: String, category: String)]) {
        switch kind {
        case .stepExecution:
            return (team?.systemPromptTemplate ?? SystemTemplates.genericTemplate,
                    SystemTemplates.systemPromptPlaceholders)
        case .consultation:
            return (team?.consultationPromptTemplate ?? SystemTemplates.genericConsultationTemplate,
                    SystemTemplates.consultationPlaceholders)
        case .meeting:
            return (team?.meetingPromptTemplate ?? SystemTemplates.genericMeetingTemplate,
                    SystemTemplates.meetingPlaceholders)
        }
    }

    /// Per-kind resolved-values dictionary. Internal visibility for tests.
    static func wirePreviewValues(
        kind: WirePromptKind,
        inputs: WirePreviewInputs
    ) -> [String: String] {
        switch kind {
        case .stepExecution:
            return wirePreviewSystemValues(inputs: inputs)
        case .consultation:
            return wirePreviewConsultationValues(inputs: inputs)
        case .meeting:
            return wirePreviewMeetingValues(inputs: inputs)
        }
    }

    /// Filtered tool schemas the renderer attaches to the Harmony block.
    /// Internal visibility for tests.
    static func resolveWirePreviewTools(
        kind: WirePromptKind,
        inputs: WirePreviewInputs
    ) -> [ToolSchema] {
        switch kind {
        case .consultation:
            // Production passes `tools: []` to `streamChat` for consultations.
            return []
        case .stepExecution:
            return runtimeToolPipeline(inputs: inputs)
        case .meeting:
            return MeetingCoordinator.filterMeetingTools(runtimeToolPipeline(inputs: inputs))
        }
    }

    // MARK: - Private

    private static func guardRenderable(team: Team?) throws(WirePreviewError) {
        if team?.templateID == "generated" {
            throw .generatedTeamNotRenderable
        }
    }

    /// Resolves the body via `TemplateResolver.resolveSystemPrompt` — the
    /// shared helper that runtime step / consultation / meeting builders also
    /// use, so body parity is structural rather than test-enforced.
    private static func resolveWirePreviewBody(
        kind: WirePromptKind,
        inputs: WirePreviewInputs
    ) -> String {
        let (template, _) = wirePreviewTemplateAndDefs(kind: kind, team: inputs.team)
        let values = wirePreviewValues(kind: kind, inputs: inputs)
        return TemplateResolver.resolveSystemPrompt(
            template,
            placeholders: values,
            globalContext: inputs.globalContext
        )
    }

    /// Append the Harmony tool block with the same `\n\n` separator semantics
    /// `NativeLMStudioClient.buildRequest` uses. No-op when tools is empty OR
    /// when `body` already contains the Harmony body marker — that happens
    /// when the template includes the `{toolCalling}` placeholder, in which
    /// case the block is already in the resolved body and appending would
    /// duplicate. Detection anchors on the body marker (a phrase only
    /// `buildToolSchemaBody` emits), NOT on the `## Tool Calling` header
    /// substring — user prose with the header heading must not fool the
    /// auto-append into skipping.
    private static func appendingToolBlock(to body: String, tools: [ToolSchema]) -> String {
        guard !tools.isEmpty else { return body }
        if body.contains(NativeLMStudioClient.harmonyBodyMarker) { return body }
        var result = body
        if !result.isEmpty { result += "\n\n" }
        result += NativeLMStudioClient.buildToolSchemaSection(tools: tools)
        return result
    }

    /// Step-execution placeholder dictionary — same keys, same string
    /// sources, same fallback chains as `PromptBuilder.buildChatMessages`.
    /// Reuses the same `PromptBuilder.build…` helpers (`buildTeamRolesLine`,
    /// `buildPositionContext`, `buildArtifactInstructions`, etc.) so refactors
    /// in one path can't silently desync the preview.
    private static func wirePreviewSystemValues(inputs: WirePreviewInputs) -> [String: String] {
        let roleDef = inputs.role
        let team = inputs.team
        let role = Role.fromDefinition(roleDef)

        let tools = resolveWirePreviewTools(kind: .stepExecution, inputs: inputs)
        let toolNames = tools.map(\.name).sorted()

        // Synthetic 1-step run — `buildTeamRolesLine` / `buildArtifactInstructions`
        // walk these structures.
        let step = StepExecution.make(for: roleDef)
        let run = Run(id: 0, steps: [step], teamID: team?.id)

        let teamRolesLine = buildTeamRolesLine(team: team, run: run)
        let teamDescriptionLine = buildTeamDescriptionLine(team: team)
        let positionContext = buildPositionContext(roleDefinition: roleDef, team: team)
        let (expectedArtifactsLine, artifactInstructionsBlock) = buildArtifactInstructions(
            step: step,
            teamArtifacts: team?.artifacts ?? []
        )
        let toolList = renderToolListPlaceholder(toolNames: toolNames)
        let hasFileReadTools = !Set(toolNames).isDisjoint(with: ToolHandlerRegistry.fileReadTools)
        let conversationMechanics = buildConversationMechanicsGuidance(hasFileReadTools: hasFileReadTools)
        let workFolderContext = buildWorkFolderContextMessage(
            workFolder: inputs.workFolder,
            agentInstructions: inputs.agentInstructions
        ) ?? ""
        let roleGuidance = wirePreviewStepRoleGuidance(role: roleDef, builtIn: role)

        return [
            "roleName": roleDef.name,
            "teamName": team?.name ?? "(unknown team)",
            "teamDescription": teamDescriptionLine,
            "teamRoles": teamRolesLine,
            // Runtime emits this exact string on first iteration of a 1-step
            // run — must match for byte parity.
            "stepInfo": "",  // retired chip — resolves empty (matches runtime)
            "positionContext": positionContext,
            "roleGuidance": roleGuidance,
            "conversationMechanics": conversationMechanics,
            // Backwards-compat alias for stored team templates created before the
            // 2026-05 rename — keeps the wire-preview byte-identical to runtime
            // on legacy teams.json files.
            "contextAwareness": conversationMechanics,
            "workFolderContext": workFolderContext,
            "toolList": toolList,
            "expectedArtifacts": expectedArtifactsLine,
            "artifactInstructions": artifactInstructionsBlock,
            "globalContext": PromptBuilder.formatGlobalContext(inputs.globalContext),
            "toolCalling": PromptBuilder.formatToolCallingBlock(tools: tools),
            // Backwards-compat alias for stored templates with the older
            // `{toolCallingBlock}` placeholder name.
            "toolCallingBlock": PromptBuilder.formatToolCallingBlock(tools: tools),
        ]
    }

    /// Consultation placeholder dictionary — mirrors the runtime
    /// `TeammateConsultationService.buildSystemPrompt`.
    private static func wirePreviewConsultationValues(inputs: WirePreviewInputs) -> [String: String] {
        let role = inputs.role
        let team = inputs.team
        return [
            "consultedRoleName": role.name,
            // Runtime resolves `{requestingRoleName}` generically: the persistent
            // consultation chat serves every requester and each question turn
            // names who is asking. Byte-identical to
            // `LLMExecutionService.buildConsultationSystemPrompt`.
            "requestingRoleName": "a teammate",
            // Consultation's role-guidance resolution returns roleDef.prompt
            // as-is (no trim+fallback for empty strings). Match it.
            "roleGuidance": wirePreviewCollaborationRoleGuidance(role: role, team: team),
            "teamDescription": team?.description ?? "",
            "globalContext": PromptBuilder.formatGlobalContext(inputs.globalContext),
        ]
    }

    /// Meeting placeholder dictionary — mirrors the runtime
    /// `MeetingStreamingService.buildSpeakerSystemPrompt`. Turn 1 baseline;
    /// `inputs.isCoordinator` toggles the coordinator vs non-coordinator
    /// branch. Late-meeting wrap-up / steering hints are runtime-dynamic and
    /// not previewable in this single-turn model.
    private static func wirePreviewMeetingValues(inputs: WirePreviewInputs) -> [String: String] {
        let role = inputs.role
        let team = inputs.team
        let tools = resolveWirePreviewTools(kind: .meeting, inputs: inputs)
        return [
            "speakerName": role.name,
            "roleGuidance": wirePreviewCollaborationRoleGuidance(role: role, team: team),
            "meetingTopic": "(example: meeting topic)",
            "turnNumber": "1",
            "coordinatorHint": inputs.isCoordinator
                ? "- As the coordinator, help guide the discussion toward a decision."
                : "",
            "teamDescription": team?.description ?? "",
            "globalContext": PromptBuilder.formatGlobalContext(inputs.globalContext),
            "toolCalling": PromptBuilder.formatToolCallingBlock(tools: tools),
            // Backwards-compat alias for stored templates with the older
            // `{toolCallingBlock}` placeholder name.
            "toolCallingBlock": PromptBuilder.formatToolCallingBlock(tools: tools),
        ]
    }

    /// Step-execution role guidance — trim + empty-fallback to
    /// `SystemTemplates.roles[builtIn.baseID].prompt`. Built-in roles with an
    /// empty `roleDefinition.prompt` still emit canonical guidance.
    private static func wirePreviewStepRoleGuidance(
        role: TeamRoleDefinition,
        builtIn: Role
    ) -> String {
        let trimmed = role.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return SystemTemplates.roles[builtIn.baseID]?.prompt ?? ""
    }

    /// Consultation / meeting role guidance — fall back to `SystemTemplates`
    /// ONLY when the role isn't in the team. Empty `role.prompt` returns "".
    /// Different from step execution's aggressive trim+fallback — both runtime
    /// builders match this contract.
    private static func wirePreviewCollaborationRoleGuidance(
        role: TeamRoleDefinition,
        team: Team?
    ) -> String {
        if team?.findRole(byIdentifier: role.id) != nil {
            return role.prompt
        }
        let builtIn = Role.fromDefinition(role)
        return SystemTemplates.roles[builtIn.baseID]?.prompt ?? ""
    }

    /// Production tool-resolution pipeline: `resolveToolSchemas` →
    /// `filterForDefaultStorage` → (for real folders) `filterForGitAvailability`.
    private static func runtimeToolPipeline(inputs: WirePreviewInputs) -> [ToolSchema] {
        let role = Role.fromDefinition(inputs.role)
        let raw = LLMExecutionService.resolveToolSchemas(
            for: role,
            team: inputs.team,
            allTeams: inputs.allTeams,
            selectedScheme: inputs.selectedScheme,
            isVisionConfigured: inputs.isVisionConfigured,
            isComputerUseEnabled: inputs.isComputerUseEnabled,
            // Sourced from the real projection (single source of truth) so the
            // Autovisor Manager role's create_managed_task preview stays
            // byte-identical to the wire when generation is disabled for the folder.
            autovisorAllowTeamGeneration: inputs.workFolder?.settings.autovisorAllowTeamGeneration ?? true
        )
        switch inputs.workFolderState {
        case .defaultStorage:
            return LLMExecutionService.filterForDefaultStorage(raw, isDefaultStorage: true)
        case .realFolder(let root):
            let filtered = LLMExecutionService.filterForDefaultStorage(raw, isDefaultStorage: false)
            return LLMExecutionService.filterForGitAvailability(filtered, workFolderRoot: root)
        }
    }

    /// Mirror of `TemplateResolver.stripOrphanHeaders` for `NSMutableAttributedString`.
    /// Fixed-point regex pass over the underlying string, deleting any `^## …\n`
    /// header line whose body is empty (only whitespace until the next `^##` or
    /// end-of-string). Chip attachments don't sit inside header lines so they're
    /// untouched.
    private static func stripOrphanHeadersInAttributed(_ mas: NSMutableAttributedString) {
        let pattern = #"(?m)^##[ \t]+[^\n]*\n[\s]*(?=^##[ \t]|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return
        }
        for _ in 0..<8 {
            let nsRange = NSRange(location: 0, length: (mas.string as NSString).length)
            let matches = regex.matches(in: mas.string, range: nsRange).reversed()
            guard !matches.isEmpty else { break }
            for match in matches {
                mas.replaceCharacters(in: match.range, with: "")
            }
        }
        // Trailing-header case (header line with no body till EOS).
        let trailingPattern = #"(?m)^##[ \t]+[^\n]*[\s]*\z"#
        if let trailingRegex = try? NSRegularExpression(pattern: trailingPattern, options: []) {
            let nsRange = NSRange(location: 0, length: (mas.string as NSString).length)
            let matches = trailingRegex.matches(in: mas.string, range: nsRange).reversed()
            for match in matches {
                mas.replaceCharacters(in: match.range, with: "")
            }
        }
    }

    /// Mirror of `TemplateResolver.stripOrphanInlineLabels` for
    /// `NSMutableAttributedString`. Strips `^Team purpose:[ \t]*$\n?` orphans
    /// left when `{teamDescription}` resolves to an empty string. The `$`
    /// end-of-line anchor ensures non-empty values are never stripped. Chip
    /// attachments don't sit inside this line shape (the label is plain
    /// template text), so they're untouched.
    private static func stripOrphanInlineLabelsInAttributed(_ mas: NSMutableAttributedString) {
        let pattern = #"(?m)^Team purpose:[ \t]*$\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return
        }
        let nsRange = NSRange(location: 0, length: (mas.string as NSString).length)
        let matches = regex.matches(in: mas.string, range: nsRange).reversed()
        for match in matches {
            mas.replaceCharacters(in: match.range, with: "")
        }
    }

    /// In-place trim of leading/trailing whitespace + newlines. Mirrors
    /// `String.trimmingCharacters(in: .whitespacesAndNewlines)` so attributed
    /// and plain renderers produce equivalent strings byte-for-byte after
    /// placeholder collapse leaves dangling padding around the body.
    private static func trimAttributedLeadingTrailingWhitespace(_ mas: NSMutableAttributedString) {
        let trimSet = CharacterSet.whitespacesAndNewlines
        let ns = mas.string as NSString
        var leading = 0
        while leading < ns.length,
              let scalar = (ns.substring(with: NSRange(location: leading, length: 1)).unicodeScalars.first),
              trimSet.contains(scalar) {
            leading += 1
        }
        var trailing = ns.length
        while trailing > leading,
              let scalar = (ns.substring(with: NSRange(location: trailing - 1, length: 1)).unicodeScalars.first),
              trimSet.contains(scalar) {
            trailing -= 1
        }
        // Trailing first so the leading range stays valid.
        if trailing < ns.length {
            mas.replaceCharacters(in: NSRange(location: trailing, length: ns.length - trailing), with: "")
        }
        if leading > 0 {
            mas.replaceCharacters(in: NSRange(location: 0, length: leading), with: "")
        }
    }

    /// In-place collapse of `\n{3,}` → `\n\n` on the attributed body.
    /// Reverse-walks matches so earlier ranges stay valid as the string shrinks.
    private static func collapseAttributedBlankLines(_ mas: NSMutableAttributedString) {
        // `try!` not `try?` — the pattern is a compile-time literal that
        // cannot fail to compile. Silent-skip-on-regex-failure would let an
        // unmaintained future change to the pattern silently desync the
        // attributed preview from the plain preview's blank-line collapse.
        let regex = try! NSRegularExpression(pattern: "\n{3,}")
        let fullRange = NSRange(location: 0, length: (mas.string as NSString).length)
        let matches = regex.matches(in: mas.string, range: fullRange).reversed()
        for match in matches {
            mas.replaceCharacters(in: match.range, with: "\n\n")
        }
    }
}
