import Foundation

/// Disk shape of the search index. Pure data — no I/O, no walk logic.
/// Owned by `SearchIndexService`, which handles build, load, save.
///
/// **The index is a WORD VECTOR plus the roster it was built from.** It records which words
/// exist in the work folder, not where they are: locating a word is the grep's job
/// (`SearchExecutor`), and the grep already runs over `[query] + expanded` on every exploratory
/// search. The inverted `postings: [String: [Int]]` this replaces was 6.8 of the 9.5 compact MB
/// of a real index, and its only production reader narrowed a grep that was about to run anyway
/// — so removing it also WIDENS recall, since files the index cannot read (outside the
/// extension allow-list, over 1 MB) are no longer excluded from the result by an index that
/// never saw them.
///
/// Two consumers remain:
/// - `VocabVectorIndexBuilder` embeds `vocabulary` for query expansion;
/// - `files` is the diff base for "what changed" and the candidate list for `FilenameMatcher`.
///
/// One invariant survives: `path` is unique across `files`, and it is enforced on BOTH sides —
/// `SearchIndexPlanner.deduplicated` on the producing side, `init(from:)` below on decode. The
/// memberwise init does not throw because by then the candidate list is already unique.
///
/// The two gates are not redundant, and having only the second was a defect: a walk that minted
/// a duplicate wrote it through the full rebuild's own checkpoint, and every later launch then
/// decoded the file into `duplicateFilePaths`, called it corrupt, and rebuilt from the same tree
/// into the same duplicate — with no exit. Uniqueness is a property of the WALK (each path is a
/// chain of enumerated names from the root), not of `visited`, which only bounds how often a
/// directory is entered.
nonisolated struct SearchIndex: Codable, Equatable {
    /// Bump on incompatible shape changes — readers discard older payloads and rebuild from
    /// scratch. No migrations: the index is regenerable.
    ///
    /// **Also bump on any change to what a file tokenizes INTO** — `TokenExtractor`,
    /// `SearchIndexService.textIndexableExtensions`, `maxRawTextIndexableBytes`,
    /// `DocumentTextExtractor.supportedReadExtensions`, `SearchIndexPlanner.VocabularyFilter`.
    /// Under the old full-rebuild-every-time model a tokenizer change self-healed on the next
    /// build; now the vocabulary is incremental, so without a bump half of it would stay in the
    /// old tokenizer's shape until the churn budget happened to force a full rebuild.
    ///
    /// v2 (2026-09-11): `tokens` + `postings` → `vocabulary`; `signature` became computed;
    /// `changedSinceFullBuild` added.
    static let currentVersion: Int = 2

    let version: Int
    let generatedAt: Date

    /// The roster of what the vocabulary was built FROM: path, mTime (floored to ms), size.
    /// Both the diff base for the next walk and the name list `FilenameMatcher` reads.
    ///
    /// NOT "everything the walk found": a file whose content pass did not complete — cancelled,
    /// or unreadable — is deliberately absent, so the next `loadOrBuild` still sees it as dirty
    /// and finishes the job.
    let files: [IndexedFile]

    /// The word vector. Between full rebuilds this is a SUPERSET of the filtered vocabulary of
    /// the tree: an incremental pass adds the words of changed files without re-applying the
    /// document-frequency filter (a count of one file says nothing), and words of deleted files
    /// linger until the churn budget triggers a full rebuild that recomputes both.
    let vocabulary: Set<String>

    /// Files touched (added + changed + deleted) since the last FULL rebuild. The one
    /// cumulative budget in `SearchIndexPlanner` reads it — see `churnBudgetFraction`.
    let changedSinceFullBuild: Int

    /// Derived from `files`, never persisted here.
    ///
    /// The single persisted copy lives in `vocab_vectors.meta.json`, whose `Meta` is frozen by
    /// shape: a new field there silently invalidates every user's vector index and re-embeds
    /// the whole vocabulary with no message. That is why `changedSinceFullBuild` lives on
    /// `SearchIndex` and this stays computed.
    var signature: IndexSignature { IndexSignature(files: files) }

    enum ValidationError: Error, Equatable {
        case duplicateFilePaths(path: String)
    }

    init(
        version: Int = SearchIndex.currentVersion,
        generatedAt: Date,
        files: [IndexedFile],
        vocabulary: Set<String>,
        changedSinceFullBuild: Int = 0
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.files = files
        self.vocabulary = vocabulary
        self.changedSinceFullBuild = changedSinceFullBuild
    }

    /// Decode, then check the one invariant a foreign payload can break. A throw here is how
    /// `SearchIndexService.loadFromDisk` learns the file is corrupt and rebuilds from scratch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let files = try c.decode([IndexedFile].self, forKey: .files)
        try Self.validate(files: files)
        self.init(
            version: try c.decode(Int.self, forKey: .version),
            generatedAt: try c.decode(Date.self, forKey: .generatedAt),
            files: files,
            vocabulary: try c.decode(Set<String>.self, forKey: .vocabulary),
            changedSinceFullBuild: try c.decodeIfPresent(
                Int.self, forKey: .changedSinceFullBuild) ?? 0
        )
    }

    static func validate(files: [IndexedFile]) throws {
        var seen = Set<String>()
        seen.reserveCapacity(files.count)
        for file in files where !seen.insert(file.path).inserted {
            throw ValidationError.duplicateFilePaths(path: file.path)
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, generatedAt, files, vocabulary, changedSinceFullBuild
    }
}

/// Single file entry in the index.
nonisolated struct IndexedFile: Codable, Equatable, Hashable {
    /// Path relative to the work folder root (forward slashes).
    var path: String
    /// Last-modified time at index build.
    var mTime: Date
    /// Size in bytes at index build.
    var size: Int64
}

/// Lightweight fingerprint of the indexed tree.
///
/// No longer the freshness gate — that is `SearchIndexPlanner`'s per-file roster diff, which
/// this aggregate cannot express (an in-place edit preserving size and a rename preserving
/// mTime both leave it unchanged). Nor is it the gate for anything ELSE: `meta.indexSignature`
/// has three write sites and zero comparisons. It survives only because `VocabVectorIndex.Meta`
/// is frozen by shape and this is one of its fields — a provenance stamp, not a decision.
/// Embedding freshness is decided by the builder's token-identity diff.
nonisolated struct IndexSignature: Codable, Equatable, Hashable {
    var fileCount: Int
    /// Latest mTime seen across all indexed files.
    var maxMTime: Date
    /// Sum of all file sizes.
    var totalSize: Int64

    init(fileCount: Int, maxMTime: Date, totalSize: Int64) {
        self.fileCount = fileCount
        self.maxMTime = maxMTime
        self.totalSize = totalSize
    }

    /// Folds a roster into the fingerprint. One definition, so the value cannot drift between
    /// the builder and the reader.
    init(files: [IndexedFile]) {
        var maxMTime = Date.distantPast
        var totalSize: Int64 = 0
        for file in files {
            if file.mTime > maxMTime { maxMTime = file.mTime }
            totalSize += file.size
        }
        self.init(fileCount: files.count, maxMTime: maxMTime, totalSize: totalSize)
    }
}
