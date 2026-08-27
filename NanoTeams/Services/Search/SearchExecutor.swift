import Foundation

/// Stateless grep engine shared by plain `SearchTool.handle` and the broad-
/// search processor in `LLMExecutionService+ExploratorySearch`.
///
/// Round-robin fan-out across `queries`: for N terms, each query gets
/// `ceil(maxResults / N)` slots in pass 1; a second greedy pass fills any
/// leftover budget. Dedup key is `(path, line)`. Matches from the first query
/// (the original LLM query) come first, expanded terms follow in order.
nonisolated enum SearchExecutor {

    // MARK: - Paging bounds

    /// Upper bound on `maxResults`, i.e. the largest page a caller may request.
    ///
    /// Sourced from `AppDefaults` rather than from `ExploratorySearchPayload.maxAllowedResults`,
    /// which is the TOOL layer's clamp for the same setting. Reading it from here made a pure
    /// `Services/Search` engine depend on a `Services/Tools` DTO for its own budget — and the
    /// inconsistency was visible in one file, since `maxAllowedOffset` right below was local.
    /// Both aliases now point at the one setting the Settings stepper edits.
    static let maxAllowedResults = AppDefaults.searchMaxResultsMax

    /// Upper bound on `offset`, i.e. how deep into the result set a caller may page.
    ///
    /// The number of PAGES is deliberately unbounded — only the page SIZE is capped. This exists
    /// solely to keep the paging arithmetic away from `Int` overflow; a billion matches deep is
    /// unreachable by any real corpus, so it never truncates a legitimate request.
    static let maxAllowedOffset = 1_000_000_000

    // MARK: - Scan width

    /// How many candidate files are scanned at once by default.
    ///
    /// The 8 is a MEMORY bound, not a throughput one: `maxSearchableFileBytes` is 16 MB and each
    /// in-flight scan holds one file resident, so this width admits `8 x 16 MB = 128 MB` where
    /// the sequential version held one file. Raising it to 32 would quietly authorise 512 MB —
    /// and three independent sources can be searching at once (a role's tool batch, a meeting
    /// turn, the Autovisor), so the real ceiling is a multiple of this.
    ///
    /// `activeProcessorCount` is the other half: on a 4-core machine 8 workers would only add
    /// context switches to a workload that is already I/O-and-CPU bound per file.
    static var defaultScanConcurrency: Int {
        min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// `@concurrent` is the difference between a parallel scan and a parallel scan that still
    /// blocks the UI.
    ///
    /// This project builds with `SWIFT_APPROACHABLE_CONCURRENCY = YES`, and one of the five
    /// features that turns on is SE-0461: a `nonisolated async` function runs on the CALLER's
    /// executor, not the global one. The plain tool path reaches here from inside
    /// `Task.detached`, so it was already off the main actor — but the exploratory path calls
    /// `runPlainExecutor` from `LLMExecutionService`, which is `@MainActor`, so the whole
    /// whole-tree grep ran on the main thread. `@concurrent` states the requirement once, at the
    /// engine, instead of asking every caller to remember it. Pinned by
    /// `SearchExecutorParallelEquivalenceTests.testRun_calledFromTheMainActor_walksOffTheMainThread`.
    @concurrent
    static func run(_ input: SearchExecutorInput) async throws -> SearchExecutorOutput {
        // All mutable per-run state — matches, counters, skips, stats — lives in one value so the
        // walk and the extracted per-file scan share it explicitly rather than through implicit
        // capture. See `SearchScanResults`.
        var results = SearchScanResults(queryCount: input.queries.count)

        // Compile `file_glob` ONCE. Doubles as the pre-validation that used to live here: without
        // it a malformed glob fail-closes on every candidate and the envelope carries zero hits
        // with no signal that the user's glob is the problem.
        //
        // `nil` means "no glob supplied" and is checked with `?? true` at the three filter sites.
        // The old code passed `input.fileGlob ?? "*"` into a function that re-escaped and
        // re-compiled `^.*$` for EVERY walked file — ~10 ms per search on a 1500-file tree, paid
        // even when the caller never asked for a glob.
        let compiledGlob: CompiledGlob? = try input.fileGlob.map {
            results.stats.globCompilations += 1
            return try CompiledGlob(glob: $0, caseInsensitive: false)
        }

        // MARK: - Budget: page size, offset, per-query caps

        // Clamp HERE, at the single choke point every caller passes through. The exploratory path
        // clamps in `ExploratorySearchPayload.init`, but the plain path handed the LLM's raw
        // integer straight down, which made three failures reachable:
        //   `max_results: Int.max` -> trap (see `perQueryCap` below)
        //   `max_results: 0`       -> `totalMatches() >= 0` true on the first check, so a silent
        //                             empty result with `truncated: false`
        //   `max_results: -5`      -> `truncated = (0 >= -5)` true on an empty result
        let effectiveMaxResults = max(
            1, min(input.maxResults, maxAllowedResults))
        // The page COUNT is unbounded — only the page SIZE is capped — so `offset` is not clamped
        // to any small value. It IS bounded away from the top of `Int` so the downstream
        // arithmetic cannot overflow: `offset: Int.max` made `offset + maxResults` TRAP, and a
        // trap is not catchable by `ToolErrorHandler`, so one malformed tool call took the app
        // down.
        //
        // The bound has REAL HEADROOM rather than sitting exactly at `Int.max - maxResults - 1`.
        // That tighter version still trapped, one step further along: `perQueryCap` computes
        // `collectBudget + queryCount - 1`, which is left-associative, so `collectBudget + 1`
        // overflows before the `- 1` can bring it back. A billion matches deep is unreachable by
        // any real corpus (a billion pages of 300), so the headroom costs nothing.
        let effectiveOffset = min(max(0, input.offset), maxAllowedOffset)
        // How many matches must be COLLECTED before the page can be cut. The extra +1 is what
        // makes `has_more` honest without walking the whole tree.
        let collectTarget = effectiveOffset + effectiveMaxResults
        let collectBudget = collectTarget + 1

        // Cap per query = max(1, ceil(maxResults / N))
        let queryCount = max(1, input.queries.count)
        // Integer ceiling division. The old `Int(Double(maxResults).rounded(.up))` TRAPPED on
        // `max_results: Int.max` — `Double(Int.max)` rounds to exactly 2^63, one past `Int.max`,
        // and a trap is not catchable by `ToolErrorHandler`. `effectiveMaxResults` already closes
        // that, but keep the arithmetic integer-only so no future caller can re-open it.
        let perQueryCap = max(1, (collectBudget + queryCount - 1) / queryCount)

        // MARK: - Query compilation

        // Pre-compile regexes (if needed) once per query. A malformed pattern
        // throws so the caller can surface the reason in the envelope's
        // `search_error` field — the prior `try?` swallowed the failure and
        // returned zero matches with no signal that the QUERY itself, not the
        // corpus, was the problem.
        let regexes: [NSRegularExpression?] = try input.queries.map { q in
            guard input.mode == .regex else { return nil }
            do {
                return try NSRegularExpression(pattern: q, options: [])
            } catch {
                throw SearchExecutorError.regexCompileFailed(
                    query: q, message: error.localizedDescription
                )
            }
        }

        // Compile each query's byte form once per run rather than re-inspecting it per line.
        let needles: [LineScanner.CompiledNeedle] = input.queries.map {
            LineScanner.CompiledNeedle($0)
        }
        // Read `Locale.current` ONCE. Turkic locales fold ASCII I/i differently from a plain
        // A-Z table, so the byte fast path is disabled wholesale there.
        let asciiFoldMatchesLocale = LineScanner.asciiFoldMatchesLocale

        // Everything the per-file scan reads, frozen for the run.
        let plan = SearchScanPlan(
            needles: needles,
            regexes: regexes,
            contextBefore: input.contextBefore,
            contextAfter: input.contextAfter,
            perQueryCap: perQueryCap,
            collectBudget: collectBudget,
            asciiFoldMatchesLocale: asciiFoldMatchesLocale
        )

        // Early-return when an empty `constrainToFiles` is supplied — nothing to scan.
        if let constrained = input.constrainToFiles, constrained.isEmpty {
            return .empty
        }

        // MARK: - Walk scope

        let fm = input.fileManager
        let workFolderRoot = input.workFolderRoot
        // Canonical root for the symlink-containment check in the walk. Resolved ONCE, and
        // resolved on BOTH sides of that comparison: `resolvingSymlinksInPath()` normalises
        // `/private/var` back to `/var` for paths that exist, so comparing a resolved target
        // against an unresolved root would reject legitimate in-folder links on macOS temp dirs.
        let canonicalRoot = workFolderRoot.resolvingSymlinksInPath().standardizedFileURL
        let internalDir = input.internalDir
        // The internal dir expressed as a work-folder-relative prefix, computed ONCE. The walk
        // then excludes it with a string compare instead of calling
        // `SandboxPathResolver.isWithin` (two `standardizedFileURL` normalisations plus two
        // `pathComponents` arrays) on every single entry.
        //
        // `nil` when the internal dir is absent OR lies outside the root — in the latter case
        // nothing the walk enumerates can be inside it, so "no prefix" is the correct answer.
        // Canonical internal dir, for the symlink check in the walk. The relative-prefix
        // exclusion below cannot see a link that reaches it under another name.
        let internalCanonical = internalDir?.resolvingSymlinksInPath().standardizedFileURL
        let internalRelPrefix: String? = internalDir.flatMap { dir -> String? in
            let rootComponents = workFolderRoot.standardizedFileURL.pathComponents
            let dirComponents = dir.standardizedFileURL.pathComponents
            guard dirComponents.count > rootComponents.count,
                  Array(dirComponents.prefix(rootComponents.count)) == rootComponents
            else { return nil }
            return dirComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }

        // MARK: - Walk scope and stop conditions

        // List mode: an all-empty query set means "enumerate files, don't grep".
        // The walk still builds the roster (glob-filtered) but skips the content
        // read entirely, and the roster is returned as filename matches.
        // Triggered only via `queries: [""]` from the plain `SearchTool` path;
        // the exploratory path always carries a non-empty original query.
        //
        // The `!isEmpty` guard is load-bearing: `[].allSatisfy` is vacuously
        // TRUE, so a degenerate empty query ARRAY (no terms at all — distinct
        // from one empty term) must NOT enumerate the whole tree. It stays a
        // zero-result search, matching `FilenameMatcher.match(queries: [])`.
        let listMode = !input.queries.isEmpty && input.queries.allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // Where the walk starts. Resolution throws (an absolute or escaping `paths` entry is a
        // sandbox reject), so it stays here rather than inside the walker, which is total.
        var roots: [SearchDirectoryWalker.Root] = []
        if let constrained = input.constrainToFiles {
            roots = constrained.map { .constrainedFile(relativePath: $0) }
        } else if let paths = input.paths, !paths.isEmpty {
            for p in paths {
                roots.append(.entry(url: try input.resolver.resolveFileURL(relativePath: p)))
            }
        } else {
            roots = [.entry(url: workFolderRoot)]
        }

        var walker = SearchDirectoryWalker(
            fileManager: fm,
            workFolderRoot: workFolderRoot,
            canonicalRoot: canonicalRoot,
            internalCanonical: internalCanonical,
            internalRelPrefix: internalRelPrefix,
            compiledGlob: compiledGlob,
            listMode: listMode,
            collectTarget: collectTarget,
            roots: roots
        )

        // MARK: - Drive the walk

        // Files the walk enumerated and would have grepped — fed to `FilenameMatcher` after the
        // walk so name/path matches can be returned alongside content matches in one tool call.
        // Bounded by the same content budget that gates the walk, so on saturated searches the
        // filename hit list reflects "what we walked" rather than the entire tree.
        var visitedPaths: [String]
        // Set once list mode discovers a distinct candidate BEYOND `maxResults`. Distinguishes
        // "stopped early, more exist" from "finished with exactly maxResults" so `truncated` is
        // never a false positive on a roster that happens to equal the cap.
        var rosterTruncated: Bool

        if listMode {
            // Nothing to scan, so nothing to parallelise: the walker's own `rosterTruncated` is
            // the whole stop condition and the loop is the sequential walk, verbatim.
            while let step = walker.next() {
                if case .skip(let entry) = step.event { results.skipped.append(entry) }
            }
            results.stats.dirsEnumerated = walker.dirsEnumerated
            visitedPaths = walker.visitedPaths
            rosterTruncated = walker.rosterTruncated
        } else {
            let outcome = await runScan(
                walker: &walker,
                plan: plan,
                queryCount: input.queries.count,
                concurrency: max(1, input.scanConcurrency ?? Self.defaultScanConcurrency),
                into: &results
            )
            visitedPaths = outcome.visitedPaths
            rosterTruncated = walker.rosterTruncated
        }

        // MARK: - Assemble and cut the page

        // Round-robin assemble: original query first, then expansions in order, cycling through
        // each bucket so no single query monopolizes the page when they all had plenty of hits.
        // Assembled up to `collectBudget` (one past the page) so the slice below can tell
        // "page is full" from "there is more".
        var combined: [SearchMatch] = []
        combined.reserveCapacity(min(results.totalMatchCount, plan.collectBudget))
        var heads = Array(repeating: 0, count: results.perQueryMatches.count)
        outer: while combined.count < plan.collectBudget {
            var progress = false
            for qIdx in results.perQueryMatches.indices {
                if combined.count >= plan.collectBudget { break outer }
                guard heads[qIdx] < results.perQueryMatches[qIdx].count else { continue }
                combined.append(results.perQueryMatches[qIdx][heads[qIdx]])
                heads[qIdx] += 1
                progress = true
            }
            if !progress { break }
        }

        // Cut the requested page out of an assembled list. An `offset` past the end yields an
        // empty page rather than an error — the caller paged off the end, which is not a failure.
        func pageSlice<T>(_ all: [T]) -> [T] {
            let start = min(effectiveOffset, all.count)
            let end = min(start + effectiveMaxResults, all.count)
            return Array(all[start..<end])
        }

        let page = pageSlice(combined)
        let hasMoreContent = combined.count > collectTarget

        // Filename matches.
        //
        // In LIST mode the roster IS the result, so it is the list `offset` walks.
        //
        // In CONTENT mode names are an orientation aid returned ALONGSIDE `matches`, and they
        // are deliberately NOT paged. `offset` advances over exactly one list and the caller is
        // told to advance it by `count`; paging both in lockstep — the shape this replaces — is
        // unsound the moment the two lists differ in length. A query with 3 content hits and 400
        // name hits returned names[0..<300] on page 1, whereupon the caller advanced by
        // `count == 3` and got names[3..<303] — 297 of them for the second time.
        var warnings: [String] = []
        let filenameMatches: [FilenameMatch]
        if listMode {
            filenameMatches = pageSlice(
                FilenameMatcher.matchAll(candidates: visitedPaths, limit: plan.collectBudget))
        } else if effectiveOffset == 0 {
            // One past the cap, so the cut is detectable rather than silent.
            let all = FilenameMatcher.match(
                candidates: visitedPaths,
                queries: input.queries,
                limit: effectiveMaxResults + 1
            )
            filenameMatches = Array(all.prefix(effectiveMaxResults))
            if all.count > effectiveMaxResults {
                warnings.append(
                    "filename_matches capped at \(effectiveMaxResults); narrow the query or pass file_glob")
            }
        } else {
            // Page 2+: names already went out with page 1. Repeating them every page is noise.
            filenameMatches = []
        }

        let truncated = listMode ? rosterTruncated : hasMoreContent

        // Exact ONLY when nothing was cut anywhere — page boundary, per-query cap, or roster cap.
        // Reporting it beside `has_more: true` is a direct contradiction, which is what the
        // previous shape produced on every saturated list-mode search: `combined` is empty in
        // list mode, so `hasMoreContent` was always false and the envelope carried
        // `total_matches: 0` next to a full `filename_matches` array.
        let totalMatches: Int? =
            (truncated || results.perQueryBucketSaturated || effectiveOffset > 0)
                ? nil
                : (listMode ? filenameMatches.count : combined.count)

        return SearchExecutorOutput(
            matches: page,
            skipped: results.skipped,
            skippedBinaryCount: results.skippedBinaryCount,
            truncated: truncated,
            filenameMatches: filenameMatches,
            totalMatches: totalMatches,
            // The number of results `offset` advances over on THIS page. Content mode pages
            // `matches`; list mode pages `filename_matches`. The tool description tells the model
            // to re-issue with `offset` advanced by `count`, so reporting `matches.count` in list
            // mode — always 0, since list mode has no content matches — told it to advance by
            // zero, i.e. to request the same page forever.
            pageCount: listMode ? filenameMatches.count : page.count,
            warnings: warnings + results.documentWarnings,
            stats: results.stats
        )
    }
}
