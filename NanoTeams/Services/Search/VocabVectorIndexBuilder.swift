import Foundation

/// Stateless builder that produces a fresh `VocabVectorIndex` from a
/// `SearchIndex`. Does network I/O (via `EmbeddingClient`) and nothing else —
/// no disk writes, no actor state. `VocabVectorIndexService` wraps this with
/// persistence + observable state.
///
/// Smart-diff is the default: only tokens not already in `current.tokenMap`
/// are sent to the embedding server. Tokens present in `current` but missing
/// from the fresh `searchIndex` vocab are dropped.
///
/// Partial failure contract: if a batch permanently fails (after retries), its
/// tokens are collected into `failedTokens` on the returned `Meta` and the
/// build continues. The next invocation's diff will automatically re-attempt
/// them (they're not in the new `tokenMap`). This ensures one 500 in the
/// middle of a long build doesn't burn 25 minutes of successful batches.
///
/// Cancellation: `Task.checkCancellation` is polled at each batch boundary.
/// On cancellation the whole build throws — the caller is expected to NOT
/// persist partial state, so the next invocation resumes from disk.
struct VocabVectorIndexBuilder {

    // MARK: - Types

    struct BuildProgress: Sendable, Equatable {
        /// Tokens successfully embedded so far.
        let processed: Int
        /// Tokens queued for embedding this run (== count of addedTokens).
        let total: Int
        /// Tokens that permanently failed their batch so far.
        let failed: Int
    }

    struct BuildResult: Sendable {
        let index: VocabVectorIndex
        /// `true` when the returned `index` differs from `current` on disk
        /// so the caller must run an atomic persist. **Not** a general
        /// "something changed" flag — a diff that only removes gone tokens
        /// sets this true; a no-op run where reused == current and no adds
        /// sets it false.
        let needsPersist: Bool
        let addedCount: Int
        let removedCount: Int
        let failedCount: Int
    }

    /// Vocabulary filter knobs. Tokens with `posting.count == 1` are pure
    /// noise (one-off typos, unique identifiers); tokens that appear in more
    /// than `nearUniversalRatio` of files are stopword-equivalents. Both are
    /// skipped to keep the vocab to meaningful terms.
    struct VocabFilter: Sendable {
        let minPostingCount: Int
        let nearUniversalRatio: Double
        /// Skip filter until `fileCount > nearUniversalSkipBelowFileCount`.
        /// On tiny test corpora (4 files) `nearUniversalRatio` drops almost
        /// everything — the filter only makes sense on realistic corpora.
        let nearUniversalSkipBelowFileCount: Int

        static let `default` = VocabFilter(
            minPostingCount: 2,
            nearUniversalRatio: 0.8,
            nearUniversalSkipBelowFileCount: 20
        )

        static let permissive = VocabFilter(
            minPostingCount: 1,
            nearUniversalRatio: 1.0,
            nearUniversalSkipBelowFileCount: 0
        )

        func accepts(token: String, postingCount: Int, fileCount: Int) -> Bool {
            // On tiny corpora every token appears in exactly one file by
            // construction; `minPostingCount: 2` would empty the vocab.
            // Same threshold as the near-universal guard — below it, both
            // filters are statistically meaningless and the safer default
            // is to accept everything.
            if fileCount > nearUniversalSkipBelowFileCount {
                guard postingCount >= minPostingCount else { return false }
                if Double(postingCount) > Double(fileCount) * nearUniversalRatio {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Dependencies

    let client: any EmbeddingClient
    let filter: VocabFilter
    let batchRetries: Int
    let retryBackoffSeconds: [Double]

    init(
        client: any EmbeddingClient,
        filter: VocabFilter = .default,
        batchRetries: Int = 2,
        retryBackoffSeconds: [Double] = [0.5, 2.0]
    ) {
        self.client = client
        self.filter = filter
        self.batchRetries = batchRetries
        self.retryBackoffSeconds = retryBackoffSeconds
    }

    // MARK: - Build

    func build(
        searchIndex: SearchIndex,
        current: VocabVectorIndex?,
        config: EmbeddingConfig,
        force: Bool,
        progressHandler: @Sendable (BuildProgress) -> Void = { _ in }
    ) async throws -> BuildResult {

        // 1. Filter vocab down to meaningful tokens.
        let targetVocab = filteredVocab(searchIndex: searchIndex)

        // 2. Compute diff against the existing index. Force clears the
        //    reused-token set so every target token shows up as added.
        let reused: Set<String>
        let added: [String]
        let goneCount: Int
        if let current, !force, current.meta.modelName == config.modelName {
            let existing = Set(current.meta.tokenMap.keys)
            reused = targetVocab.intersection(existing)
            added = targetVocab.subtracting(existing).sorted()
            goneCount = existing.subtracting(targetVocab).count
        } else {
            reused = []
            added = targetVocab.sorted()
            goneCount = current?.meta.tokenMap.count ?? 0
        }

        // 3. Compute stale failedTokens — previous-run failures for tokens
        //    that are no longer in the current vocab. Pruning them prevents
        //    unbounded growth of `meta.failedTokens` on long-running projects
        //    where transient failures accumulate for files that later get
        //    deleted.
        let staleFailedCount: Int = {
            guard let current else { return 0 }
            let allPreviousFailed = Set(current.meta.failedTokens)
            return allPreviousFailed.subtracting(targetVocab).count
        }()

        // 4. Short-circuit when there's nothing to embed, nothing to prune
        //    from tokenMap, AND no stale failedTokens — caller avoids the
        //    atomic persist entirely.
        if added.isEmpty, goneCount == 0, staleFailedCount == 0, let current {
            return BuildResult(
                index: current,
                needsPersist: false,
                addedCount: 0,
                removedCount: 0,
                failedCount: current.meta.failedTokens.count
            )
        }

        // 5. Embed added tokens. Each batch is retried up to `batchRetries`
        //    times; permanent failures land in `failedTokens` and the loop
        //    continues.
        progressHandler(BuildProgress(processed: 0, total: added.count, failed: 0))
        var embeddings: [String: [Float]] = [:]
        var failedTokens: [String] = []

        // `config.batchSize > 0` is guaranteed by `EmbeddingConfig`'s init
        // validation — no defensive `max(1, ...)` needed.
        let batches = chunked(added, size: config.batchSize)
        var processed = 0
        for batch in batches {
            try Task.checkCancellation()
            let vectors = try await embedBatchWithRetry(batch, config: config)
            if let vectors {
                for (token, vec) in zip(batch, vectors) {
                    embeddings[token] = VectorMath.normalize(vec)
                }
                processed += batch.count
            } else {
                failedTokens.append(contentsOf: batch)
            }
            progressHandler(BuildProgress(
                processed: processed,
                total: added.count,
                failed: failedTokens.count
            ))
        }

        // 5. Determine dims. Priority: first new embedding > existing index.
        //    If neither is available (no added, no current), nothing to
        //    persist — surface as "nothing changed" with an empty index.
        let dims: Int
        if let firstEmbed = embeddings.values.first {
            dims = firstEmbed.count
        } else if let current {
            dims = current.meta.dims
        } else {
            let emptyMeta = try VocabVectorIndex.Meta(
                generatedAt: Date(),
                modelName: config.modelName,
                dims: 0,
                indexSignature: searchIndex.signature,
                tokenMap: [:],
                failedTokens: failedTokens
            )
            return BuildResult(
                index: try VocabVectorIndex(meta: emptyMeta, vectors: []),
                needsPersist: false,
                addedCount: 0,
                removedCount: goneCount,
                failedCount: failedTokens.count
            )
        }

        // 6. Assemble the new index. Reused tokens first (stable sort by
        //    token string), then newly embedded tokens. Row indices are
        //    compact — 0, 1, 2... no holes.
        let reusedSorted = reused.sorted()
        let embeddedSorted = embeddings.keys.sorted()
        let allTokens = reusedSorted + embeddedSorted
        var newVectors: [Float] = []
        newVectors.reserveCapacity(allTokens.count * dims)
        var newTokenMap: [String: Int] = [:]

        for (row, token) in allTokens.enumerated() {
            newTokenMap[token] = row
            // Branch by SET membership, not by "does token exist in current's
            // tokenMap". When `force: true`, `reused` is empty and every
            // target token must consume its fresh embedding — checking
            // `current.meta.tokenMap[token]` would wrongly copy the old
            // vector and silently no-op the force rebuild.
            if reused.contains(token),
               let current,
               let oldRow = current.meta.tokenMap[token],
               current.meta.dims == dims {
                let start = oldRow * current.meta.dims
                let end = start + current.meta.dims
                newVectors.append(contentsOf: current.vectors[start..<end])
            } else if let vec = embeddings[token], vec.count == dims {
                newVectors.append(contentsOf: vec)
            } else {
                // Unreachable by construction (every token in allTokens is
                // either in `reused` with a valid current vector, or in
                // `embeddings` with dims that match the first embed result
                // by definition). Fail loud rather than silently corrupt.
                preconditionFailure(
                    "Builder contract violated: token '\(token)' is in allTokens but has no vector source"
                )
            }
        }

        let meta = try VocabVectorIndex.Meta(
            generatedAt: Date(),
            modelName: config.modelName,
            dims: dims,
            indexSignature: searchIndex.signature,
            tokenMap: newTokenMap,
            failedTokens: failedTokens
        )
        let index = try VocabVectorIndex(meta: meta, vectors: newVectors)

        return BuildResult(
            index: index,
            needsPersist: true,
            addedCount: embeddings.count,
            removedCount: goneCount,
            failedCount: failedTokens.count
        )
    }

    // MARK: - Embedding with retry

    /// Returns `nil` on permanent batch failure (after `batchRetries`).
    /// Throws on cancellation, on terminal classifications that retrying
    /// can't help (`.modelNotLoaded`, `.dimensionMismatch`,
    /// `.requestEncodingFailed`). Transient classifications (HTTP 5xx,
    /// timeout, transport, invalidResponse) are retried; callers treat `nil`
    /// as "skip this batch, add tokens to failedTokens, continue".
    private func embedBatchWithRetry(
        _ batch: [String],
        config: EmbeddingConfig
    ) async throws -> [[Float]]? {
        // Document prefix is per-model — see `EmbeddingConfig.documentPrefix`.
        // Mismatched prefix silently degrades retrieval (the model lands the
        // token in the wrong region of the embedding space).
        let prefix = config.documentPrefix
        let inputs = batch.map { prefix + $0 }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await client.embed(texts: inputs, config: config)
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as EmbeddingClientError where err.isTerminal {
                // Terminal: re-attempting won't help. Propagate to the
                // service, which routes to `.modelUnavailable` / `.error`
                // state instead of burning minutes on pointless retries.
                throw err
            } catch {
                attempt += 1
                if attempt > batchRetries {
                    return nil
                }
                let delay = retryBackoffSeconds[min(attempt - 1, retryBackoffSeconds.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // MARK: - Vocab filtering

    private func filteredVocab(searchIndex: SearchIndex) -> Set<String> {
        let fileCount = searchIndex.files.count
        var out = Set<String>()
        out.reserveCapacity(searchIndex.postings.count)
        for (token, files) in searchIndex.postings {
            if filter.accepts(token: token, postingCount: files.count, fileCount: fileCount) {
                out.insert(token)
            }
        }
        return out
    }

    // MARK: - Helpers

    private func chunked<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0, !array.isEmpty else { return [] }
        var result: [[T]] = []
        result.reserveCapacity((array.count + size - 1) / size)
        var i = 0
        while i < array.count {
            let end = min(i + size, array.count)
            result.append(Array(array[i..<end]))
            i = end
        }
        return result
    }
}
