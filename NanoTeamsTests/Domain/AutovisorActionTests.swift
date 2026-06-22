import XCTest
@testable import NanoTeams

/// Pure-value corners for the Autovisor action types: `targetTaskID` drives
/// the orchestrator's self-guard, so its folder-level-vs-task-level split must be
/// exact; `AutovisorActionResult` factories; `AutovisorActivation` defaults.
final class AutovisorActionTests: XCTestCase {

    // MARK: - targetTaskID (self-guard input)

    func testTargetTaskID_taskScopedActions_returnTheirTaskID() {
        XCTAssertEqual(AutovisorAction.controlTask(taskID: 5, verb: .pause).targetTaskID, 5)
        XCTAssertEqual(AutovisorAction.manageRole(taskID: 7, roleID: "r", verb: .restart(comment: nil)).targetTaskID, 7)
        XCTAssertEqual(AutovisorAction.answerTaskQuestion(taskID: 3, answer: "a").targetTaskID, 3)
        XCTAssertEqual(AutovisorAction.messageTask(taskID: 9, text: "m", roleID: nil).targetTaskID, 9)
        XCTAssertEqual(AutovisorAction.scheduleTask(taskID: 4, intervalMinutes: 10).targetTaskID, 4)
    }

    func testTargetTaskID_folderLevelActions_areNil() {
        // nil target = the self-guard never blocks these (no task to compare against).
        XCTAssertNil(AutovisorAction.createManagedTask(title: "t", brief: "b", teamID: nil).targetTaskID)
        XCTAssertNil(AutovisorAction.setWorkFolderContext(content: "ctx").targetTaskID)
    }

    // MARK: - AutovisorActionResult

    func testResult_factories() {
        let ok = AutovisorActionResult.success("done", createdTaskID: 12)
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.message, "done")
        XCTAssertEqual(ok.createdTaskID, 12)

        let fail = AutovisorActionResult.failure("nope")
        XCTAssertFalse(fail.ok)
        XCTAssertEqual(fail.message, "nope")
        XCTAssertNil(fail.createdTaskID)
    }

    func testResult_successWithoutTaskID_defaultsNil() {
        XCTAssertNil(AutovisorActionResult.success("ok").createdTaskID)
    }

    // MARK: - AutovisorActivation

    func testActivation_defaults() {
        let a = AutovisorActivation.default
        XCTAssertTrue(a.onTaskNeedsSupervisor, "needs-supervisor (the supervisor-routing gate) defaults ON")
        XCTAssertTrue(a.onTaskFailed)
        XCTAssertTrue(a.onTaskCompleted, "wake-on-complete defaults ON so the manager reviews finished work")
        XCTAssertFalse(a.onTaskCreated)
        XCTAssertTrue(a.onTaskStuck)
    }

    func testActivation_roundTrip() throws {
        var a = AutovisorActivation.default
        a.onTaskCompleted = true
        a.onTaskNeedsSupervisor = false
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(a)
        let back = try JSONCoderFactory.makeDateDecoder().decode(AutovisorActivation.self, from: data)
        XCTAssertEqual(back, a)
    }

    func testActivation_legacyDebounceKey_ignoredOnDecode() throws {
        // The removed `minSecondsBetweenRuns` (no throttle anymore) — an old settings.json
        // carrying it must still decode, the stale key simply dropped.
        let json = #"{"onTaskNeedsSupervisor":true,"onTaskFailed":true,"onTaskCompleted":false,"onTaskCreated":false,"minSecondsBetweenRuns":0}"#
        let back = try JSONCoderFactory.makeDateDecoder()
            .decode(AutovisorActivation.self, from: Data(json.utf8))
        XCTAssertFalse(back.onTaskCompleted, "present fields still decode")
    }

    // MARK: - ControlVerb / RoleVerb decode boundary (D1)

    func testControlVerb_parse_validAndArgs() {
        XCTAssertEqual(try? ControlVerb.parse(action: "pause", arg: nil).get(), .pause)
        XCTAssertEqual(try? ControlVerb.parse(action: "STOP", arg: nil).get(), .stop, "case-insensitive")
        XCTAssertEqual(try? ControlVerb.parse(action: "rename", arg: "  New  ").get(), .rename(title: "New"))
        XCTAssertEqual(try? ControlVerb.parse(action: "set_timeout", arg: "90").get(), .setTimeout(seconds: 90))
        XCTAssertEqual(try? ControlVerb.parse(action: "set_timeout", arg: "0").get(), .setTimeout(seconds: nil),
                       "0 clears the timeout")
        XCTAssertEqual(try? ControlVerb.parse(action: "set_timeout", arg: nil).get(), .setTimeout(seconds: nil))
    }

    func testControlVerb_parse_rejectsUnknownAndEmptyRename() {
        guard case .failure = ControlVerb.parse(action: "frobnicate", arg: nil) else { return XCTFail("unknown action must fail") }
        guard case .failure = ControlVerb.parse(action: "rename", arg: "   ") else { return XCTFail("empty rename title must fail") }
    }

    func testRoleVerb_parse_commentRequirements() {
        XCTAssertEqual(try? RoleVerb.parse(action: "restart", comment: nil).get(), .restart(comment: nil))
        XCTAssertEqual(try? RoleVerb.parse(action: "restart", comment: " go ").get(), .restart(comment: "go"))
        XCTAssertEqual(try? RoleVerb.parse(action: "accept", comment: nil).get(), .accept)
        XCTAssertEqual(try? RoleVerb.parse(action: "request_changes", comment: "fix it").get(), .requestChanges(comment: "fix it"))
        XCTAssertEqual(try? RoleVerb.parse(action: "correct", comment: "do X").get(), .correct(comment: "do X"))
        XCTAssertEqual(try? RoleVerb.parse(action: "finish_advisory", comment: nil).get(), .finishAdvisory)
    }

    func testRoleVerb_parse_rejectsMissingComment() {
        guard case .failure = RoleVerb.parse(action: "request_changes", comment: "  ") else { return XCTFail() }
        guard case .failure = RoleVerb.parse(action: "correct", comment: nil) else { return XCTFail() }
        guard case .failure = RoleVerb.parse(action: "nope", comment: nil) else { return XCTFail() }
    }

    // MARK: - AutovisorStatus.lastError (F2: task-scoped, not the global banner)

    func testStatusLastError_returnsFailedStepNote() {
        let step = StepExecution(
            id: "engineer", role: .custom(id: "engineer"), title: "Engineer",
            status: .failed,
            messages: [StepMessage(role: .custom(id: "engineer"), content: "LLM error: boom")]
        )
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "do", runs: [Run(id: 0, steps: [step])])
        XCTAssertEqual(AutovisorStatus.lastError(for: task), "LLM error: boom")
    }

    func testStatusLastError_nilWhenNoFailedStep() {
        let step = StepExecution(id: "engineer", role: .custom(id: "engineer"), title: "Engineer", status: .done)
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "do", runs: [Run(id: 0, steps: [step])])
        XCTAssertNil(AutovisorStatus.lastError(for: task),
                     "a healthy task reports no error (NOT the global banner)")
    }

    func testStatusLastError_genericFallbackWhenNoNote() {
        let step = StepExecution(id: "pm", role: .custom(id: "pm"), title: "PM", status: .failed)
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "do", runs: [Run(id: 0, steps: [step])])
        XCTAssertEqual(AutovisorStatus.lastError(for: task), "Role 'pm' failed.")
    }
}
