import XCTest

@testable import NanoTeams

/// When an automatic compaction epoch is armed, and — more importantly — when it is not.
///
/// Every false positive here costs a conversation: an epoch discards the model's own turns,
/// and it cannot be undone. So the trigger reads the SERVER's count and nothing else, it
/// refuses to act on a guessed window, and it latches terminally once an epoch has failed to
/// buy anything rather than re-running forever.
@MainActor
final class ContextFillTriggerTests: XCTestCase {

    var sut: LLMExecutionService!
    var delegate: MockLLMExecutionDelegate!

    private let stepID = "engineer"
    private let taskID = 5
    private let config = LLMConfig(baseURLString: "http://127.0.0.1:1234", modelName: "m")

    override func setUp() async throws {
        try await super.setUp()
        sut = LLMExecutionService(repository: NTMSRepository(), prefixLedger: PromptPrefixLedger())
        delegate = MockLLMExecutionDelegate()
        delegate.autoCompactBudgetPercent = 25
        sut.attach(delegate: delegate)
        sut._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    override func tearDown() async throws {
        sut = nil
        delegate = nil
        try await super.tearDown()
    }

    private func evaluate(
        serverPromptTokens: Int?,
        window: Int? = 8192,
        client: ProbeClient? = nil
    ) async -> ProbeClient {
        let probe = client ?? ProbeClient(contextLength: window)
        await sut._testEvaluateCompactionTrigger(
            stepID: stepID, taskID: taskID, client: probe, config: config,
            serverPromptTokens: serverPromptTokens)
        return probe
    }

    private var armed: CompactionPolicy.CompactionReason? {
        sut._testCompactRequested(stepID: stepID, taskID: taskID)
    }

    // MARK: - Budget

    /// A quarter of 8192 is 2048, and equality counts as exceeded — the same convention
    /// `ContextBudgetPolicy.verdict` uses.
    func testAtTheBudget_armsTheEpoch() async {
        _ = await evaluate(serverPromptTokens: 2048)
        XCTAssertEqual(armed, .budgetExceeded)
    }

    func testBelowTheBudget_armsNothing() async {
        _ = await evaluate(serverPromptTokens: 2047)
        XCTAssertNil(armed)
    }

    /// No count means no measurement. The estimator is deliberately not consulted: it reads
    /// 2.2× high on Cyrillic, so a Russian-language conversation would compact itself at 45% of
    /// the occupancy it actually has.
    func testNoServerCount_armsNothing() async {
        _ = await evaluate(serverPromptTokens: nil)
        XCTAssertNil(armed)
        _ = await evaluate(serverPromptTokens: 0)
        XCTAssertNil(armed)
    }

    /// A failed probe must never manufacture a budget. The other two automatic triggers —
    /// truncation and refusal — still cover this case, and both are server-reported facts.
    func testUnknownWindow_armsNothing() async {
        _ = await evaluate(serverPromptTokens: 999_999, window: nil)
        XCTAssertNil(armed)
    }

    func testAutoCompactOff_armsNothing() async {
        delegate.autoCompactEnabled = false
        _ = await evaluate(serverPromptTokens: 999_999)
        XCTAssertNil(armed)
    }

    /// The user's share is read live, so lowering it in Settings takes effect on the next
    /// response rather than on the next run.
    func testTheBudgetSharesIsTheUsersSetting() async {
        delegate.autoCompactBudgetPercent = 5
        _ = await evaluate(serverPromptTokens: 410)
        XCTAssertEqual(armed, .budgetExceeded, "5% of 8192 is 409")
    }

    // MARK: - Terminal latch

    /// The ping-pong this exists to stop: compact → still over budget → compact → … one LLM
    /// call and one discarded conversation per iteration, forever.
    ///
    /// RED: delete the `lastCompactionServerPromptTokens` comparison → this fails, and a step
    /// whose pinned head is already past the budget compacts on every single turn.
    func testAnEpochThatBoughtNothing_latchesTerminally() async {
        sut._testSetCompactionState(
            stepID: stepID, taskID: taskID, lastCompactionServerPromptTokens: 2100)
        _ = await evaluate(serverPromptTokens: 2090)  // saved 10 — nothing
        XCTAssertNil(armed)
        XCTAssertEqual(sut._testAutoCompactExhausted(stepID: stepID, taskID: taskID), true)
        XCTAssertFalse(delegate.lastErrorMessages.isEmpty,
                       "a latch the user cannot see is a step that quietly stops improving")
    }

    /// Hysteresis: an epoch that genuinely freed room may arm again later.
    func testAnEpochThatFreedRoom_mayArmAgain() async {
        sut._testSetCompactionState(
            stepID: stepID, taskID: taskID, lastCompactionServerPromptTokens: 8000)
        _ = await evaluate(serverPromptTokens: 2500)  // saved 5500 — material
        XCTAssertEqual(armed, .budgetExceeded)
        XCTAssertEqual(sut._testAutoCompactExhausted(stepID: stepID, taskID: taskID), false)
    }

    func testOnceLatched_theBudgetTriggerStaysSilent() async {
        sut._testSetCompactionState(
            stepID: stepID, taskID: taskID, autoCompactExhausted: true)
        _ = await evaluate(serverPromptTokens: 999_999)
        XCTAssertNil(armed)
    }

    /// A human asking twice knows the first one did not help — the manual path is not the
    /// automatic one and does not read the latch.
    func testTheLatchDoesNotBlockAManualRequest() {
        sut._testSetCompactionState(stepID: stepID, taskID: taskID, autoCompactExhausted: true)
        sut._testInjectRunningTask(
            stepID: stepID, taskID: taskID,
            runningTask: Task { try? await Task.sleep(for: .seconds(60)) })
        XCTAssertTrue(sut.requestCompaction(stepID: stepID, taskID: taskID))
        XCTAssertEqual(armed, .manual)
        sut.cancelExecutions(forTaskID: taskID)
    }

    /// An epoch already armed is not re-armed with a different reason: the feed row would then
    /// name the wrong cause for the fold that actually happened.
    func testAnAlreadyArmedEpochIsNotOverwritten() async {
        sut._testSetCompactionState(stepID: stepID, taskID: taskID, compactRequested: .manual)
        _ = await evaluate(serverPromptTokens: 999_999)
        XCTAssertEqual(armed, .manual)
    }

    // MARK: - Window probing

    /// One probe per epoch, no more. Ollama's `/api/ps` is silent on a cold model and LM
    /// Studio reports the NOMINAL maximum before load, so the answer only becomes true after a
    /// response — but it does not change again inside an epoch, and a probe per iteration is a
    /// network round-trip on the hot path.
    func testWindowIsReprobedAtMostOncePerEpoch() async {
        let probe = ProbeClient(contextLength: nil)
        _ = await evaluate(serverPromptTokens: 1000, client: probe)
        _ = await evaluate(serverPromptTokens: 1100, client: probe)
        _ = await evaluate(serverPromptTokens: 1200, client: probe)
        XCTAssertEqual(probe.probeCount, 1)
        XCTAssertEqual(sut._testWindowReprobeSpent(stepID: stepID, taskID: taskID), true)
    }

    /// A real answer is memoized service-wide, so later steps on the same (server, model) pay
    /// nothing — the same rule the pre-send warning uses.
    func testASuccessfulProbeIsMemoizedForTheService() async {
        let probe = ProbeClient(contextLength: 8192)
        _ = await evaluate(serverPromptTokens: 1000, client: probe)
        _ = await evaluate(serverPromptTokens: 1100, client: probe)
        XCTAssertEqual(probe.probeCount, 1)
        XCTAssertEqual(
            sut._testProbedContextLength(baseURL: config.baseURLString, model: config.modelName),
            8192)
    }

    // MARK: - Fill publication

    /// The indicator is published for any server count, budget or not — its job is to show the
    /// slope, which exists whether or not a window was ever probed.
    func testFillIsPublishedWithTheServerCount() async {
        _ = await evaluate(serverPromptTokens: 1234)
        XCTAssertEqual(delegate.contextFillUpdates.count, 1)
        let fill = delegate.contextFillUpdates[0].fill
        XCTAssertEqual(fill.promptTokens, 1234)
        XCTAssertEqual(fill.window, 8192)
        XCTAssertEqual(fill.budget, 2048)
        XCTAssertFalse(fill.isEstimate, "a server count is never an estimate")
    }

    func testFillIsPublishedEvenWithoutAWindow() async {
        _ = await evaluate(serverPromptTokens: 1234, window: nil)
        XCTAssertEqual(delegate.contextFillUpdates.count, 1)
        XCTAssertNil(delegate.contextFillUpdates[0].fill.window)
        XCTAssertNil(delegate.contextFillUpdates[0].fill.budget)
    }

    func testNoFillIsPublishedWithoutACount() async {
        _ = await evaluate(serverPromptTokens: nil)
        XCTAssertTrue(delegate.contextFillUpdates.isEmpty)
    }

    /// Two tasks on the same TEAM share step ids — `StepExecution.id` is the role id — so a
    /// stepID-keyed trigger would have one task's occupancy arm the other's epoch
    /// (multi-task invariant #5).
    func testTwoTasksSharingAStepID_areIndependent() async {
        let otherTaskID = 6
        sut._testRegisterStepTask(stepID: stepID, taskID: otherTaskID)
        _ = await evaluate(serverPromptTokens: 4000)
        XCTAssertEqual(armed, .budgetExceeded)
        XCTAssertNil(
            sut._testCompactRequested(stepID: stepID, taskID: otherTaskID),
            "the other task's step must not inherit this one's verdict")
    }

    // MARK: - Truncation trigger

    /// The one automatic trigger that needs no window: the server has SAID it stopped keeping
    /// up, which is the fact a budget is only a proxy for.
    func testServerTruncation_armsAnEpoch() {
        sut.noteServerTruncationForCompaction(stepID: stepID, taskID: taskID)
        XCTAssertEqual(armed, .serverTruncation)
    }

    func testServerTruncation_respectsTheSettingAndTheLatch() {
        delegate.autoCompactEnabled = false
        sut.noteServerTruncationForCompaction(stepID: stepID, taskID: taskID)
        XCTAssertNil(armed)

        delegate.autoCompactEnabled = true
        sut._testSetCompactionState(stepID: stepID, taskID: taskID, autoCompactExhausted: true)
        sut.noteServerTruncationForCompaction(stepID: stepID, taskID: taskID)
        XCTAssertNil(armed)
    }

    // MARK: - Re-entry

    /// A step that parked over its budget must not spend a whole request to rediscover that.
    /// The persisted fill carries the SERVER's count, so the verdict is derivable at entry —
    /// derived state, not carried state, exactly like the planning phase's.
    func testReEntry_derivesTheTriggerFromThePersistedFill() {
        let step = StepExecution(
            id: stepID, role: .softwareEngineer, title: "work",
            contextFill: ContextFill(
                promptTokens: 3000, window: 8192, budget: 2048, isEstimate: false))
        sut.seedCompactionStateOnEntry(stepID: stepID, taskID: taskID, step: step)
        XCTAssertEqual(armed, .budgetExceeded)
        XCTAssertEqual(sut._testLastContextFill(stepID: stepID, taskID: taskID)?.promptTokens, 3000)
    }

    /// An ESTIMATE seeds the indicator and nothing else. Re-entry is exactly where a wrong
    /// "compact now" costs a whole conversation, and the estimator's spread makes it unusable
    /// as a threshold.
    ///
    /// RED: drop `!fill.isEstimate` → this fails, and a Cyrillic conversation compacts itself
    /// on every re-entry at 45% of its true occupancy.
    func testReEntry_neverArmsFromAnEstimate() {
        let step = StepExecution(
            id: stepID, role: .softwareEngineer, title: "work",
            contextFill: ContextFill(
                promptTokens: 9999, window: 8192, budget: 2048, isEstimate: true))
        sut.seedCompactionStateOnEntry(stepID: stepID, taskID: taskID, step: step)
        XCTAssertNil(armed)
        XCTAssertEqual(sut._testLastContextFill(stepID: stepID, taskID: taskID)?.promptTokens, 9999)
    }

    func testReEntry_withNoPersistedFill_isANoOp() {
        sut.seedCompactionStateOnEntry(
            stepID: stepID, taskID: taskID,
            step: StepExecution(id: stepID, role: .softwareEngineer, title: "work"))
        XCTAssertNil(armed)
        XCTAssertNil(sut._testLastContextFill(stepID: stepID, taskID: taskID))
    }

    // MARK: - Failure attribution

    /// The overflow failure text has to name what the runtime already tried, because the three
    /// outcomes point the user at three different actions.
    func testCompactionOutcomeForFailure_reflectsWhatHappened() async {
        delegate.autoCompactEnabled = false
        XCTAssertEqual(
            sut.compactionOutcomeForFailure(stepID: stepID, taskID: taskID), .disabled)

        delegate.autoCompactEnabled = true
        XCTAssertEqual(
            sut.compactionOutcomeForFailure(stepID: stepID, taskID: taskID), .nothingToSeed)

        var conversation = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "task"),
            ChatMessage(role: .assistant, content: "work"),
        ]
        _ = await sut._testCompactAfterServerRefusal(
            stepID: stepID, taskID: taskID,
            step: StepExecution(
                id: stepID, role: .softwareEngineer, title: "work", scratchpad: "notes"),
            conversationMessages: &conversation)
        XCTAssertEqual(
            sut.compactionOutcomeForFailure(stepID: stepID, taskID: taskID), .attempted)
    }
}

// MARK: - Probe client

/// Counts window probes so the once-per-epoch bound is observable.
private final class ProbeClient: LLMClient, @unchecked Sendable {
    let contextLength: Int?
    private(set) var probeCount = 0

    init(contextLength: Int?) { self.contextLength = contextLength }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }

    func modelContextLength(config _: LLMConfig) async -> Int? {
        probeCount += 1
        return contextLength
    }
}
