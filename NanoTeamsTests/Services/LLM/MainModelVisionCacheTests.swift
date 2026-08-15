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
            logger _: NetworkLogger?, stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }

    var sut: LLMExecutionService!
    private var client: ProbeCountingClient!

    override func setUp() async throws {
        try await super.setUp()
        sut = LLMExecutionService(repository: NTMSRepository())
        client = ProbeCountingClient()
    }

    override func tearDown() async throws {
        sut = nil
        client = nil
        try await super.tearDown()
    }

    private func config(url: String = "http://localhost:1234", model: String = "m1") -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: url, modelName: model,
                  temperature: nil)
    }

    func testDefinitiveTrue_isCached() async {
        client.verdict = true
        let first = await sut.mainModelSeesImages(config: config(), client: client, stepKey: nil)
        let second = await sut.mainModelSeesImages(config: config(), client: client, stepKey: nil)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(client.probeCount, 1, "definitive verdict must not re-probe")
    }

    func testDefinitiveFalse_isCached() async {
        client.verdict = false
        _ = await sut.mainModelSeesImages(config: config(), client: client, stepKey: nil)
        let second = await sut.mainModelSeesImages(config: config(), client: client, stepKey: nil)
        XCTAssertFalse(second)
        XCTAssertEqual(client.probeCount, 1, "false is definitive too — must cache")
    }

    func testUndeterminable_resolvesFalse_andIsNotCached() async {
        client.verdict = nil
        let first = await sut.mainModelSeesImages(config: config(), client: client, stepKey: nil)
        XCTAssertFalse(first, "undeterminable must fail toward the no-vision path")
        // Server comes back up with a definitive answer — the next call must
        // re-probe and pick it up rather than serving a stale negative.
        client.verdict = true
        let second = await sut.mainModelSeesImages(config: config(), client: client, stepKey: nil)
        XCTAssertTrue(second)
        XCTAssertEqual(client.probeCount, 2, "nil verdicts must not enter the cache")
    }

    func testCacheKey_isPerModel() async {
        client.verdict = true
        _ = await sut.mainModelSeesImages(config: config(model: "vlm-model"), client: client, stepKey: nil)
        client.verdict = false
        let other = await sut.mainModelSeesImages(config: config(model: "text-model"), client: client, stepKey: nil)
        XCTAssertFalse(other, "a different model must get its own probe")
        // The first model's cached verdict is untouched by the second probe.
        client.verdict = nil
        let firstAgain = await sut.mainModelSeesImages(config: config(model: "vlm-model"), client: client, stepKey: nil)
        XCTAssertTrue(firstAgain)
        XCTAssertEqual(client.probeCount, 2)
    }

    // MARK: - The per-step latch on undeterminable probes

    /// The probe is consulted once per `screen_capture` and once per `analyze_image`, carries a
    /// 5s timeout, and answers `nil` by construction against any endpoint with no capability
    /// metadata. Uncapped that is up to five dead seconds before every screenshot of an agent
    /// loop — so within one step it must ask at most once.
    ///
    /// RED: drop the `probedVisionKeys` latch → probeCount is 3.
    func testUndeterminable_withinOneStep_probesOnce() async {
        sut._testRegisterStepTask(stepID: "s1", taskID: 1)
        let key = TaskStepKey(taskID: 1, stepID: "s1")
        client.verdict = nil

        for _ in 0..<3 {
            let seen = await sut.mainModelSeesImages(config: config(), client: client, stepKey: key)
            XCTAssertFalse(seen, "undeterminable still resolves toward the no-vision path")
        }

        XCTAssertEqual(client.probeCount, 1, "one dead probe per step, not one per capture")
    }

    /// The other half, and the reason the latch is per-step rather than the lifetime memo the
    /// context-window probe first tried: a server that was down, or a model not yet listed,
    /// must be re-asked. `testUndeterminable_resolvesFalse_andIsNotCached` above pins that a
    /// `nil` never enters the lifetime cache; this pins that the latch doesn't smuggle one in.
    ///
    /// RED: memoize `false` into `mainModelVisionCache` on the nil branch → the second step
    /// serves the stale negative and probeCount stays 1.
    func testUndeterminable_nextStep_reProbes() async {
        sut._testRegisterStepTask(stepID: "s1", taskID: 1)
        sut._testRegisterStepTask(stepID: "s2", taskID: 1)
        client.verdict = nil
        _ = await sut.mainModelSeesImages(
            config: config(), client: client, stepKey: TaskStepKey(taskID: 1, stepID: "s1"))

        client.verdict = true
        let second = await sut.mainModelSeesImages(
            config: config(), client: client, stepKey: TaskStepKey(taskID: 1, stepID: "s2"))

        XCTAssertTrue(second, "a recovered server must be picked up on the next step")
        XCTAssertEqual(client.probeCount, 2)
    }

    /// The latch must not outlive the question it answers: a step that resolves a DIFFERENT
    /// (server, model) is a different question. Mirrors why `probedContextKeys` is a keyed set
    /// rather than a Bool.
    ///
    /// RED: make `probedVisionKeys` a Bool → the second model is never probed and reads false.
    func testLatch_isPerServerAndModel() async {
        sut._testRegisterStepTask(stepID: "s1", taskID: 1)
        let key = TaskStepKey(taskID: 1, stepID: "s1")
        client.verdict = nil
        _ = await sut.mainModelSeesImages(config: config(model: "a"), client: client, stepKey: key)

        client.verdict = true
        let other = await sut.mainModelSeesImages(
            config: config(model: "b"), client: client, stepKey: key)

        XCTAssertTrue(other, "a different model in the same step deserves its own probe")
        XCTAssertEqual(client.probeCount, 2)
    }

    /// A definitive verdict outranks the latch — it is memoized for the service's lifetime and
    /// every later step reads it without probing. Anti-vacuity for the three tests above: they
    /// all pass for an implementation that simply never probes twice.
    ///
    /// RED: latch BEFORE consulting `mainModelVisionCache` → step 2 returns false.
    func testDefinitiveVerdict_isServedToLaterStepsWithoutProbing() async {
        sut._testRegisterStepTask(stepID: "s1", taskID: 1)
        sut._testRegisterStepTask(stepID: "s2", taskID: 1)
        client.verdict = true
        _ = await sut.mainModelSeesImages(
            config: config(), client: client, stepKey: TaskStepKey(taskID: 1, stepID: "s1"))

        client.verdict = nil
        let second = await sut.mainModelSeesImages(
            config: config(), client: client, stepKey: TaskStepKey(taskID: 1, stepID: "s2"))

        XCTAssertTrue(second)
        XCTAssertEqual(client.probeCount, 1, "a real answer is never re-asked")
    }

    // MARK: - Cache key

    /// `String.normalizedBaseURL` is the house SSOT for "is this the same server" — the Keychain
    /// account key, the model-list cache and the ensurer's census all delegate to it, and
    /// CLAUDE.md records divergence from it as silent and expensive. This cache was the one
    /// consumer keying on the raw string, so a trailing slash minted a second entry and a
    /// second 5s probe for one server.
    ///
    /// RED: key on `config.baseURLString` again → probeCount is 3.
    func testCacheKey_normalizesTheBaseURL() async {
        client.verdict = true
        _ = await sut.mainModelSeesImages(
            config: config(url: "http://localhost:1234"), client: client, stepKey: nil)
        _ = await sut.mainModelSeesImages(
            config: config(url: "http://localhost:1234/"), client: client, stepKey: nil)
        let third = await sut.mainModelSeesImages(
            config: config(url: "HTTP://LOCALHOST:1234"), client: client, stepKey: nil)

        XCTAssertTrue(third)
        XCTAssertEqual(client.probeCount, 1, "one server, one probe")
    }

    /// The companion the normalization must NOT swallow: `localhost` and `127.0.0.1` are
    /// deliberately distinct in `normalizedBaseURL` (different network identities, and firewalls
    /// can route them differently), so they stay separate cache entries.
    ///
    /// RED: collapse the two in `normalizedBaseURL` → probeCount is 1 and the second server
    /// inherits the first's verdict.
    func testCacheKey_doesNotCollapseLoopbackSpellings() async {
        client.verdict = true
        _ = await sut.mainModelSeesImages(
            config: config(url: "http://localhost:1234"), client: client, stepKey: nil)
        client.verdict = false
        let other = await sut.mainModelSeesImages(
            config: config(url: "http://127.0.0.1:1234"), client: client, stepKey: nil)

        XCTAssertFalse(other)
        XCTAssertEqual(client.probeCount, 2)
    }

    func testCacheKey_isPerBaseURL() async {
        // Same model name on two servers (e.g. a per-role override pointing at
        // a different LM Studio instance) — verdicts must not cross.
        client.verdict = true
        _ = await sut.mainModelSeesImages(config: config(url: "http://localhost:1234"), client: client, stepKey: nil)
        client.verdict = false
        let other = await sut.mainModelSeesImages(config: config(url: "http://192.168.0.2:1234"), client: client, stepKey: nil)
        XCTAssertFalse(other)
        XCTAssertEqual(client.probeCount, 2)
    }
}
