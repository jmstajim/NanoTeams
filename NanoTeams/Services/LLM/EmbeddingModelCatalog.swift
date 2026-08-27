import Foundation

/// Process-wide cache of embedding-model lists, keyed by base URL.
///
/// Sibling of `ModelCatalog`, and a SEPARATE type rather than another axis on its `CacheKey`
/// — the split `ModelCatalog`'s own doc comment already records as deliberate. Three reasons,
/// each of which would have to be papered over to merge them: that one stores
/// `[LLMModelInfo]` (name + format + quantization) from `fetchModels`, this one stores the
/// `[String]` that `fetchEmbeddingModels` returns; that one keys on provider because one URL
/// can legitimately be probed under two, while embeddings are LM-Studio-only; and only this
/// one has to honour a bearer token the user has TYPED but not yet saved, which is what the
/// resolver argument on `clientFactory` exists for.
///
/// **Why the fetch lives here and not in the card that renders it.** The default factory
/// resolves OUTWARD to a live `LLMClientRouter` (CLAUDE.md #49), so while this ran as a
/// stored property of `ExploratorySearchEmbeddingsCard` its `#Preview` issued a real request
/// against whatever embedding server the developer had configured, on canvas open — the
/// card's `.task` gates only on the list being empty. The seam that was supposed to prevent
/// that was `var client: any LLMClient = LLMClientRouter()`, documented "Injected for
/// testability" and injected by nothing: measured 0 call sites out of 2 constructions, and
/// no test built the card at all. Moving the fetch out is what makes the claim true —
/// `coverage/tools/swiftui_declarations.py` axis v1 now ranks the two catalog types too, so
/// a view that constructs one directly is a review event rather than a silent edit.
///
/// Caching contract mirrors `ModelCatalog` exactly, so the two behave the same way under the
/// same gestures: `loadIfNeeded` is the idempotent first-appear load, `refresh` is the
/// user-initiated force-fetch (Refresh button, URL commit), and both coalesce against an
/// in-flight fetch for the same URL.
@MainActor @Observable
final class EmbeddingModelCatalog {

    /// Cached lists, keyed by normalized URL. Absent means "never fetched"; present-and-empty
    /// means the server answered and offered no embedding model — the same distinction
    /// `ModelCatalog.hasLoaded` exists to preserve.
    private(set) var modelsByURL: [String: [String]] = [:]
    /// Last fetch error per URL, cleared when a fetch starts and on success.
    private(set) var errorByURL: [String: String] = [:]
    /// URLs with an in-flight fetch — observable so the picker can render a spinner.
    private(set) var fetchingURLs: Set<String> = []

    /// Builds the client for one fetch. The argument is the typed-but-unsaved bearer token's
    /// resolver, or `nil` when the user has not typed one and the Keychain-backed default is
    /// what should answer.
    private let clientFactory: ((any LLMTokenResolver)?) -> any LLMClient

    init(
        clientFactory: @escaping ((any LLMTokenResolver)?) -> any LLMClient = { resolver in
            if let resolver { return LLMClientRouter(tokenResolver: resolver) }
            return LLMClientRouter()
        }
    ) {
        self.clientFactory = clientFactory
    }

    // MARK: - Reads

    /// Cached names for `url`, or `[]` if not fetched yet.
    func models(for url: String) -> [String] {
        modelsByURL[Self.normalize(url)] ?? []
    }

    /// `true` once a fetch for this URL has RETURNED a list, including an empty one.
    /// `models(for:)` collapses "never fetched" and "fetched, server offered none" into `[]`,
    /// and those two want opposite things said about them.
    func hasLoaded(_ url: String) -> Bool {
        modelsByURL[Self.normalize(url)] != nil
    }

    /// Last error for `url`, or `nil`.
    func error(for url: String) -> String? {
        errorByURL[Self.normalize(url)]
    }

    /// `true` if a fetch for `url` is currently running.
    func isFetching(_ url: String) -> Bool {
        fetchingURLs.contains(Self.normalize(url))
    }

    // MARK: - Fetch

    /// Fetches the list once. A cached or in-flight URL is a no-op, so several cards opening
    /// on the same server don't re-issue the request. Wired to the card's `.task`.
    func loadIfNeeded(url: String, tokenOverride: String? = nil) async {
        let key = Self.normalize(url)
        guard !key.isEmpty else { return }
        if modelsByURL[key] != nil { return }
        if fetchingURLs.contains(key) { return }
        await fetch(url: url, tokenOverride: tokenOverride)
    }

    /// Force re-fetch — the Refresh button and the URL/token commit paths. Bypasses the cache
    /// hit but still coalesces with any in-flight fetch for the same URL.
    ///
    /// Returns `true` only when THIS call completed a fetch that returned a list; `false`
    /// claims nothing, exactly as on `ModelCatalog.refresh` — the fetch may have failed, or
    /// coalesced onto someone else's in-flight fetch whose outcome this call did not observe.
    @discardableResult
    func refresh(url: String, tokenOverride: String? = nil) async -> Bool {
        let key = Self.normalize(url)
        guard !key.isEmpty else { return false }
        if fetchingURLs.contains(key) { return false }
        return await fetch(url: url, tokenOverride: tokenOverride)
    }

    @discardableResult
    private func fetch(url: String, tokenOverride: String?) async -> Bool {
        let key = Self.normalize(url)
        fetchingURLs.insert(key)
        errorByURL[key] = nil
        defer { fetchingURLs.remove(key) }

        // The override is keyed by the URL the request will actually go to, which is the
        // un-normalized one the caller holds: `OverridingLLMTokenResolver` matches on the
        // request's own base URL.
        let resolver: (any LLMTokenResolver)? = tokenOverride
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : OverridingLLMTokenResolver(overrides: [url: $0]) }

        let config = LLMConfig(provider: .lmStudio, baseURLString: url)
        do {
            // A failed fetch deliberately leaves the previous list standing: a transient 401
            // while the user retypes a token should surface as an error row, not as a picker
            // that empties itself.
            modelsByURL[key] = try await clientFactory(resolver).fetchEmbeddingModels(config: config)
            return true
        } catch {
            errorByURL[key] = "Failed to load embedding models: \(error.localizedDescription)"
            return false
        }
    }

    /// Trim + lowercase + collapse trailing slashes, through the shared normalizer, so this
    /// cache key cannot drift from `ModelCatalog`'s or from the Keychain account key.
    nonisolated static func normalize(_ url: String) -> String {
        url.normalizedBaseURL
    }
}
