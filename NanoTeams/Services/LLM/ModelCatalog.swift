import Foundation

/// Process-wide cache of LM Studio chat-model lists keyed by base URL.
///
/// Multiple settings cards (LLM, Vision, Per-role override, Generated Team)
/// pick a model for a server endpoint. Without a shared cache, opening
/// multiple settings tabs would issue redundant `GET /api/v1/models` calls
/// against the same server. The catalog dedupes:
/// - `loadIfNeeded(url:)` is idempotent — fetches at most once per URL per
///   app session unless `refresh(url:)` is called.
/// - `refresh(url:)` is the user-initiated re-fetch (Refresh button).
/// - In-flight fetches are coalesced — concurrent calls for the same URL
///   return the same result without a second network round-trip.
///
/// Vision-capable models are cached separately per URL via the `visionOnly`
/// flag — `(url, visionOnly)` is the composite cache key.
///
/// State is keyed by `normalize(_:)` so trivial URL variations (trailing
/// slash, casing, leading/trailing whitespace) collapse to one entry.
///
/// Embedding models live in a separate fetch path (`fetchEmbeddingModels`)
/// and are NOT cached here: they are held by `EmbeddingModelCatalog`, whose
/// doc comment records the three differences that keep the two types apart.
/// It used to say "the Embeddings card owns its own state" — it did, and that
/// is exactly what put a live `LLMClientRouter` in a `#Preview`.
@MainActor @Observable
final class ModelCatalog {
    struct CacheKey: Hashable {
        let url: String
        let provider: LLMProvider
        let visionOnly: Bool
    }

    /// Identity of ONE model on one endpoint. Separate from `CacheKey` because it names a
    /// model rather than a list, and because `visionOnly` is meaningless here.
    struct DetailsKey: Hashable {
        let url: String
        let provider: LLMProvider
        let modelName: String
    }

    /// Cached model lists, keyed by `(normalized URL, visionOnly)`.
    ///
    /// Descriptors, not names: the fetch that fills this already carries each model's format and
    /// quantization (see `LLMModelInfo`), and storing names alone was where those two facts were
    /// lost for every surface in the app.
    private(set) var modelsByKey: [CacheKey: [LLMModelInfo]] = [:]
    /// Last fetch error per key (cleared on success).
    private(set) var errorByKey: [CacheKey: String] = [:]
    /// Keys with an in-flight fetch — observable so pickers can render
    /// a spinner.
    private(set) var fetchingKeys: Set<CacheKey> = []

    /// One model's load parameters, keyed by `(url, provider, modelName)`.
    ///
    /// Deliberately NOT cached the way `modelsByKey` is — see `loadDetails`. What is kept is
    /// the LAST answer per key, so a re-probe renders the previous values instead of
    /// flickering through an empty state, which is what the card did while it owned this.
    private(set) var detailsByKey: [DetailsKey: ModelLoadDetails] = [:]
    /// Keys whose probe has RETURNED, including one that returned nothing. `detailsByKey`
    /// alone collapses "never asked" and "asked, server had nothing to say", and the card
    /// renders those two differently.
    private(set) var loadedDetailKeys: Set<DetailsKey> = []
    private(set) var fetchingDetailKeys: Set<DetailsKey> = []

    private let clientFactory: () -> any LLMClient

    init(clientFactory: @escaping () -> any LLMClient = { LLMClientRouter() }) {
        self.clientFactory = clientFactory
    }

    /// Cached names for `(url, provider)`, or `[]` if not fetched yet. What every model PICKER
    /// reads — the order is the one `normalizedUnique` established and has always rendered.
    func models(for url: String, provider: LLMProvider, visionOnly: Bool = false) -> [String] {
        infos(for: url, provider: provider, visionOnly: visionOnly).map(\.name)
    }

    /// Cached descriptors for `(url, provider)`, or `[]` if not fetched yet. Same list, same order,
    /// with the format and quantization the server reported alongside each name.
    func infos(for url: String, provider: LLMProvider, visionOnly: Bool = false) -> [LLMModelInfo] {
        modelsByKey[key(url, provider, visionOnly)] ?? []
    }

    /// What this server said about ONE model, or nil when it did not list it — a model the user
    /// typed by hand, a stale selection, or a server that has not been fetched. Nil is never
    /// rendered as "no format": it means nobody asked, or nobody answered.
    ///
    /// Matched on the trimmed name, which is `LLMModelInfo`'s own invariant, so a selection carrying
    /// stray whitespace still finds its entry.
    func info(
        for url: String, provider: LLMProvider, modelName: String, visionOnly: Bool = false
    ) -> LLMModelInfo? {
        let target = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return infos(for: url, provider: provider, visionOnly: visionOnly)
            .first { $0.name == target }
    }

    /// Last error for `(url, provider)`, or `nil`.
    func error(for url: String, provider: LLMProvider, visionOnly: Bool = false) -> String? {
        errorByKey[key(url, provider, visionOnly)]
    }

    /// `true` if a fetch for `(url, provider)` is currently running.
    func isFetching(_ url: String, provider: LLMProvider, visionOnly: Bool = false) -> Bool {
        fetchingKeys.contains(key(url, provider, visionOnly))
    }

    /// `true` once a fetch for this key has RETURNED a list — including an empty
    /// one. `models(for:)` collapses "never fetched" and "fetched, server offered
    /// none" into `[]`, and those two want opposite things said about them: the
    /// second is a fact about the server, the first is a fact about us. Without
    /// this discriminator an empty result gets narrated from the reachability pill,
    /// which can be up to a poll interval stale — and then reads "Server is
    /// offline" about a server that just answered 2xx.
    func hasLoaded(_ url: String, provider: LLMProvider, visionOnly: Bool = false) -> Bool {
        modelsByKey[key(url, provider, visionOnly)] != nil
    }

    /// Fetches the model list once. If the key is already cached or
    /// currently fetching, this is a no-op. Used by view `.task(id:)` so
    /// opening multiple cards on the same server doesn't re-fetch.
    ///
    /// `provider` selects the wire format for the fetch (`/api/v1/models` vs
    /// `/api/tags`) AND is part of the cache key: override surfaces can pin a
    /// provider while inheriting the GLOBAL URL, so one URL can legitimately
    /// be probed under two providers within a session — a URL-only key would
    /// let the wrong-provider result (usually an error) poison the other
    /// surface's list.
    func loadIfNeeded(url: String, provider: LLMProvider, visionOnly: Bool = false) async {
        let k = key(url, provider, visionOnly)
        guard !k.url.isEmpty else { return }
        if modelsByKey[k] != nil { return }
        if fetchingKeys.contains(k) { return }
        await fetch(url: url, provider: provider, visionOnly: visionOnly)
    }

    /// Force re-fetch — wired to the Refresh button and to the status-bar picker's
    /// open gesture. Bypasses the cache hit but still coalesces with any in-flight
    /// fetch for the same key.
    ///
    /// Returns `true` only when THIS call completed a fetch that returned a list.
    /// That is positive proof the server is reachable: `reachabilityProbePath` and
    /// the model-list endpoint are the same path on both providers, so a returned
    /// list is a 2xx from the path the status pill probes. A `false` claims nothing
    /// — the fetch may have failed (401 = reachable but unauthorized; a decode error
    /// = reachable but mismatched) or coalesced onto someone else's in-flight fetch,
    /// whose outcome this call did not observe. Callers may only use `true` to turn
    /// reachability ON, never OFF.
    @discardableResult
    func refresh(url: String, provider: LLMProvider, visionOnly: Bool = false) async -> Bool {
        let k = key(url, provider, visionOnly)
        guard !k.url.isEmpty else { return false }
        if fetchingKeys.contains(k) { return false }
        return await fetch(url: url, provider: provider, visionOnly: visionOnly)
    }

    @discardableResult
    private func fetch(url: String, provider: LLMProvider, visionOnly: Bool) async -> Bool {
        let k = key(url, provider, visionOnly)
        fetchingKeys.insert(k)
        errorByKey[k] = nil
        defer { fetchingKeys.remove(k) }

        let config = LLMConfig(provider: provider, baseURLString: url)
        do {
            let list = try await clientFactory()
                .fetchModels(config: config, visionOnly: visionOnly)
            modelsByKey[k] = list
            return true
        } catch {
            errorByKey[k] = error.localizedDescription
            return false
        }
    }

    // MARK: - Per-model load details

    /// What the server reports about ONE loaded model, or `nil` when it has not answered yet
    /// or had nothing to say.
    func details(for config: LLMConfig) -> ModelLoadDetails? {
        detailsByKey[detailsKey(config)]
    }

    /// `true` once a probe for this model has RETURNED — including one that returned nothing.
    func hasLoadedDetails(for config: LLMConfig) -> Bool {
        loadedDetailKeys.contains(detailsKey(config))
    }

    func isLoadingDetails(for config: LLMConfig) -> Bool {
        fetchingDetailKeys.contains(detailsKey(config))
    }

    /// Probes one model's load parameters.
    ///
    /// Takes the whole `LLMConfig` rather than the three identity fields because the probe is
    /// a real request and the caller's timeout / keep-alive settings belong to it; only the
    /// identity triple becomes the key, so two configs differing in timeout are still the
    /// same model.
    ///
    /// Unlike the model LIST, this deliberately does NOT serve from cache: the card that
    /// reads it exists to report what the server has loaded *right now*, and a model can be
    /// evicted, re-loaded at a different context length, or swapped between two looks at the
    /// same picker. Only an in-flight probe for the same key is coalesced.
    ///
    /// Keying is also what replaces the caller's generation counter (CLAUDE.md #38): a slow
    /// probe from a previous selection writes into ITS OWN key, so it cannot overwrite the
    /// current one — the counter was guarding a single shared slot that no longer exists.
    func loadDetails(for config: LLMConfig) async {
        let k = detailsKey(config)
        guard !k.url.isEmpty, !k.modelName.isEmpty else { return }
        if fetchingDetailKeys.contains(k) { return }

        fetchingDetailKeys.insert(k)
        defer { fetchingDetailKeys.remove(k) }

        let fetched = await clientFactory().modelLoadDetails(config: config)
        loadedDetailKeys.insert(k)
        // `nil` is an answer ("the server told us nothing about this model"), so it must
        // REPLACE a previous one rather than leave stale values on screen.
        detailsByKey[k] = fetched
    }

    private func key(_ url: String, _ provider: LLMProvider, _ visionOnly: Bool) -> CacheKey {
        CacheKey(url: Self.normalize(url), provider: provider, visionOnly: visionOnly)
    }

    private func detailsKey(_ config: LLMConfig) -> DetailsKey {
        DetailsKey(
            url: Self.normalize(config.baseURLString),
            provider: config.provider,
            modelName: config.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Trim + lowercase + collapse trailing slashes so trivial URL
    /// variations (`http://x:1234/` vs `http://x:1234`) hit one cache entry.
    /// Delegates to the shared normalizer so the cache key can't drift from
    /// the Keychain account key or the model-load coalescing key.
    nonisolated static func normalize(_ url: String) -> String {
        url.normalizedBaseURL
    }
}
