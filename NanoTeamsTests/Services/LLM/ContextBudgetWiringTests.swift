import XCTest

@testable import NanoTeams

/// Wiring for `LLMExecutionService.warnIfContextBudgetExceeded` — the @MainActor half that
/// `ContextBudgetPolicyTests` cannot reach: the once-per-step latch, the probe memo, and the
/// live-step guard.
///
/// The pure policy decides WHETHER a prompt overflows; this decides how often the user hears
/// about it and how often we pay a network round-trip to find out.
@MainActor
final class ContextBudgetWiringTests: XCTestCase {

    var service: LLMExecutionService!
    var delegate: MockLLMExecutionDelegate!
    var client: ProbeCountingLLMClient!

    private let stepID = "swe"
    private let taskID = 77

    /// A prompt comfortably past any window used here, so the verdict is driven by the probe
    /// rather than by the estimate being borderline.
    private var oversizedMessages: [ChatMessage] {
        [ChatMessage(role: .user, content: String(repeating: "token ", count: 4000))]
    }

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        client = ProbeCountingLLMClient()
        service = LLMExecutionService(repository: NTMSRepository(), clientFactory: { [c = client!] in c })
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
    }

    override func tearDown() async throws {
        client = nil
        delegate = nil
        service = nil
        try await super.tearDown()
    }

    private func config() -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")
    }

    private func warn(messages: [ChatMessage]? = nil) async {
        await service.warnIfContextBudgetExceeded(
            stepID: stepID, taskID: taskID, client: client, config: config(),
            toolSchemaText: "", messages: messages ?? oversizedMessages)
    }

    // MARK: - The once-per-step latch

    /// The banner is a single coalescing slot and the condition only worsens as the
    /// conversation grows, so re-posting it every iteration would clobber every other message
    /// the user needs to see for the rest of the step.
    func testOverflow_warnsExactlyOnce_acrossManyIterations() async {
        client.contextLength = 512
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)

        for _ in 0..<5 { await warn() }

        XCTAssertEqual(
            delegate.lastErrorMessages.count, 1,
            "five iterations of an overflowing step must produce one banner, not five")
        XCTAssertTrue(delegate.lastErrorMessages[0].contains("512"))
    }

    /// Two concurrent steps are independent: the latch is per (taskID, stepID), so one step
    /// warning must not silence another.
    func testOverflow_latchIsPerStep_notGlobal() async {
        client.contextLength = 512
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        service._testRegisterStepTask(stepID: "other", taskID: taskID)

        await warn()
        await service.warnIfContextBudgetExceeded(
            stepID: "other", taskID: taskID, client: client, config: config(),
            toolSchemaText: "", messages: oversizedMessages)

        XCTAssertEqual(delegate.lastErrorMessages.count, 2, "each step gets its own warning")
    }

    // MARK: - Silence

    func testWithinBudget_neverWarns() async {
        client.contextLength = 1_000_000
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        await warn()
        XCTAssertTrue(delegate.lastErrorMessages.isEmpty)
    }

    /// A server that reports no window must produce silence, not a guess. This is the one
    /// wiring behaviour with real user impact if inverted — a false "your prompt is too long"
    /// sends the user to change a setting that was never the problem.
    func testUnknownWindow_staysSilent_evenForAHugePrompt() async {
        client.contextLength = nil
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        await warn()
        XCTAssertTrue(delegate.lastErrorMessages.isEmpty)
    }

    /// No execution state means the step was torn down (pause, task switch). It must neither
    /// warn nor probe — a dead step has no user watching and no reason to hit the network.
    func testTornDownStep_neitherWarnsNorProbes() async {
        client.contextLength = 512
        await warn()  // no _testRegisterStepTask
        XCTAssertTrue(delegate.lastErrorMessages.isEmpty)
        XCTAssertEqual(client.probeCount, 0, "a torn-down step must not pay a round-trip")
    }

    // MARK: - Probe memoization

    /// The probe is a network round-trip, the answer only changes when the user reloads the
    /// model, and the check runs on every iteration of every step.
    func testProbe_isMemoizedAcrossStepsSharingTheSameModel() async {
        client.contextLength = 1_000_000  // within budget, so the latch never short-circuits
        for i in 0..<4 {
            service._testRegisterStepTask(stepID: "step\(i)", taskID: taskID)
            await service.warnIfContextBudgetExceeded(
                stepID: "step\(i)", taskID: taskID, client: client, config: config(),
                toolSchemaText: "", messages: oversizedMessages)
        }
        XCTAssertEqual(client.probeCount, 1, "four steps on one model probe the window once")
    }

    /// A FAILED probe is cached too: a server that reports no window will not start doing so
    /// mid-run, and retrying per iteration adds a round-trip to the hot path forever.
    /// A failed probe is retried ONCE PER STEP, never cached for the service's life.
    ///
    /// The old behaviour cached `nil` forever, on the rationale that a server which
    /// doesn't report a window won't start mid-run. That holds for `/api/show` and is
    /// false for `/api/ps`, which answers nothing precisely while the model is cold —
    /// the state of the first probe of every session. Caching it there is what left the
    /// overflow warning structurally unarmable on a stock `ollama pull`.
    func testFailedProbe_isRetriedOncePerStep_notCachedForever() async {
        client.contextLength = nil
        for i in 0..<4 {
            service._testRegisterStepTask(stepID: "step\(i)", taskID: taskID)
            await service.warnIfContextBudgetExceeded(
                stepID: "step\(i)", taskID: taskID, client: client, config: config(),
                toolSchemaText: "", messages: oversizedMessages)
        }
        XCTAssertEqual(
            client.probeCount, 4,
            "each step gets one chance to learn a window the previous step couldn't see")
    }

    /// …but bounded: within ONE step the probe is not re-paid per iteration.
    func testFailedProbe_isNotRetriedEveryIterationWithinAStep() async {
        client.contextLength = nil
        service._testRegisterStepTask(stepID: "step", taskID: taskID)
        for _ in 0..<5 {
            await service.warnIfContextBudgetExceeded(
                stepID: "step", taskID: taskID, client: client, config: config(),
                toolSchemaText: "", messages: oversizedMessages)
        }
        XCTAssertEqual(
            client.probeCount, 1,
            "a server that never answers must cost one round-trip per step, not per iteration")
    }

    /// Different models have different windows, so the memo key must include the model.
    func testProbe_isKeyedByModel_notJustBaseURL() async {
        client.contextLength = 1_000_000
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        await service.warnIfContextBudgetExceeded(
            stepID: stepID, taskID: taskID, client: client,
            config: LLMConfig(provider: .ollama, baseURLString: "http://h:1", modelName: "a"),
            toolSchemaText: "", messages: oversizedMessages)
        await service.warnIfContextBudgetExceeded(
            stepID: stepID, taskID: taskID, client: client,
            config: LLMConfig(provider: .ollama, baseURLString: "http://h:1", modelName: "b"),
            toolSchemaText: "", messages: oversizedMessages)
        XCTAssertEqual(client.probeCount, 2, "a second model needs its own probe")
    }

    /// Base URLs differing only in trailing slash / case are the same endpoint — the memo key
    /// runs through `normalizedBaseURL`, the project's single canonicalizer, so it must not
    /// double-probe.
    func testProbe_memoKeyIsNormalized() async {
        client.contextLength = 1_000_000
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        for base in ["http://Host:1", "http://host:1/", "http://host:1"] {
            await service.warnIfContextBudgetExceeded(
                stepID: stepID, taskID: taskID, client: client,
                config: LLMConfig(provider: .ollama, baseURLString: base, modelName: "m"),
                toolSchemaText: "", messages: oversizedMessages)
        }
        XCTAssertEqual(client.probeCount, 1, "one endpoint spelled three ways is one probe")
    }
}

/// Counts `modelContextLength` calls and serves a configurable answer. Local to this file
/// rather than added to a shared double: shared doubles are injected into every orchestrator
/// suite, so widening one has a blast radius far beyond the tests that name it.
final class ProbeCountingLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _probeCount = 0
    var probeCount: Int { lock.withLock { _probeCount } }

    /// `nil` models a server that reports no window (old build, transport failure).
    var contextLength: Int?

    func modelContextLength(config: LLMConfig) async -> Int? {
        lock.withLock { _probeCount += 1 }
        return contextLength
    }

    func streamChat(
        config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
        logger: NetworkLogger?, stepID: String?, roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    func fetchEmbeddingModels(config: LLMConfig) async throws -> [String] { [] }
    func loadModel(modelName: String, baseURLString: String) async throws -> String { "" }
    func unloadModel(instanceID: String, baseURLString: String) async throws {}
    func listLoadedInstances(baseURLString: String) async throws -> [LoadedModelInstance] { [] }
}
