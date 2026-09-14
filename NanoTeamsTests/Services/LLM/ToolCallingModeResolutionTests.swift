import XCTest

@testable import NanoTeams

/// `LLMExecutionService.resolveToolCallingMode` — the one resolution point every tool-bearing
/// caller shares. The contract is the memo's: a definitive answer is kept for the service's
/// lifetime, an undeterminable one is retried at most once per step entry, and an explicit
/// preference asks the server nothing.
@MainActor
final class ToolCallingModeResolutionTests: XCTestCase {

    private final class ProbeClient: LLMClient, @unchecked Sendable {
        var answers: [Bool?] = []
        private(set) var probes = 0
        func toolCallingSupport(config: LLMConfig) async -> Bool? {
            probes += 1
            guard !answers.isEmpty else { return nil }
            return answers.removeFirst()
        }
        func streamChat(
            config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
            logger: NetworkLogger?, stepID: String?, roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    private var client: ProbeClient!
    private var delegate: MockLLMExecutionDelegate!
    private var sut: LLMExecutionService!
    private let stepKey = TaskStepKey(taskID: 7, stepID: "swe")
    private let config = LLMConfig(provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "ornith")

    override func setUp() async throws {
        try await super.setUp()
        client = ProbeClient()
        delegate = MockLLMExecutionDelegate()
        let probe = client!
        sut = LLMExecutionService(repository: NTMSRepository(), clientFactory: { probe })
        sut.attach(delegate: delegate)
        sut._testRegisterStepTask(stepID: stepKey.stepID, taskID: stepKey.taskID)
    }

    override func tearDown() async throws {
        sut = nil; delegate = nil; client = nil
        try await super.tearDown()
    }

    func testAuto_probesOnce_andMemoizesADefinitiveAnswer() async {
        client.answers = [true]
        let r1 = await sut.resolveToolCallingMode(config: config, stepKey: stepKey)
        XCTAssertEqual(r1, .native)
        let r2 = await sut.resolveToolCallingMode(config: config, stepKey: stepKey)
        XCTAssertEqual(r2, .native)
        let r3 = await sut.resolveToolCallingMode(config: config)
        XCTAssertEqual(r3, .native, "a step-less caller reads the same memo")
        XCTAssertEqual(client.probes, 1)
    }

    func testAuto_false_isPromptTaught_andMemoized() async {
        client.answers = [false]
        let r4 = await sut.resolveToolCallingMode(config: config, stepKey: stepKey)
        XCTAssertEqual(r4, .promptTaught)
        let r5 = await sut.resolveToolCallingMode(config: config, stepKey: stepKey)
        XCTAssertEqual(r5, .promptTaught)
        XCTAssertEqual(client.probes, 1)
    }

    /// The transient: an unreachable server on the first request must not pin the fallback
    /// for the service's lifetime — the next STEP asks again. But not the next iteration.
    func testAuto_undeterminable_isNotMemoized_andRetriedOncePerStep() async {
        client.answers = [nil, nil, true]
        let r6 = await sut.resolveToolCallingMode(config: config, stepKey: stepKey)
        XCTAssertEqual(r6, .promptTaught)
        let r7 = await sut.resolveToolCallingMode(config: config, stepKey: stepKey)
        XCTAssertEqual(r7, .promptTaught)
        XCTAssertEqual(client.probes, 1, "the second ask within the same step entry is bounded")

        // A fresh entry of the step gets one more probe.
        sut._testRegisterStepTaskReplacingEntry(stepID: stepKey.stepID, taskID: stepKey.taskID)
        let r8 = await sut.resolveToolCallingMode(config: config, stepKey: stepKey)
        XCTAssertEqual(r8, .promptTaught)
        XCTAssertEqual(client.probes, 2)
        sut._testRegisterStepTaskReplacingEntry(stepID: stepKey.stepID, taskID: stepKey.taskID)
        let r9 = await sut.resolveToolCallingMode(config: config, stepKey: stepKey)
        XCTAssertEqual(r9, .native)
        XCTAssertEqual(client.probes, 3)
    }

    func testExplicitPreference_asksTheServerNothing() async {
        delegate.toolCallingPreference = .native
        let r10 = await sut.resolveToolCallingMode(config: config, stepKey: stepKey)
        XCTAssertEqual(r10, .native)
        delegate.toolCallingPreference = .promptTaught
        let r11 = await sut.resolveToolCallingMode(config: config, stepKey: stepKey)
        XCTAssertEqual(r11, .promptTaught)
        XCTAssertEqual(client.probes, 0)
    }

    /// The memo is keyed by (server, model): one answer must not leak onto another model.
    func testMemo_isPerServerAndModel() async {
        client.answers = [true, false]
        let r12 = await sut.resolveToolCallingMode(config: config)
        XCTAssertEqual(r12, .native)
        var other = config
        other.modelName = "gemma4"
        let r13 = await sut.resolveToolCallingMode(config: other)
        XCTAssertEqual(r13, .promptTaught)
        XCTAssertEqual(client.probes, 2)
    }

    func testWithResolvedToolCallingMode_stampsTheConfigAndNothingElse() async {
        client.answers = [true]
        let resolved = await sut.withResolvedToolCallingMode(config, stepKey: stepKey)
        XCTAssertEqual(resolved.toolCallingMode, .native)
        var expected = config
        expected.toolCallingMode = .native
        XCTAssertEqual(resolved, expected)
    }
}
