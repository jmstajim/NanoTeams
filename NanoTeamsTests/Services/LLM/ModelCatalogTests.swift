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
        var lastConfig: LLMConfig?
        var lastVisionOnly: Bool = false
        var modelsToReturn: [String] = ["model-a", "model-b"]
        var visionModelsToReturn: [String] = ["vision-model-a"]
        var errorToThrow: Error?
        /// Used to artificially extend a fetch so two concurrent calls
        /// can race the in-flight dedup check.
        var fetchDelayNanos: UInt64 = 0

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] {
            fetchCount += 1
            lastVisionOnly = visionOnly
            lastConfig = config
            if fetchDelayNanos > 0 {
                try? await Task.sleep(for: .nanoseconds(fetchDelayNanos))
            }
            if let err = errorToThrow { throw err }
            return visionOnly ? visionModelsToReturn : modelsToReturn
        }

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

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        XCTAssertEqual(stub.fetchCount, 1,
                       "Cached URL must NOT trigger a second fetch")
        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .lmStudio), ["model-a", "model-b"])
    }

    func testLoadIfNeeded_normalizesURLBeforeCacheLookup() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        await catalog.loadIfNeeded(url: "http://x:1234/", provider: .lmStudio)
        await catalog.loadIfNeeded(url: "  HTTP://X:1234  ", provider: .lmStudio)

        XCTAssertEqual(stub.fetchCount, 1,
                       "Trivial URL variations must collapse to one cache entry")
    }

    func testLoadIfNeeded_emptyURL_isNoOp() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "", provider: .lmStudio)
        await catalog.loadIfNeeded(url: "   ", provider: .lmStudio)

        XCTAssertEqual(stub.fetchCount, 0,
                       "Empty URL must not trigger a fetch — picker would have nothing to talk to")
    }

    // MARK: - refresh always re-fetches

    func testRefresh_forceRefetchesEvenWhenCached() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        XCTAssertEqual(stub.fetchCount, 1)

        stub.modelsToReturn = ["model-c"]
        await catalog.refresh(url: "http://x:1234", provider: .lmStudio)

        XCTAssertEqual(stub.fetchCount, 2,
                       "Refresh must always re-fetch — that's its whole purpose")
        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .lmStudio), ["model-c"],
                       "Cache must be updated with the fresh result")
    }

    // MARK: - Different URLs are independent

    func testDifferentURLs_eachFetchedOnce() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        await catalog.loadIfNeeded(url: "http://y:1234", provider: .lmStudio)

        XCTAssertEqual(stub.fetchCount, 2)
        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .lmStudio), ["model-a", "model-b"])
        XCTAssertEqual(catalog.models(for: "http://y:1234", provider: .lmStudio), ["model-a", "model-b"])
    }

    // MARK: - Error handling

    func testFetchFailure_surfacesError_emptyList() async {
        let stub = StubClient()
        stub.errorToThrow = NSError(
            domain: "test", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Could not connect."]
        )
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .lmStudio), [])
        XCTAssertEqual(catalog.error(for: "http://x:1234", provider: .lmStudio), "Could not connect.")
    }

    func testRefresh_clearsPriorError_onSuccess() async {
        let stub = StubClient()
        stub.errorToThrow = NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "fail"])
        let catalog = ModelCatalog(clientFactory: { stub })
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        XCTAssertNotNil(catalog.error(for: "http://x:1234", provider: .lmStudio))

        stub.errorToThrow = nil
        await catalog.refresh(url: "http://x:1234", provider: .lmStudio)
        XCTAssertNil(catalog.error(for: "http://x:1234", provider: .lmStudio),
                     "Successful refresh must clear the prior error")
    }

    // MARK: - In-flight dedup

    // MARK: - visionOnly cache split

    func testVisionOnly_cachedSeparatelyFromAllModels() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio, visionOnly: true)

        XCTAssertEqual(stub.fetchCount, 2,
                       "Same URL with different visionOnly must fetch twice — separate cache entries")
        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .lmStudio), ["model-a", "model-b"])
        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .lmStudio, visionOnly: true), ["vision-model-a"])
    }

    func testVisionOnly_passesFlagToClient() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio, visionOnly: true)

        XCTAssertTrue(stub.lastVisionOnly,
                      "ModelCatalog must forward visionOnly to the LLMClient")
    }

    func testVisionOnly_cachedFetchDoesNotRepeat() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio, visionOnly: true)
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio, visionOnly: true)

        XCTAssertEqual(stub.fetchCount, 1,
                       "Vision cache must dedup independently of the all-models cache")
    }

    func testVisionOnly_errorIsolatedFromAllModelsCache() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        // All-models succeeds.
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        XCTAssertNil(catalog.error(for: "http://x:1234", provider: .lmStudio))

        // Vision-only fails.
        stub.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "vision fail"])
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio, visionOnly: true)

        XCTAssertNil(catalog.error(for: "http://x:1234", provider: .lmStudio),
                     "All-models cache error must not be polluted by vision-only failure")
        XCTAssertEqual(catalog.error(for: "http://x:1234", provider: .lmStudio, visionOnly: true), "vision fail")
    }

    // MARK: - In-flight dedup

    func testConcurrentLoadIfNeeded_secondCallSkipped() async {
        let stub = StubClient()
        // 50ms delay so both Tasks can observe each other in flight.
        stub.fetchDelayNanos = 50_000_000
        let catalog = ModelCatalog(clientFactory: { stub })

        async let a: Void = catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        async let b: Void = catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        _ = await (a, b)

        XCTAssertEqual(stub.fetchCount, 1,
                       "Concurrent loadIfNeeded for the same URL must coalesce — one network call total")
    }

    // MARK: - Provider threading

    func testFetch_threadsProviderIntoClientConfig() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })
        await catalog.loadIfNeeded(url: "http://x:11434", provider: .ollama)
        XCTAssertEqual(stub.lastConfig?.provider, .ollama,
                       "Re-hardcoding .lmStudio inside fetch() would make the provider parameter cosmetic")
        XCTAssertEqual(stub.lastConfig?.baseURLString, "http://x:11434")
    }

    func testCacheKey_separatesProvidersOnTheSameURL() async {
        // Override surfaces can pin a provider while inheriting the GLOBAL
        // URL — one URL under two providers must be two cache entries so a
        // wrong-provider result (usually an error) can't poison the other
        // surface's list.
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })
        stub.modelsToReturn = ["lm-model"]
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        stub.modelsToReturn = ["ollama-model"]
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .ollama)

        XCTAssertEqual(stub.fetchCount, 2, "different provider = different cache entry = second fetch")
        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .lmStudio), ["lm-model"])
        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .ollama), ["ollama-model"])
    }
}
