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

    func testCreateManagedTask_emptyTitle_errors() async throws {
        let r = try invoke(makeRuntime(), ToolNames.createManagedTask, ["title": "  ", "brief": "B"])
        XCTAssertTrue(r.isError)
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
}
