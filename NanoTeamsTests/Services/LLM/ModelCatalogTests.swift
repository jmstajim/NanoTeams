import XCTest
@testable import NanoTeams

/// Pins the dedup + caching contract of `ModelCatalog`. The catalog is
/// the single source of truth for LM Studio model lists across every
/// settings card, so these invariants are load-bearing:
/// - one network call per URL per `loadIfNeeded` lifetime
/// - in-flight fetches coalesce instead of duplicating
/// - `refresh` is the explicit force-fetch path
/// - URL normalization collapses trivial differences (slash, casing)
@MainActor
final class ModelCatalogTests: XCTestCase {

    // MARK: - Stub client

    private final class StubClient: LLMClient, @unchecked Sendable {
        var fetchCount: Int = 0
        var modelsToReturn: [String] = ["model-a", "model-b"]
        var errorToThrow: Error?
        /// Used to artificially extend a fetch so two concurrent calls
        /// can race the in-flight dedup check.
        var fetchDelayNanos: UInt64 = 0

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] {
            fetchCount += 1
            if fetchDelayNanos > 0 {
                try? await Task.sleep(nanoseconds: fetchDelayNanos)
            }
            if let err = errorToThrow { throw err }
            return modelsToReturn
        }

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            session: LLMSession?,
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    // MARK: - URL normalization

    func testNormalize_collapsesTrailingSlash() {
        XCTAssertEqual(ModelCatalog.normalize("http://x:1234/"), "http://x:1234")
        XCTAssertEqual(ModelCatalog.normalize("http://x:1234"), "http://x:1234")
    }

    func testNormalize_lowercases() {
        XCTAssertEqual(ModelCatalog.normalize("HTTP://X:1234"), "http://x:1234")
    }

    func testNormalize_trimsWhitespace() {
        XCTAssertEqual(ModelCatalog.normalize("  http://x:1234  "), "http://x:1234")
    }

    func testNormalize_collapsesMultipleTrailingSlashes() {
        XCTAssertEqual(ModelCatalog.normalize("http://x:1234///"), "http://x:1234")
    }

    // MARK: - loadIfNeeded dedup

    func testLoadIfNeeded_fetchesOnce_thenServesFromCache() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234")
        await catalog.loadIfNeeded(url: "http://x:1234")
        await catalog.loadIfNeeded(url: "http://x:1234")

        XCTAssertEqual(stub.fetchCount, 1,
                       "Cached URL must NOT trigger a second fetch")
        XCTAssertEqual(catalog.models(for: "http://x:1234"), ["model-a", "model-b"])
    }

    func testLoadIfNeeded_normalizesURLBeforeCacheLookup() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234")
        await catalog.loadIfNeeded(url: "http://x:1234/")
        await catalog.loadIfNeeded(url: "  HTTP://X:1234  ")

        XCTAssertEqual(stub.fetchCount, 1,
                       "Trivial URL variations must collapse to one cache entry")
    }

    func testLoadIfNeeded_emptyURL_isNoOp() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "")
        await catalog.loadIfNeeded(url: "   ")

        XCTAssertEqual(stub.fetchCount, 0,
                       "Empty URL must not trigger a fetch — picker would have nothing to talk to")
    }

    // MARK: - refresh always re-fetches

    func testRefresh_forceRefetchesEvenWhenCached() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234")
        XCTAssertEqual(stub.fetchCount, 1)

        stub.modelsToReturn = ["model-c"]
        await catalog.refresh(url: "http://x:1234")

        XCTAssertEqual(stub.fetchCount, 2,
                       "Refresh must always re-fetch — that's its whole purpose")
        XCTAssertEqual(catalog.models(for: "http://x:1234"), ["model-c"],
                       "Cache must be updated with the fresh result")
    }

    // MARK: - Different URLs are independent

    func testDifferentURLs_eachFetchedOnce() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234")
        await catalog.loadIfNeeded(url: "http://y:1234")

        XCTAssertEqual(stub.fetchCount, 2)
        XCTAssertEqual(catalog.models(for: "http://x:1234"), ["model-a", "model-b"])
        XCTAssertEqual(catalog.models(for: "http://y:1234"), ["model-a", "model-b"])
    }

    // MARK: - Error handling

    func testFetchFailure_surfacesError_emptyList() async {
        let stub = StubClient()
        stub.errorToThrow = NSError(
            domain: "test", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Could not connect."]
        )
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234")

        XCTAssertEqual(catalog.models(for: "http://x:1234"), [])
        XCTAssertEqual(catalog.error(for: "http://x:1234"), "Could not connect.")
    }

    func testRefresh_clearsPriorError_onSuccess() async {
        let stub = StubClient()
        stub.errorToThrow = NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "fail"])
        let catalog = ModelCatalog(clientFactory: { stub })
        await catalog.loadIfNeeded(url: "http://x:1234")
        XCTAssertNotNil(catalog.error(for: "http://x:1234"))

        stub.errorToThrow = nil
        await catalog.refresh(url: "http://x:1234")
        XCTAssertNil(catalog.error(for: "http://x:1234"),
                     "Successful refresh must clear the prior error")
    }

    // MARK: - In-flight dedup

    func testConcurrentLoadIfNeeded_secondCallSkipped() async {
        let stub = StubClient()
        // 50ms delay so both Tasks can observe each other in flight.
        stub.fetchDelayNanos = 50_000_000
        let catalog = ModelCatalog(clientFactory: { stub })

        async let a: Void = catalog.loadIfNeeded(url: "http://x:1234")
        async let b: Void = catalog.loadIfNeeded(url: "http://x:1234")
        _ = await (a, b)

        XCTAssertEqual(stub.fetchCount, 1,
                       "Concurrent loadIfNeeded for the same URL must coalesce — one network call total")
    }
}
