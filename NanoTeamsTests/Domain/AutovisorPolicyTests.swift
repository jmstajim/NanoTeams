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

    // MARK: - showsSetupPane (which pane `.autovisor` renders)

    /// No manager task yet → setup, whatever the enabled flag says (the
    /// never-created first-run state).
    func testShowsSetupPane_noTask_alwaysTrue() {
        XCTAssertTrue(AutovisorPolicy.showsSetupPane(taskExists: false, enabled: false))
        XCTAssertTrue(AutovisorPolicy.showsSetupPane(taskExists: false, enabled: true),
            "a persisted enabled flag with no manager behind it still routes through setup")
    }

    /// THE rule this split exists for: a disabled manager shows the start page, so
    /// turning it back on is one screen away. The goal is deliberately NOT an input
    /// — a disabled manager with a real goal used to be stranded on a chat it could
    /// never drive.
    func testShowsSetupPane_taskExistsDisabled_trueRegardlessOfGoal() {
        XCTAssertTrue(AutovisorPolicy.showsSetupPane(taskExists: true, enabled: false),
            "disabled → setup, not a chat for a manager that won't run")
    }

    /// An ENABLED manager shows its chat — even on the placeholder goal, don't
    /// interrupt a live run.
    func testShowsSetupPane_taskExistsEnabled_false() {
        XCTAssertFalse(AutovisorPolicy.showsSetupPane(taskExists: true, enabled: true))
    }

    // MARK: - requiresSetupBeforeEnabling (the pill's OFF→ON intercept)

    /// Nothing to turn on yet → the click must land on setup and create it there.
    func testRequiresSetupBeforeEnabling_noTask_alwaysTrue() {
        XCTAssertTrue(AutovisorPolicy.requiresSetupBeforeEnabling(taskExists: false, goalIsUnset: true))
        XCTAssertTrue(AutovisorPolicy.requiresSetupBeforeEnabling(taskExists: false, goalIsUnset: false),
            "even with a goal pre-set in Settings, a never-created manager routes through setup")
    }

    /// Placeholder goal → route to setup rather than start the manager on the inert
    /// "explore & wait" directive.
    func testRequiresSetupBeforeEnabling_unsetGoal_true() {
        XCTAssertTrue(AutovisorPolicy.requiresSetupBeforeEnabling(taskExists: true, goalIsUnset: true))
    }

    /// Real goal → the pill stays a true one-click toggle, no detour.
    func testRequiresSetupBeforeEnabling_realGoal_false() {
        XCTAssertFalse(AutovisorPolicy.requiresSetupBeforeEnabling(taskExists: true, goalIsUnset: false),
            "an existing manager with a real goal enables in place")
    }

    // MARK: - Cross-rule invariant

    /// The intercept can never land on the chat. It only fires while the Autovisor is
    /// OFF, and every disabled state shows setup — so over the whole
    /// `(taskExists, goalIsUnset)` matrix,
    /// `requiresSetupBeforeEnabling ⟹ showsSetupPane(enabled: false)`.
    /// This is the structural replacement for the old single shared predicate.
    func testIntercept_alwaysLandsOnSetup() {
        for taskExists in [false, true] {
            for goalIsUnset in [false, true] {
                guard AutovisorPolicy.requiresSetupBeforeEnabling(
                    taskExists: taskExists, goalIsUnset: goalIsUnset
                ) else { continue }
                XCTAssertTrue(
                    AutovisorPolicy.showsSetupPane(taskExists: taskExists, enabled: false),
                    "intercept fired for (taskExists: \(taskExists), goalIsUnset: \(goalIsUnset)) but the pane would show the chat"
                )
            }
        }
    }
}
