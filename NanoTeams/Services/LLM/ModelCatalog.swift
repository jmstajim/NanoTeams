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
    private(set) var modelsByKey: [CacheKey: [String]] = [:]
    /// Last fetch error per key (cleared on success).
    private(set) var errorByKey: [CacheKey: String] = [:]
    /// Keys with an in-flight fetch — observable so pickers can render
    /// a spinner.
    private(set) var fetchingKeys: Set<CacheKey> = []

    private let clientFactory: () -> any LLMClient

    init(clientFactory: @escaping () -> any LLMClient = { LLMClientRouter() }) {
        self.clientFactory = clientFactory
    }

    /// Cached list for `(url, provider)`, or `[]` if not fetched yet.
    func models(for url: String, provider: LLMProvider, visionOnly: Bool = false) -> [String] {
        modelsByKey[key(url, provider, visionOnly)] ?? []
    }

    /// Last error for `(url, provider)`, or `nil`.
    func error(for url: String, provider: LLMProvider, visionOnly: Bool = false) -> String? {
        errorByKey[key(url, provider, visionOnly)]
    }

    /// `true` if a fetch for `(url, provider)` is currently running.
    func isFetching(_ url: String, provider: LLMProvider, visionOnly: Bool = false) -> Bool {
        fetchingKeys.contains(key(url, provider, visionOnly))
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

    /// Force re-fetch — wired to the Refresh button. Bypasses the cache
    /// hit but still coalesces with any in-flight fetch for the same key.
    func refresh(url: String, provider: LLMProvider, visionOnly: Bool = false) async {
        let k = key(url, provider, visionOnly)
        guard !k.url.isEmpty else { return }
        if fetchingKeys.contains(k) { return }
        await fetch(url: url, provider: provider, visionOnly: visionOnly)
    }

    private func fetch(url: String, provider: LLMProvider, visionOnly: Bool) async {
        let k = key(url, provider, visionOnly)
        fetchingKeys.insert(k)
        errorByKey[k] = nil
        defer { fetchingKeys.remove(k) }

        let config = LLMConfig(provider: provider, baseURLString: url)
        do {
            let list = try await clientFactory()
                .fetchModels(config: config, visionOnly: visionOnly)
            modelsByKey[k] = list
        } catch {
            errorByKey[k] = error.localizedDescription
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
