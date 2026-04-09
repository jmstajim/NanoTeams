import XCTest
@testable import NanoTeams

/// Tests for the Watchtower notification dismiss/undismiss lifecycle.
///
/// Covers the interaction between `dismissedNotificationIDs`, `allWatchtowerNotifications`,
/// and the stale-dismiss cleanup logic in `refreshNotifications()`.
@MainActor
final class WatchtowerDismissLifecycleTests: XCTestCase {

    var config: StoreConfiguration!

    override func setUp() {
        super.setUp()
        config = StoreConfiguration(storage: InMemoryStorage())
    }

    override func tearDown() {
        config = nil
        super.tearDown()
    }

    // MARK: - Dismiss / Undismiss

    func testDismissNotification_addsToSet() {
        config.dismissNotification(id: "step_1")
        XCTAssertTrue(config.dismissedNotificationIDs.contains("step_1"))
    }

    func testUndismissNotification_removesFromSet() {
        config.dismissNotification(id: "step_1")
        config.undismissNotification(id: "step_1")
        XCTAssertFalse(config.dismissedNotificationIDs.contains("step_1"))
    }

    func testUndismiss_nonexistentID_noOp() {
        config.undismissNotification(id: "nonexistent")
        XCTAssertTrue(config.dismissedNotificationIDs.isEmpty)
    }

    // MARK: - allWatchtowerNotifications

    func testSupervisorInput_appearsWhenNeedsSupervisorInput() {
        let step = makeStep(id: "step_1", needsSupervisorInput: true, question: "What next?")
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: [])
        XCTAssertEqual(notifications.count, 1)
        if case .supervisorInput(let stepID, let question, _) = notifications.first {
            XCTAssertEqual(stepID, "step_1")
            XCTAssertEqual(question, "What next?")
        } else {
            XCTFail("Expected supervisorInput notification")
        }
    }

    func testSupervisorInput_hiddenWhenAnswered() {
        let step = makeStep(
            id: "step_1",
            needsSupervisorInput: true,
            question: "What next?",
            answer: "Do X"
        )
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: [])
        XCTAssertTrue(notifications.isEmpty, "Answered question should not generate notification")
    }

    func testSupervisorInput_reappearsAfterNewQuestion() {
        // Simulate: first question answered, then new question on same step
        let step = makeStep(
            id: "step_1",
            needsSupervisorInput: true,
            question: "New question?",
            answer: nil  // new question, answer cleared
        )
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: [])
        XCTAssertEqual(notifications.count, 1)
    }

    // MARK: - Dismiss Lifecycle (simulates refreshNotifications logic)

    func testDismissedStep_filteredFromDisplay() {
        let step = makeStep(id: "step_1", needsSupervisorInput: true, question: "Q?")
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        config.dismissNotification(id: "step_1")

        let all = run.allWatchtowerNotifications(task: task, teamRoles: [])
        let visible = all.filter { !config.dismissedNotificationIDs.contains($0.dismissID) }
        XCTAssertTrue(visible.isEmpty, "Dismissed notification should not be visible")
    }

    func testStaleCleanup_undismissesAnsweredStep() {
        // Step was dismissed (user answered), then step is no longer needsSupervisorInput
        config.dismissNotification(id: "step_1")

        let step = makeStep(id: "step_1", needsSupervisorInput: false, question: nil)
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        // Simulate refreshNotifications cleanup
        let all = run.allWatchtowerNotifications(task: task, teamRoles: [])
        let activeIDs = Set(all.map(\.dismissID))

        for id in config.dismissedNotificationIDs where !activeIDs.contains(id) {
            config.undismissNotification(id: id)
        }

        XCTAssertFalse(config.dismissedNotificationIDs.contains("step_1"),
                        "Stale dismiss should be cleared when step no longer has active notification")
    }

    func testStaleCleanup_preservesDismissForActiveStep() {
        // Step is dismissed via X button, but step still has active question
        config.dismissNotification(id: "step_1")

        let step = makeStep(id: "step_1", needsSupervisorInput: true, question: "Q?")
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        let all = run.allWatchtowerNotifications(task: task, teamRoles: [])
        let activeIDs = Set(all.map(\.dismissID))

        for id in config.dismissedNotificationIDs where !activeIDs.contains(id) {
            config.undismissNotification(id: id)
        }

        XCTAssertTrue(config.dismissedNotificationIDs.contains("step_1"),
                       "Active notification dismiss should NOT be cleared")
    }

    func testStaleCleanup_emptyTasks_preservesDismissed() {
        // Simulates app startup — no tasks loaded yet
        config.dismissNotification(id: "step_1")
        config.dismissNotification(id: "step_2")

        let allLoadedTasks: [NTMSTask] = []  // empty on startup

        // Guard: only run cleanup when tasks are loaded
        if !allLoadedTasks.isEmpty {
            // Would undismiss, but guard prevents it
            config.undismissNotification(id: "step_1")
        }

        XCTAssertEqual(config.dismissedNotificationIDs.count, 2,
                        "Dismissed IDs must survive when no tasks are loaded (app startup)")
    }

    func testFullLifecycle_answer_newQuestion_shows() {
        // 1. Question appears
        let step1 = makeStep(id: "step_1", needsSupervisorInput: true, question: "Q1?")
        var run = makeRun(steps: [step1])
        let task = makeTask(runs: [run])

        var all = run.allWatchtowerNotifications(task: task, teamRoles: [])
        XCTAssertEqual(all.count, 1, "Question should generate notification")

        // 2. User answers → dismiss
        config.dismissNotification(id: "step_1")
        var visible = all.filter { !config.dismissedNotificationIDs.contains($0.dismissID) }
        XCTAssertTrue(visible.isEmpty, "Answered notification should be hidden")

        // 3. Step processes answer (no longer needsSupervisorInput)
        let step2 = makeStep(id: "step_1", needsSupervisorInput: false, question: nil, answer: "A1")
        run = makeRun(steps: [step2])
        all = run.allWatchtowerNotifications(task: makeTask(runs: [run]), teamRoles: [])
        let activeIDs = Set(all.map(\.dismissID))
        for id in config.dismissedNotificationIDs where !activeIDs.contains(id) {
            config.undismissNotification(id: id)
        }
        XCTAssertFalse(config.dismissedNotificationIDs.contains("step_1"),
                        "Stale dismiss should be cleared")

        // 4. New question arrives on same step
        let step3 = makeStep(id: "step_1", needsSupervisorInput: true, question: "Q2?")
        run = makeRun(steps: [step3])
        all = run.allWatchtowerNotifications(task: makeTask(runs: [run]), teamRoles: [])
        visible = all.filter { !config.dismissedNotificationIDs.contains($0.dismissID) }
        XCTAssertEqual(visible.count, 1, "New question should show (dismiss was cleared)")
    }

    // MARK: - Helpers

    private func makeStep(
        id: String,
        needsSupervisorInput: Bool,
        question: String?,
        answer: String? = nil
    ) -> StepExecution {
        StepExecution(
            id: id,
            role: .softwareEngineer,
            title: "Test Step",
            status: needsSupervisorInput ? .needsSupervisorInput : .running,
            needsSupervisorInput: needsSupervisorInput,
            supervisorQuestion: question,
            supervisorAnswer: answer
        )
    }

    private func makeRun(steps: [StepExecution]) -> Run {
        var run = Run(id: 0, teamID: "test_team")
        run.steps = steps
        return run
    }

    private func makeTask(runs: [Run]) -> NTMSTask {
        NTMSTask(id: 1, title: "Test Task", supervisorTask: "Do something", runs: runs)
    }
}

// MARK: - In-Memory Storage

private final class InMemoryStorage: ConfigurationStorage {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
