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

    /// Cached list for `url`, or `[]` if not fetched yet.
    func models(for url: String, visionOnly: Bool = false) -> [String] {
        modelsByKey[key(url, visionOnly)] ?? []
    }

    /// Last error for `url`, or `nil`.
    func error(for url: String, visionOnly: Bool = false) -> String? {
        errorByKey[key(url, visionOnly)]
    }

    /// `true` if a fetch for `url` is currently running.
    func isFetching(_ url: String, visionOnly: Bool = false) -> Bool {
        fetchingKeys.contains(key(url, visionOnly))
    }

    /// Fetches the model list once. If the URL is already cached or
    /// currently fetching, this is a no-op. Used by view `.task(id:)` so
    /// opening multiple cards on the same server doesn't re-fetch.
    func loadIfNeeded(url: String, visionOnly: Bool = false) async {
        let k = key(url, visionOnly)
        guard !k.url.isEmpty else { return }
        if modelsByKey[k] != nil { return }
        if fetchingKeys.contains(k) { return }
        await fetch(url: url, visionOnly: visionOnly)
    }

    /// Force re-fetch — wired to the Refresh button. Bypasses the cache
    /// hit but still coalesces with any in-flight fetch for the same URL.
    func refresh(url: String, visionOnly: Bool = false) async {
        let k = key(url, visionOnly)
        guard !k.url.isEmpty else { return }
        if fetchingKeys.contains(k) { return }
        await fetch(url: url, visionOnly: visionOnly)
    }

    private func fetch(url: String, visionOnly: Bool) async {
        let k = key(url, visionOnly)
        fetchingKeys.insert(k)
        errorByKey[k] = nil
        defer { fetchingKeys.remove(k) }

        let config = LLMConfig(provider: .lmStudio, baseURLString: url)
        do {
            let list = try await clientFactory()
                .fetchModels(config: config, visionOnly: visionOnly)
            modelsByKey[k] = list
        } catch {
            errorByKey[k] = error.localizedDescription
        }
    }

    private func key(_ url: String, _ visionOnly: Bool) -> CacheKey {
        CacheKey(url: Self.normalize(url), visionOnly: visionOnly)
    }

    /// Trim + lowercase + collapse trailing slashes so trivial URL
    /// variations (`http://x:1234/` vs `http://x:1234`) hit one cache entry.
    static func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }
}
