import XCTest

@testable import NanoTeams

/// The production adapter between the sweep and the app's shared model-list cache.
///
/// `BenchmarkDiscoveryClassifier` already has its own table test for the four-way decision; what
/// is pinned HERE is the wiring — that the adapter asks the catalog the right question, and that
/// the three outcomes it can produce are reachable through a real `ModelCatalog` rather than only
/// through the classifier called directly.
@MainActor
final class BenchmarkModelDiscoveryTests: XCTestCase, @unchecked Sendable {

    /// Answers the model list, or throws. `visionOnly` is recorded because the sweep must ask for
    /// CHAT models — a vision-filtered list would silently drop most of the machine.
    private final class StubClient: LLMClient, @unchecked Sendable {
        var models: [LLMModelInfo] = []
        var errorToThrow: Error?
        var delayNanos: UInt64 = 0
        private(set) var lastVisionOnly: Bool?

        func fetchModels(config _: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] {
            lastVisionOnly = visionOnly
            if delayNanos > 0 { try? await Task.sleep(for: .nanoseconds(delayNanos)) }
            if let errorToThrow { throw errorToThrow }
            return models
        }

        func streamChat(
            config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
            logger _: NetworkLogger?, stepID _: String?, roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private var stub: StubClient!
    private var catalog: ModelCatalog!
    private var sut: ModelCatalogDiscovery!

    override func setUp() async throws {
        try await super.setUp()
        stub = StubClient()
        let stub = stub!
        catalog = ModelCatalog(clientFactory: { stub })
        sut = ModelCatalogDiscovery(catalog: catalog)
    }

    override func tearDown() async throws {
        sut = nil
        catalog = nil
        stub = nil
        try await super.tearDown()
    }

    private func server(_ provider: LLMProvider = .lmStudio) -> BenchmarkServer {
        BenchmarkServer(provider: provider, baseURLString: "http://127.0.0.1:1234")
    }

    /// A returned list is `.answered`, and it warms the very cache the pickers read — the reason
    /// the adapter goes through `ModelCatalog` at all rather than calling a client itself.
    /// RED: return `.noAnswer` on a successful refresh → the sweep plans nothing and the row reads
    /// "no answer" about a server that just listed its models.
    func testChatModels_returnedList_isAnsweredAndWarmsTheSharedCache() async {
        // Already ordered: `normalizedUnique` runs inside each provider client, so the catalog
        // and this adapter pass the list through untouched — asserting a re-sort here would pin
        // an ordering neither of them performs.
        stub.models = [.init(name: "a", format: "mlx"), .init(name: "b", format: "gguf")]

        let outcome = await sut.chatModels(on: server())

        XCTAssertEqual(outcome, .answered(["a", "b"]))
        XCTAssertEqual(
            catalog.models(for: "http://127.0.0.1:1234", provider: .lmStudio), ["a", "b"],
            "the scan must fill the cache the model pickers and the chips read")
        XCTAssertEqual(stub.lastVisionOnly, false, "the sweep measures chat models, not vision ones")
    }

    /// An EMPTY list is still an answer — a fact the server stated about itself, and a different
    /// sentence from having not answered. It still earns the server a clearing pass, because
    /// `fetchModels` filters embedders out and an embedder holds real memory.
    /// RED: collapse an empty `.answered` into `.noAnswer` → the server most likely to be poisoning
    /// the numbers is the one exempted from being cleared.
    func testChatModels_emptyList_isStillAnAnswer() async {
        stub.models = []

        let outcome = await sut.chatModels(on: server())
        XCTAssertEqual(outcome, .answered([]))
    }

    /// A failed lookup carries the captured reason, so the row can say WHY — a 401 is a server
    /// running perfectly well and refusing an unauthorized request.
    /// RED: return `.noAnswer(detail: nil)` → the row loses the only thing that distinguishes
    /// "unauthorized" from "nothing there".
    func testChatModels_failedLookup_isNoAnswerCarryingTheReason() async {
        stub.errorToThrow = LLMClientError.badHTTPStatus(401, "unauthorized")

        guard case .noAnswer(let detail) = await sut.chatModels(on: server()) else {
            return XCTFail("expected .noAnswer")
        }
        XCTAssertNotNil(detail)
    }

    /// A lookup that coalesced onto one already in flight observed NOTHING, and saying "this server
    /// has no models" would be a claim about a server nobody heard from. The row asks for a rescan.
    /// RED: fold `.undetermined` into `.answered([])` → an overlapping scan reports an empty
    /// machine, which is the mistake `LoadedInstanceListing` was split to end.
    func testChatModels_lookupAlreadyInFlight_isUndeterminedNotEmpty() async {
        stub.delayNanos = 50_000_000

        async let first = sut.chatModels(on: server())
        // Yield until the first refresh has actually claimed the key, so the second call takes the
        // in-flight branch rather than racing ahead of it.
        while !catalog.isFetching("http://127.0.0.1:1234", provider: .lmStudio) {
            await Task.yield()
        }
        let second = await sut.chatModels(on: server())
        _ = await first

        XCTAssertEqual(second, .undetermined)
    }

    /// The liveness probe is a separate, cheaper question than enumerating models, and it is
    /// answered by a real connection attempt. A closed local port is not answering.
    /// RED: have `isAnswering` return `true` unconditionally — the shape it would take if anyone
    /// decided the probe was too slow to be worth making → a server that is not there is measured
    /// anyway, and every remaining model pays `repeats + 1` requests that each wait out the full
    /// request timeout. That governor is the whole reason this question exists separately from
    /// `chatModels`.
    func testIsAnswering_closedPort_isFalse() async {
        let closed = BenchmarkServer(provider: .lmStudio, baseURLString: "http://127.0.0.1:1")

        let answering = await sut.isAnswering(closed)

        XCTAssertFalse(answering)
    }
}
