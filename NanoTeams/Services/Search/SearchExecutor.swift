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

    static func run(_ input: SearchExecutorInput) throws -> SearchExecutorOutput {
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

        func searchFile(at url: URL, relativePath: String) {
            SearchExecutor.scanFile(
                at: url, relativePath: relativePath, plan: plan, into: &results)
        }

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

        // MARK: - Roster and stop conditions

        // Files we enumerated and would have grepped — fed to `FilenameMatcher`
        // after the walk so name/path matches can be returned alongside
        // content matches in one tool call. Bounded by the same content
        // budget that gates the walk, so on saturated searches the filename
        // hit list reflects "what we walked" rather than the entire tree.
        var visitedPaths: [String] = []
        // Dedup the roster on insert. Overlapping/duplicate `paths` entries
        // (e.g. `["src", "src/utils"]` or `["a.txt", "a.txt"]`) would otherwise
        // append the same file twice — inflating `visitedPaths.count`, which in
        // list mode gates the walk and would stop it early (dropping genuinely-
        // distinct files and spuriously marking `truncated`). Content mode also
        // benefits: a file reachable via two paths is searched once instead of
        // twice (matches were already deduped by `(path, line)`).
        var visitedSet: Set<String> = []
        // Canonical (symlink-resolved) paths of directories already entered — the cycle guard.
        var visitedDirs: Set<String> = []
        // Set once list mode discovers a distinct candidate BEYOND `maxResults`
        // (see `admitToRoster`). Distinguishes "stopped early, more exist" from
        // "finished with exactly maxResults" so `truncated` is never a false
        // positive on a roster that happens to equal the cap.
        var rosterTruncated = false

        // List mode: an all-empty query set means "enumerate files, don't grep".
        // The walk still builds `visitedPaths` (glob-filtered) but skips the
        // content read entirely, and the roster is returned as filename matches.
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

        // Count only. The old second term (`totalMatchLines >= maxMatchLines`, a hardcoded 40)
        // made CONTEXT govern the RESULT COUNT: at 2+3 lines per match it stopped the walk after
        // 8 matches and reported `truncated`, leaving most of `max_results` unused, and raising
        // the context setting silently returned FEWER matches. Context and page size are now
        // independent.
        func budgetExhausted() -> Bool { results.budgetExhausted(plan) }

        // In list mode there are no content matches, so `budgetExhausted` never
        // trips. Instead the walk halts once `admitToRoster` has confirmed one
        // distinct candidate beyond the cap (`rosterTruncated`) — so a rare glob
        // still walks the tree to find matches, but the walk stops one candidate
        // past `maxResults` rather than enumerating everything after the cap.
        func walkShouldStop() -> Bool {
            listMode ? rosterTruncated : budgetExhausted()
        }

        // Central roster gate: dedups on insert and, in list mode, enforces the
        // result cap. Returns true when `path` was newly admitted (the caller
        // then decides whether to also grep it). At capacity, the first distinct
        // over-cap candidate flips `rosterTruncated` and returns false, which
        // halts the walk via `walkShouldStop` — nothing past the cap is added.
        func admitToRoster(_ path: String) -> Bool {
            guard visitedSet.insert(path).inserted else { return false }
            if listMode && visitedPaths.count >= collectTarget {
                rosterTruncated = true
                return false
            }
            visitedPaths.append(path)
            return true
        }

        // MARK: - Directory walk

        func searchDirectory(at url: URL, relativePath: String) {
            guard !walkShouldStop() else { return }
            if Task.isCancelled { return }

            // Cycle detection, mirroring `SearchIndexService.walkRecursive`. `.isDirectoryKey`
            // FOLLOWS symlinks, so `a/loop -> a` recurses until the stack overflows — and on a
            // zero-match query `walkShouldStop()` never trips, so nothing else bounds it. One
            // `resolvingSymlinksInPath()` per DIRECTORY (not per entry) is a few hundred calls
            // on a real tree, far below the read costs this walk already pays.
            //
            // It is reported, not swallowed: silence here is indistinguishable from an empty
            // subtree, which is exactly the confusion `skipped` exists to prevent. The same
            // guard also collapses a plain ALIAS (`alias -> real`, no cycle) to one visit, so
            // the reason names both shapes.
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard visitedDirs.insert(canonical).inserted else {
                results.skipped.append(SkippedFile(
                    path: relativePath.isEmpty ? "." : relativePath,
                    reason: "symlink already visited under another path (alias or cycle)"
                ))
                return
            }

            // Prefetch `.isDirectoryKey` so the type comes back with the single readdir the
            // kernel already performed. The old shape called `contentsOfDirectory(atPath:)`
            // (names only, discarding `d_type`) and then paid a SEPARATE `fileExists` stat per
            // entry.
            guard let urls = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                // Deliberately NOT `.skipsHiddenFiles`: `.gitignore` and `.nanoteams` are hidden
                // entries the walk must still see.
                options: []
            ) else { return }
            results.stats.dirsEnumerated += 1

            // Sort by NAME with Swift's `String <`, reproducing the old `contents.sorted()` over
            // the name array exactly. NOT `localizedStandardCompare` — that is `list_files`'s
            // ordering and would reorder non-ASCII filenames here
            // (`SearchExecutorCharacterizationTests.testCharacterization_directoryOrder_*`).
            var entries: [(name: String, url: URL, isDir: Bool)] = []
            entries.reserveCapacity(urls.count)
            for itemURL in urls {
                // A nil `isDirectory` means the entry vanished or is unreadable.
                guard let rv = try? itemURL.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      let isDir = rv.isDirectory
                else { continue }

                var isDirValue = isDir
                // What the walk descends into / reads. For a symlink this is the RESOLVED
                // target: `contentsOfDirectory(at:)` returns ZERO entries for a symlink URL
                // (it is not a directory-path URL), so descending into the link itself silently
                // yields an empty subtree — measured, and pinned below.
                var traverseURL = itemURL
                if rv.isSymbolicLink == true {
                    // `.isDirectoryKey` describes the LINK, not its target: it reports `false`
                    // for a symlink to a directory. The pre-rewrite walk asked
                    // `fileExists(atPath:isDirectory:)`, which DOES follow, so a symlinked source
                    // tree was searched. Prefetching resource values silently stopped searching
                    // them and handed the link itself to `searchFile` as though it were a
                    // document — measured, not reasoned: see the probe in
                    // `SearchExecutorContractTests`.
                    var targetIsDir: ObjCBool = false
                    // A dangling link fails here, which is what `fileExists` did before.
                    guard fm.fileExists(atPath: itemURL.path, isDirectory: &targetIsDir) else {
                        continue
                    }
                    // Following a link OUT of the work folder would read files this tool is
                    // sandboxed away from — the walk is the one path that never consults
                    // `SandboxPathResolver` per entry, so restoring "follow symlinks" without
                    // this check would re-open an escape (`outside -> /etc` resolves and reads).
                    // Same rule, for the same reason, as `AgentInstructionsScanner`.
                    let target = itemURL.resolvingSymlinksInPath().standardizedFileURL
                    let name = itemURL.lastPathComponent
                    // `.nanoteams/internal` is excluded below by RELATIVE path prefix, and that
                    // exclusion rests on an assumption following symlinks breaks: `itemPath` is
                    // built from enumerated NAMES, so `peek -> .nanoteams/internal` has relative
                    // path `peek`, matches no prefix, and its target is legitimately inside the
                    // work folder. Without this the walk read `workfolder.json`, `teams.json` and
                    // every `task.json`.
                    //
                    // Silent, matching `SandboxPathResolver.restrictedPath` (which reports
                    // internal paths as "not found"): a notice here would tell the model the
                    // internal directory exists and is worth probing.
                    if let internalCanonical,
                       SandboxPathResolver.isWithin(candidate: target, container: internalCanonical) {
                        continue
                    }
                    guard SandboxPathResolver.isWithin(candidate: target, container: canonicalRoot)
                    else {
                        results.skipped.append(SkippedFile(
                            path: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                            reason: "symlink points outside the work folder"
                        ))
                        continue
                    }
                    isDirValue = targetIsDir.boolValue
                    // Keep the LOGICAL name/path (the link's) for reporting — a match under
                    // `alias/a.swift` is a path `read_file` can open — but traverse the target.
                    traverseURL = target
                }
                entries.append((itemURL.lastPathComponent, traverseURL, isDirValue))
            }
            entries.sort { $0.name < $1.name }

            for (name, itemURL, isDirValue) in entries {
                if walkShouldStop() { return }
                if Task.isCancelled { return }
                guard !WalkSkipRules.skipped.contains(name) else { continue }

                let itemPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                // Relative-path prefix compare instead of `SandboxPathResolver.isWithin`, which
                // ran `standardizedFileURL` + two `pathComponents` allocations PER ENTRY — 10 ms
                // of the walk's 25.6 ms. Equivalent because `itemPath` is built purely from names
                // enumerated under the root.
                if let prefix = internalRelPrefix,
                   itemPath == prefix || itemPath.hasPrefix(prefix + "/") {
                    continue
                }

                // RTFD is a file-bundle directory — treat as a single document.
                if isDirValue && name.hasSuffix(".rtfd") {
                    if admitToRoster(itemPath), !listMode {
                        searchFile(at: itemURL, relativePath: itemPath)
                    }
                    continue
                }

                if isDirValue {
                    searchDirectory(at: itemURL, relativePath: itemPath)
                } else {
                    if !(compiledGlob?.matches(name) ?? true) { continue }
                    guard admitToRoster(itemPath) else { continue }
                    if !listMode { searchFile(at: itemURL, relativePath: itemPath) }
                }
            }
        }

        // MARK: - Drive the walk

        // Walk either the constrained set or the directory tree.
        if let constrained = input.constrainToFiles {
            for relative in constrained {
                if walkShouldStop() { break }
                let url = workFolderRoot.appendingPathComponent(relative)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                // Treat .rtfd bundles as single files; otherwise skip directories.
                if isDir.boolValue && !url.pathExtension.lowercased().hasSuffix("rtfd") { continue }
                if !(compiledGlob?.matches(url.lastPathComponent) ?? true) { continue }
                guard admitToRoster(relative) else { continue }
                if !listMode { searchFile(at: url, relativePath: relative) }
            }
        } else {
            var searchDirs: [URL] = []
            if let paths = input.paths, !paths.isEmpty {
                for p in paths {
                    let url = try input.resolver.resolveFileURL(relativePath: p)
                    searchDirs.append(url)
                }
            } else {
                searchDirs = [workFolderRoot]
            }
            for dir in searchDirs {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        let rel = dir.path.replacingOccurrences(
                            of: workFolderRoot.path + "/", with: "")
                        searchDirectory(at: dir, relativePath: rel == dir.path ? "" : rel)
                    } else {
                        // Apply `file_glob` uniformly: a single-file `paths`
                        // entry is filtered by the glob just like a file found
                        // in a directory walk, so a non-matching named file
                        // doesn't slip past the filter.
                        guard compiledGlob?.matches(dir.lastPathComponent) ?? true else { continue }
                        let rel = dir.path.replacingOccurrences(
                            of: workFolderRoot.path + "/", with: "")
                        // Mirror the dir-walk: also feed single-file `paths`
                        // entries into `visitedPaths` so filename matching
                        // sees them. Without this, `paths: ["foo.swift"]`
                        // would silently omit the only candidate from the
                        // filename-match scan. No `walkShouldStop` gate here:
                        // list mode is already bounded by `admitToRoster`, and
                        // an explicitly-named file stays visible for filename
                        // matching even once the content budget is full.
                        if admitToRoster(rel), !listMode {
                            searchFile(at: dir, relativePath: rel)
                        }
                    }
                }
            }
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
            warnings: warnings,
            stats: results.stats
        )
    }
}
