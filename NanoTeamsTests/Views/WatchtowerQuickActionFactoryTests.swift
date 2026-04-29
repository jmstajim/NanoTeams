import XCTest
@testable import NanoTeams

/// Tests `WatchtowerNotificationType.QuickAction.makeActions(...)` — the factory
/// driving the Watchtower action bar. Five conditional branches gate which
/// buttons render; existing `WatchtowerNotificationTypeTests` only cover the
/// type's display properties.
@MainActor
final class WatchtowerQuickActionFactoryTests: XCTestCase {

    // MARK: - Branch coverage

    func testMakeActions_noActiveTask_returnsOnlyNewTask() {
        let actions = QuickAction.makeActions(
            activeTask: nil,
            engineStatus: nil,
            requiresFinalReview: false,
            onNewTask: {},
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
            onNewTask: {},
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
            onNewTask: {},
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
            onNewTask: {},
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
            onNewTask: {},
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
            onNewTask: {},
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
            onNewTask: {},
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
            onNewTask: {},
            onNavigateToTask: { _ in },
            onPauseRun: { _ in },
            onShowFinalReview: {},
            onCloseTask: { _ in }
        )
        let ids = actions.map(\.id)
        XCTAssertFalse(ids.contains("reviewTask"))
        XCTAssertFalse(ids.contains("acceptTask"))
    }

    // MARK: - Action invocation routing

    func testMakeActions_newTaskAction_invokesOnNewTask() {
        var fired = false
        let actions = QuickAction.makeActions(
            activeTask: nil,
            engineStatus: nil,
            requiresFinalReview: false,
            onNewTask: { fired = true },
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
            onNewTask: {},
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
            onNewTask: {},
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
            onNewTask: {},
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
            onNewTask: {},
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
            onNewTask: {},
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
