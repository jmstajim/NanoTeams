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
        let stepID = "test_step"
        let id1 = TimelineEvent.stableID(stepID: stepID, eventType: .started)
        let id2 = TimelineEvent.stableID(stepID: stepID, eventType: .started)
        XCTAssertEqual(id1, id2)
    }

    func testStableID_differentForDifferentEventTypes() {
        let stepID = "test_step"
        let started = TimelineEvent.stableID(stepID: stepID, eventType: .started)
        let completed = TimelineEvent.stableID(stepID: stepID, eventType: .completed)
        let failed = TimelineEvent.stableID(stepID: stepID, eventType: .failed)
        XCTAssertNotEqual(started, completed)
        XCTAssertNotEqual(started, failed)
        XCTAssertNotEqual(completed, failed)
    }

    // MARK: - TimelineEvent.displayText

    func testDisplayText_started() {
        let event = TimelineEvent(
            id: UUID(), taskID: Int(), taskTitle: "T",
            role: .productManager, roleDefinition: nil, stepTitle: "Requirements",
            eventType: .started, timestamp: Date()
        )
        XCTAssertTrue(event.displayText.contains("started"))
        XCTAssertTrue(event.displayText.contains("Product Manager"))
    }

    func testDisplayText_completed() {
        let event = TimelineEvent(
            id: UUID(), taskID: Int(), taskTitle: "T",
            role: .techLead, roleDefinition: nil, stepTitle: "Plan",
            eventType: .completed, timestamp: Date()
        )
        XCTAssertTrue(event.displayText.contains("finished"))
    }

    func testDisplayText_failed() {
        let event = TimelineEvent(
            id: UUID(), taskID: Int(), taskTitle: "T",
            role: .softwareEngineer, roleDefinition: nil, stepTitle: "Code",
            eventType: .failed, timestamp: Date()
        )
        XCTAssertTrue(event.displayText.contains("failed"))
    }
}
