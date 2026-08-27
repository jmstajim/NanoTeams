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
        var modelsToReturn: [LLMModelInfo] = [.init(name: "model-a"), .init(name: "model-b")]
        var visionModelsToReturn: [LLMModelInfo] = [.init(name: "vision-model-a")]
        var errorToThrow: Error?
        /// Used to artificially extend a fetch so two concurrent calls
        /// can race the in-flight dedup check.
        var fetchDelayNanos: UInt64 = 0

        var detailsToReturn: ModelLoadDetails? = ModelLoadDetails(
            fields: [.init(label: "Format", value: "gguf")])
        var detailsFetchCount = 0
        var lastDetailsConfig: LLMConfig?

        func modelLoadDetails(config: LLMConfig) async -> ModelLoadDetails? {
            detailsFetchCount += 1
            lastDetailsConfig = config
            if fetchDelayNanos > 0 {
                try? await Task.sleep(for: .nanoseconds(fetchDelayNanos))
            }
            return detailsToReturn
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] {
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

    // MARK: - Descriptors

    /// The catalog caches what the SERVER said about each model, not just its name. This is the
    /// half that used not to exist: `fetchModels` returned `[String]`, so format and quantization
    /// were decoded off the wire and dropped before anything could read them.
    /// RED: store `list.map(\.name)` and rebuild descriptors on read → both fields come back nil.
    func testInfos_cachesFormatAndQuantizationAlongsideNames() async {
        let stub = StubClient()
        stub.modelsToReturn = [
            .init(name: "qwen3.8-4b", format: "gguf", quantization: "Q4_K_M"),
            .init(name: "google/gemma-4-e2b", format: "mlx", quantization: "4bit"),
        ]
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        let infos = catalog.infos(for: "http://x:1234", provider: .lmStudio)
        XCTAssertEqual(infos.map(\.format), ["gguf", "mlx"])
        XCTAssertEqual(infos.map(\.quantization), ["Q4_K_M", "4bit"])
    }

    /// `models(for:)` is what every picker reads and must keep returning bare names in the SAME
    /// order the descriptors are held in — the pickers were not touched by the widening, and an
    /// order that moved would be a silent regression in six unrelated surfaces.
    func testModels_returnsTheDescriptorNamesInOrder() async {
        let stub = StubClient()
        stub.modelsToReturn = [
            .init(name: "alpha", format: "gguf"),
            .init(name: "beta", format: "mlx"),
        ]
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .lmStudio), ["alpha", "beta"])
    }

    /// One model, by name — what the Run tab's picker asks for the model it is about to measure.
    func testInfo_matchesByName_andTrimsTheQuery() async {
        let stub = StubClient()
        stub.modelsToReturn = [.init(name: "qwen3.8-4b", format: "gguf", quantization: "Q4_K_M")]
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        XCTAssertEqual(
            catalog.info(for: "http://x:1234", provider: .lmStudio, modelName: "  qwen3.8-4b ")?
                .quantization,
            "Q4_K_M")
    }

    /// Nil is "nobody asked, or nobody answered" — never "this model has no format". A model the
    /// server did not list, an empty selection, and a server that was never fetched are all nil.
    func testInfo_nilForUnlistedModelEmptyNameAndUnfetchedServer() async {
        let stub = StubClient()
        stub.modelsToReturn = [.init(name: "listed", format: "gguf")]
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        XCTAssertNil(catalog.info(for: "http://x:1234", provider: .lmStudio, modelName: "absent"))
        XCTAssertNil(catalog.info(for: "http://x:1234", provider: .lmStudio, modelName: "   "))
        XCTAssertNil(catalog.info(for: "http://other:1234", provider: .lmStudio, modelName: "listed"))
    }

    /// A failed fetch writes nothing, so neither view of the cache invents a row.
    func testInfos_emptyAfterFailedFetch() async {
        let stub = StubClient()
        stub.errorToThrow = NSError(domain: "test", code: 1)
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        XCTAssertTrue(catalog.infos(for: "http://x:1234", provider: .lmStudio).isEmpty)
        XCTAssertTrue(catalog.models(for: "http://x:1234", provider: .lmStudio).isEmpty)
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

        stub.modelsToReturn = [.init(name: "model-c")]
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
        stub.modelsToReturn = [.init(name: "lm-model")]
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)
        stub.modelsToReturn = [.init(name: "ollama-model")]
        await catalog.loadIfNeeded(url: "http://x:1234", provider: .ollama)

        XCTAssertEqual(stub.fetchCount, 2, "different provider = different cache entry = second fetch")
        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .lmStudio), ["lm-model"])
        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .ollama), ["ollama-model"])
    }

    // MARK: - refresh's success return (reachability evidence)

    /// A returned list is a 2xx from `reachabilityProbePath` — the same path the
    /// status pill probes — so the status-bar picker may use it to turn the pill
    /// green without paying a second round-trip.
    func testRefresh_onSuccess_reportsTrue() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        let reached = await catalog.refresh(url: "http://x:1234", provider: .lmStudio)

        XCTAssertTrue(reached)
    }

    /// A failure proves nothing about reachability (401 = reachable but
    /// unauthorized; a decode error = reachable but mismatched), so it must not be
    /// reported as evidence in either direction.
    func testRefresh_onFailure_reportsFalse() async {
        let stub = StubClient()
        stub.errorToThrow = NSError(domain: "test", code: 1)
        let catalog = ModelCatalog(clientFactory: { stub })

        let reached = await catalog.refresh(url: "http://x:1234", provider: .lmStudio)

        XCTAssertFalse(reached)
    }

    /// Coalescing means THIS call observed no outcome. Reporting the in-flight
    /// caller's eventual success would be claiming evidence we never saw.
    /// Mutation: return `true` from the in-flight early return → a picker open that
    /// piggybacks on a doomed fetch turns the pill green.
    func testRefresh_whenCoalescingOntoAnInFlightFetch_reportsFalse() async {
        let stub = StubClient()
        stub.fetchDelayNanos = 200_000_000
        let catalog = ModelCatalog(clientFactory: { stub })

        async let first = catalog.refresh(url: "http://x:1234", provider: .lmStudio)
        // Let the first call insert its key before the second checks it.
        try? await Task.sleep(for: .milliseconds(30))
        let second = await catalog.refresh(url: "http://x:1234", provider: .lmStudio)
        let firstResult = await first

        XCTAssertTrue(firstResult, "The call that actually fetched saw the outcome")
        XCTAssertFalse(second, "The coalesced call observed nothing and must claim nothing")
        XCTAssertEqual(stub.fetchCount, 1)
    }

    func testRefresh_emptyURL_reportsFalse() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        let reached = await catalog.refresh(url: "   ", provider: .lmStudio)

        XCTAssertFalse(reached)
        XCTAssertEqual(stub.fetchCount, 0)
    }

    // MARK: - hasLoaded discriminator

    func testHasLoaded_falseBeforeAnyFetch() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        XCTAssertFalse(catalog.hasLoaded("http://x:1234", provider: .lmStudio),
                       "Nothing fetched yet — 'never fetched' must read false")
    }

    func testHasLoaded_trueAfterSuccessfulFetch() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        XCTAssertTrue(catalog.hasLoaded("http://x:1234", provider: .lmStudio))
    }

    /// The whole reason `hasLoaded` exists: `models(for:)` collapses "never
    /// fetched" and "fetched, server offered none" into `[]`, and the picker
    /// must say opposite things about them. An implementation derived from the
    /// list's emptiness (the natural shortcut) fails exactly here.
    func testHasLoaded_trueAfterFetchReturningEmptyList() async {
        let stub = StubClient()
        stub.modelsToReturn = []
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        XCTAssertTrue(catalog.hasLoaded("http://x:1234", provider: .lmStudio),
                      "A returned EMPTY list is still a completed fetch — a fact about the server, not about us")
        XCTAssertEqual(catalog.models(for: "http://x:1234", provider: .lmStudio), [],
                       "…and is indistinguishable from 'never fetched' through models(for:) alone")
    }

    func testHasLoaded_falseAfterFailedFetch() async {
        let stub = StubClient()
        stub.errorToThrow = NSError(domain: "test", code: 1)
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        XCTAssertFalse(catalog.hasLoaded("http://x:1234", provider: .lmStudio),
                       "fetch writes modelsByKey only on success — a failure must not read as 'loaded'")
    }

    func testHasLoaded_isScopedToItsKey() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadIfNeeded(url: "http://x:1234", provider: .lmStudio)

        XCTAssertFalse(catalog.hasLoaded("http://other:1234", provider: .lmStudio))
        XCTAssertFalse(catalog.hasLoaded("http://x:1234", provider: .ollama))
        XCTAssertFalse(catalog.hasLoaded("http://x:1234", provider: .lmStudio, visionOnly: true))
        XCTAssertTrue(catalog.hasLoaded("http://x:1234/", provider: .lmStudio),
                      "Trivial URL variations must hit the same cache entry")
    }

    // MARK: - isFetching observability

    /// The picker's spinner and its disabled Refresh button both read this, and it
    /// had no test at all.
    func testIsFetching_isTrueDuringAFetchAndFalseAfter() async {
        let stub = StubClient()
        stub.fetchDelayNanos = 200_000_000
        let catalog = ModelCatalog(clientFactory: { stub })

        XCTAssertFalse(catalog.isFetching("http://x:1234", provider: .lmStudio))
        async let inFlight: Bool = catalog.refresh(url: "http://x:1234", provider: .lmStudio)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(catalog.isFetching("http://x:1234", provider: .lmStudio))

        _ = await inFlight
        XCTAssertFalse(catalog.isFetching("http://x:1234", provider: .lmStudio))
    }

    /// `isFetching` is per key, so one endpoint's spinner never appears on another's
    /// picker.
    func testIsFetching_isScopedToItsKey() async {
        let stub = StubClient()
        stub.fetchDelayNanos = 200_000_000
        let catalog = ModelCatalog(clientFactory: { stub })

        async let inFlight: Bool = catalog.refresh(url: "http://x:1234", provider: .lmStudio)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(catalog.isFetching("http://x:1234", provider: .lmStudio))
        XCTAssertFalse(catalog.isFetching("http://other:1234", provider: .lmStudio))
        XCTAssertFalse(catalog.isFetching("http://x:1234", provider: .ollama))

        _ = await inFlight
    }

    // MARK: - Per-model load details

    /// The details probe deliberately does NOT serve from cache: the card that reads it
    /// reports what the server has loaded RIGHT NOW, and a model can be evicted or re-loaded
    /// at a different context length between two looks at the same picker.
    func testLoadDetails_refetchesEveryTime_ratherThanCaching() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://x:1234", modelName: "m")

        await catalog.loadDetails(for: config)
        await catalog.loadDetails(for: config)

        XCTAssertEqual(stub.detailsFetchCount, 2)
        XCTAssertEqual(catalog.details(for: config)?.fields.first?.value, "gguf")
    }

    /// The probe is a real request, so the caller's timeout / keep-alive settings must ride
    /// along — only the identity triple becomes the key.
    func testLoadDetails_passesTheWholeConfigThrough() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })
        let config = LLMConfig(
            provider: .ollama, baseURLString: "http://x:11434", modelName: "m",
            requestTimeoutSeconds: 42)

        await catalog.loadDetails(for: config)

        XCTAssertEqual(stub.lastDetailsConfig?.requestTimeoutSeconds, 42)
        XCTAssertEqual(stub.lastDetailsConfig?.provider, .ollama)
    }

    /// Keyed by `(url, provider, model)` — which is what replaced the card's generation
    /// counter (CLAUDE.md #38). A slow probe for one selection lands in its own slot.
    func testLoadDetails_isKeyedPerModelEndpointAndProvider() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })
        let a = LLMConfig(provider: .lmStudio, baseURLString: "http://x:1234", modelName: "a")
        let b = LLMConfig(provider: .lmStudio, baseURLString: "http://x:1234", modelName: "b")

        stub.detailsToReturn = ModelLoadDetails(fields: [.init(label: "Format", value: "for-a")])
        await catalog.loadDetails(for: a)
        stub.detailsToReturn = ModelLoadDetails(fields: [.init(label: "Format", value: "for-b")])
        await catalog.loadDetails(for: b)

        XCTAssertEqual(catalog.details(for: a)?.fields.first?.value, "for-a")
        XCTAssertEqual(catalog.details(for: b)?.fields.first?.value, "for-b")
        XCTAssertFalse(catalog.hasLoadedDetails(
            for: LLMConfig(provider: .ollama, baseURLString: "http://x:1234", modelName: "a")))
    }

    /// A trimmed model name is the same model — the card hands over whatever is in the field.
    func testLoadDetails_trimsTheModelNameIntoTheKey() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadDetails(
            for: LLMConfig(provider: .lmStudio, baseURLString: "http://x:1234", modelName: " m "))

        XCTAssertTrue(catalog.hasLoadedDetails(
            for: LLMConfig(provider: .lmStudio, baseURLString: "HTTP://X:1234/", modelName: "m")))
    }

    /// Nothing selected, or no server, is not a probe. The card renders its own empty row for
    /// the first, and the second cannot be asked at all.
    func testLoadDetails_isANoOpWithoutAModelOrAURL() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })

        await catalog.loadDetails(
            for: LLMConfig(provider: .lmStudio, baseURLString: "http://x:1234", modelName: "  "))
        await catalog.loadDetails(
            for: LLMConfig(provider: .lmStudio, baseURLString: "", modelName: "m"))

        XCTAssertEqual(stub.detailsFetchCount, 0)
    }

    /// `nil` is an ANSWER — "the server told us nothing about this model" — so it must replace
    /// the previous values rather than leave stale ones on screen, while still counting as
    /// loaded so the card can tell it apart from "never asked".
    func testLoadDetails_nilAnswerReplacesTheOldValue_andCountsAsLoaded() async {
        let stub = StubClient()
        let catalog = ModelCatalog(clientFactory: { stub })
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://x:1234", modelName: "m")
        await catalog.loadDetails(for: config)
        XCTAssertNotNil(catalog.details(for: config))

        stub.detailsToReturn = nil
        await catalog.loadDetails(for: config)

        XCTAssertNil(catalog.details(for: config))
        XCTAssertTrue(catalog.hasLoadedDetails(for: config))
    }

    func testLoadDetails_concurrentProbesCoalesce_andDriveIsLoading() async {
        let stub = StubClient()
        stub.fetchDelayNanos = 200_000_000
        let catalog = ModelCatalog(clientFactory: { stub })
        let config = LLMConfig(provider: .lmStudio, baseURLString: "http://x:1234", modelName: "m")

        XCTAssertFalse(catalog.isLoadingDetails(for: config))
        async let first: Void = catalog.loadDetails(for: config)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(catalog.isLoadingDetails(for: config))
        async let second: Void = catalog.loadDetails(for: config)
        _ = await (first, second)

        XCTAssertEqual(stub.detailsFetchCount, 1)
        XCTAssertFalse(catalog.isLoadingDetails(for: config))
    }
}
