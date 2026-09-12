import Foundation

/// The decisions a rebuild makes, as pure functions over values.
///
/// No file system, no actor, no clock: given the walk's candidates and the previous index, this
/// says whether anything must be re-read at all, which files those are, and how the results fold
/// back into a `SearchIndex`. That is what makes "only new and changed files" testable without a
/// temp directory — the cases that matter (an in-place edit of the same size, a rename that
/// preserves mTime, a cancelled pass, the churn budget) are all values.
///
/// `SearchIndexService` keeps the I/O: the walk, the content passes, persistence.
nonisolated enum SearchIndexPlanner {

    // MARK: - Inputs

    /// One file-like entry the walk found, with the two attributes the diff needs already in
    /// hand.
    ///
    /// `mTime`/`size` come from the resource values `contentsOfDirectory(at:)` PREFETCHED, not
    /// from a separate `attributesOfItem(atPath:)` per file: that call builds an `NSDictionary`
    /// of every attribute to hand back two of them, and it used to run per file on EVERY
    /// `loadOrBuild`. Measured on this work folder: 100 ms of every warm exploratory search.
    struct IndexCandidate: Sendable, Equatable {
        let url: URL
        let relativePath: String
        let isRTFDBundle: Bool
        let mTime: Date
        let size: Int64
    }

    /// What one file's content pass produced.
    ///
    /// Three cases, not two, because "no tokens" has three different meanings and the build
    /// must treat them differently — conflating them is defect Д1: a cancelled pass used to
    /// return an empty token set, which stamped the file into the roster with a fresh
    /// `(mTime, size)` and no words, so the next diff called it clean FOREVER.
    enum IndexFilePass: Sendable, Equatable {
        /// The pass ran. These are the file's words (filename tokens always, content tokens
        /// when the extension says the bytes are text).
        case indexed(Set<String>)
        /// The pass could not read the content — permissions, I/O error. The file is NOT
        /// stamped into the roster, so it stays dirty and is retried, and re-warned, on every
        /// `loadOrBuild`. That is what makes a `chmod` heal it (Д6): readability is not a
        /// property of mTime, so a warning remembered in the roster would never be retried.
        case unreadable(warning: String)
        /// The pass never ran — the task was cancelled. Says nothing about the file, and makes
        /// the whole FULL build suspect.
        case cancelled
    }

    /// Document-frequency knobs, applied in `build` where every file's words are in hand.
    ///
    /// Lives here rather than on `VocabVectorIndexBuilder` (where it was until 2026-09-11) by
    /// Information Expert: frequency is known where the files are tokenized. The builder now
    /// reads `SearchIndex.vocabulary` directly.
    ///
    /// Measured on a real 2015-file index: of 114 072 distinct tokens this keeps 39 099 (34 %).
    /// The 74 962 singletons it drops are long compound test names, hex hashes and one-off
    /// typos; the 11 near-universal ones are `and for func import in is let not on the to`.
    struct VocabularyFilter: Sendable, Equatable {
        /// Below this many files, a token is a one-off.
        let minFileCount: Int
        /// Above this share of the roster, a token is a stopword.
        let nearUniversalRatio: Double
        /// Both rules are statistically meaningless on a tiny corpus — on four files every
        /// token appears in exactly one — so below this roster size everything is accepted.
        let nearUniversalSkipBelowFileCount: Int

        static let `default` = VocabularyFilter(
            minFileCount: 2,
            nearUniversalRatio: 0.8,
            nearUniversalSkipBelowFileCount: 20
        )

        func accepts(fileCount: Int, rosterCount: Int) -> Bool {
            guard rosterCount > nearUniversalSkipBelowFileCount else { return true }
            guard fileCount >= minFileCount else { return false }
            return Double(fileCount) <= Double(rosterCount) * nearUniversalRatio
        }
    }

    // MARK: - The roster invariant

    /// The walk's candidates with `SearchIndex`'s one roster invariant enforced on the PRODUCING
    /// side: `relativePath` unique.
    ///
    /// `SearchIndex.init(from:)` has always rejected a duplicate path on DECODE, while `build`
    /// and `merge` — the only two producers of `SearchIndex.files` — never checked it. That
    /// asymmetry is what turns a walk bug from transient into PERMANENT: a full rebuild
    /// checkpoints immediately, the next launch decodes the file into
    /// `ValidationError.duplicateFilePaths`, calls it corrupt, and rebuilds from the same tree
    /// into the same duplicate. Nothing in that loop ever terminates it.
    ///
    /// It runs on the candidate list rather than inside `build`/`merge` because `Diff.dirty`
    /// holds INDICES into that list and `merge` zips `passes` against them — dropping an element
    /// later would point every index at a different file.
    struct DeduplicatedCandidates: Equatable, Sendable {
        let candidates: [IndexCandidate]
        /// Paths a later candidate repeated, in drop order. Empty on every healthy walk; a
        /// non-empty list is a WALK defect, which is why the service reports rather than
        /// swallows it.
        let droppedPaths: [String]

        /// The same defect in the form `lastIndexWarnings` carries — EMPTY on a healthy walk,
        /// so the service appends it unconditionally and owns no branch of its own.
        ///
        /// The message lives here rather than in the actor by Information Expert: the roster
        /// fact is produced here, so how it is described belongs here too — and it is then
        /// reachable from a pure test, which a private helper behind a walk that can no longer
        /// mint duplicates would not be.
        ///
        /// Capped at three: a pathological walk would otherwise paste the tree into one string.
        var warnings: [String] {
            guard !droppedPaths.isEmpty else { return [] }
            return ["index roster: \(droppedPaths.count) duplicate path(s) dropped — "
                + droppedPaths.prefix(3).joined(separator: ", ")]
        }
    }

    /// Dedups by first occurrence — the same tie-break `plan` and `merge` apply to the base
    /// roster with `uniquingKeysWith: { first, _ in first }`, so the roster and the diff cannot
    /// disagree about which row a repeated path means.
    ///
    /// Chosen over throwing and over asserting. Throwing would turn "an index that cannot be
    /// loaded" into "no index at all" — the service's only answer is `abandoned(base:)` — which
    /// is strictly worse for the user and no more informative for us; it would also share
    /// `build`'s existing `nil` channel, which already means "a pass was cancelled".
    /// `assertionFailure` is a no-op in release, which is the only build where the corruption is
    /// permanent. Dedup keeps the index usable and routes the defect to `lastIndexWarnings`, the
    /// surface that exists for exactly "the index is not comprehensive".
    ///
    /// On the healthy walk the input array is returned by identity: one `Set<String>` and one
    /// hash per candidate, against the two `Dictionary(base.files…)` builds the diff below pays
    /// on every FS event anyway.
    static func deduplicated(_ candidates: [IndexCandidate]) -> DeduplicatedCandidates {
        var seen = Set<String>()
        seen.reserveCapacity(candidates.count)
        guard candidates.contains(where: { !seen.insert($0.relativePath).inserted }) else {
            return DeduplicatedCandidates(candidates: candidates, droppedPaths: [])
        }
        seen.removeAll(keepingCapacity: true)
        var unique: [IndexCandidate] = []
        unique.reserveCapacity(candidates.count)
        var dropped: [String] = []
        for candidate in candidates {
            if seen.insert(candidate.relativePath).inserted {
                unique.append(candidate)
            } else {
                dropped.append(candidate.relativePath)
            }
        }
        return DeduplicatedCandidates(candidates: unique, droppedPaths: dropped)
    }

    // MARK: - Plan

    /// What the diff found, and which candidates must be re-read.
    struct Diff: Equatable, Sendable {
        /// Indices into the candidate array whose content must be read. Ascending.
        let dirty: [Int]
        let added: Int
        let changed: Int
        let deleted: Int
        /// The number the churn budget counts.
        var touched: Int { added + changed + deleted }
    }

    enum Plan: Equatable, Sendable {
        /// Nothing on disk moved: the previous index still describes the tree exactly.
        case reuse
        /// Re-read only `Diff.dirty` and fold the words in.
        case incremental(Diff)
        /// Re-read everything and re-apply the document-frequency filter. Reached with no
        /// previous index (first run, version bump, corrupt file), when the caller forced it,
        /// or when the churn budget below is exhausted.
        case fullRebuild
    }

    /// Share of the roster that may be touched between full rebuilds.
    ///
    /// One cumulative budget bounding three separate kinds of drift at once, which is why it is
    /// a single number rather than three rules:
    /// 1. words of DELETED files linger in an incremental vocabulary;
    /// 2. `(mTime, size)` has blind spots — `cp -p`, `rsync -a`, a sync client rolling a file
    ///    back, two same-sized files swapping names;
    /// 3. incremental additions skip the document-frequency filter, so singletons accumulate.
    ///
    /// A full rebuild costs the tokenization of ~29 MB (seconds) and NOTHING for the vector
    /// index — the builder re-embeds only what is new and drops what is gone for free.
    static let churnBudgetFraction = 0.25

    /// Compares the walk against the previous index. The freshness gate — `IndexSignature` is
    /// not, and never could be: an in-place edit of the same size and a rename that preserves
    /// mTime both leave that aggregate unchanged (Д3).
    static func plan(candidates: [IndexCandidate], base: SearchIndex?) -> Plan {
        guard let base else { return .fullRebuild }
        // `uniquingKeysWith` and not `uniqueKeysWithValues`: a duplicate path can only arrive
        // from a foreign payload, `SearchIndex.init(from:)` rejects those, and a trap in the
        // hot path is not how the service should learn its disk file is bad.
        var remaining = Dictionary(
            base.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        var dirty: [Int] = []
        var added = 0
        var changed = 0
        for (index, candidate) in candidates.enumerated() {
            guard let previous = remaining.removeValue(forKey: candidate.relativePath) else {
                dirty.append(index)
                added += 1
                continue
            }
            // An `.rtfd` is a DIRECTORY that is a document: editing the text inside it does not
            // move the bundle's own mTime, so it can never be proven clean. The same trap from
            // the other side is documented in `DocumentTextExtractor`.
            if candidate.isRTFDBundle
                || previous.mTime != candidate.mTime
                || previous.size != candidate.size {
                dirty.append(index)
                changed += 1
            }
        }
        let deleted = remaining.count
        let touched = added + changed + deleted
        if touched == 0 { return .reuse }

        let cumulative = base.changedSinceFullBuild + touched
        let budget = Int((Double(candidates.count) * churnBudgetFraction).rounded(.up))
        if cumulative > budget { return .fullRebuild }
        return .incremental(
            Diff(dirty: dirty, added: added, changed: changed, deleted: deleted))
    }

    // MARK: - Fold

    /// Incremental fold: `vocabulary ∪= words(dirty files that were read)`.
    ///
    /// Always valid and always RESUMABLE — a pass that did not run leaves the base's roster row
    /// in place (or, for a brand-new file, no row at all), so the file stays dirty and the next
    /// `loadOrBuild` finishes the job. Nothing here can produce a roster row whose
    /// `(mTime, size)` is fresh while its words are missing, which is the exact shape of Д1.
    ///
    /// `passes[k]` is the result for candidate `diff.dirty[k]`.
    static func merge(
        base: SearchIndex,
        candidates: [IndexCandidate],
        diff: Diff,
        passes: [IndexFilePass],
        generatedAt: Date
    ) -> SearchIndex {
        var passByCandidate: [Int: IndexFilePass] = [:]
        passByCandidate.reserveCapacity(passes.count)
        for (k, candidateIndex) in diff.dirty.enumerated() where k < passes.count {
            passByCandidate[candidateIndex] = passes[k]
        }
        let previousByPath = Dictionary(
            base.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        var vocabulary = base.vocabulary
        var files: [IndexedFile] = []
        files.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            switch passByCandidate[index] {
            case .some(.indexed(let tokens)):
                vocabulary.formUnion(tokens)
                files.append(IndexedFile(
                    path: candidate.relativePath, mTime: candidate.mTime, size: candidate.size))
            case .some(.unreadable), .some(.cancelled):
                // Not stamped. A file that was already in the roster keeps its OLD row, which
                // is what leaves it dirty for the next run rather than freezing it clean.
                if let previous = previousByPath[candidate.relativePath] { files.append(previous) }
            case .none:
                // Clean by the diff, so a base row exists by construction. `if let` rather than
                // a fabricated row keeps that an assertion instead of an invention.
                if let previous = previousByPath[candidate.relativePath] { files.append(previous) }
            }
        }
        return SearchIndex(
            generatedAt: generatedAt,
            files: files,
            vocabulary: vocabulary,
            changedSinceFullBuild: base.changedSinceFullBuild + diff.touched)
    }

    /// Full fold: every candidate was read, document frequency is counted transiently, and the
    /// filter is applied once — this is the only place the vocabulary ever SHRINKS.
    ///
    /// `nil` when any pass was CANCELLED: a document-frequency filter over a subset of the tree
    /// would drop shared words as singletons, so a partial full build is worse than none. An
    /// UNREADABLE file is not that — it is a fact about one file, so it is simply absent from
    /// the roster and from the frequency counts, and stays dirty for the next run (Д6).
    static func build(
        candidates: [IndexCandidate],
        passes: [IndexFilePass],
        filter: VocabularyFilter,
        generatedAt: Date
    ) -> SearchIndex? {
        guard passes.count == candidates.count else { return nil }
        var documentFrequency: [String: Int] = [:]
        var files: [IndexedFile] = []
        files.reserveCapacity(candidates.count)
        for (candidate, pass) in zip(candidates, passes) {
            switch pass {
            case .cancelled:
                return nil
            case .unreadable:
                continue
            case .indexed(let tokens):
                files.append(IndexedFile(
                    path: candidate.relativePath, mTime: candidate.mTime, size: candidate.size))
                for token in tokens { documentFrequency[token, default: 0] += 1 }
            }
        }
        let rosterCount = files.count
        var vocabulary = Set<String>()
        vocabulary.reserveCapacity(documentFrequency.count)
        for (token, fileCount) in documentFrequency {
            guard filter.accepts(fileCount: fileCount, rosterCount: rosterCount) else { continue }
            vocabulary.insert(token)
        }
        return SearchIndex(
            generatedAt: generatedAt,
            files: files,
            vocabulary: vocabulary,
            changedSinceFullBuild: 0)
    }
}
