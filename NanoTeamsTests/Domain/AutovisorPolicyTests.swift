import XCTest
@testable import NanoTeams

/// Pins `AutovisorPolicy.supervisesTask` — the auto-answer suppression gate in
/// `handleSupervisorAutoAnswer`. When it returns true the task's question is
/// NOT auto-answered: the step parks at `.needsSupervisorInput`, the engine
/// pauses (TeamEngine+RunLoop pauses on any parked step), and the Autovisor is
/// woken to answer. A wrong `true` silently strands a task that expected the
/// generic auto-answer; a wrong `false` auto-answers a question the manager
/// (or human) should have seen.
final class AutovisorPolicyTests: XCTestCase {

    private func supervises(
        taskID: Int = 7,
        parentTaskID: Int? = nil,
        enabled: Bool = true,
        onTaskNeedsSupervisor: Bool = true,
        autovisorTaskID: Int? = 1
    ) -> Bool {
        AutovisorPolicy.supervisesTask(
            taskID: taskID,
            parentTaskID: parentTaskID,
            autovisorEnabled: enabled,
            activation: AutovisorActivation(onTaskNeedsSupervisor: onTaskNeedsSupervisor),
            autovisorTaskID: autovisorTaskID
        )
    }

    func testTopLevelTask_withFeatureAndTriggerOn_isSupervised() {
        XCTAssertTrue(supervises())
    }

    func testFeatureDisabled_isNotSupervised() {
        XCTAssertFalse(supervises(enabled: false))
    }

    func testNeedsSupervisorTriggerOff_isNotSupervised() {
        // The trigger is the master gate: when off, tasks fall back to the
        // normal auto-answer / human-wait path (AutovisorActivation type doc).
        XCTAssertFalse(supervises(onTaskNeedsSupervisor: false))
    }

    func testDelegationChild_isNotSupervised() {
        // Children route ask_supervisor back to their delegating role.
        XCTAssertFalse(supervises(parentTaskID: 3))
    }

    func testManagersOwnTask_isNotSupervised() {
        // The manager never routes to itself — it carries no ask_supervisor at
        // all (resolveToolSchemas excludes it for the autovisor template); the
        // exclusion here keeps the generic auto-answer fallback live for its
        // task instead of creating a self-supervision deadlock.
        XCTAssertFalse(supervises(taskID: 1, autovisorTaskID: 1))
    }

    func testNoManagerTaskPinned_topLevelTaskStillSupervised() {
        // autovisorTaskID can be nil while enable is in flight, or if manager
        // creation failed (createAutovisorTask surfaces that via
        // lastErrorMessage). The suppression gate has always treated
        // nil != taskID as supervised; pinned so a change here is deliberate.
        XCTAssertTrue(supervises(autovisorTaskID: nil))
    }
}
