import XCTest
@testable import NanoTeams

/// Tests `WatchtowerNotificationType.QuickAction.makeActions(...)` — the factory
/// driving the Watchtower action bar. Conditional branches gate which buttons
/// render; existing `WatchtowerNotificationTypeTests` only cover the type's
/// display properties.
///
/// Task-action tests pass `hasWorkFolder: false` so the Autovisor action
/// stays out of the array and their `id` assertions stay focused on the branch
/// under test. The Autovisor action has its own section below.
@MainActor
final class WatchtowerQuickActionFactoryTests: XCTestCase {

    // MARK: - Branch coverage

    func testMakeActions_noActiveTask_returnsOnlyNewTask() {
        let actions = QuickAction.makeActions(
            activeTask: nil,
            engineStatus: nil,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        XCTAssertEqual(actions.map(\.id), ["newTask"])
    }

    func testMakeActions_activeTaskWithNoEngine_includesContinueTaskAfterNewTask() {
        let task = makeRunningTask()
        let actions = QuickAction.makeActions(
            activeTask: task,
            engineStatus: nil,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        XCTAssertEqual(actions.map(\.id), ["newTask", "continueTask"])
        XCTAssertEqual(actions.first { $0.id == "continueTask" }?.subtitle, task.title)
    }

    func testMakeActions_engineRunning_includesPauseRun() {
        let actions = QuickAction.makeActions(
            activeTask: makeRunningTask(),
            engineStatus: .running,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        XCTAssertTrue(actions.map(\.id).contains("pauseRun"))
    }

    func testMakeActions_engineNeedsAcceptance_includesPauseRun() {
        let actions = QuickAction.makeActions(
            activeTask: makeRunningTask(),
            engineStatus: .needsAcceptance,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        XCTAssertTrue(actions.map(\.id).contains("pauseRun"))
    }

    func testMakeActions_engineDone_excludesPauseRun() {
        let actions = QuickAction.makeActions(
            activeTask: makeRunningTask(),
            engineStatus: .done,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        XCTAssertFalse(actions.map(\.id).contains("pauseRun"))
    }

    func testMakeActions_engineFailed_excludesPauseRun() {
        let actions = QuickAction.makeActions(
            activeTask: makeRunningTask(),
            engineStatus: .failed,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        XCTAssertFalse(actions.map(\.id).contains("pauseRun"))
    }

    func testMakeActions_readyForFinalAcceptance_includesReviewThenAccept() {
        let task = makeReadyForAcceptanceTask()
        XCTAssertTrue(task.isReadyForFinalAcceptance, "fixture precondition")
        let actions = QuickAction.makeActions(
            activeTask: task,
            engineStatus: .done,
            requiresFinalReview: true,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        let ids = actions.map(\.id)
        let reviewIdx = ids.firstIndex(of: "reviewTask")
        let acceptIdx = ids.firstIndex(of: "acceptTask")
        XCTAssertNotNil(reviewIdx)
        XCTAssertNotNil(acceptIdx)
        XCTAssertLessThan(reviewIdx ?? .max, acceptIdx ?? .min,
                          "Review must come before Accept in the action bar")
    }

    func testMakeActions_notReadyForFinalAcceptance_omitsReviewAndAccept() {
        let actions = QuickAction.makeActions(
            activeTask: makeRunningTask(),
            engineStatus: .running,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        let ids = actions.map(\.id)
        XCTAssertFalse(ids.contains("reviewTask"))
        XCTAssertFalse(ids.contains("acceptTask"))
    }

    // MARK: - Autovisor action

    func testMakeActions_hasWorkFolder_insertsAutovisorSecond() {
        // No active task → only New Task would show; FM must still be second.
        let actions = QuickAction.makeActions(
            activeTask: nil,
            engineStatus: nil,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: true,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        XCTAssertEqual(actions.map(\.id), ["newTask", "autovisor"])
    }

    func testMakeActions_hasWorkFolder_autovisorStaysSecondWithActiveTask() {
        let actions = QuickAction.makeActions(
            activeTask: makeRunningTask(),
            engineStatus: .running,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: true,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        let ids = actions.map(\.id)
        XCTAssertEqual(ids.firstIndex(of: "autovisor"), 1,
                       "Autovisor must be the second action, before task actions")
        XCTAssertEqual(Array(ids.prefix(2)), ["newTask", "autovisor"])
    }

    func testMakeActions_noWorkFolder_omitsAutovisor() {
        let actions = QuickAction.makeActions(
            activeTask: makeRunningTask(),
            engineStatus: .running,
            requiresFinalReview: false,
            autovisorEnabled: true,
            autovisorRunning: true,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        XCTAssertFalse(actions.map(\.id).contains("autovisor"))
    }

    func testMakeActions_autovisorSubtitle_reflectsState() {
        func subtitle(enabled: Bool, running: Bool) -> String? {
            QuickAction.makeActions(
                activeTask: nil,
                engineStatus: nil,
                requiresFinalReview: false,
                autovisorEnabled: enabled,
                autovisorRunning: running,
                hasWorkFolder: true,
                onNewTask: {},
                onToggleAutovisor: {},
                onNavigateToTask: { _ in },
                onPauseRun: { _ in },
                onShowFinalReview: {},
                onCloseTask: { _ in }
            ).first { $0.id == "autovisor" }?.subtitle
        }
        XCTAssertEqual(subtitle(enabled: false, running: false), "Off")
        XCTAssertEqual(subtitle(enabled: true, running: false), "On")
        XCTAssertEqual(subtitle(enabled: true, running: true), "Reviewing…")
        // Inconsistent-but-reachable: `running` is derived from a separate snapshot
        // read than `enabled` and can momentarily disagree during a toggle. The
        // factory must report "Off" (running is only consulted when enabled), never
        // "Reviewing…" on a disabled manager — pin it so a future ternary flatten
        // can't silently regress.
        XCTAssertEqual(subtitle(enabled: false, running: true), "Off")
    }

    func testMakeActions_autovisorAction_invokesToggle() {
        var fired = false
        let actions = QuickAction.makeActions(
            activeTask: nil,
            engineStatus: nil,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: true,
            onNewTask: {},
            onToggleAutovisor: { fired = true },
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        actions.first { $0.id == "autovisor" }?.action()
        XCTAssertTrue(fired)
    }

    func testMakeActions_autovisor_presentationContract() {
        // Pins the user-facing identity + the deliberate on/off color semantics
        // (muted when off, accented when on — same as the old power toggle).
        func autovisorAction(enabled: Bool) -> QuickAction? {
            QuickAction.makeActions(
                activeTask: nil,
                engineStatus: nil,
                requiresFinalReview: false,
                autovisorEnabled: enabled,
                autovisorRunning: false,
                hasWorkFolder: true,
                onNewTask: {},
                onToggleAutovisor: {},
                onNavigateToTask: { _ in },
                onPauseRun: { _ in },
                onShowFinalReview: {},
                onCloseTask: { _ in }
            ).first { $0.id == "autovisor" }
        }
        let off = autovisorAction(enabled: false)
        XCTAssertEqual(off?.title, "Autovisor")
        XCTAssertEqual(off?.icon, "power.circle.fill")
        // Compared as a not-equal pair so the test pins the state→color mapping
        // without coupling to a specific design-token Color value.
        XCTAssertNotEqual(off?.color, autovisorAction(enabled: true)?.color,
                          "icon color must differ between off and on state")
    }

    // MARK: - Action invocation routing

    func testMakeActions_newTaskAction_invokesOnNewTask() {
        var fired = false
        let actions = QuickAction.makeActions(
            activeTask: nil,
            engineStatus: nil,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: { fired = true },
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        actions.first { $0.id == "newTask" }?.action()
        XCTAssertTrue(fired)
    }

    func testMakeActions_continueAction_invokesOnNavigateWithTaskID() {
        let task = makeRunningTask(id: 42)
        var navigatedTo: Int?
        let actions = QuickAction.makeActions(
            activeTask: task,
            engineStatus: nil,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { navigatedTo = $0 },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        actions.first { $0.id == "continueTask" }?.action()
        XCTAssertEqual(navigatedTo, 42)
    }

    func testMakeActions_pauseAction_invokesOnPauseRunWithTaskID() {
        let task = makeRunningTask(id: 7)
        var paused: Int?
        let actions = QuickAction.makeActions(
            activeTask: task,
            engineStatus: .running,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { paused = $0 },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        actions.first { $0.id == "pauseRun" }?.action()
        XCTAssertEqual(paused, 7)
    }

    func testMakeActions_reviewAction_routesToShowFinalReview_whenRequiresFinalReviewTrue() {
        let task = makeReadyForAcceptanceTask(id: 99)
        var navigatedTo: Int?
        var reviewShown = false
        let actions = QuickAction.makeActions(
            activeTask: task,
            engineStatus: .done,
            requiresFinalReview: true,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { navigatedTo = $0 },
            onPauseRun: { _ in },
            onShowFinalReview: { reviewShown = true },
            onCloseTask: { _ in }
        )
        actions.first { $0.id == "reviewTask" }?.action()
        XCTAssertTrue(reviewShown)
        XCTAssertNil(navigatedTo, "must not navigate when final review modal is shown")
    }

    func testMakeActions_reviewAction_routesToNavigate_whenRequiresFinalReviewFalse() {
        let task = makeReadyForAcceptanceTask(id: 99)
        var navigatedTo: Int?
        var reviewShown = false
        let actions = QuickAction.makeActions(
            activeTask: task,
            engineStatus: .done,
            requiresFinalReview: false,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { navigatedTo = $0 },
            onPauseRun: { _ in },
            onShowFinalReview: { reviewShown = true },
            onCloseTask: { _ in }
        )
        actions.first { $0.id == "reviewTask" }?.action()
        XCTAssertEqual(navigatedTo, 99)
        XCTAssertFalse(reviewShown, "must not show final review modal when not requested")
    }

    func testMakeActions_acceptAction_invokesOnCloseTaskWithTaskID() {
        let task = makeReadyForAcceptanceTask(id: 13)
        var closed: Int?
        let actions = QuickAction.makeActions(
            activeTask: task,
            engineStatus: .done,
            requiresFinalReview: true,
            autovisorEnabled: false,
            autovisorRunning: false,
            hasWorkFolder: false,
            onNewTask: {},
            onToggleAutovisor: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { closed = $0 }
        )
        actions.first { $0.id == "acceptTask" }?.action()
        XCTAssertEqual(closed, 13)
    }

    // MARK: - Fixtures

    private func makeRunningTask(id: Int = 1) -> NTMSTask {
        NTMSTask(
            id: id,
            title: "Task #\(id)",
            supervisorTask: "do something",
            status: .running
        )
    }

    /// Builds a task whose `isReadyForFinalAcceptance` evaluates to `true`:
    /// non-chat-mode, has a run with one `.done` step and a single role status
    /// of `.done` (which `RoleExecutionStatus.metadata` marks as `isComplete`).
    /// `closedAt == nil` so `derivedStatusFromActiveRun()` returns
    /// `.needsSupervisorAcceptance`, not `.done`.
    private func makeReadyForAcceptanceTask(id: Int = 1) -> NTMSTask {
        let step = StepExecution(
            id: "supervisor",
            role: .supervisor,
            title: "wrap-up",
            status: .done,
            completedAt: Date()
        )
        let run = Run(
            id: 0,
            steps: [step],
            roleStatuses: ["supervisor": .done]
        )
        return NTMSTask(
            id: id,
            title: "Task #\(id)",
            supervisorTask: "ready",
            status: .running,
            runs: [run]
        )
    }
}
