import XCTest
@testable import NanoTeams

/// Pins `EmbeddingModelCatalog` — the type that took the embedding-model fetch out of
/// `ExploratorySearchEmbeddingsCard`.
///
/// Two things are pinned here that nothing pinned before, and the reason is the same for both:
/// while this lived on the card it was a `private func` on a `View`, so the only consumer that
/// could ever have exercised its seam was a preview. The card carried
/// `var client: any LLMClient = LLMClientRouter()` under the doc comment "Injected for
/// testability", injected by zero of its two construction sites and by no test at all.
///
///   - the TOKEN OVERRIDE path: a bearer token the user has typed but not yet saved has to
///     reach the request, and an empty field must fall through to the Keychain rather than
///     forcing an unauthenticated call;
///   - the CACHING contract it inherited from `ModelCatalog`, which the card's own
///     `guard availableEmbeddingModels.isEmpty` could not provide across appearances.
@MainActor
final class EmbeddingModelCatalogTests: XCTestCase {

    // MARK: - Stub client

    private final class StubClient: LLMClient, @unchecked Sendable {
        var fetchCount = 0
        var modelsToReturn: [String] = ["nomic-embed-text-v1.5", "bge-m3"]
        var errorToThrow: Error?
        /// Extends a fetch so two concurrent calls can race the in-flight dedup check.
        var fetchDelayNanos: UInt64 = 0

        func fetchEmbeddingModels(config: LLMConfig) async throws -> [String] {
            fetchCount += 1
            if fetchDelayNanos > 0 {
                try? await Task.sleep(for: .nanoseconds(fetchDelayNanos))
            }
            if let errorToThrow { throw errorToThrow }
            return modelsToReturn
        }

        /// Not what this catalog asks for — `fetchModels` is the CHAT list, and it has no
        /// protocol default, so the stub has to answer something.
        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private struct Probe: Error {}

    /// Records the resolver each fetch was built with — the only way to see the token path,
    /// since the resolver is consumed inside the client the factory returns.
    private final class ResolverRecorder: @unchecked Sendable {
        var resolvers: [(any LLMTokenResolver)?] = []
    }

    // MARK: - Normalization

    func testNormalize_matchesTheSharedNormalizer() {
        XCTAssertEqual(EmbeddingModelCatalog.normalize("  HTTP://X:1234///  "), "http://x:1234")
        XCTAssertEqual(EmbeddingModelCatalog.normalize("http://x:1234"), "http://x:1234")
        // Same answer as the sibling catalog: one drifting key would split one server in two.
        XCTAssertEqual(EmbeddingModelCatalog.normalize("http://X:1234/"),
                       ModelCatalog.normalize("http://X:1234/"))
    }

    func testReads_areKeyedByTheNormalizedURL() async {
        let stub = StubClient()
        let catalog = EmbeddingModelCatalog(clientFactory: { _ in stub })

        await catalog.loadIfNeeded(url: "http://x:1234")

        XCTAssertEqual(catalog.models(for: "HTTP://X:1234/"), ["nomic-embed-text-v1.5", "bge-m3"])
        XCTAssertTrue(catalog.hasLoaded("  http://x:1234  "))
    }

    // MARK: - loadIfNeeded / refresh

    func testLoadIfNeeded_fetchesOnce_thenServesFromCache() async {
        let stub = StubClient()
        let catalog = EmbeddingModelCatalog(clientFactory: { _ in stub })

        await catalog.loadIfNeeded(url: "http://x:1234")
        await catalog.loadIfNeeded(url: "http://x:1234")

        XCTAssertEqual(stub.fetchCount, 1)
    }

    func testRefresh_forcesARefetch() async {
        let stub = StubClient()
        let catalog = EmbeddingModelCatalog(clientFactory: { _ in stub })

        await catalog.loadIfNeeded(url: "http://x:1234")
        let didFetch = await catalog.refresh(url: "http://x:1234")

        XCTAssertTrue(didFetch)
        XCTAssertEqual(stub.fetchCount, 2)
    }

    func testConcurrentLoads_coalesceIntoOneFetch() async {
        let stub = StubClient()
        stub.fetchDelayNanos = 50_000_000
        let catalog = EmbeddingModelCatalog(clientFactory: { _ in stub })

        async let a: Void = catalog.loadIfNeeded(url: "http://x:1234")
        async let b: Void = catalog.loadIfNeeded(url: "http://x:1234")
        _ = await (a, b)

        XCTAssertEqual(stub.fetchCount, 1)
    }

    /// An empty URL is not a server. Both entry points must decline before touching a client —
    /// the card's `fetchURL` is empty exactly while the user is clearing the field.
    func testEmptyURL_isANoOpOnBothEntryPoints() async {
        let stub = StubClient()
        let catalog = EmbeddingModelCatalog(clientFactory: { _ in stub })

        await catalog.loadIfNeeded(url: "   ")
        let didFetch = await catalog.refresh(url: "")

        XCTAssertEqual(stub.fetchCount, 0)
        XCTAssertFalse(didFetch)
        XCTAssertFalse(catalog.hasLoaded(""))
    }

    // MARK: - Token override

    func testTypedToken_reachesTheClientAsAnOverrideForThatURL() async {
        let recorder = ResolverRecorder()
        let stub = StubClient()
        let catalog = EmbeddingModelCatalog(clientFactory: { resolver in
            recorder.resolvers.append(resolver)
            return stub
        })

        await catalog.loadIfNeeded(url: "http://x:1234", tokenOverride: "typed-but-unsaved")

        XCTAssertEqual(recorder.resolvers.count, 1)
        let resolver = try? XCTUnwrap(recorder.resolvers.first ?? nil)
        XCTAssertEqual(resolver?.token(forBaseURL: "http://x:1234"), "typed-but-unsaved")
        // Scoped to the URL it was typed for — a token for the embedding server must not
        // authenticate a request to the chat server.
        XCTAssertNotEqual(resolver?.token(forBaseURL: "http://other:9999"), "typed-but-unsaved")
    }

    /// No typed token means "let the Keychain-backed default answer", NOT "send the request
    /// unauthenticated" — so the factory must get `nil` and build its own resolver.
    func testNoTokenAndWhitespaceOnlyToken_bothPassNilResolver() async {
        let recorder = ResolverRecorder()
        let stub = StubClient()
        let catalog = EmbeddingModelCatalog(clientFactory: { resolver in
            recorder.resolvers.append(resolver)
            return stub
        })

        await catalog.refresh(url: "http://x:1234", tokenOverride: nil)
        await catalog.refresh(url: "http://x:1234", tokenOverride: "   ")

        XCTAssertEqual(recorder.resolvers.count, 2)
        XCTAssertNil(recorder.resolvers[0])
        XCTAssertNil(recorder.resolvers[1])
    }

    // MARK: - Errors

    func testFailure_recordsTheError_andLeavesThePreviousListStanding() async {
        let stub = StubClient()
        let catalog = EmbeddingModelCatalog(clientFactory: { _ in stub })
        await catalog.loadIfNeeded(url: "http://x:1234")

        stub.errorToThrow = Probe()
        await catalog.refresh(url: "http://x:1234")

        XCTAssertNotNil(catalog.error(for: "http://x:1234"))
        XCTAssertEqual(catalog.models(for: "http://x:1234"), ["nomic-embed-text-v1.5", "bge-m3"])
    }

    func testSuccessAfterFailure_clearsTheError() async {
        let stub = StubClient()
        stub.errorToThrow = Probe()
        let catalog = EmbeddingModelCatalog(clientFactory: { _ in stub })
        await catalog.loadIfNeeded(url: "http://x:1234")
        XCTAssertNotNil(catalog.error(for: "http://x:1234"))

        stub.errorToThrow = nil
        await catalog.refresh(url: "http://x:1234")

        XCTAssertNil(catalog.error(for: "http://x:1234"))
    }

    /// A failed fetch never marks the URL loaded, so `loadIfNeeded` retries on the next
    /// appearance instead of caching the failure forever.
    func testFailure_doesNotCount_asLoaded() async {
        let stub = StubClient()
        stub.errorToThrow = Probe()
        let catalog = EmbeddingModelCatalog(clientFactory: { _ in stub })

        await catalog.loadIfNeeded(url: "http://x:1234")
        await catalog.loadIfNeeded(url: "http://x:1234")

        XCTAssertFalse(catalog.hasLoaded("http://x:1234"))
        XCTAssertEqual(stub.fetchCount, 2)
    }

    /// "Server answered, and it has no embedding models" is a fact about the server;
    /// "nobody asked" is a fact about us. `models(for:)` collapses both to `[]`.
    func testEmptyServerList_isLoadedRatherThanMissing() async {
        let stub = StubClient()
        stub.modelsToReturn = []
        let catalog = EmbeddingModelCatalog(clientFactory: { _ in stub })

        await catalog.loadIfNeeded(url: "http://x:1234")

        XCTAssertTrue(catalog.hasLoaded("http://x:1234"))
        XCTAssertEqual(catalog.models(for: "http://x:1234"), [])
        XCTAssertFalse(catalog.hasLoaded("http://never-asked:1234"))
    }

    // MARK: - isFetching

    /// `Task.yield()` is not a synchronization primitive, and using one as if it were is what
    /// made this test fail intermittently in the full parallel run while passing in isolation.
    ///
    /// The shape was: `async let` starts the child, ONE `await Task.yield()`, then assert the
    /// child has already flipped the flag. A single yield hands the executor one opportunity to
    /// schedule the child — on a loaded cooperative pool it need not take it, and the assertion
    /// then reads "the flag was never set" when the truth is "the child had not started".
    /// D-4's triage table calls this form B: a real assertion on a real run, therefore this
    /// test's own nondeterminism rather than infrastructure.
    ///
    /// Replaced with a bounded WAIT on the condition, and a fetch slow enough that the window is
    /// wide rather than incidental.
    ///
    /// RED: stop setting `isFetching` at the start of `loadIfNeeded` → `observed` stays false
    /// and the first assertion fails after the deadline instead of flaking.
    func testIsFetching_isTrueOnlyWhileTheFetchRuns() async {
        let stub = StubClient()
        stub.fetchDelayNanos = 250_000_000
        let catalog = EmbeddingModelCatalog(clientFactory: { _ in stub })

        XCTAssertFalse(catalog.isFetching("http://x:1234"))
        async let inFlight: Void = catalog.loadIfNeeded(url: "http://x:1234")

        let deadline = ContinuousClock.now + .seconds(5)
        var observed = false
        while ContinuousClock.now < deadline {
            if catalog.isFetching("http://x:1234") { observed = true; break }
            await Task.yield()
        }

        XCTAssertTrue(observed, "isFetching must be true while the fetch is in flight")
        await inFlight
        XCTAssertFalse(catalog.isFetching("http://x:1234"))
    }
}
