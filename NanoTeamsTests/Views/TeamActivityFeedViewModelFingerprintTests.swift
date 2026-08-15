import XCTest

@testable import NanoTeams

/// Tests for `TeamActivityFeedViewModel.computeFingerprint`'s
/// `supervisorInputCount` field. The fingerprint drives `recomputeAndRebuild`'s
/// short-circuit — if it falls out of sync with the active-question definition
/// used by `emitItems` and `activeSupervisorQuestions`, the rebuild won't fire
/// when the composer chip flips, and the user sees stale UI.
///
/// (The supervisor-answer attachment / submit guards that previously lived on
/// this VM were retired when the in-feed answer composer was removed — the
/// docked `TeamActivityComposer` is the single answering surface now.)
@MainActor
final class TeamActivityFeedViewModelFingerprintTests: XCTestCase {

    var viewModel: TeamActivityFeedViewModel!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        viewModel = TeamActivityFeedViewModel()
    }

    override func tearDown() async throws {
        viewModel = nil
        try await super.tearDown()
    }

    // MARK: - Timeline Fingerprint

    func testTimelineFingerprint_includesSupervisorInputCount() {
        let step1 = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "SWE",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Question?"
        )
        let step2 = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "PM",
            status: .done
        )

        let fingerprint = viewModel.computeFingerprint(
            steps: [step1, step2], run: nil, activeTaskID: Int()
        )

        XCTAssertEqual(fingerprint.supervisorInputCount, 1)
    }

    func testTimelineFingerprint_answeredQuestionNotCounted() {
        var step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "SWE",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Question?"
        )
        step.supervisorAnswer = "Answer"
        // After answering, needsSupervisorInput is cleared by StepMessagingService.
        step.needsSupervisorInput = false

        let fingerprint = viewModel.computeFingerprint(
            steps: [step], run: nil, activeTaskID: Int()
        )

        XCTAssertEqual(fingerprint.supervisorInputCount, 0)
    }

    /// Multi-round race: after iter N is answered but before
    /// `setNeedsSupervisorInput(N+1)` clears `step.supervisorAnswer`, the
    /// trailing `ask_supervisor` for iter N+1 is in-flight. The naive
    /// `needsSupervisorInput && supervisorAnswer == nil` fingerprint would
    /// return 0 here — but the docked composer treats the question as active
    /// AND `emitItems` skips it. Three surfaces must agree, otherwise the
    /// rebuild trigger doesn't fire when the composer state changes.
    ///
    /// This test fails against the pre-fix fingerprint predicate and passes
    /// once the predicate is wired through `stepHasActiveSupervisorInput`.
    func testTimelineFingerprint_multiRoundRace_stillCountsTrailingUnanswered() {
        let ask1 = StepToolCall(
            createdAt: MonotonicClock.shared.now(),
            name: ToolNames.askSupervisor,
            argumentsJSON: #"{"question":"first?"}"#
        )
        let answer1 = LLMMessage(
            createdAt: MonotonicClock.shared.now(),
            role: .user,
            content: "Supervisor answer: yes",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer
        )
        let ask2 = StepToolCall(
            createdAt: MonotonicClock.shared.now(),
            name: ToolNames.askSupervisor,
            argumentsJSON: #"{"question":"second?"}"#
        )
        var step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "SWE",
            status: .running,
            toolCalls: [ask1, ask2],
            llmConversation: [answer1]
        )
        // Race window: ask2 has landed, supervisorAnswer carries the iter-1
        // answer, needsSupervisorInput has not yet been re-set for iter 2.
        step.supervisorAnswer = "yes"
        step.needsSupervisorInput = false

        let fingerprint = viewModel.computeFingerprint(
            steps: [step], run: nil, activeTaskID: Int()
        )

        XCTAssertEqual(
            fingerprint.supervisorInputCount, 1,
            "Trailing unanswered ask must count even when step.supervisorAnswer is stale-carried from a prior round"
        )
    }
}
