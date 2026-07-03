import XCTest

@testable import NanoTeams

/// Pins `LLMExecutionService.mainModelSeesImages` — the cached front of the
/// auto-detected vision capability. Contract corners:
///   - definitive verdicts (true AND false) cache per `(baseURL, model)` and
///     stop re-probing;
///   - an undeterminable probe (`nil`) resolves to `false` but is NOT cached,
///     so a transient failure can't pin a wrong verdict for the service
///     lifetime;
///   - the cache key includes BOTH the base URL and the model name — per-role
///     LLM overrides must not read another server/model's verdict.
@MainActor
final class MainModelVisionCacheTests: XCTestCase, @unchecked Sendable {

    /// Minimal LLMClient double: scripted `modelSupportsVision` + probe counter.
    /// `streamChat` / `fetchModels` are never reached by the code under test.
    private final class ProbeCountingClient: LLMClient, @unchecked Sendable {
        nonisolated(unsafe) var verdict: Bool?
        nonisolated(unsafe) var probeCount = 0

        func modelSupportsVision(config _: LLMConfig) async -> Bool? {
            probeCount += 1
            return verdict
        }

        func streamChat(
            config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
            session _: LLMSession?, logger _: NetworkLogger?, stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }

    var sut: LLMExecutionService!
    private var client: ProbeCountingClient!

    override func setUp() {
        super.setUp()
        sut = LLMExecutionService(repository: NTMSRepository())
        client = ProbeCountingClient()
    }

    override func tearDown() {
        sut = nil
        client = nil
        super.tearDown()
    }

    private func config(url: String = "http://localhost:1234", model: String = "m1") -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: url, modelName: model,
                  maxTokens: 1024, temperature: nil)
    }

    func testDefinitiveTrue_isCached() async {
        client.verdict = true
        let first = await sut.mainModelSeesImages(config: config(), client: client)
        let second = await sut.mainModelSeesImages(config: config(), client: client)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(client.probeCount, 1, "definitive verdict must not re-probe")
    }

    func testDefinitiveFalse_isCached() async {
        client.verdict = false
        _ = await sut.mainModelSeesImages(config: config(), client: client)
        let second = await sut.mainModelSeesImages(config: config(), client: client)
        XCTAssertFalse(second)
        XCTAssertEqual(client.probeCount, 1, "false is definitive too — must cache")
    }

    func testUndeterminable_resolvesFalse_andIsNotCached() async {
        client.verdict = nil
        let first = await sut.mainModelSeesImages(config: config(), client: client)
        XCTAssertFalse(first, "undeterminable must fail toward the no-vision path")
        // Server comes back up with a definitive answer — the next call must
        // re-probe and pick it up rather than serving a stale negative.
        client.verdict = true
        let second = await sut.mainModelSeesImages(config: config(), client: client)
        XCTAssertTrue(second)
        XCTAssertEqual(client.probeCount, 2, "nil verdicts must not enter the cache")
    }

    func testCacheKey_isPerModel() async {
        client.verdict = true
        _ = await sut.mainModelSeesImages(config: config(model: "vlm-model"), client: client)
        client.verdict = false
        let other = await sut.mainModelSeesImages(config: config(model: "text-model"), client: client)
        XCTAssertFalse(other, "a different model must get its own probe")
        // The first model's cached verdict is untouched by the second probe.
        client.verdict = nil
        let firstAgain = await sut.mainModelSeesImages(config: config(model: "vlm-model"), client: client)
        XCTAssertTrue(firstAgain)
        XCTAssertEqual(client.probeCount, 2)
    }

    func testCacheKey_isPerBaseURL() async {
        // Same model name on two servers (e.g. a per-role override pointing at
        // a different LM Studio instance) — verdicts must not cross.
        client.verdict = true
        _ = await sut.mainModelSeesImages(config: config(url: "http://localhost:1234"), client: client)
        client.verdict = false
        let other = await sut.mainModelSeesImages(config: config(url: "http://192.168.0.2:1234"), client: client)
        XCTAssertFalse(other)
        XCTAssertEqual(client.probeCount, 2)
    }
}
