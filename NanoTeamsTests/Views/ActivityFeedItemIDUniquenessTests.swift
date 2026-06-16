import XCTest

@testable import NanoTeams

/// Robustness pins for the activity-feed timeline's stable ids:
/// `ActivityFeedBuilder.buildTimelineItems` must produce collision-free
/// `TaggedItem` ids even when two steps in the same source list share the same
/// `step.id` (= roleID). Message/tool-call items anchor on per-item UUIDs; the
/// `.failed` notification id folds in the failure timestamp for exactly this
/// reason — these tests are its regression pin (ForEach stable-id rule, #22).
@MainActor
final class ActivityFeedItemIDUniquenessTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func step(_ id: String, messages: [String], status: StepStatus = .done) -> StepExecution {
        StepExecution(
            id: id, role: .softwareEngineer, title: "Mgr", status: status,
            llmConversation: messages.map { LLMMessage(role: .assistant, content: $0) }
        )
    }

    func testDuplicateStepID_messages_uniqueIDsChronologicalNoBoundary() {
        // Two steps share step.id "r" — item identities anchor on each message's
        // UUID, so the shared step.id can't collide.
        let stepA = step("r", messages: ["a 1", "a 2"])
        let stepB = step("r", messages: ["b 1"], status: .running)

        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [stepA, stepB],
            run: Run(id: 1, steps: [stepB]),
            activeTaskID: 7,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )

        let ids = items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicate TaggedItem ids across same-id steps")
        XCTAssertEqual(items.count, 3, "all three messages render")
        XCTAssertTrue(items.allSatisfy { $0.boundary == nil },
                      "one shared originTaskID → no team-boundary bands")
        let dates = items.map(\.item.createdAt)
        XCTAssertEqual(dates, dates.sorted(), "items render in chronological order")
    }

    func testDuplicateStepID_failedSteps_uniqueIDs() {
        // Two `.failed` steps share step.id "r". The `.failed` notification id must
        // fold the failure timestamp so the two don't collide (the bare "fail" key
        // did — ForEach #22).
        let stepA = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr",
                                  status: .failed, completedAt: MonotonicClock.shared.now())
        let stepB = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr",
                                  status: .failed, completedAt: MonotonicClock.shared.now())

        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [stepA, stepB],
            run: Run(id: 1, steps: [stepB]),
            activeTaskID: 7,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )

        let failedIDs = items.map(\.id).filter { $0.contains("-fail") }
        XCTAssertEqual(failedIDs.count, 2, "both failed-step notifications render")
        XCTAssertEqual(Set(failedIDs).count, 2, "failed-notification ids must be unique for same-id steps")
    }

    func testDuplicateStepID_toolCalls_uniqueIDs() {
        // Tool-call items key on `call.id` (UUID), so two steps sharing step.id "r"
        // still produce distinct ids.
        let stepA = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr", status: .done,
                                  toolCalls: [StepToolCall(name: "read_file", argumentsJSON: "{}")])
        let stepB = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr", status: .done,
                                  toolCalls: [StepToolCall(name: "read_file", argumentsJSON: "{}")])
        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [stepA, stepB], run: Run(id: 1, steps: [stepB]),
            activeTaskID: 7, stepArtifactContentCache: [:], debugModeEnabled: false,
            isStreaming: { _ in false })

        let ids = items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "merged tool-call items must have unique ids")
        XCTAssertEqual(items.filter { $0.id.hasPrefix("tool-") }.count, 2, "both tool calls render")
    }
}
