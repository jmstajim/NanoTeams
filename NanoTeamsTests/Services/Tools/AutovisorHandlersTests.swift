import XCTest
@testable import NanoTeams

/// In-handler argument validation + signal emission for the 9 Autovisor
/// management tools. The async dispatch (`performAutovisorAction` / the read
/// handlers) runs through the orchestrator end-to-end; these cover the shape
/// checks and the `ToolSignal` each handler emits before that.
///
/// Test methods are `async` even though the bodies are synchronous: a `@MainActor`
/// XCTestCase with a sync test method that constructs `@MainActor` classes
/// (`ToolRuntime` / `NTMSRepository`) in-body can `abort()` on CI (CLAUDE.md pitfall).
@MainActor
final class AutovisorHandlersTests: XCTestCase {

    private func makeRuntime() throws -> ToolRuntime {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-fm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: root, toolCallsLogURL: nil, isDefaultStorage: false
        )
        return runtime
    }

    private func invoke(_ runtime: ToolRuntime, _ name: String, _ args: [String: Any]) throws -> ToolExecutionResult {
        let argsJSON = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "{}"
        return try invokeRaw(runtime, name, argsJSON)
    }

    /// Drives a verbatim arguments string through `ToolRuntime` — exercises the
    /// real `parseAndNormalizeArguments` path (JSON `null` → NSNull, non-JSON
    /// plain text → `__raw_input__` wrap) instead of a pre-built dictionary.
    private func invokeRaw(_ runtime: ToolRuntime, _ name: String, _ argsJSON: String) throws -> ToolExecutionResult {
        let call = StepToolCall(name: name, argumentsJSON: argsJSON)
        let results = runtime.executeAll(
            context: ToolExecutionContext(
                workFolderRoot: FileManager.default.temporaryDirectory,
                taskID: 1, runID: 0, roleID: AutovisorConstants.managerRoleSystemID
            ),
            toolCalls: [call]
        )
        return try XCTUnwrap(results.first)
    }

    // MARK: - Happy-path signals

    func testListTasks_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.listTasks, [:])
        XCTAssertFalse(r.isError)
        guard case .listTasks? = r.signal else { return XCTFail("expected .listTasks, got \(String(describing: r.signal))") }
    }

    func testTaskStatus_validID_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.taskStatus, ["task_id": 7])
        XCTAssertFalse(r.isError)
        guard case .taskStatus(let id)? = r.signal, id == 7 else { return XCTFail("got \(String(describing: r.signal))") }
    }

    func testCreateManagedTask_valid_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.createManagedTask, ["title": "Fix bug", "brief": "Do X", "team_id": "faang"])
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, let b, let team)? = r.signal else { return XCTFail() }
        XCTAssertEqual(t, "Fix bug"); XCTAssertEqual(b, "Do X"); XCTAssertEqual(team, "faang")
    }

    func testControlTask_validVerb_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.controlTask, ["task_id": 3, "action": "pause"])
        XCTAssertFalse(r.isError)
        guard case .controlTask(let id, let verb)? = r.signal, id == 3, verb == .pause else { return XCTFail() }
    }

    func testControlTask_rename_carriesTitleInVerb() async throws {
        let r = try invoke(makeRuntime(), ToolNames.controlTask, ["task_id": 3, "action": "rename", "arg": "New name"])
        XCTAssertFalse(r.isError)
        guard case .controlTask(_, let verb)? = r.signal, verb == .rename(title: "New name") else { return XCTFail() }
    }

    func testControlTask_renameMissingTitle_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.controlTask, ["task_id": 3, "action": "rename"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.outputJSON.contains("INVALID_ARGS"))
    }

    func testManageRole_validVerb_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.manageRole, ["task_id": 3, "role_id": "engineer", "action": "restart", "comment": "redo"])
        XCTAssertFalse(r.isError)
        guard case .manageRole(let id, let role, let verb)? = r.signal else { return XCTFail() }
        XCTAssertEqual(id, 3); XCTAssertEqual(role, "engineer"); XCTAssertEqual(verb, .restart(comment: "redo"))
    }

    func testManageRole_requestChangesMissingComment_errors() async throws {
        // request_changes requires a comment — the decode boundary rejects it.
        let r = try invoke(makeRuntime(), ToolNames.manageRole, ["task_id": 3, "role_id": "r", "action": "request_changes"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.outputJSON.contains("INVALID_ARGS"))
    }

    func testAnswerTaskQuestion_valid_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.answerTaskQuestion, ["task_id": 2, "answer": "yes"])
        XCTAssertFalse(r.isError)
        guard case .answerTaskQuestion(let id, let a)? = r.signal, id == 2, a == "yes" else { return XCTFail() }
    }

    func testMessageTask_valid_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.messageTask, ["task_id": 2, "message": "focus on auth", "role_id": "pm"])
        XCTAssertFalse(r.isError)
        guard case .messageTask(let id, let m, let role)? = r.signal else { return XCTFail() }
        XCTAssertEqual(id, 2); XCTAssertEqual(m, "focus on auth"); XCTAssertEqual(role, "pm")
    }

    func testScheduleTask_valid_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.scheduleTask, ["task_id": 5, "interval_minutes": 30])
        XCTAssertFalse(r.isError)
        guard case .scheduleTask(let id, let mins)? = r.signal, id == 5, mins == 30 else { return XCTFail() }
    }

    func testScheduleTask_zero_clears_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.scheduleTask, ["task_id": 5, "interval_minutes": 0])
        XCTAssertFalse(r.isError)
        guard case .scheduleTask(_, let mins)? = r.signal, mins == 0 else { return XCTFail() }
    }

    func testSetWorkFolderContext_valid_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.setWorkFolderContext, ["content": "This is a Swift app."])
        XCTAssertFalse(r.isError)
        guard case .setWorkFolderContext(let c)? = r.signal, c == "This is a Swift app." else { return XCTFail() }
    }

    func testWaitForEvents_emitsSignal() async throws {
        let r = try invoke(makeRuntime(), ToolNames.waitForEvents, [:])
        XCTAssertFalse(r.isError)
        guard case .waitForEvents? = r.signal else {
            return XCTFail("expected .waitForEvents, got \(String(describing: r.signal))")
        }
    }

    // MARK: - Invalid args → error envelopes (no signal acted on)

    func testTaskStatus_missingID_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.taskStatus, [:])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.outputJSON.contains("INVALID_ARGS"))
    }

    func testCreateManagedTask_emptyTitle_derivesFromShortBrief() async throws {
        let r = try invoke(makeRuntime(), ToolNames.createManagedTask, ["title": "  ", "brief": "B"])
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, let b, _)? = r.signal else { return XCTFail() }
        XCTAssertEqual(t, "B"); XCTAssertEqual(b, "B")
    }

    func testCreateManagedTask_missingTitle_derivesFromBrief() async throws {
        let brief = "**Goal**: Add an onboarding tour with tooltips and a help overlay\nSecond line with details."
        let r = try invoke(makeRuntime(), ToolNames.createManagedTask, ["brief": brief])
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, _, _)? = r.signal else { return XCTFail() }
        XCTAssertEqual(t, "**Goal**: Add an onboarding to…")
    }

    func testCreateManagedTask_emptyBrief_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.createManagedTask, ["title": "T", "brief": "   "])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.outputJSON.contains("INVALID_ARGS"))
    }

    // MARK: - create_managed_task title-derivation corners

    /// JSON `null` title — the most common shape of the emission quirk. Must
    /// derive from brief, NOT coerce NSNull into a literal "<null>" task title.
    func testCreateManagedTask_nullTitle_derivesFromBrief() async throws {
        let r = try invokeRaw(makeRuntime(), ToolNames.createManagedTask,
                              #"{"title": null, "brief": "Fix the login bug"}"#)
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, _, _)? = r.signal else {
            return XCTFail("got \(String(describing: r.signal))")
        }
        XCTAssertEqual(t, "Fix the login bug")
    }

    /// Non-string title (number) falls to derivation rather than stringifying "42".
    func testCreateManagedTask_numericTitle_derivesFromBrief() async throws {
        let r = try invokeRaw(makeRuntime(), ToolNames.createManagedTask,
                              #"{"title": 42, "brief": "B"}"#)
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, _, _)? = r.signal else {
            return XCTFail("got \(String(describing: r.signal))")
        }
        XCTAssertEqual(t, "B")
    }

    /// Multi-line brief with a SHORT first line — pins the first-line split
    /// independently of prefix(30): no embedded newline, no ellipsis.
    func testCreateManagedTask_multiLineBrief_shortFirstLine_usesFirstLineOnly() async throws {
        let r = try invoke(makeRuntime(), ToolNames.createManagedTask,
                           ["brief": "Fix login\nThe OAuth flow breaks on refresh tokens."])
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, _, _)? = r.signal else {
            return XCTFail("got \(String(describing: r.signal))")
        }
        XCTAssertEqual(t, "Fix login")
    }

    /// Exactly-30-char first line is used verbatim — no spurious ellipsis.
    func testCreateManagedTask_exactly30CharBrief_noEllipsis() async throws {
        let line30 = "123456789012345678901234567890"
        let r = try invoke(makeRuntime(), ToolNames.createManagedTask, ["brief": line30])
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, _, _)? = r.signal else {
            return XCTFail("got \(String(describing: r.signal))")
        }
        XCTAssertEqual(t, line30)
    }

    /// 31-char first line truncates to 30 + ellipsis — the other side of the boundary.
    func testCreateManagedTask_31CharBrief_truncatesWithEllipsis() async throws {
        let line31 = "123456789012345678901234567890X"
        let r = try invoke(makeRuntime(), ToolNames.createManagedTask, ["brief": line31])
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, _, _)? = r.signal else {
            return XCTFail("got \(String(describing: r.signal))")
        }
        XCTAssertEqual(t, "123456789012345678901234567890…")
    }

    /// prefix(30) counts grapheme clusters — multi-scalar emoji are never split.
    func testCreateManagedTask_emojiBrief_truncatesOnGraphemeBoundary() async throws {
        let brief = String(repeating: "👨‍👩‍👧‍👦", count: 31)
        let r = try invoke(makeRuntime(), ToolNames.createManagedTask, ["brief": brief])
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, _, _)? = r.signal else {
            return XCTFail("got \(String(describing: r.signal))")
        }
        XCTAssertEqual(t, String(repeating: "👨‍👩‍👧‍👦", count: 30) + "…")
    }

    /// Explicit title with surrounding whitespace is trimmed, not derived.
    func testCreateManagedTask_paddedTitle_isTrimmedAndUsed() async throws {
        let r = try invoke(makeRuntime(), ToolNames.createManagedTask,
                           ["title": "  Fix bug  ", "brief": "Long brief about the login flow"])
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, _, _)? = r.signal else {
            return XCTFail("got \(String(describing: r.signal))")
        }
        XCTAssertEqual(t, "Fix bug")
    }

    /// Model emits a plain non-JSON string as args → ToolRuntime wraps it in
    /// `__raw_input__`, `requiredString` recovers it as the brief, title derives.
    func testCreateManagedTask_rawPlainStringArgs_briefIsRawTextTitleDerived() async throws {
        let r = try invokeRaw(makeRuntime(), ToolNames.createManagedTask, "Fix the login bug")
        XCTAssertFalse(r.isError)
        guard case .createManagedTask(let t, let b, _)? = r.signal else {
            return XCTFail("got \(String(describing: r.signal))")
        }
        XCTAssertEqual(b, "Fix the login bug")
        XCTAssertEqual(t, "Fix the login bug")
    }

    func testControlTask_unknownVerb_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.controlTask, ["task_id": 1, "action": "frobnicate"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.outputJSON.contains("INVALID_ARGS"))
    }

    func testManageRole_unknownVerb_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.manageRole, ["task_id": 1, "role_id": "r", "action": "nope"])
        XCTAssertTrue(r.isError)
    }

    func testManageRole_missingRoleID_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.manageRole, ["task_id": 1, "action": "restart"])
        XCTAssertTrue(r.isError)
    }

    func testScheduleTask_negativeInterval_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.scheduleTask, ["task_id": 1, "interval_minutes": -5])
        XCTAssertTrue(r.isError)
    }

    func testAnswerTaskQuestion_emptyAnswer_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.answerTaskQuestion, ["task_id": 1, "answer": "   "])
        XCTAssertTrue(r.isError)
    }

    func testMessageTask_emptyMessage_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.messageTask, ["task_id": 1, "message": ""])
        XCTAssertTrue(r.isError)
    }

    func testSetWorkFolderContext_missingContent_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.setWorkFolderContext, [:])
        XCTAssertTrue(r.isError)
    }

    // MARK: - create_managed_task team-generation gate (buildSchema)

    /// A non-hidden, non-chat probe team so the catalog has a real entry regardless of
    /// the flag. The Supervisor requires a deliverable, so `isChatMode == false` and the
    /// catalog line carries no `[chat]` mark (kept separate from the mark tests below).
    private func probeTeam() -> Team {
        let supervisor = TeamRoleDefinition(
            id: "supervisor", name: "Supervisor", prompt: "", toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Deliverable"]),
            systemRoleID: "supervisor"
        )
        return Team(id: "catalog-probe", name: "Catalog Probe", roles: [supervisor], artifacts: [],
                    settings: TeamSettings(), graphLayout: TeamGraphLayout())
    }

    /// A chat-mode probe team (no supervisor deliverables → `isChatMode == true`).
    private func chatProbeTeam() -> Team {
        Team(id: "chat-probe", name: "Chat Probe", roles: [], artifacts: [],
             settings: TeamSettings(), graphLayout: TeamGraphLayout())
    }

    func testBuildSchema_marksChatModeTeams() async throws {
        let schema = CreateManagedTaskTool.buildSchema(allTeams: [chatProbeTeam()], allowGenerated: false)
        XCTAssertTrue(schema.description.contains("chat-probe"),
                      "a chat team is still listed in the catalog")
        XCTAssertTrue(schema.description.contains("[chat"),
                      "a chat team's catalog line must carry the [chat] mark")
    }

    func testBuildSchema_pipelineTeam_isNotMarkedChat() async throws {
        let schema = CreateManagedTaskTool.buildSchema(allTeams: [probeTeam()], allowGenerated: false)
        XCTAssertTrue(schema.description.contains("catalog-probe"))
        XCTAssertFalse(schema.description.contains("[chat"),
                       "a pipeline team's catalog line must NOT carry the [chat] mark")
    }

    func testBuildSchema_stillListsChatModeTeams() async throws {
        // Pins the "mark, don't filter" decision: chat teams are marked but remain
        // selectable (unlike delegate_to_team, which excludes them) — the Autovisor can
        // close a chat task, so it may legitimately open one.
        let schema = CreateManagedTaskTool.buildSchema(allTeams: [chatProbeTeam()], allowGenerated: false)
        XCTAssertTrue(schema.description.contains("`chat-probe`"),
                      "chat teams must appear as a selectable catalog bullet")
    }

    func testBuildSchema_allowGeneratedTrue_advertisesGeneratedSentinel() async throws {
        let schema = CreateManagedTaskTool.buildSchema(allTeams: [probeTeam()], allowGenerated: true)
        XCTAssertTrue(schema.description.contains("`\(DelegationConstants.generatedTeamSentinel)`"),
                      "the catalog must carry the `generated` bullet when allowed")
        let teamIDDesc = schema.parameters.properties?["team_id"]?.description ?? ""
        XCTAssertTrue(teamIDDesc.contains("generated"),
                      "the team_id param description must mention \"generated\" when allowed")
    }

    func testBuildSchema_allowGeneratedFalse_hidesGeneratedSentinel() async throws {
        let schema = CreateManagedTaskTool.buildSchema(allTeams: [probeTeam()], allowGenerated: false)
        XCTAssertFalse(schema.description.contains("generated"),
                       "the catalog must NOT mention generation when disallowed")
        XCTAssertTrue(schema.description.contains("catalog-probe"),
                      "an existing team must still be listed when generation is off")
        let teamIDDesc = schema.parameters.properties?["team_id"]?.description ?? ""
        XCTAssertFalse(teamIDDesc.contains("generated"),
                       "the team_id param description must not mention \"generated\" when disallowed")
    }

    func testBuildSchema_defaultAllowsGenerated() async throws {
        // The default arg preserves the historical always-on behaviour for callers
        // (e.g. offline preview / renderer) that don't pass the flag.
        let schema = CreateManagedTaskTool.buildSchema(allTeams: [])
        XCTAssertTrue(schema.description.contains("generated"),
                      "buildSchema must default to advertising generation")
    }

    /// Hidden teams (Autovisor + the `generated` placeholder) must never leak into
    /// the catalog. With ONLY a hidden team and generation off, the catalog has no
    /// bullet entries at all — just the header — and the manager falls back to the
    /// active team (documented in the team_id description).
    func testBuildSchema_hiddenOnlyTeams_disabled_emitsNoBullets() async throws {
        let hidden = TeamTemplateFactory.autovisor()   // isHiddenFromPickers == true
        let schema = CreateManagedTaskTool.buildSchema(allTeams: [hidden], allowGenerated: false)
        XCTAssertTrue(schema.description.contains("Available teams:"),
                      "the catalog header is always present")
        XCTAssertFalse(schema.description.contains("- `"),
                       "a hidden-only catalog with generation off must list no teams")
        XCTAssertFalse(schema.description.contains("generated"))
    }

    /// Enabled + only a hidden team → the sole bullet is `generated` (the hidden
    /// team is still filtered out).
    func testBuildSchema_hiddenOnlyTeams_enabled_showsOnlyGenerated() async throws {
        let hidden = TeamTemplateFactory.autovisor()
        let schema = CreateManagedTaskTool.buildSchema(allTeams: [hidden], allowGenerated: true)
        XCTAssertTrue(schema.description.contains("`\(DelegationConstants.generatedTeamSentinel)`"))
        XCTAssertFalse(schema.description.contains(hidden.id),
                       "a hidden team must not appear even when generation is on")
    }

    /// Empty catalog + generation off: still a valid schema — required params intact,
    /// team_id present without a generation mention.
    func testBuildSchema_emptyTeams_disabled_isValidSchema() async throws {
        let schema = CreateManagedTaskTool.buildSchema(allTeams: [], allowGenerated: false)
        XCTAssertEqual(schema.parameters.required ?? [], ["title", "brief"],
                       "required params must be preserved regardless of the flag")
        XCTAssertNotNil(schema.parameters.properties?["team_id"],
                        "team_id stays available (for existing/active-team selection)")
        XCTAssertFalse((schema.parameters.properties?["team_id"]?.description ?? "").contains("generated"))
    }
}
