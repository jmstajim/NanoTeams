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
/// Embedding models live in a separate fetch path
/// (`fetchEmbeddingModels`) and are NOT cached here — the Embeddings
/// card owns its own state because the filter shape differs.
@MainActor @Observable
final class ModelCatalog {
    struct CacheKey: Hashable {
        let url: String
        let provider: LLMProvider
        let visionOnly: Bool
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

    private func key(_ url: String, _ provider: LLMProvider, _ visionOnly: Bool) -> CacheKey {
        CacheKey(url: Self.normalize(url), provider: provider, visionOnly: visionOnly)
    }

    /// Trim + lowercase + collapse trailing slashes so trivial URL
    /// variations (`http://x:1234/` vs `http://x:1234`) hit one cache entry.
    /// Delegates to the shared normalizer so the cache key can't drift from
    /// the Keychain account key or the model-load coalescing key.
    nonisolated static func normalize(_ url: String) -> String {
        url.normalizedBaseURL
    }
}
