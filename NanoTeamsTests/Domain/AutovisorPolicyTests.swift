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

    // MARK: - canEnable (work-folder gate)

    /// Shared by the `setAutovisorEnabled` guard and the Watchtower pill's
    /// visibility — both must agree that the feature needs a real work folder.
    func testCanEnable_requiresRealWorkFolder() {
        XCTAssertTrue(AutovisorPolicy.canEnable(hasRealWorkFolder: true),
            "with a real work folder the Autovisor can be enabled")
        XCTAssertFalse(AutovisorPolicy.canEnable(hasRealWorkFolder: false),
            "default storage has nothing to manage — enabling would be a dead toggle")
    }

    // MARK: - goalIsUnset (configured-vs-placeholder gate)

    func testGoalIsUnset_empty_true() {
        XCTAssertTrue(AutovisorPolicy.goalIsUnset(""))
    }

    func testGoalIsUnset_whitespaceOnly_true() {
        XCTAssertTrue(AutovisorPolicy.goalIsUnset("   \n\t  "),
            "whitespace-only goal is unset (trimmed to empty)")
    }

    func testGoalIsUnset_seededDefault_true() {
        XCTAssertTrue(AutovisorPolicy.goalIsUnset(AutovisorConstants.defaultGoal),
            "the seeded placeholder counts as unset — the user hasn't typed a real goal")
    }

    func testGoalIsUnset_seededDefaultWithSurroundingWhitespace_true() {
        XCTAssertTrue(AutovisorPolicy.goalIsUnset("\n  " + AutovisorConstants.defaultGoal + "  \n"),
            "match is after trimming, so a re-seeded default with stray whitespace is still unset")
    }

    func testGoalIsUnset_realGoal_false() {
        XCTAssertFalse(AutovisorPolicy.goalIsUnset("Ship the v2 onboarding flow and keep tests green."),
            "a real typed goal is configured")
    }

    func testGoalIsUnset_realGoalContainingDefaultAsSubstring_false() {
        // Exact match, NOT contains — a real goal that quotes the placeholder is
        // still configured.
        XCTAssertFalse(AutovisorPolicy.goalIsUnset(AutovisorConstants.defaultGoal + " Also: refactor X."),
            "default-as-prefix is a real goal, not the unset placeholder")
    }

    // MARK: - needsSetup (setup-pane-vs-chat routing)

    /// No manager task yet → always setup, regardless of enabled/goal (the
    /// never-created first-run state).
    func testNeedsSetup_noTask_alwaysTrue() {
        XCTAssertTrue(AutovisorPolicy.needsSetup(taskExists: false, enabled: false, goalIsUnset: true))
        XCTAssertTrue(AutovisorPolicy.needsSetup(taskExists: false, enabled: false, goalIsUnset: false),
            "even with a goal pre-set in Settings, a never-created manager routes through setup")
    }

    /// THE regression case: a created-then-disabled manager whose goal is still the
    /// placeholder must route back to setup — it used to be stranded on the chat.
    func testNeedsSetup_taskExistsDisabledUnsetGoal_true() {
        XCTAssertTrue(AutovisorPolicy.needsSetup(taskExists: true, enabled: false, goalIsUnset: true),
            "disabled manager with no real goal → setup, not a chat for a manager that won't run")
    }

    /// A disabled manager WITH a real goal doesn't need setup — the pill re-enables
    /// it directly and the chat is meaningful.
    func testNeedsSetup_taskExistsDisabledRealGoal_false() {
        XCTAssertFalse(AutovisorPolicy.needsSetup(taskExists: true, enabled: false, goalIsUnset: false))
    }

    /// An ENABLED manager never needs setup — it's already running. `enabled`
    /// dominates an unset goal (don't interrupt a live placeholder run).
    func testNeedsSetup_taskExistsEnabled_falseEvenWithUnsetGoal() {
        XCTAssertFalse(AutovisorPolicy.needsSetup(taskExists: true, enabled: true, goalIsUnset: true),
            "enabled dominates — a running manager on the placeholder goal stays on its chat")
        XCTAssertFalse(AutovisorPolicy.needsSetup(taskExists: true, enabled: true, goalIsUnset: false))
    }
}
