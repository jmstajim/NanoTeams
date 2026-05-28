import XCTest
@testable import NanoTeams

/// Pin the wire-payload parity contract of `PromptBuilder.buildWirePromptPreview`.
///
/// The load-bearing invariant is `testStepExecutionPreview_byteIdenticalToWire`
/// — preview output must exactly equal `NativeChatRequest.systemPrompt` from
/// the same `(role, team, …)` inputs run through `NativeLMStudioClient.buildRequest`.
/// Every other test in this file pins a sub-contract that helps localize
/// regressions when the byte-identity assertion fails.
@MainActor
final class PromptBuilderWirePreviewTests: XCTestCase {

    var faang: Team!
    var codingAgent: Team!
    var allTeams: [Team]!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        faang = TeamTemplateFactory.faang()
        codingAgent = TeamTemplateFactory.codingAgent()
        allTeams = TeamTemplateFactory.allTemplates
    }

    override func tearDown() {
        faang = nil
        codingAgent = nil
        allTeams = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeInputs(
        role: TeamRoleDefinition,
        team: Team?,
        workFolder: WorkFolderProjection? = nil,
        workFolderRoot: URL? = nil,
        isDefaultStorage: Bool = true,
        selectedScheme: String? = nil,
        isVisionConfigured: Bool = false,
        globalContext: String = "One tool call per response.",
        isCoordinator: Bool = false
    ) -> PromptBuilder.WirePreviewInputs {
        // Translate the (URL?, Bool) tuple test helpers use into the typed
        // `WorkFolderState` enum the production API now requires. Tests with
        // historical inputs continue to compile unchanged.
        let state: PromptBuilder.WireWorkFolder
        if let root = workFolderRoot, !isDefaultStorage {
            state = .realFolder(root: root)
        } else {
            state = .defaultStorage
        }
        return PromptBuilder.WirePreviewInputs(
            role: role,
            team: team,
            allTeams: allTeams ?? [],
            workFolder: workFolder,
            workFolderState: state,
            selectedScheme: selectedScheme,
            isVisionConfigured: isVisionConfigured,
            globalContext: globalContext,
            isCoordinator: isCoordinator
        )
    }

    /// Build the actual wire system_prompt string the same way `FirstPromptRenderer.run`
    /// does for an in-memory team/role. Used as the ground-truth comparand
    /// for `testStepExecutionPreview_byteIdenticalToWire`.
    private func buildProductionWireSystemPrompt(
        team: Team,
        roleDefinition: TeamRoleDefinition,
        inputs: PromptBuilder.WirePreviewInputs
    ) -> String {
        let role = Role.fromDefinition(roleDefinition)
        let raw = LLMExecutionService.resolveToolSchemas(
            for: role,
            team: team,
            allTeams: inputs.allTeams,
            selectedScheme: inputs.selectedScheme,
            isVisionConfigured: inputs.isVisionConfigured
        )
        let tools: [ToolSchema]
        switch inputs.workFolderState {
        case .defaultStorage:
            tools = LLMExecutionService.filterForDefaultStorage(raw, isDefaultStorage: true)
        case .realFolder(let root):
            let filtered = LLMExecutionService.filterForDefaultStorage(raw, isDefaultStorage: false)
            tools = LLMExecutionService.filterForGitAvailability(filtered, workFolderRoot: root)
        }

        let step = StepExecution.make(for: roleDefinition)
        let run = Run(id: 0, steps: [step], teamID: team.id)
        let task = NTMSTask(id: 0, title: "preview", supervisorTask: "", runs: [run], preferredTeamID: team.id)

        let context = PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: 0,
            run: run,
            workFolder: inputs.workFolder,
            artifactReader: { _ in nil },
            activeTeam: team,
            roleDefinition: roleDefinition,
            globalContext: inputs.globalContext
        )
        let messages = PromptBuilder.buildChatMessages(context: context, tools: tools)
        let llmConfig = LLMConfig(
            provider: .lmStudio,
            baseURLString: LLMProvider.lmStudio.defaultBaseURL,
            modelName: "test-model",
            maxTokens: 2048,
            temperature: 0.0
        )
        let request = NativeLMStudioClient.buildRequest(
            config: llmConfig,
            messages: messages,
            tools: tools,
            session: nil
        )
        return request.systemPrompt ?? ""
    }

    // MARK: - Byte-identity parity (load-bearing)

    func testStepExecutionPreview_byteIdenticalToWire_codingAgent() throws {
        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(role: role, team: codingAgent)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
        let wire = buildProductionWireSystemPrompt(team: codingAgent, roleDefinition: role, inputs: inputs)

        XCTAssertEqual(preview, wire, "Preview must equal wire systemPrompt byte-for-byte")
    }

    func testStepExecutionPreview_byteIdenticalToWire_faangPM() throws {
        let pm = faang.roles.first(where: { $0.name == "Product Manager" })!
        let inputs = makeInputs(role: pm, team: faang)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
        let wire = buildProductionWireSystemPrompt(team: faang, roleDefinition: pm, inputs: inputs)

        XCTAssertEqual(preview, wire)
    }

    /// Production shape: real work folder URL pointing at a git repo, full
    /// toolset survives both default-storage and git filters. Previous
    /// byte-identity tests run with `isDefaultStorage: true` + `workFolderRoot:
    /// nil` — the most stripped state. This test covers the un-stripped path.
    func testStepExecutionPreview_byteIdenticalToWire_realWorkFolderWithGit() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wire-preview-real-wf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(
            role: role,
            team: codingAgent,
            workFolderRoot: tmp,
            isDefaultStorage: false,
            selectedScheme: "NanoTeams",
            isVisionConfigured: true
        )

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
        let wire = buildProductionWireSystemPrompt(team: codingAgent, roleDefinition: role, inputs: inputs)

        XCTAssertEqual(preview, wire,
                       "Preview must equal wire systemPrompt with real WF / git / scheme / vision enabled")
    }

    /// Byte-identity for the consultation kind. Builds the runtime body by
    /// constructing the placeholders dict the same way
    /// `TeammateConsultationService.buildSystemPrompt` does and running it
    /// through `TemplateResolver.resolveSystemPrompt` — the exact helper the
    /// runtime now uses too. Verifies the preview's value-builder matches the
    /// runtime's, including the `getRolePrompt` (no aggressive empty-fallback)
    /// contract that differs from step execution.
    func testConsultationPreview_byteIdenticalToWire() throws {
        let pm = faang.roles.first(where: { $0.name == "Product Manager" })!
        let inputs = makeInputs(role: pm, team: faang)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .consultation, inputs: inputs)

        // Construct the runtime-equivalent placeholders using the same
        // synthetic requesting role the wire-preview uses (first non-consulted
        // non-supervisor role per `syntheticRequestingRoleName`).
        let candidates = faang.nonSupervisorRoles.filter { $0.id != pm.id }
        let requestingName = candidates.first?.name ?? "(example: requesting role)"
        let placeholders: [String: String] = [
            "consultedRoleName": pm.name,
            "requestingRoleName": requestingName,
            "roleGuidance": pm.prompt,
            "teamDescription": faang.description,
            "globalContext": PromptBuilder.formatGlobalContext(inputs.globalContext),
        ]
        let runtimeBody = TemplateResolver.resolveSystemPrompt(
            faang.consultationPromptTemplate,
            placeholders: placeholders,
            globalContext: inputs.globalContext
        )
        // Consultation passes `tools: []` to the LLM client — no Harmony block.
        XCTAssertEqual(preview, runtimeBody,
                       "Consultation preview must equal runtime system_prompt byte-for-byte")
    }

    /// Byte-identity for the meeting kind, non-coordinator role at turn 1.
    /// The runtime's `MeetingStreamingService.buildSpeakerSystemPrompt`
    /// produces `coordinatorHint = ""` for this combination — matches the
    /// wire-preview's default.
    func testMeetingPreview_byteIdenticalToWire_nonCoordinator() throws {
        let pm = faang.roles.first(where: { $0.name == "Product Manager" })!
        let inputs = makeInputs(role: pm, team: faang)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .meeting, inputs: inputs)

        // Mirror MeetingStreamingService runtime placeholders for non-coordinator.
        // 2026-05 chip-format contract: chips resolve to BARE BODIES. The
        // `## Global guidance` / `## Tool Calling` headers live in the template.
        let filteredTools = PromptBuilder.resolveWirePreviewTools(kind: .meeting, inputs: inputs)
        let placeholders: [String: String] = [
            "speakerName": pm.name,
            "roleGuidance": pm.prompt,
            "meetingTopic": "(example: meeting topic)",
            "turnNumber": "1",
            "coordinatorHint": "",  // non-coordinator → empty
            "teamDescription": faang.description,
            "globalContext": PromptBuilder.formatGlobalContext(inputs.globalContext),
            "toolCalling": PromptBuilder.formatToolCallingBlock(tools: filteredTools),
        ]
        let expectedWire = TemplateResolver.resolveSystemPrompt(
            faang.meetingPromptTemplate,
            placeholders: placeholders,
            globalContext: inputs.globalContext
        )

        XCTAssertEqual(preview, expectedWire,
                       "Meeting preview (non-coordinator, turn 1) must equal runtime system_prompt byte-for-byte")
    }

    /// Byte-identity for the meeting kind, **coordinator role at turn 1**.
    /// Runtime emits `coordinatorHint = "- As the coordinator, help guide..."`
    /// for this case (per MeetingStreamingService:142-143). The wire-preview
    /// must replicate this branching when `inputs.isCoordinator` is set.
    func testMeetingPreview_byteIdenticalToWire_coordinatorAtTurn1() throws {
        let coordinator = faang.roles.first(where: { $0.name == "Tech Lead" })!
        let inputs = makeInputs(role: coordinator, team: faang, isCoordinator: true)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .meeting, inputs: inputs)

        // Mirror MeetingStreamingService.buildSpeakerSystemPrompt's branching:
        // turn 1, isCoordinator=true, typical maxMeetingTurns (8) → falls
        // through to the "help guide the discussion" hint. Meeting template
        // now resolves `{globalContext}` + `{toolCallingBlock}` inline — no
        // separate Harmony append step.
        let filteredTools = PromptBuilder.resolveWirePreviewTools(kind: .meeting, inputs: inputs)
        let placeholders: [String: String] = [
            "speakerName": coordinator.name,
            "roleGuidance": coordinator.prompt,
            "meetingTopic": "(example: meeting topic)",
            "turnNumber": "1",
            "coordinatorHint": "- As the coordinator, help guide the discussion toward a decision.",
            "teamDescription": faang.description,
            "globalContext": PromptBuilder.formatGlobalContext(inputs.globalContext),
            "toolCalling": PromptBuilder.formatToolCallingBlock(tools: filteredTools),
        ]
        let expectedWire = TemplateResolver.resolveSystemPrompt(
            faang.meetingPromptTemplate,
            placeholders: placeholders,
            globalContext: inputs.globalContext
        )

        XCTAssertEqual(preview, expectedWire,
                       "Meeting preview as coordinator must emit the runtime coordinatorHint")
    }

    /// Smoke test — `team: nil` should fall through to `genericTemplate` and
    /// render without crashing or leaking literal `{key}` markers. The
    /// genericTemplate doesn't use `{teamName}` (only `{teamRoles}` /
    /// `{teamDescription}` / `{positionContext}`), so the assertion is on
    /// "no literal placeholder leaks" + "the role name appears" rather than
    /// a specific fallback string.
    func testStepExecutionPreview_nilTeam_doesNotCrash() throws {
        let role = TeamRoleDefinition(
            id: "orphan_role",
            name: "Orphan",
            prompt: "Stub guidance.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let inputs = makeInputs(role: role, team: nil)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
        XCTAssertFalse(preview.isEmpty, "Preview must render content for team: nil")
        XCTAssertTrue(preview.contains("Orphan"),
                      "team: nil should still resolve `{roleName}` to the supplied role's display name")
        for literal in ["{roleName}", "{teamName}", "{teamRoles}", "{roleGuidance}", "{toolCalling}"] {
            XCTAssertFalse(preview.contains(literal),
                           "team: nil must not leak literal placeholder \(literal)")
        }
    }

    // MARK: - Auto-injection

    func testStepExecutionPreview_includesAutoInjectedAskSupervisor() throws {
        // Coding Agent (advisory, non-supervisor, no producesArtifacts) — runtime
        // auto-injects ask_supervisor via shouldAutoInjectAskSupervisor.
        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(role: role, team: codingAgent)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)

        XCTAssertTrue(preview.contains("**ask_supervisor**"),
                      "Auto-injected ask_supervisor must appear in the Harmony block")
    }

    func testStepExecutionPreview_includesAutoInjectedCreateArtifact() throws {
        // PM produces "Product Requirements" → runtime auto-injects create_artifact.
        let pm = faang.roles.first(where: { $0.name == "Product Manager" })!
        let inputs = makeInputs(role: pm, team: faang)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)

        XCTAssertTrue(preview.contains("**create_artifact**"),
                      "Auto-injected create_artifact must appear in the Harmony block")
        // The per-role schema constrains `name` enum to expected artifacts.
        XCTAssertTrue(preview.contains("Product Requirements"),
                      "create_artifact's name enum should inline the role's expected artifact")
    }

    func testStepExecutionPreview_includesDelegationPackForCodingAgent() throws {
        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(role: role, team: codingAgent)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)

        XCTAssertTrue(preview.contains("**delegate_to_team**"))
        XCTAssertTrue(preview.contains("**cancel_delegation**"))
        XCTAssertTrue(preview.contains("**resume_delegation**"))
        XCTAssertTrue(preview.contains("**forward_to_team**"))
    }

    // MARK: - Filter strips

    func testStepExecutionPreview_stripsXcodebuildWhenNoScheme() throws {
        // TL has run_xcodebuild in its toolIDs; with selectedScheme == nil it
        // gets stripped by resolveToolSchemas.
        let tl = faang.roles.first(where: { $0.name == "Tech Lead" })!
        let inputs = makeInputs(role: tl, team: faang, selectedScheme: nil)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)

        XCTAssertFalse(preview.contains("**run_xcodebuild**"))
        XCTAssertFalse(preview.contains("**run_xcodetests**"))
    }

    func testStepExecutionPreview_stripsAnalyzeImageWhenVisionOff() throws {
        // analyze_image is in tool registry but resolveToolSchemas drops it
        // when isVisionConfigured == false.
        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(role: role, team: codingAgent, isVisionConfigured: false)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)

        XCTAssertFalse(preview.contains("**analyze_image**"))
    }

    func testStepExecutionPreview_stripsGitWhenNoGitDir() throws {
        // Create a tmp dir with no .git → filterForGitAvailability strips git tools.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(
            role: role,
            team: codingAgent,
            workFolderRoot: tmp,
            isDefaultStorage: false
        )

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)

        XCTAssertFalse(preview.contains("**git_status**"))
        XCTAssertFalse(preview.contains("**git_log**"))
        XCTAssertFalse(preview.contains("**git_diff**"))
    }

    func testStepExecutionPreview_defaultStorageStripsBlockedTools() throws {
        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(role: role, team: codingAgent, isDefaultStorage: true)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)

        // ToolHandlerRegistry.defaultStorageBlocked covers writes/git/xcode.
        for blocked in ToolHandlerRegistry.defaultStorageBlocked {
            XCTAssertFalse(
                preview.contains("**\(blocked)**"),
                "Default storage must strip \(blocked) from the Harmony block"
            )
        }
    }

    // MARK: - Consultation

    func testConsultationPreview_noToolBlock() throws {
        let role = faang.roles.first(where: { $0.name == "Product Manager" })!
        let inputs = makeInputs(role: role, team: faang)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .consultation, inputs: inputs)

        XCTAssertFalse(preview.contains("## Tool Calling"),
                       "Consultations send tools: [] — no Harmony block")
        XCTAssertFalse(preview.contains("<|call|>"))
    }

    func testConsultationPreview_synthesizesRequestingRole_multiRoleTeam() throws {
        let pm = faang.roles.first(where: { $0.name == "Product Manager" })!
        let inputs = makeInputs(role: pm, team: faang)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .consultation, inputs: inputs)

        // The synthetic requestingRoleName is the first non-consulted
        // non-supervisor role. For FAANG with PM consulted, that's whichever
        // appears first after PM in nonSupervisorRoles.
        let candidates = faang.nonSupervisorRoles.filter { $0.id != pm.id }
        let expected = candidates.first!.name
        XCTAssertTrue(preview.contains(expected),
                      "Expected requestingRoleName=\(expected) in preview")
        XCTAssertFalse(preview.contains("(example: requesting role)"),
                       "Multi-role team should use a real teammate name, not the fallback")
    }

    func testConsultationPreview_synthesizesRequestingRole_singleRoleTeam() throws {
        // Build a single-role team so the synthesizer hits the fallback branch.
        var soloTeam = TeamTemplateFactory.codingAssistant()
        let solo = soloTeam.nonSupervisorRoles.first!
        // Strip every other role so only one remains.
        soloTeam.roles = soloTeam.roles.filter { $0.id == solo.id || $0.name == "Supervisor" }

        let inputs = makeInputs(role: solo, team: soloTeam)
        let preview = try PromptBuilder.buildWirePromptPreview(kind: .consultation, inputs: inputs)

        XCTAssertTrue(preview.contains("(example: requesting role)"))
    }

    // MARK: - Meeting

    func testMeetingPreview_excludesMeetingFilteredTools() throws {
        // Pick a FAANG role that has meeting-excluded tools in its set.
        let pm = faang.roles.first(where: { $0.name == "Product Manager" })!
        let inputs = makeInputs(role: pm, team: faang)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .meeting, inputs: inputs)

        // Every tool in MeetingCoordinator.meetingExcludedTools must NOT appear
        // in the Harmony block.
        for excluded in MeetingCoordinator.meetingExcludedTools {
            XCTAssertFalse(
                preview.contains("**\(excluded)**"),
                "Meeting filter must strip \(excluded) from the Harmony block"
            )
        }
    }

    func testMeetingPreview_meetingTopicIsExampleString() throws {
        let role = faang.nonSupervisorRoles.first!
        let inputs = makeInputs(role: role, team: faang)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .meeting, inputs: inputs)

        XCTAssertTrue(preview.contains("(example: meeting topic)"))
    }

    // MARK: - All-kinds invariants

    func testAllKinds_globalContextAppended() throws {
        let role = codingAgent.nonSupervisorRoles.first!
        let marker = "GlobalContextMarker_8a3f"
        let inputs = makeInputs(role: role, team: codingAgent, globalContext: marker)

        for kind in [WirePromptKind.stepExecution, .consultation, .meeting] {
            let preview = try PromptBuilder.buildWirePromptPreview(kind: kind, inputs: inputs)
            // After 2026-05 chip-format contract: templates wrap the chip as
            // `## Global guidance\n{globalContext}` (single \n — Swift literal
            // indentation), so the resolved value sits right under the header.
            XCTAssertTrue(
                preview.contains("## Global guidance\n" + marker),
                "\(kind): globalContext should appear under the `## Global guidance` header; got:\n\(preview)"
            )
        }
    }

    func testAllKinds_blankLineCollapse_noLiteralPlaceholder() throws {
        // Empty workFolder => {workFolderContext} resolves to "" and
        // collapseBlankLines must remove the resulting triple-newline runs
        // from the **body**. The Harmony tool block can legitimately contain
        // `\n\n\n` runs (e.g. before the tail operational reminder) — that's
        // wire-payload content, not template-resolution slop.
        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(role: role, team: codingAgent, workFolder: nil)

        for kind in [WirePromptKind.stepExecution, .consultation, .meeting] {
            let preview = try PromptBuilder.buildWirePromptPreview(kind: kind, inputs: inputs)
            let body = bodyBeforeFooters(preview)
            XCTAssertFalse(body.contains("\n\n\n"),
                           "\(kind): no triple-newline runs in template body after collapse — got\n\(body)")
            XCTAssertFalse(preview.contains("{workFolderContext}"),
                           "\(kind): no literal placeholder should leak")
        }
    }

    /// Returns the substring of `preview` before the globalContext footer
    /// (`\n\n## Global guidance`) or the Harmony tool block (`\n\n## Tool Calling`),
    /// whichever appears first. Tool blocks contain legitimate `\n\n\n` runs
    /// the `collapseBlankLines` pass doesn't (and shouldn't) touch.
    private func bodyBeforeFooters(_ preview: String) -> String {
        let footers = [
            preview.range(of: "\n\n## Global guidance"),
            preview.range(of: "\n\n## Tool Calling"),
        ].compactMap { $0?.lowerBound }
        guard let earliest = footers.min() else { return preview }
        return String(preview[..<earliest])
    }

    // MARK: - roleGuidance fallback

    func testStepExecutionPreview_emptyRoleGuidance_fallsBackToSystemTemplate() throws {
        var role = faang.roles.first(where: { $0.name == "Product Manager" })!
        role.prompt = ""
        // Replace the PM in the team so findRole(byIdentifier:) returns the empty-prompt version.
        var team = faang!
        if let idx = team.roles.firstIndex(where: { $0.id == role.id }) {
            team.roles[idx] = role
        }
        let inputs = makeInputs(role: role, team: team)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)

        // Step-execution path uses PromptBuilder.rolePrompt's trim+fallback chain.
        // For PM, the canonical SystemTemplates fallback prompt contains a known
        // distinctive substring — assert against it indirectly via "the prompt
        // is non-empty in the rendered output."
        let builtIn = Role.fromDefinition(role)
        let expectedFallback = SystemTemplates.roles[builtIn.baseID]?.prompt ?? ""
        XCTAssertFalse(expectedFallback.isEmpty, "Test invariant: PM should have a SystemTemplates fallback")
        // Take a stable sentence from the fallback and assert it appears in the
        // preview (substring match — exact rendering depends on the template
        // layout). Use the first ~40 chars trimmed.
        let head = String(expectedFallback.prefix(40))
        XCTAssertTrue(preview.contains(head),
                      "Step preview should fall back to SystemTemplates.roles[builtIn.baseID].prompt")
    }

    // MARK: - Generated Team

    func testGeneratedTeam_buildWirePromptPreview_throws() {
        var generated = TeamTemplateFactory.generatedTeam()
        // generatedTeam() returns the placeholder with templateID == "generated".
        XCTAssertEqual(generated.templateID, "generated", "Test invariant: factory should mark it generated")
        // The placeholder ships without non-supervisor roles, so synthesize one
        // for the call site.
        let stub = TeamRoleDefinition(
            id: "stub",
            name: "Stub",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        generated.roles.append(stub)
        let inputs = makeInputs(role: stub, team: generated)

        XCTAssertThrowsError(
            try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
        ) { error in
            XCTAssertEqual(error as? PromptBuilder.WirePreviewError, .generatedTeamNotRenderable)
        }
    }

    /// Parallel coverage for the attributed renderer — without this, a future
    /// regression that drops `guardRenderable` from the attributed path would
    /// land a generated-team preview silently (UI's `WirePreviewUnavailableView`
    /// branch is gated on the error, so a non-throw renders a meaningless body).
    func testGeneratedTeam_buildWirePromptPreviewAttributed_throws() {
        var generated = TeamTemplateFactory.generatedTeam()
        let stub = TeamRoleDefinition(
            id: "stub",
            name: "Stub",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        generated.roles.append(stub)
        let inputs = makeInputs(role: stub, team: generated)

        XCTAssertThrowsError(
            try PromptBuilder.buildWirePromptPreviewAttributed(kind: .stepExecution, inputs: inputs)
        ) { error in
            XCTAssertEqual(error as? PromptBuilder.WirePreviewError, .generatedTeamNotRenderable)
        }
    }

    /// Pin the user-facing copy that `WirePreviewUnavailableView` displays — a
    /// silent edit to this string would change visible UI text with no other
    /// surface stopping it.
    func testWirePreviewError_descriptionPinsUserVisibleCopy() {
        let cases: [PromptBuilder.WirePreviewError] = [
            .generatedTeamNotRenderable,
            .roleNotFoundInTeam(roleID: "stale_id", teamName: "FAANG"),
        ]
        for error in cases {
            XCTAssertFalse(error.description.isEmpty,
                           "\(error): description must be non-empty user-visible text")
        }
        XCTAssertTrue(
            PromptBuilder.WirePreviewError.generatedTeamNotRenderable.description.contains("Generated Team"),
            "generatedTeamNotRenderable description must name the placeholder"
        )
        let roleErr = PromptBuilder.WirePreviewError.roleNotFoundInTeam(roleID: "abc123", teamName: "FAANG")
        XCTAssertTrue(roleErr.description.contains("abc123"), "Must include the missing role id")
        XCTAssertTrue(roleErr.description.contains("FAANG"), "Must include the team name")
    }

    // MARK: - Attributed / plain equivalence

    func testAttributedAndPlain_textEquivalent() throws {
        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(role: role, team: codingAgent)

        for kind in [WirePromptKind.stepExecution, .consultation, .meeting] {
            let plain = try PromptBuilder.buildWirePromptPreview(kind: kind, inputs: inputs)
            let attributed = try PromptBuilder.buildWirePromptPreviewAttributed(kind: kind, inputs: inputs)
            XCTAssertEqual(plain, attributed.string,
                           "\(kind): attributed.string should equal plain output")
        }
    }

    /// Matrix coverage — the plain path uses `TemplateResolver.appendingSeparator`
    /// + `appendingToolBlock`; the attributed path appends separator / tool
    /// block as monospaced runs. Both assembly paths are structurally distinct
    /// — equality only holds because they produce identical strings. A
    /// regression where one path emits an extra newline or skips collapse
    /// would silently desync. Cover `globalContext × kind` combinations:
    /// empty / whitespace-only / non-empty globalContext × all 3 kinds.
    func testAttributedAndPlain_textEquivalent_globalContextMatrix() throws {
        let role = codingAgent.nonSupervisorRoles.first!
        let globalContexts = ["", "   \n\n  ", "Real global context."]
        let kinds: [WirePromptKind] = [.stepExecution, .consultation, .meeting]

        for global in globalContexts {
            for kind in kinds {
                let inputs = makeInputs(role: role, team: codingAgent, globalContext: global)
                let plain = try PromptBuilder.buildWirePromptPreview(kind: kind, inputs: inputs)
                let attributed = try PromptBuilder.buildWirePromptPreviewAttributed(kind: kind, inputs: inputs)
                XCTAssertEqual(
                    plain, attributed.string,
                    "kind=\(kind), globalContext=\(global.debugDescription): plain/attributed must match"
                )
            }
        }
    }

    /// Pin the contract that whitespace-only / empty `globalContext` produces
    /// NO `## Global guidance` footer. Deleted suite covered this for the old
    /// API; the new renderer's `TemplateResolver.appendingSeparator` already
    /// enforces it (trims + early-returns), but a regression that bypasses
    /// the helper would otherwise ship.
    func testAttributedAndPlain_emptyGlobalContext_omitsSeparator() throws {
        let role = codingAgent.nonSupervisorRoles.first!

        for global in ["", "   ", "\n\n   \n"] {
            let inputs = makeInputs(role: role, team: codingAgent, globalContext: global)
            for kind in [WirePromptKind.stepExecution, .consultation, .meeting] {
                let plain = try PromptBuilder.buildWirePromptPreview(kind: kind, inputs: inputs)
                let attributed = try PromptBuilder.buildWirePromptPreviewAttributed(kind: kind, inputs: inputs)
                XCTAssertFalse(plain.contains("## Global guidance"),
                               "\(kind), global=\(global.debugDescription): plain must not emit `## Global guidance` footer")
                XCTAssertFalse(attributed.string.contains("## Global guidance"),
                               "\(kind), global=\(global.debugDescription): attributed must not emit `## Global guidance` footer")
            }
        }
    }

    // MARK: - WirePreviewRender enum

    /// `WirePreviewRender` is an enum — `.notRendered`, `.success(plain, attributed)`,
    /// `.failure(error)`. Constructors enforce mutual exclusivity (error XOR
    /// content) at the type level; the previous 3-`var` struct allowed
    /// `error != nil` together with non-empty content.
    func testWirePreviewRender_successCarriesBothEncodings() {
        let plain = "hello"
        let attr = NSAttributedString(string: "hello")
        let render = WirePreviewRender.success(plain: plain, attributed: attr)
        if case .success(let p, let a) = render {
            XCTAssertEqual(p, plain)
            XCTAssertEqual(a, attr)
        } else {
            XCTFail("Expected .success case")
        }
    }

    func testWirePreviewRender_failureCarriesError() {
        let render = WirePreviewRender.failure(.generatedTeamNotRenderable)
        if case .failure(let err) = render {
            XCTAssertEqual(err, .generatedTeamNotRenderable)
        } else {
            XCTFail("Expected .failure case")
        }
    }

    func testWirePreviewRender_notRendered_isDistinctFromSuccessOfEmpty() {
        let notRendered = WirePreviewRender.notRendered
        let emptySuccess = WirePreviewRender.success(plain: "", attributed: NSAttributedString())
        if case .notRendered = notRendered {} else {
            XCTFail("Expected .notRendered case")
        }
        if case .success = emptySuccess {} else {
            XCTFail("Expected .success case (empty content is still success)")
        }
    }

    // MARK: - WorkFolderState

    /// `WorkFolderState.defaultStorage` collapses the previous `(workFolderRoot: nil,
    /// isDefaultStorage: true)` shape into a single case. Skips git filtering
    /// and routes through `filterForDefaultStorage` (which strips write/git/xcode tools).
    func testWorkFolderState_defaultStorage_stripsBlockedTools() throws {
        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(role: role, team: codingAgent)
        XCTAssertEqual(inputs.workFolderState, PromptBuilder.WireWorkFolder.defaultStorage,
                       "makeInputs defaults should collapse to .defaultStorage")
        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
        for blocked in ToolHandlerRegistry.defaultStorageBlocked {
            XCTAssertFalse(preview.contains("**\(blocked)**"),
                           "default-storage state must strip \(blocked)")
        }
    }

    /// `WorkFolderState.realFolder(root:)` carries the URL — git filter only
    /// runs in this case (so the previous `if let workFolderRoot` dance is
    /// gone from `runtimeToolPipeline`).
    func testWorkFolderState_realFolder_carriesURL() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-state-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let role = codingAgent.nonSupervisorRoles.first!
        let inputs = makeInputs(
            role: role,
            team: codingAgent,
            workFolderRoot: tmp,
            isDefaultStorage: false
        )
        XCTAssertEqual(inputs.workFolderState, PromptBuilder.WireWorkFolder.realFolder(root: tmp),
                       "URL+isDefaultStorage:false must collapse to .realFolder(root:)")
        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
        // No .git in the tmp dir → git tools stripped.
        XCTAssertFalse(preview.contains("**git_status**"))
    }

    // MARK: - Empty tools

    // MARK: - Issue 1: attributed/plain parity for empty-template edge case

    /// When `template == ""` and tools are non-empty:
    /// - Plain path: `resolveSystemPrompt("", ...)` → `""`, then `appendingToolBlock`
    ///   appends the full Harmony block → final = `## Tool Calling\n\n<body>`.
    /// - Attributed path: body is empty, then the auto-append should fire
    ///   (mirror the plain path's contract) → final = same.
    ///
    /// Pre-fix the attributed path's tool-block guard checked
    /// `result.length > 0` for the separator — so an empty body kept length 0
    /// and the auto-append still fired correctly. But the documented
    /// byte-parity contract is fragile here; this pin ensures both paths
    /// produce identical output for the "fully cleared template" case.
    func testEmptyTemplate_withTools_attributedAndPlainParity() throws {
        // Use a team with empty system prompt template to force the edge case.
        // codingAgent fixture is convenient — we override its system prompt to empty.
        var team = codingAgent!
        team.systemPromptTemplate = ""
        let role = team.nonSupervisorRoles.first!
        let inputs = makeInputs(role: role, team: team)

        let plain = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
        let attributed = try PromptBuilder.buildWirePromptPreviewAttributed(kind: .stepExecution, inputs: inputs)
        XCTAssertEqual(plain, attributed.string,
                       "Attributed and plain renderers must match byte-for-byte even when template is empty")

        // Additionally pin that the tool block IS in the output — empty
        // template + tools should NOT silently drop the Harmony spec.
        XCTAssertTrue(plain.contains("Call tools using this Harmony format:"),
                      "Empty template with tools must still ship the Harmony body. Got:\n\(plain)")
    }

    func testEmptyToolList_emitsNoToolsNoticeNotHarmony() throws {
        // Supervisor stub in any team has empty toolIDs and is filtered as a
        // role anyway. Use a custom role with no tools and no producesArtifacts
        // (no auto-injection triggers).
        let role = TeamRoleDefinition(
            id: "no_tools_role",
            name: "No Tools",
            prompt: "Stub.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        var team = TeamTemplateFactory.codingAssistant()
        team.roles.append(role)
        let inputs = makeInputs(role: role, team: team)

        let preview = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)

        // 2026-05 merged contract: the template's `## Tool Calling` section
        // ALWAYS ships (header lives in template); the `{toolCalling}` chip
        // resolves to "None available..." when tools is empty or to the
        // Harmony block when tools are present.
        let tools = PromptBuilder.resolveWirePreviewTools(kind: .stepExecution, inputs: inputs)
        XCTAssertTrue(preview.contains("## Tool Calling"),
                      "template's `## Tool Calling` header ships unconditionally")
        if tools.isEmpty {
            XCTAssertTrue(preview.contains("None available"),
                          "empty-tools branch must ship the bare 'None available' notice")
            XCTAssertFalse(preview.contains("Call tools using this Harmony format"),
                           "Harmony preamble must not ship when role has no tools")
        } else {
            XCTAssertTrue(preview.contains("Call tools using this Harmony format"),
                          "non-empty tools must ship the Harmony preamble")
        }
    }

    // MARK: - 2026-05: `Team purpose:` label is plain, value is coloured

    /// Regression pin for the chip-rendering refactor: in the attributed
    /// step-execution preview, the literal `Team purpose: ` label MUST carry
    /// the default text colour (`Colors.nsTextPrimary`), and the resolved
    /// description that follows MUST carry the `"role"` category colour
    /// (`PlaceholderAttachment.color(for: "role")`).
    ///
    /// Before the refactor, the label was baked into the `{teamDescription}`
    /// value and the parser coloured the whole run — making the label
    /// visually inconsistent with `Members:` / `Your position:`.
    func testStepExecutionPreviewAttributed_teamPurposeLabel_isPlainColour_valueIsColoured() throws {
        let pm = faang.roles.first(where: { $0.name == "Product Manager" })!
        let inputs = makeInputs(role: pm, team: faang, globalContext: "")

        let attributed = try PromptBuilder.buildWirePromptPreviewAttributed(
            kind: .stepExecution,
            inputs: inputs
        )
        let ns = attributed.string as NSString

        // Locate the literal `Team purpose: ` label. Anchored on the
        // preceding newline so role guidance or other resolved values that
        // happen to mention the substring inside a sentence can't be sampled
        // here by accident.
        let anchorRange = ns.range(of: "\nTeam purpose: ")
        XCTAssertTrue(anchorRange.location != NSNotFound,
                      "preview must render `Team purpose: ` as a template-text line")
        // Skip the leading `\n` so `labelStart` lands on the `T` of the label.
        let labelStart = anchorRange.location + 1

        // Label colour — sample the foreground at the label's first char.
        let labelAttrs = attributed.attributes(at: labelStart, effectiveRange: nil)
        let labelColour = labelAttrs[.foregroundColor] as? NSColor
        XCTAssertEqual(labelColour, Colors.nsTextPrimary,
                       "`Team purpose:` label must render in default text colour, "
                       + "not the `\"role\"` category colour")

        // Value colour — sample the foreground immediately after the label.
        // The team description starts after `\nTeam purpose: ` (15 chars including
        // the leading newline; `anchorRange.length - 1` excludes the newline).
        let valueStart = labelStart + (anchorRange.length - 1)
        XCTAssertLessThan(valueStart, attributed.length,
                          "label must be followed by the resolved description text")
        let valueAttrs = attributed.attributes(at: valueStart, effectiveRange: nil)
        let valueColour = valueAttrs[.foregroundColor] as? NSColor
        XCTAssertEqual(valueColour, PlaceholderAttachment.color(for: "role"),
                       "resolved `{teamDescription}` value must carry the `\"role\"` "
                       + "category colour (indigo)")
    }

    /// Empty `team.description` MUST NOT leave an orphan `Team purpose:` label
    /// in the attributed preview — `stripOrphanInlineLabelsInAttributed`
    /// mirrors the plain-path strip.
    func testStepExecutionPreviewAttributed_emptyTeamDescription_noOrphanLabel() throws {
        // Clone FAANG with an empty description.
        var team = faang!
        team.description = ""
        let pm = team.roles.first(where: { $0.name == "Product Manager" })!
        let inputs = makeInputs(role: pm, team: team, globalContext: "")

        let attributed = try PromptBuilder.buildWirePromptPreviewAttributed(
            kind: .stepExecution,
            inputs: inputs
        )
        XCTAssertFalse(attributed.string.contains("Team purpose:"),
                       "orphan `Team purpose:` label must be stripped from the "
                       + "attributed preview when `team.description` is empty. "
                       + "Got:\n\(attributed.string)")
    }

}
