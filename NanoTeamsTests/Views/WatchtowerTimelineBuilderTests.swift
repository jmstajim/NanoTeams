import XCTest
@testable import NanoTeams

final class WatchtowerTimelineBuilderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStep(
        role: Role = .softwareEngineer,
        title: String = "Step",
        status: StepStatus = .done,
        createdAt: Date = Date(timeIntervalSince1970: 1000),
        completedAt: Date? = Date(timeIntervalSince1970: 2000)
    ) -> StepExecution {
        StepExecution(
            id: "test_step",
            role: role,
            title: title,
            status: status,
            createdAt: createdAt,
            updatedAt: completedAt ?? createdAt,
            completedAt: completedAt
        )
    }

    private func makeTask(
        id: Int = 0,
        title: String = "Test Task",
        runs: [Run] = []
    ) -> NTMSTask {
        NTMSTask(
            id: id,
            title: title,
            supervisorTask: "Goal",
            runs: runs
        )
    }

    // MARK: - collectEvents

    func testCollectEvents_doneStep_twoEvents() {
        let step = makeStep(status: .done)
        let run = Run(id: 0, steps: [step])
        let task = makeTask(runs: [run])

        let events = WatchtowerTimelineBuilder.collectEvents(from: task, roleDefinitions: [])

        XCTAssertEqual(events.count, 2)
        let types = events.map(\.eventType)
        XCTAssertTrue(types.contains(.started))
        XCTAssertTrue(types.contains(.completed))
    }

    func testCollectEvents_failedStep_twoEvents() {
        let step = makeStep(status: .failed, completedAt: Date(timeIntervalSince1970: 2000))
        let run = Run(id: 0, steps: [step])
        let task = makeTask(runs: [run])

        let events = WatchtowerTimelineBuilder.collectEvents(from: task, roleDefinitions: [])

        XCTAssertEqual(events.count, 2)
        let types = events.map(\.eventType)
        XCTAssertTrue(types.contains(.started))
        XCTAssertTrue(types.contains(.failed))
    }

    func testCollectEvents_runningStep_oneEvent() {
        let step = makeStep(status: .running, completedAt: nil)
        let run = Run(id: 0, steps: [step])
        let task = makeTask(runs: [run])

        let events = WatchtowerTimelineBuilder.collectEvents(from: task, roleDefinitions: [])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, .started)
    }

    func testCollectEvents_pendingStep_oneEvent() {
        let step = makeStep(status: .pending, completedAt: nil)
        let run = Run(id: 0, steps: [step])
        let task = makeTask(runs: [run])

        let events = WatchtowerTimelineBuilder.collectEvents(from: task, roleDefinitions: [])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, .started)
    }

    func testCollectEvents_emptyRuns_noEvents() {
        let task = makeTask(runs: [])

        let events = WatchtowerTimelineBuilder.collectEvents(from: task, roleDefinitions: [])

        XCTAssertTrue(events.isEmpty)
    }

    func testCollectEvents_multipleRuns_allEvents() {
        let step1 = makeStep(role: .productManager, status: .done)
        let step2 = makeStep(role: .techLead, status: .running, completedAt: nil)
        let run1 = Run(id: 0, steps: [step1])
        let run2 = Run(id: 0, steps: [step2])
        let task = makeTask(runs: [run1, run2])

        let events = WatchtowerTimelineBuilder.collectEvents(from: task, roleDefinitions: [])

        // step1 (done) = 2 events, step2 (running) = 1 event
        XCTAssertEqual(events.count, 3)
    }

    func testCollectEvents_setsTaskFields() {
        let taskID = 0
        let step = makeStep(role: .productManager, title: "Requirements", status: .running, completedAt: nil)
        let run = Run(id: 0, steps: [step])
        let task = makeTask(id: taskID, title: "My Task", runs: [run])

        let events = WatchtowerTimelineBuilder.collectEvents(from: task, roleDefinitions: [])

        XCTAssertEqual(events[0].taskID, taskID)
        XCTAssertEqual(events[0].taskTitle, "My Task")
        XCTAssertEqual(events[0].role, .productManager)
        XCTAssertEqual(events[0].stepTitle, "Requirements")
    }

    // MARK: - buildTimeline

    func testBuildTimeline_nilTask_empty() {
        let events = WatchtowerTimelineBuilder.buildTimeline(
            task: nil, roleDefinitions: [], taskFilter: nil, clearedUpTo: nil
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testBuildTimeline_sortsNewestFirst() {
        let early = Date(timeIntervalSince1970: 1000)
        let late = Date(timeIntervalSince1970: 3000)
        let step1 = makeStep(status: .running, createdAt: early, completedAt: nil)
        let step2 = makeStep(status: .running, createdAt: late, completedAt: nil)
        let run = Run(id: 0, steps: [step1, step2])
        let task = makeTask(runs: [run])

        let events = WatchtowerTimelineBuilder.buildTimeline(
            task: task, roleDefinitions: [], taskFilter: nil, clearedUpTo: nil
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].timestamp >= events[1].timestamp)
    }

    func testBuildTimeline_taskFilter_matchingID() {
        let taskID = 0
        let step = makeStep(status: .running, completedAt: nil)
        let run = Run(id: 0, steps: [step])
        let task = makeTask(id: taskID, runs: [run])

        let events = WatchtowerTimelineBuilder.buildTimeline(
            task: task, roleDefinitions: [], taskFilter: taskID, clearedUpTo: nil
        )

        XCTAssertEqual(events.count, 1)
    }

    func testBuildTimeline_taskFilter_nonMatchingID() {
        let step = makeStep(status: .running, completedAt: nil)
        let run = Run(id: 0, steps: [step])
        let task = makeTask(runs: [run])

        let events = WatchtowerTimelineBuilder.buildTimeline(
            task: task, roleDefinitions: [], taskFilter: 999, clearedUpTo: nil
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testBuildTimeline_clearedUpTo_filtersOldEvents() {
        let cutoff = Date(timeIntervalSince1970: 1500)
        let oldStep = makeStep(status: .running, createdAt: Date(timeIntervalSince1970: 1000), completedAt: nil)
        let newStep = makeStep(status: .running, createdAt: Date(timeIntervalSince1970: 2000), completedAt: nil)
        let run = Run(id: 0, steps: [oldStep, newStep])
        let task = makeTask(runs: [run])

        let events = WatchtowerTimelineBuilder.buildTimeline(
            task: task, roleDefinitions: [], taskFilter: nil, clearedUpTo: cutoff
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].timestamp > cutoff)
    }

    // MARK: - TimelineEvent.stableID

    func testStableID_deterministicForSameInput() {
        let id1 = TimelineEvent.stableID(taskID: 0, runID: 0, stepID: "test_step", eventType: .started)
        let id2 = TimelineEvent.stableID(taskID: 0, runID: 0, stepID: "test_step", eventType: .started)
        XCTAssertEqual(id1, id2)
    }

    func testStableID_differentForDifferentEventTypes() {
        let started = TimelineEvent.stableID(taskID: 0, runID: 0, stepID: "test_step", eventType: .started)
        let completed = TimelineEvent.stableID(taskID: 0, runID: 0, stepID: "test_step", eventType: .completed)
        let failed = TimelineEvent.stableID(taskID: 0, runID: 0, stepID: "test_step", eventType: .failed)
        XCTAssertNotEqual(started, completed)
        XCTAssertNotEqual(started, failed)
        XCTAssertNotEqual(completed, failed)
    }

    /// The crash fix: `stepID` is the ROLE id, which recurs in every run, so the
    /// same role+event in DIFFERENT runs must get DIFFERENT ids — otherwise the
    /// Watchtower `ForEach` sees a duplicate UUID ("ID occurs multiple times").
    func testStableID_differentForDifferentRuns() {
        let run0 = TimelineEvent.stableID(taskID: 0, runID: 0, stepID: "se", eventType: .started)
        let run1 = TimelineEvent.stableID(taskID: 0, runID: 1, stepID: "se", eventType: .started)
        XCTAssertNotEqual(run0, run1, "same role+event across runs must not collide")
    }

    /// And different tasks (defensive — if the timeline ever aggregates tasks).
    func testStableID_differentForDifferentTasks() {
        let task0 = TimelineEvent.stableID(taskID: 0, runID: 0, stepID: "se", eventType: .started)
        let task1 = TimelineEvent.stableID(taskID: 1, runID: 0, stepID: "se", eventType: .started)
        XCTAssertNotEqual(task0, task1, "same role+event across tasks must not collide")
    }

    /// End-to-end reproduction: a task with two runs of the SAME role must yield
    /// timeline events with all-unique ids (the duplicate-ID crash the user hit).
    func testCollectEvents_sameRoleAcrossRuns_producesUniqueIDs() {
        let step1 = makeStep(status: .done)   // run 0, role SE, id "test_step"
        let step2 = makeStep(status: .done)   // run 1, SAME role + id
        let run1 = Run(id: 0, steps: [step1])
        let run2 = Run(id: 1, steps: [step2])
        let task = makeTask(runs: [run1, run2])

        let events = WatchtowerTimelineBuilder.collectEvents(from: task, roleDefinitions: [])

        XCTAssertEqual(events.count, 4, "2 done steps × (started + completed)")
        let ids = events.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "every timeline event id must be unique — the same role recurs across runs")
    }

    // MARK: - TimelineEvent.displayText

    func testDisplayText_started() {
        let event = TimelineEvent(
            id: UUID(), taskID: Int(), taskTitle: "T",
            role: .productManager, roleDefinition: nil, stepTitle: "Requirements",
            eventType: .started, isChatMode: false, timestamp: Date()
        )
        XCTAssertTrue(event.displayText.contains("started"))
        XCTAssertTrue(event.displayText.contains("Product Manager"))
    }

    func testDisplayText_completed() {
        let event = TimelineEvent(
            id: UUID(), taskID: Int(), taskTitle: "T",
            role: .techLead, roleDefinition: nil, stepTitle: "Plan",
            eventType: .completed, isChatMode: false, timestamp: Date()
        )
        XCTAssertTrue(event.displayText.contains("finished"))
    }

    func testDisplayText_failed() {
        let event = TimelineEvent(
            id: UUID(), taskID: Int(), taskTitle: "T",
            role: .softwareEngineer, roleDefinition: nil, stepTitle: "Code",
            eventType: .failed, isChatMode: false, timestamp: Date()
        )
        XCTAssertTrue(event.displayText.contains("failed"))
    }

    // MARK: - Chat-mode displayText overrides

    func testDisplayText_chatMode_startedDropsStepTitle() {
        let event = TimelineEvent(
            id: UUID(), taskID: Int(), taskTitle: "T",
            role: .assistant, roleDefinition: nil, stepTitle: "work",
            eventType: .started, isChatMode: true, timestamp: Date()
        )
        XCTAssertEqual(event.displayText, "Chat with Assistant started")
        XCTAssertFalse(event.displayText.contains("work"))
    }

    func testDisplayText_chatMode_completed() {
        let event = TimelineEvent(
            id: UUID(), taskID: Int(), taskTitle: "T",
            role: .assistant, roleDefinition: nil, stepTitle: "work",
            eventType: .completed, isChatMode: true, timestamp: Date()
        )
        XCTAssertEqual(event.displayText, "Chat with Assistant ended")
    }

    func testDisplayText_chatMode_failed() {
        let event = TimelineEvent(
            id: UUID(), taskID: Int(), taskTitle: "T",
            role: .assistant, roleDefinition: nil, stepTitle: "work",
            eventType: .failed, isChatMode: true, timestamp: Date()
        )
        XCTAssertEqual(event.displayText, "Chat with Assistant failed")
    }

    func testCollectEvents_chatModeTask_propagatesFlag() {
        let step = makeStep(role: .assistant, title: "work", status: .running, completedAt: nil)
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(
            id: 0, title: "Chat", supervisorTask: "привет",
            runs: [run], isChatMode: true
        )

        let events = WatchtowerTimelineBuilder.collectEvents(from: task, roleDefinitions: [])

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isChatMode)
        XCTAssertEqual(events[0].displayText, "Chat with Assistant started")
    }
}
