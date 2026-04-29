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
/// State is keyed by `normalize(_:)` so trivial URL variations (trailing
/// slash, casing, leading/trailing whitespace) collapse to one entry.
///
/// Embedding models live in a separate fetch path
/// (`fetchEmbeddingModels`) and are NOT cached here — the Embeddings
/// card owns its own state because the filter shape differs.
@MainActor @Observable
final class ModelCatalog {
    /// Cached model lists, keyed by normalized URL.
    private(set) var modelsByURL: [String: [String]] = [:]
    /// Last fetch error per URL (cleared on success).
    private(set) var errorByURL: [String: String] = [:]
    /// URLs with an in-flight fetch — observable so pickers can render
    /// a spinner.
    private(set) var fetchingURLs: Set<String> = []

    private let clientFactory: () -> any LLMClient

    init(clientFactory: @escaping () -> any LLMClient = { LLMClientRouter() }) {
        self.clientFactory = clientFactory
    }

    /// Cached list for `url`, or `[]` if not fetched yet.
    func models(for url: String) -> [String] {
        modelsByURL[Self.normalize(url)] ?? []
    }

    /// Last error for `url`, or `nil`.
    func error(for url: String) -> String? {
        errorByURL[Self.normalize(url)]
    }

    /// `true` if a fetch for `url` is currently running.
    func isFetching(_ url: String) -> Bool {
        fetchingURLs.contains(Self.normalize(url))
    }

    /// Fetches the model list once. If the URL is already cached or
    /// currently fetching, this is a no-op. Used by view `.task(id:)` so
    /// opening multiple cards on the same server doesn't re-fetch.
    func loadIfNeeded(url: String) async {
        let key = Self.normalize(url)
        guard !key.isEmpty else { return }
        if modelsByURL[key] != nil { return }
        if fetchingURLs.contains(key) { return }
        await fetch(url: url)
    }

    /// Force re-fetch — wired to the Refresh button. Bypasses the cache
    /// hit but still coalesces with any in-flight fetch for the same URL.
    func refresh(url: String) async {
        let key = Self.normalize(url)
        guard !key.isEmpty else { return }
        if fetchingURLs.contains(key) { return }
        await fetch(url: url)
    }

    private func fetch(url: String) async {
        let key = Self.normalize(url)
        fetchingURLs.insert(key)
        errorByURL[key] = nil
        defer { fetchingURLs.remove(key) }

        let config = LLMConfig(provider: .lmStudio, baseURLString: url)
        do {
            let list = try await clientFactory()
                .fetchModels(config: config, visionOnly: false)
            modelsByURL[key] = list
        } catch {
            errorByURL[key] = error.localizedDescription
        }
    }

    /// Trim + lowercase + collapse trailing slashes so trivial URL
    /// variations (`http://x:1234/` vs `http://x:1234`) hit one cache entry.
    static func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }
}
