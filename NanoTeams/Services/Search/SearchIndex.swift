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
struct SearchIndex: Codable, Equatable {
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

    /// Sorted unique lowercase tokens. Equal-as-set to `postings.keys`
    /// (validated); kept explicit so the LLM vocabulary hint list is cheap
    /// to slice without instantiating a `Set` from a dictionary's keys.
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
struct IndexedFile: Codable, Equatable, Hashable {
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
struct IndexSignature: Codable, Equatable, Hashable {
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
// Ranking and posting-intersection live on the data type, not on the service
// that persists it. Both `SearchIndexService` (actor) and
// `LLMExecutionService+ExpandedSearch` (processor) call these directly; without
// this split the ranking would need to be duplicated in both places.

extension SearchIndex {

    /// Ranked vocabulary candidates for `query`, tiered by match specificity:
    /// 0. Exact case-insensitive equality.
    /// 1. Prefix match either direction.
    /// 2. Substring either direction.
    /// 3. ≥ `fuzzyMinLength`-char shared substring (cheap fuzzy).
    /// 4. Sparse-vocabulary top-up — only fires when tiers 0–3 fill fewer
    ///    than half the limit:
    ///    4a. Opposite-script tokens first (bridges cross-lingual gaps —
    ///        Cyrillic ↔ ASCII, CJK ↔ ASCII, Arabic ↔ ASCII, etc. Scripts
    ///        share no multi-char substrings so the tiered matcher can't
    ///        find these on its own).
    ///    4b. Same-script tokens as general top-up (gives the LLM semantic
    ///        context when the tiered matcher misses abbreviations like
    ///        `dnd`, `dbpool` that don't share 3-char substrings with the
    ///        query). Large real-world indexes fill tiers 0–3 easily; this
    ///        only fires on small / sparse ones.
    ///
    /// Stops early once `limit` distinct tokens are seen.
    func vocabulary(matching query: String, limit: Int, fuzzyMinLength: Int = 3) -> [String] {
        let tokensInQuery = TokenExtractor.extractTokens(from: query)
        guard !tokensInQuery.isEmpty else { return [] }

        var tier0: [String] = []
        var tier1: [String] = []
        var tier2: [String] = []
        var tier3: [String] = []
        var seen: Set<String> = []

        for token in tokens {
            for q in tokensInQuery {
                if token == q {
                    if seen.insert(token).inserted { tier0.append(token) }
                    break
                }
                if token.hasPrefix(q) || q.hasPrefix(token) {
                    if seen.insert(token).inserted { tier1.append(token) }
                    break
                }
                if token.contains(q) || q.contains(token) {
                    if seen.insert(token).inserted { tier2.append(token) }
                    break
                }
                if SearchIndex.sharesSubstring(token, q, minLength: fuzzyMinLength) {
                    if seen.insert(token).inserted { tier3.append(token) }
                    break
                }
            }
            if seen.count >= limit { break }
        }

        var ranked = Array((tier0 + tier1 + tier2 + tier3).prefix(limit))

        // Tier 4: sparse-vocabulary top-up. Only when the tiered match is
        // clearly sparse (< half the limit), first add opposite-script
        // tokens (bridges cross-lingual gaps), then top up with same-script
        // tokens (surfaces abbreviations the fuzzy matcher misses like
        // `dnd` for "drag and drop" or `dbpool` for "database connection").
        if ranked.count < limit / 2 {
            let queryIsASCII = query.unicodeScalars.allSatisfy { $0.isASCII }

            // Phase A: opposite-script first (translation candidates).
            for token in tokens {
                if ranked.count >= limit { break }
                if seen.contains(token) { continue }
                let tokenIsASCII = token.unicodeScalars.allSatisfy { $0.isASCII }
                if tokenIsASCII == queryIsASCII { continue }
                ranked.append(token)
                seen.insert(token)
            }

            // Phase B: same-script top-up (semantic-context candidates).
            for token in tokens {
                if ranked.count >= limit { break }
                if seen.contains(token) { continue }
                ranked.append(token)
                seen.insert(token)
            }
        }

        return ranked
    }

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

    /// True when the two strings share any substring of at least `minLength`.
    /// O(n·m) but strings are short here (tokens are tens of chars at most).
    static func sharesSubstring(_ a: String, _ b: String, minLength: Int) -> Bool {
        guard a.count >= minLength, b.count >= minLength else { return false }
        let aArr = Array(a)
        for i in 0...(aArr.count - minLength) {
            let needle = String(aArr[i..<(i + minLength)])
            if b.contains(needle) { return true }
        }
        return false
    }
}
