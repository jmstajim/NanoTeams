import Foundation

/// Disk shape of the search index. Pure data — no I/O, no walk logic.
/// Owned by `SearchIndexService` which handles build, load, save.
///
/// Invariants enforced by the throwing init:
/// 1. `Set(tokens) == Set(postings.keys)` — vocabulary surface matches.
/// 2. Every posting ID is in `0..<files.count` — no dangling references.
/// 3. Each posting list is strictly ascending (sorted, no duplicates) — so
///    intersection/union are simple merges.
///
/// A corrupt on-disk payload is caught at `Codable` decode (which re-runs the
/// validator) and treated as missing so the service rebuilds. Without this,
/// `files(containing:)` needed a defensive `0 <= id < files.count` guard just
/// to avoid out-of-bounds crashes on a tampered index — now the guard is
/// redundant by construction.
nonisolated struct SearchIndex: Codable, Equatable {
    /// Bump on incompatible shape changes — readers discard older payloads
    /// and rebuild from scratch. No migrations: the index is regenerable.
    static let currentVersion: Int = 1

    let version: Int
    let generatedAt: Date

    /// Stable identity of the folder at the time of the build. Used for
    /// `signature`-based freshness checks without a full tree walk.
    let signature: IndexSignature

    /// `files[i]` is the file with stable id `i`. `postings[token]` stores
    /// ids into this array (sorted ascending, deduplicated).
    let files: [IndexedFile]

    /// Sorted unique lowercase tokens. Equal-as-set to `postings.keys`, enforced
    /// by the validating init and re-run on decode.
    ///
    /// The rationale here used to name the tiered `vocabulary` ranker's slicing
    /// as the reason the field is stored — and that ranker is gone. Its real
    /// production reader is `SearchIndexCoordinator`'s `tokenCount` telemetry,
    /// plus `ExploratorySearchTrainer`'s vocabulary-recall measurement. Kept
    /// stored rather than derived from `postings.keys`: it is a persisted
    /// `CodingKey` in a versioned on-disk format, so dropping it is a format
    /// change, not a cleanup.
    let tokens: [String]

    /// Inverted posting lists. Key is lowercase token; values are file ids
    /// (indices into `files`), sorted ascending so intersections/unions are
    /// simple merges.
    let postings: [String: [Int]]

    enum ValidationError: Error, Equatable {
        case tokensDisagreeWithPostingsKeys
        case postingIDOutOfRange(token: String, id: Int, fileCount: Int)
        case postingListNotStrictlyAscending(token: String)
    }

    init(
        version: Int = SearchIndex.currentVersion,
        generatedAt: Date,
        signature: IndexSignature,
        files: [IndexedFile],
        tokens: [String],
        postings: [String: [Int]]
    ) throws {
        guard Set(tokens) == Set(postings.keys) else {
            throw ValidationError.tokensDisagreeWithPostingsKeys
        }
        let fileCount = files.count
        for (token, ids) in postings {
            // Strictly ascending: catches both "not sorted" and "duplicates"
            // in one pass so the builder's sort+dedup is a real contract.
            // Guarded with `where ids.count >= 2` — `1..<0` on empty lists
            // would crash Swift's range init.
            if ids.count >= 2 {
                for i in 1..<ids.count where ids[i - 1] >= ids[i] {
                    throw ValidationError.postingListNotStrictlyAscending(token: token)
                }
            }
            for id in ids where id < 0 || id >= fileCount {
                throw ValidationError.postingIDOutOfRange(
                    token: token, id: id, fileCount: fileCount
                )
            }
        }
        self.version = version
        self.generatedAt = generatedAt
        self.signature = signature
        self.files = files
        self.tokens = tokens
        self.postings = postings
    }

    // Codable: decode raw fields then re-run the validating init so a
    // corrupt disk payload throws here and `SearchIndexService.loadFromDisk`
    // treats it as missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: c.decode(Int.self, forKey: .version),
            generatedAt: c.decode(Date.self, forKey: .generatedAt),
            signature: c.decode(IndexSignature.self, forKey: .signature),
            files: c.decode([IndexedFile].self, forKey: .files),
            tokens: c.decode([String].self, forKey: .tokens),
            postings: c.decode([String: [Int]].self, forKey: .postings)
        )
    }

    enum CodingKeys: String, CodingKey {
        case version, generatedAt, signature, files, tokens, postings
    }
}

/// Single file entry in the index. Stable id is its array index in
/// `SearchIndex.files`.
nonisolated struct IndexedFile: Codable, Equatable, Hashable {
    /// Path relative to the work folder root (forward slashes).
    var path: String
    /// Last-modified time at index build.
    var mTime: Date
    /// Size in bytes at index build.
    var size: Int64
}

/// Lightweight fingerprint of the indexed tree. `SearchIndexCoordinator`
/// compares this against a fresh walk signature to decide if a rebuild is
/// needed — much cheaper than actually re-tokenizing every file.
nonisolated struct IndexSignature: Codable, Equatable, Hashable {
    var fileCount: Int
    /// Latest mTime seen across all indexed files. Drift in this value means
    /// at least one file changed since the last build.
    var maxMTime: Date
    /// Sum of all file sizes. Catches renames / swaps that preserve fileCount
    /// and maxMTime.
    var totalSize: Int64
}

// MARK: - Queries (Information Expert)
//
// Posting-intersection lives on the data type, not on the service that persists
// it: `LLMExecutionService+ExploratorySearch` holds the `SearchIndex` VALUE
// returned by `LLMExecutionDelegate.awaitSearchIndex()` and calls
// `files(containing:)` on it directly, with no actor hop.
//
// A tiered `vocabulary(matching:limit:)` ranker used to live here too, and this
// comment claimed the same two consumers for it. That was false from the commit
// that introduced it: the processor never called it (it expands queries through
// the vector path), and the actor wrapper had no production caller either — so
// the whole tier-0..4 block, including its cross-script bridge and the
// `sharesSubstring` helper only it called, was test-only code that this very
// comment made read as live. Deleted 2026-08-22; the engineering-lessons entry
// for that date records what it did, so a future exploratory-search wave can
// reintroduce lexical fallback ranking deliberately instead of rediscovering it.

nonisolated extension SearchIndex {

    /// Returns the relative file paths whose postings contain ANY of `terms`
    /// (union). Terms are lowercased via `en_US_POSIX` to match the tokenizer.
    /// Output is deduplicated and lexicographically sorted — file IDs reflect
    /// walk order (`FileManager.contentsOfDirectory` is not guaranteed to be
    /// alphabetical), so sorting by ID would be unstable across filesystems.
    ///
    /// Bounds check is redundant here by construction — the validating init
    /// (and Codable decode) already rejects any posting ID outside
    /// `0..<files.count`.
    func files(containing terms: [String]) -> [String] {
        var ids: Set<Int> = []
        for term in terms {
            let key = term.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if let list = postings[key] {
                ids.formUnion(list)
            }
        }
        return ids.map { files[$0].path }.sorted()
    }
}
