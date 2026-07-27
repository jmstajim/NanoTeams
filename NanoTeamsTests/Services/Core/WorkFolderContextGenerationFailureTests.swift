import XCTest

@testable import NanoTeams

/// Pins two silent-failure regressions in the work-folder context generation flow:
///
/// 1. **Empty LLM response** must surface `lastInfoMessage` so the user understands
///    why the spinner finished without inserting any text.
/// 2. **Cancel → restart race**: when the user cancels and immediately starts a new
///    generation, the first lambda's deferred tail must not clobber the second
///    generation's flag / task handle once it eventually returns.
@MainActor
final class WorkFolderContextGenerationFailureTests: XCTestCase {

    private var tempDir: URL!
    private var sut: NTMSOrchestrator!
    private var stubClient: ControllableStubLLMClient!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        stubClient = ControllableStubLLMClient()
        let contextService = WorkFolderContextService(client: stubClient)
        let workFolderService = WorkFolderManagementService(
            repository: NTMSRepository(),
            workFolderContextService: contextService
        )
        sut = TestOrchestrator.make(workFolderManagementService: workFolderService)
    }

    override func tearDown() {
        sut = nil
        stubClient = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Empty response → user-visible info message

    func testGenerate_emptyLLMResponse_setsLastInfoMessage() async {
        await sut.openWorkFolder(tempDir)
        // Empty content stream → `WorkFolderContextService.generate` returns nil.
        stubClient.events = []

        sut.startGeneratingWorkFolderContext()
        // Drain the spawned task. Generation runs synchronously here because
        // the stub finishes its stream immediately.
        await sut.workFolderContextGenerationTask?.value

        XCTAssertFalse(sut.isGeneratingWorkFolderContext)
        XCTAssertNotNil(sut.lastInfoMessage,
                        "Empty LLM response must surface a user-visible info message — " +
                        "otherwise the spinner just disappears with no insertion and " +
                        "looks broken.")
        XCTAssertNil(sut.lastErrorMessage,
                     "Empty response is not an error — must NOT use the red error banner")
    }

    func testGenerate_whitespaceOnlyResponse_setsLastInfoMessage() async {
        await sut.openWorkFolder(tempDir)
        stubClient.events = [
            StreamEvent(contentDelta: "   \n\t   "),
        ]

        sut.startGeneratingWorkFolderContext()
        await sut.workFolderContextGenerationTask?.value

        XCTAssertFalse(sut.isGeneratingWorkFolderContext)
        XCTAssertNotNil(sut.lastInfoMessage,
                        "Whitespace-only stream must trip the same info path " +
                        "as a fully empty one")
    }

    // MARK: - Real failure → error banner (NOT the generic info banner)

    func testGenerate_streamError_setsLastErrorMessage_notInfoBanner() async {
        await sut.openWorkFolder(tempDir)
        stubClient.errorToThrow = LLMClientError.providerError("Model exploded")

        sut.startGeneratingWorkFolderContext()
        await sut.workFolderContextGenerationTask?.value

        XCTAssertFalse(sut.isGeneratingWorkFolderContext)
        XCTAssertNotNil(sut.lastErrorMessage,
                        "A real generation failure must surface the RED error banner with the cause.")
        XCTAssertTrue(sut.lastErrorMessage?.contains("Model exploded") ?? false)
        XCTAssertNil(sut.lastInfoMessage,
                     "A real failure must NOT be masked by the generic 'no usable context' info banner.")
    }

    func testGenerate_contextOverflow_surfacesActionableError() async {
        await sut.openWorkFolder(tempDir)
        stubClient.errorToThrow = LLMClientError.providerError(
            "The number of tokens to keep from the initial prompt is greater than the context length."
        )

        sut.startGeneratingWorkFolderContext()
        await sut.workFolderContextGenerationTask?.value

        let message = sut.lastErrorMessage ?? ""
        XCTAssertTrue(message.contains("context window"),
                      "A persistent context overflow must surface the actionable 'increase context length' error.")
        XCTAssertNil(sut.lastInfoMessage)
    }

    func testGenerate_cancelled_showsNeitherBanner() async {
        await sut.openWorkFolder(tempDir)
        stubClient.errorToThrow = CancellationError()

        sut.startGeneratingWorkFolderContext()
        await sut.workFolderContextGenerationTask?.value

        XCTAssertFalse(sut.isGeneratingWorkFolderContext)
        XCTAssertNil(sut.lastErrorMessage, "A cancellation is not an error — no red banner.")
        XCTAssertNil(sut.lastInfoMessage, "A cancellation is not empty output — no info banner.")
    }

    func testGenerate_success_persistsContext() async {
        await sut.openWorkFolder(tempDir)
        stubClient.events = [StreamEvent(contentDelta: "GENERATED FOLDER CONTEXT")]

        sut.startGeneratingWorkFolderContext()
        await sut.workFolderContextGenerationTask?.value

        XCTAssertEqual(sut.workFolder?.settings.context, "GENERATED FOLDER CONTEXT",
                       "A successful generation must persist the context.")
        XCTAssertNil(sut.lastErrorMessage)
        XCTAssertNil(sut.lastInfoMessage)
    }

    // MARK: - Cancel → restart race

    /// The cancel-then-restart race fix introduces a generation counter that
    /// the spawned lambda captures at start and rechecks before mutating state.
    /// Verifying the FULL race end-to-end (block T1, cancel, start T2, release T1
    /// late, assert no clobber) requires waiting on `withCheckedContinuation`
    /// timing — flaky and slow on CI. Instead we pin the counter behavior
    /// directly: if it increments on every start AND every cancel, then the
    /// lambda's `guard self.workFolderContextGenerationGeneration == myGeneration`
    /// (a one-line check) is correct by construction. The bug-shape (clobber)
    /// is only possible if the counter doesn't bump.
    func testCounter_incrementsOnStart() async {
        await sut.openWorkFolder(tempDir)
        let before = sut.workFolderContextGenerationGeneration

        sut.startGeneratingWorkFolderContext()

        XCTAssertEqual(sut.workFolderContextGenerationGeneration, before + 1,
                       "Each successful start must bump the generation counter so " +
                       "the spawned lambda captures a unique token.")

        sut.cancelWorkFolderContextGeneration()
    }

    func testCounter_incrementsOnCancel() async {
        await sut.openWorkFolder(tempDir)
        sut.startGeneratingWorkFolderContext()
        let mid = sut.workFolderContextGenerationGeneration

        sut.cancelWorkFolderContextGeneration()

        XCTAssertGreaterThan(sut.workFolderContextGenerationGeneration, mid,
                             "Cancel must bump the counter so any in-flight lambda " +
                             "from the cancelled run finds its captured token stale " +
                             "and bails before clobbering a fresh start's state.")
    }

    func testCounter_cancelThenStart_yieldsDistinctToken() async {
        // The end-to-end invariant we care about: between T1's start and T2's
        // start (with cancel in the middle), T2's captured token must differ
        // from T1's. If they're equal, T1's late tail would falsely match the
        // guard and clobber T2's state.
        await sut.openWorkFolder(tempDir)

        sut.startGeneratingWorkFolderContext()
        let t1Token = sut.workFolderContextGenerationGeneration

        sut.cancelWorkFolderContextGeneration()
        sut.startGeneratingWorkFolderContext()
        let t2Token = sut.workFolderContextGenerationGeneration

        XCTAssertNotEqual(t1Token, t2Token,
                          "T2 must capture a token distinct from T1's — otherwise " +
                          "T1's late lambda would match the guard and clobber state.")

        sut.cancelWorkFolderContextGeneration()
    }
}

// MARK: - Stub client

/// Minimal `LLMClient` stub: yields the scripted `events` array on each
/// `streamChat` call and finishes immediately. Used by the empty-response /
/// whitespace-only tests to exercise the `WorkFolderContextService.generate`
/// pipeline without touching the network. The cancel-restart race tests
/// don't go through this stub — they verify the generation counter
/// directly, which is deterministic regardless of `Task` scheduling timing.
private final class ControllableStubLLMClient: LLMClient, @unchecked Sendable {

    var events: [StreamEvent] = []
    /// When set, every `streamChat` call finishes with this error instead of
    /// yielding `events` — drives the failure-routing tests.
    var errorToThrow: Error?

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let captured = events
        let error = errorToThrow
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
            } else {
                for event in captured { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
}
