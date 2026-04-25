import Foundation

/// Actor that owns the lifecycle of `VocabVectorIndex`: load from disk, rebuild
/// via `VocabVectorIndexBuilder`, persist atomically, serve `expand(...)` at
/// query time. One instance per work folder — created by
/// `SearchIndexCoordinator` alongside `SearchIndexService`.
///
/// State-machine:
/// ```
/// missing ──load()──► loading ──► missing | ready | error
/// *       ──rebuildIfNeeded──► building ──► ready | modelUnavailable | error
/// ```
/// Callers read `state` after awaiting. UI updates are driven by the
/// coordinator polling `state` — we don't expose an `AsyncStream` here to
/// avoid continuation-bookkeeping complexity.
actor VocabVectorIndexService {

    // MARK: - Types

    /// Result of a query-time expansion. Three cases are mutually exclusive
    /// by construction — no runtime guards needed. The `+ExpandedSearch.swift`
    /// consumer collapses `errorReason` and `unavailableReason` into the
    /// envelope's single `expansion_error` field.
    enum ExpansionResult: Sendable, Equatable {
        /// Successful expansion. `terms` may be empty when no vocab token
        /// crossed threshold — that's a legitimate "no close matches" result,
        /// distinct from `.unavailable` or `.transientError`.
        case expanded(terms: [String])

        /// Per-token tier produced `terms`, but the whole-phrase embedding
        /// call failed with a recoverable error (HTTP 5xx, timeout,
        /// transport). `terms` may be empty when there was no per-token
        /// coverage. Chat LLM sees this as "retry later if this matters".
        case transientError(terms: [String], reason: String)

        /// Expansion subsystem is structurally not available: vector index
        /// missing / building / loading / model not loaded / internal error.
        /// Chat LLM sees this as "don't expect expansion on subsequent
        /// queries until the state changes".
        case unavailable(reason: String)

        /// Terms (possibly empty) regardless of case. Callers that only care
        /// about the partial result use this.
        var terms: [String] {
            switch self {
            case .expanded(let terms), .transientError(let terms, _): return terms
            case .unavailable: return []
            }
        }

        /// Canonical envelope reason for transient failures. `nil` on
        /// `.expanded` / `.unavailable`.
        var errorReason: String? {
            if case .transientError(_, let reason) = self { return reason }
            return nil
        }

        /// Canonical envelope reason for structural unavailability. `nil` on
        /// `.expanded` / `.transientError`.
        var unavailableReason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }

        /// Canonical "no-op success" — expanded with no terms. Useful when
        /// the state machine permits expansion but the tokenize step produced
        /// nothing worth sending (empty / whitespace-only query).
        static let empty = ExpansionResult.expanded(terms: [])
    }

    /// Hard cap on a query string before it's sent to `/v1/embeddings`.
    /// Nomic v1.5's standard sequence length is 2048 tokens; 2000 chars
    /// (roughly 500-2000 tokens depending on content) stays well under any
    /// reasonable embedding-model limit AND is far more than any plausible
    /// search query.
    static let maxQueryLength = 2000

    // MARK: - Dependencies

    private let internalDir: URL
    private let client: any EmbeddingClient
    private let builder: VocabVectorIndexBuilder
    private let fileManager: FileManager
    private let binURL: URL
    private let metaURL: URL

    // MARK: - State

    private var cached: VocabVectorIndex?
    private(set) var state: VocabVectorIndexState = .missing
    private var progressHandler: (@Sendable (VocabVectorIndexBuilder.BuildProgress) -> Void)?

    /// Populated when `clear()` failed to remove either the bin or meta file.
    /// Surfaced for the same reason as `SearchIndexService.lastClearError` —
    /// silent failure means the next `load()` reads the stale on-disk copy
    /// after the user explicitly asked for a clear+rebuild. Cleared on a
    /// successful clear.
    private(set) var lastClearError: String?

    // MARK: - Init

    init(
        internalDir: URL,
        client: any EmbeddingClient,
        fileManager: FileManager = .default
    ) {
        self.internalDir = internalDir
        self.client = client
        self.builder = VocabVectorIndexBuilder(client: client)
        self.fileManager = fileManager
        self.binURL = internalDir.appendingPathComponent("vocab_vectors.bin", isDirectory: false)
        self.metaURL = internalDir.appendingPathComponent("vocab_vectors.meta.json", isDirectory: false)
    }

    // MARK: - Progress observation (for UI)

    /// Sets a closure called on each batch boundary during rebuild. Kept as a
    /// single-slot handler (not broadcast) because the only caller is the
    /// coordinator — it bridges progress into its `@MainActor @Observable`
    /// state field. Pass `nil` to clear.
    func setProgressHandler(
        _ handler: (@Sendable (VocabVectorIndexBuilder.BuildProgress) -> Void)?
    ) {
        self.progressHandler = handler
    }

    // MARK: - Load

    /// Reads `vocab_vectors.bin` + `vocab_vectors.meta.json` from disk.
    /// Transitions: `.missing` on no files, `.ready` on success, `.error` on
    /// any corruption (format drift, dim/count mismatch, Meta validation
    /// failure). Sets `.loading` on entry so the UI card can reflect the
    /// read in progress — cheap enough not to need progress granularity.
    func load() async {
        guard fileManager.fileExists(atPath: metaURL.path),
              fileManager.fileExists(atPath: binURL.path) else {
            cached = nil
            state = .missing
            return
        }
        state = .loading
        do {
            let metaData = try Data(contentsOf: metaURL)
            let decoder = JSONCoderFactory.makeDateDecoder()
            let meta = try decoder.decode(VocabVectorIndex.Meta.self, from: metaData)
            guard meta.version == VocabVectorIndex.Meta.currentVersion else {
                cached = nil
                state = .missing
                return
            }

            let binData = try Data(contentsOf: binURL, options: .mappedIfSafe)
            let vectors = try VocabVectorBinaryCodec.decode(
                data: binData,
                expectedDims: meta.dims,
                expectedCount: meta.tokenMap.count
            )
            // Throws on meta/vectors size mismatch — caught by the
            // surrounding `do/catch` which transitions to `.error` and leaves
            // `cached = nil` so the next `rebuildIfNeeded` regenerates.
            let index = try VocabVectorIndex(meta: meta, vectors: vectors)
            cached = index
            state = .ready(
                coverage: Self.coverage(meta: meta),
                failed: meta.failedTokens.count,
                vectorsCount: meta.tokenMap.count
            )
        } catch {
            // Corruption on disk — expose as `.error` so the UI surfaces the
            // specific decode failure. The next `rebuildIfNeeded` regenerates
            // because `cached == nil`, so recovery is automatic.
            cached = nil
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Rebuild

    /// Smart-diff rebuild. Embeds only tokens that are in `searchIndex` but
    /// not in the current `cached.meta.tokenMap`. Pass `force: true` to clear
    /// the token map first (equivalent to a full rebuild).
    ///
    /// `config` is passed in by the caller (typically the coordinator
    /// snapshotting the user's current settings on `MainActor`) rather than
    /// stored on the service. Keeps config refresh cheap — a setting change
    /// takes effect on the next call.
    func rebuildIfNeeded(
        searchIndex: SearchIndex,
        config: EmbeddingConfig,
        force: Bool
    ) async {
        state = .building(progress: VocabVectorIndexBuilder.BuildProgress(
            processed: 0, total: 0, failed: 0
        ))

        let progressHandler = self.progressHandler

        do {
            let result = try await builder.build(
                searchIndex: searchIndex,
                current: cached,
                config: config,
                force: force,
                progressHandler: { progress in
                    progressHandler?(progress)
                }
            )
            if result.needsPersist {
                try persist(index: result.index)
                cached = result.index
            } else if cached == nil {
                // Nothing to embed (tiny / empty corpus) and no existing
                // index: persist the empty skeleton so next load() doesn't
                // flip back to .missing.
                try persist(index: result.index)
                cached = result.index
            }
            state = .ready(
                coverage: Self.coverage(meta: (cached ?? result.index).meta),
                failed: (cached ?? result.index).meta.failedTokens.count,
                vectorsCount: (cached ?? result.index).meta.tokenMap.count
            )
        } catch is CancellationError {
            // Partial state is NOT persisted. Leave `cached` unchanged; on
            // next call the diff re-computes against the pre-cancellation bin.
            state = cached.map {
                .ready(
                    coverage: Self.coverage(meta: $0.meta),
                    failed: $0.meta.failedTokens.count,
                    vectorsCount: $0.meta.tokenMap.count
                )
            } ?? .missing
        } catch let err as EmbeddingClientError {
            if case .modelNotLoaded(let name) = err {
                state = .modelUnavailable(
                    reason: "Embedding model '\(name)' is not loaded in LM Studio."
                )
            } else {
                state = .error(err.errorDescription ?? "Embedding error")
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Expand (query-time)

    func expand(
        query: String,
        tokens: [String],
        config: EmbeddingConfig,
        perTokenThreshold: Float,
        phraseThreshold: Float
    ) async -> ExpansionResult {

        // Empty / whitespace-only query: no expansion, no error. Critical
        // guard — without it the whole-phrase path below ships only the
        // query prefix to the embedding model and gets back a garbage
        // vector that pollutes nearest-neighbor matches.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // Punctuation-only queries tokenize to `[]`. Per-token tier is a
        // no-op; whole-phrase tier would burn a `/v1/embeddings` call on
        // junk. Same semantics as `trimmed.isEmpty`: return `.empty`.
        guard !tokens.isEmpty else { return .empty }

        // Check the state machine.
        switch state {
        case .missing:
            return .unavailable(reason: Self.reasonMissing)
        case .building:
            return .unavailable(reason: Self.reasonBuilding)
        case .modelUnavailable:
            return .unavailable(reason: EmbeddingClientError.modelNotLoaded("").envelopeReason)
        case .error:
            return .unavailable(reason: Self.reasonInternalError)
        case .loading:
            return .unavailable(reason: Self.reasonLoading)
        case .ready:
            break
        }
        guard let index = cached else {
            return .unavailable(reason: Self.reasonMissing)
        }

        // Empty index (no vectors after vocab filter) — no candidates to
        // match against and `index.meta.dims` is 0, which would mis-fire as
        // `vector_index_dim_mismatch` against the live phrase vector. This
        // is a clean "no close matches" result, not an error state.
        guard index.meta.dims > 0, !index.meta.tokenMap.isEmpty else {
            return .empty
        }

        // Excluded: the original query tokens themselves. Lowercased to match
        // stored token casing.
        let loweredQueryTokens = Set(tokens.map {
            $0.lowercased(with: Locale(identifier: "en_US_POSIX"))
        })
        var related = Set<String>()

        // Tier 1: per-token expansion via precomputed vectors. Zero network.
        for token in tokens {
            if let vec = index.vector(for: token) {
                let hits = index.nearestTokens(
                    to: vec, k: 10, threshold: perTokenThreshold,
                    excluding: loweredQueryTokens
                )
                related.formUnion(hits.map(\.token))
            }
        }

        // Tier 2: whole-phrase expansion. Skip when the whole query is a
        // single vocab token — per-token already covered it. Otherwise fire
        // one `/v1/embeddings` call (~10-20ms locally).
        let needsPhraseEmbed = tokens.count > 1 ||
            tokens.first.flatMap { index.vector(for: $0) } == nil
        var liveError: String?

        if needsPhraseEmbed {
            let cappedQuery = String(trimmed.prefix(Self.maxQueryLength))
            do {
                // Query prefix is per-model — see `EmbeddingConfig.queryPrefix`.
                let vectors = try await client.embed(
                    texts: [config.queryPrefix + cappedQuery],
                    config: config
                )
                if let raw = vectors.first {
                    // Dim mismatch = live model differs from the model that
                    // built the persisted vectors (e.g. user swapped
                    // `EmbeddingConfig.modelName` mid-session). `nearestTokens`
                    // silently returns [] on mismatch; surfacing the reason
                    // explicitly lets the UI prompt a rebuild and the LLM
                    // know this isn't a clean "no close matches" result.
                    // Return the per-token terms already collected — they
                    // came from the persisted index and remain valid.
                    if raw.count != index.meta.dims {
                        return .transientError(
                            terms: Array(related).sorted(),
                            reason: Self.reasonDimMismatch
                        )
                    }
                    let normalized = VectorMath.normalize(raw)
                    let hits = index.nearestTokens(
                        to: normalized, k: 20, threshold: phraseThreshold,
                        excluding: loweredQueryTokens
                    )
                    related.formUnion(hits.map(\.token))
                }
            } catch is CancellationError {
                // Caller's tree was cancelled — propagate upward is handled
                // by Swift concurrency automatically; we just return what we
                // have so far. Don't mark as error.
            } catch let err as EmbeddingClientError {
                // On model-not-loaded mid-query, update state so the UI card
                // shows the right message.
                if case .modelNotLoaded(let name) = err {
                    state = .modelUnavailable(
                        reason: "Embedding model '\(name)' is not loaded in LM Studio."
                    )
                    return .unavailable(reason: err.envelopeReason)
                }
                liveError = err.envelopeReason
            } catch {
                liveError = EmbeddingClientError.transportError("").envelopeReason
            }
        }

        if let liveError {
            return .transientError(terms: Array(related).sorted(), reason: liveError)
        }
        return .expanded(terms: Array(related).sorted())
    }

    // MARK: - Canonical envelope reasons

    /// Canonical strings for state-driven unavailability. Embedding-specific
    /// reasons (model not loaded, HTTP, timeout, transport) come from
    /// `EmbeddingClientError.envelopeReason` — SSOT for those.
    static let reasonMissing = "vector_index_missing"
    static let reasonBuilding = "vector_index_building"
    static let reasonLoading = "vector_index_loading"
    static let reasonInternalError = "vector_index_error"
    static let reasonDimMismatch = "vector_index_dim_mismatch"

    // MARK: - Clear

    /// Deletes the on-disk bin + meta and drops the cache. Used on broad-search
    /// feature disable and on `SearchIndexService.clear()`. Surfaces
    /// removeItem failures via `lastClearError` so the coordinator can warn
    /// the user that the disk copy survived (a subsequent `load()` would
    /// resurrect the stale state).
    func clear() async {
        cached = nil
        state = .missing
        var failures: [String] = []
        for url in [binURL, metaURL] where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        lastClearError = failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    // MARK: - Persistence

    private func persist(index: VocabVectorIndex) throws {
        try fileManager.createDirectory(
            at: internalDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Atomic write: tmp + rename. If the process dies between the two
        // files being written we end up with meta mismatching bin on next
        // load — load() detects via dim/count mismatch and treats as missing.
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let metaData = try encoder.encode(index.meta)
        let binData = VocabVectorBinaryCodec.encode(
            vectors: index.vectors,
            count: index.meta.tokenMap.count,
            dims: index.meta.dims
        )

        try metaData.write(to: metaURL, options: .atomic)
        try binData.write(to: binURL, options: .atomic)
    }

    // MARK: - Helpers

    private static func coverage(meta: VocabVectorIndex.Meta) -> Double {
        let total = meta.tokenMap.count + meta.failedTokens.count
        guard total > 0 else { return 1.0 }
        return Double(meta.tokenMap.count) / Double(total)
    }
}

// MARK: - State

/// Snapshot of the vector-index actor's state. UI renders from this. Enum
/// cases are distinct enough that `ExpandedSearchEmbeddingsCard` can switch on
/// them directly without peeking at internals.
enum VocabVectorIndexState: Equatable, Sendable {
    case missing
    case loading
    case building(progress: VocabVectorIndexBuilder.BuildProgress)
    case ready(coverage: Double, failed: Int, vectorsCount: Int)
    case modelUnavailable(reason: String)
    case error(String)
}
