import Foundation

/// Input bundle for a grep pass — used by both the plain `SearchTool` handler
/// and the exploratory-search processor (which constrains the walk to a posting-hit
/// set before invoking the executor).
///
/// `Sendable` because `SearchExecutor.run` is `@concurrent` — the input crosses an executor
/// boundary on every call. That is a statement about this value, not a formality: it is read by
/// the walk and frozen into the per-file `SearchScanPlan` the scan tasks share.
nonisolated struct SearchExecutorInput: Sendable {
    let workFolderRoot: URL
    let resolver: SandboxPathResolver
    /// `nonisolated(unsafe)` for the same narrow reason as `ToolHandlerDependencies.fileManager`,
    /// which carries the full argument: Apple declined to mark `FileManager` because of its
    /// DELEGATE, and nothing here sets one. Marking the property rather than the struct keeps the
    /// check live for every other field.
    nonisolated(unsafe) let fileManager: FileManager
    let queries: [String]
    let mode: SearchMode
    let paths: [String]?
    let fileGlob: String?
    let contextBefore: Int
    let contextAfter: Int
    /// Page size. Together with `offset` this is the ONLY limit on how many matches come back.
    let maxResults: Int
    /// Matches to skip, in deterministic walk order. Stateless pagination: no cursor is stored,
    /// so pages can be requested in any order and page N+1 re-scans from the start. At ~55 ms a
    /// scan that is cheaper than any cache with an invalidation story.
    let offset: Int
    /// When non-nil, the executor iterates exactly this set of relative file
    /// paths instead of walking the directory tree. Used by exploratory search after
    /// posting-list intersection narrows the candidate files.
    let constrainToFiles: [String]?
    /// Optional restriction to a set of internal paths that should never be
    /// scanned (e.g. `.nanoteams/internal/`).
    let internalDir: URL?
    /// How many candidate files may be scanned at once. `nil` uses
    /// `SearchExecutor.defaultScanConcurrency`.
    ///
    /// Exists for tests, which need `1` to compare the parallel path against the sequential
    /// ordering it must reproduce — a default that varies with the machine's core count cannot
    /// be the baseline in a comparison the machine is one side of.
    let scanConcurrency: Int?

    init(
        workFolderRoot: URL,
        resolver: SandboxPathResolver,
        fileManager: FileManager,
        queries: [String],
        mode: SearchMode = .substring,
        paths: [String]? = nil,
        fileGlob: String? = nil,
        contextBefore: Int = 0,
        contextAfter: Int = 0,
        maxResults: Int = 20,
        offset: Int = 0,
        constrainToFiles: [String]? = nil,
        internalDir: URL? = nil,
        scanConcurrency: Int? = nil
    ) {
        self.workFolderRoot = workFolderRoot
        self.resolver = resolver
        self.fileManager = fileManager
        self.queries = queries
        self.mode = mode
        self.paths = paths
        self.fileGlob = fileGlob
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.maxResults = maxResults
        self.offset = offset
        self.constrainToFiles = constrainToFiles
        self.internalDir = internalDir
        self.scanConcurrency = scanConcurrency
    }
}

nonisolated enum SearchMode: String {
    case substring
    case regex

    /// Parse the string that comes out of `SearchTool` arguments. Anything
    /// other than `"regex"` — including `nil`, `"substring"`, typos, or
    /// unknown modes — resolves to `.substring` (the safe default).
    init(raw: String?) {
        self = (raw == "regex") ? .regex : .substring
    }
}

/// Typed errors raised by `SearchExecutor.run`. Distinct from
/// `SandboxPathError` (path resolution) so callers can surface the specific
/// reason — without this, a malformed regex pattern silently produced zero
/// matches with no signal to the LLM that the query itself was the problem.
nonisolated enum SearchExecutorError: Error, Equatable, LocalizedError {
    /// `mode == .regex` and the supplied pattern failed to compile via
    /// `NSRegularExpression(pattern:options:)`. `query` is the offending
    /// pattern; `message` carries the platform-specific failure detail.
    case regexCompileFailed(query: String, message: String)

    /// The supplied `file_glob` failed to compile after escaping. Without
    /// this throw, the glob would fail-closed on every candidate
    /// and the envelope would carry zero hits with no signal that the glob
    /// itself was the problem — see CLAUDE.md "rename complete" review.
    case invalidFileGlob(pattern: String, message: String)

    /// `LocalizedError` conformance — `error.localizedDescription` is what
    /// reaches the envelope's `search_error` field, so it must be readable.
    var errorDescription: String? {
        switch self {
        case .regexCompileFailed(let query, let message):
            return "regex compile failed for pattern '\(query)': \(message)"
        case .invalidFileGlob(let pattern, _):
            // Corrective glob vocabulary, matching `list_files`'s name_glob
            // message — NOT the raw NSRegularExpression detail. Surfacing the
            // compile error taught weaker models nothing (globs aren't regex to
            // them) and drove self-correction loops. `message` is retained on
            // the case for diagnostics/Equatable, just not shown to the model.
            return "file_glob '\(pattern)' is not a valid glob (only * is a wildcard)."
        }
    }
}

/// Output of a grep pass. Mirrors `SearchData` fields used by `SearchTool` so
/// the plain path's envelope shape is preserved.
nonisolated struct SearchExecutorOutput {
    var matches: [SearchMatch]
    var skipped: [SkippedFile]
    var skippedBinaryCount: Int
    /// There is at least one more match beyond this page — i.e. another page exists.
    var truncated: Bool
    /// Exact size of the list `offset` pages over — `matches` in content mode,
    /// `filenameMatches` in list mode — or `nil` when not knowable.
    ///
    /// Known only when NOTHING was cut: the walk ran to completion, nothing was left beyond the
    /// page, no per-query bucket hit its cap, and this is the first page. Reporting it otherwise
    /// would require always scanning the entire tree, which defeats the early stop. It is never
    /// emitted alongside `truncated` — the two would contradict each other.
    var totalMatches: Int?
    /// Files whose name or relative path matched the query, independent of
    /// content. Computed against the same walk that produced `matches`, so
    /// `WalkSkipRules` and `internalDir` exclusion are already applied.
    ///
    /// Paged only in list mode, where the roster IS the result. In content mode these accompany
    /// page 1 and are absent from later pages — see the note at the assembly site.
    var filenameMatches: [FilenameMatch]
    /// Number of results on this page that `offset` advances over. Equals `matches.count` in
    /// content mode and `filenameMatches.count` in list mode.
    var pageCount: Int
    /// Non-fatal notices for the caller — today, a filename-match list that was cut. Surfaced
    /// through `ToolResultMeta.warnings` so a cap is never silent.
    var warnings: [String]
    /// Work actually performed. Not part of the tool envelope — these exist so performance can
    /// be pinned by WORK done rather than by wall-clock, which is unusable on a parallel,
    /// thermally variable CI runner. A counter pin also catches things a timer structurally
    /// cannot: a parallel scan can be faster while doing ten times the work.
    var stats: Stats

    nonisolated struct Stats {
        /// Directories the walk enumerated.
        var dirsEnumerated = 0
        /// Files whose bytes were actually read (excludes glob/size/binary rejects).
        var filesRead = 0
        /// Bytes handed to the scanner.
        var bytesScanned = 0
        /// Lines the scanner walked.
        var linesScanned = 0
        /// Per-line ICU calls — the slow path. Should stay near the count of non-ASCII lines.
        var icuComparisons = 0
        /// Regexes compiled for `file_glob`. Must be 0 with no glob and 1 with one.
        var globCompilations = 0
        /// Files the whole-buffer prefilter eliminated without a per-line pass.
        var filesPrefiltered = 0
        /// Candidate scans dispatched to the parallel lane whose result the merge did NOT use —
        /// re-scanned in order to honour a per-query cap, or dropped past the early exit.
        ///
        /// The speculation's waste, and deliberately an UPPER bound on wasted reads: a task
        /// cancelled before it opened its file is counted here too. It exists because
        /// `SearchExecutorCounterTests` is the suite that catches "faster, by reading ten times
        /// as much" — a parallel scan that ran the whole tree ahead of a 20-match budget would
        /// look identical in every other counter.
        var speculativeScansDiscarded = 0

        /// Adds the per-file counters of one candidate scan. Walk-level counters
        /// (`dirsEnumerated`, `globCompilations`, `speculativeScansDiscarded`) are the driver's
        /// and are deliberately absent: a per-candidate result has no walk.
        mutating func addScanCounters(_ other: Stats) {
            filesRead += other.filesRead
            bytesScanned += other.bytesScanned
            linesScanned += other.linesScanned
            icuComparisons += other.icuComparisons
            filesPrefiltered += other.filesPrefiltered
        }
    }

    init(
        matches: [SearchMatch],
        skipped: [SkippedFile],
        skippedBinaryCount: Int,
        truncated: Bool,
        filenameMatches: [FilenameMatch] = [],
        totalMatches: Int? = nil,
        pageCount: Int? = nil,
        warnings: [String] = [],
        stats: Stats = Stats()
    ) {
        self.matches = matches
        self.skipped = skipped
        self.skippedBinaryCount = skippedBinaryCount
        self.truncated = truncated
        self.filenameMatches = filenameMatches
        self.totalMatches = totalMatches
        // Defaults to the content page so the ~40 existing construction sites (tests, the
        // short-circuit branches) stay correct without restating it.
        self.pageCount = pageCount ?? matches.count
        self.warnings = warnings
        self.stats = stats
    }

    /// Empty output — convenience for short-circuit branches.
    static var empty: SearchExecutorOutput {
        SearchExecutorOutput(matches: [], skipped: [], skippedBinaryCount: 0, truncated: false,
                             filenameMatches: [], totalMatches: 0)
    }
}

// MARK: - Per-run scan state

/// Everything the per-file scan READS, fixed for the whole run.
///
/// This and `SearchScanResults` are the pair that let `scanFile` move out of `SearchExecutor.run`
/// (see `SearchFileScanner.swift`). They were ~10 separate locals a nested function captured
/// implicitly — the classic data clump, and the reason the scan could not be tested on its own.
nonisolated struct SearchScanPlan {
    /// Byte-form of each query, compiled once per run rather than re-inspected per line.
    let needles: [LineScanner.CompiledNeedle]
    /// Parallel to `needles`; non-nil only in `.regex` mode.
    let regexes: [NSRegularExpression?]
    let contextBefore: Int
    let contextAfter: Int
    /// Cap on how many matches ONE query may contribute — `ceil(collectBudget / queryCount)`.
    /// Keeps a single prolific term from monopolising the page.
    let perQueryCap: Int
    /// One past the requested page, so the assembly step can tell "page is full" from
    /// "there is more" without walking the whole tree.
    let collectBudget: Int
    /// False in Turkic locales, where ASCII `I`/`i` fold differently from a plain A–Z table and
    /// the byte fast path is therefore disabled wholesale.
    let asciiFoldMatchesLocale: Bool
}

/// Everything the walk and the per-file scan ACCUMULATE.
nonisolated struct SearchScanResults {
    /// Matches bucketed by query index, so the final list can be assembled round-robin.
    var perQueryMatches: [[SearchMatch]]
    /// Running total across all buckets, maintained on append — this used to be a `reduce` over
    /// `perQueryMatches` evaluated once per LINE.
    var totalMatchCount = 0
    /// Set the first time a bucket refuses a match because it is at `perQueryCap`. Suppresses the
    /// exact `total_matches`, which would otherwise report "how many we bothered to collect".
    var perQueryBucketSaturated = false
    /// Files that could not be searched, so the caller can see WHY a match might be missing
    /// instead of reading silence as "nothing matched".
    var skipped: [SkippedFile] = []
    /// Files skipped as binary. Aggregated rather than listed: every `.png`/`.o` in the tree
    /// would otherwise flood `skipped`, while the count still separates "empty scope" from
    /// "scope held N unreadable binaries".
    var skippedBinaryCount = 0
    /// Caveats about documents that WERE searched — a mid-document parse abort, an
    /// unreadable worksheet, text cut at the extraction byte cap. Deduplicated on the way
    /// in: these are per-format facts, so a folder of 50 oversize PDFs otherwise emits the
    /// same sentence 50 times, which is the flood `skippedBinaryCount` already exists to
    /// avoid one aisle over.
    private(set) var documentWarnings: [String] = []
    /// Membership half of `documentWarnings`, which keeps first-seen ORDER. Two structures
    /// for one set of strings so neither job is done badly: a `contains` scan of the array
    /// would run per warning per document, which is the per-file cost the dedup exists to
    /// remove.
    private var seenWarnings: Set<String> = []
    var stats = SearchExecutorOutput.Stats()

    init(queryCount: Int) {
        perQueryMatches = Array(repeating: [], count: queryCount)
    }

    /// Records caveats raised while extracting one document, ignoring repeats.
    mutating func noteWarnings(_ warnings: [String]) {
        for warning in warnings where seenWarnings.insert(warning).inserted {
            documentWarnings.append(warning)
        }
    }

    /// The page budget is full — stop walking.
    func budgetExhausted(_ plan: SearchScanPlan) -> Bool {
        totalMatchCount >= plan.collectBudget
    }

    /// Whether `candidate` — scanned in isolation, against EMPTY buckets and a zero total — is
    /// the same result the sequential scan would have produced against `self`.
    ///
    /// The two decisions `scanFile` makes from shared state are the per-query cap
    /// (`perQueryMatches[q].count < perQueryCap`, checked before every append) and the page
    /// budget (`totalMatchCount >= collectBudget`, checked before every line). Neither fired
    /// differently iff the merged totals stay within both limits: below them, a scan started
    /// from zero takes exactly the branches a scan started from `self` would.
    ///
    /// With one query — the plain `search` path — `perQueryCap == collectBudget` and the bucket
    /// IS the total, so this reduces to the budget test and fails at most once per run: the
    /// candidate that fills the page. That one is re-scanned in order, which is what makes the
    /// parallel output byte-identical rather than merely equivalent.
    func canAdopt(_ candidate: SearchScanResults, plan: SearchScanPlan) -> Bool {
        guard totalMatchCount + candidate.totalMatchCount <= plan.collectBudget else {
            return false
        }
        for q in perQueryMatches.indices
            where perQueryMatches[q].count + candidate.perQueryMatches[q].count > plan.perQueryCap {
            return false
        }
        return true
    }

    /// Appends one candidate's scan result at its position in the walk.
    mutating func adopt(_ candidate: SearchScanResults) {
        for q in perQueryMatches.indices {
            perQueryMatches[q].append(contentsOf: candidate.perQueryMatches[q])
        }
        totalMatchCount += candidate.totalMatchCount
        perQueryBucketSaturated = perQueryBucketSaturated || candidate.perQueryBucketSaturated
        skipped.append(contentsOf: candidate.skipped)
        skippedBinaryCount += candidate.skippedBinaryCount
        noteWarnings(candidate.documentWarnings)
        stats.addScanCounters(candidate.stats)
    }
}
