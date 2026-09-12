import XCTest
@testable import NanoTeams

/// On-demand parameter sweep for the exploratory search's RESULT BUDGET, against the
/// checked-out repository and a recorded trainer run.
///
/// NOT a CI test — it is skipped unless a request file exists, because it walks the whole tree
/// once per configuration and needs a recorded run to replay.
///
///     cat > /tmp/nt_search_sweep.json <<'JSON'
///     { "results": "/path/to/exploratory_search_results_real.json",
///       "cutoffEpoch": 1789203640 }
///     JSON
///     xcodebuild test-without-building -project NanoTeams.xcodeproj -scheme NanoTeams \
///       -destination 'platform=macOS' -only-testing:NanoTeamsTests/SearchBudgetSweepTests
///
/// **Why a harness and not a re-implementation.** The question D-44 asks — what would recall be
/// at another page size, another per-term cap, another dedup rule — is a pure function of the
/// tree once the expansion terms are known, and the terms are already recorded. So the honest
/// instrument replays the RECORDED terms through the REAL `SearchDirectoryWalker` and the REAL
/// `SearchExecutor.scanFile`, supplying `perQueryCap` and `collectBudget` by hand. A Python
/// replica of the same pipeline was written first and disagreed with the recorded run on 8 of 9
/// cases; the disagreement was entirely in the replica, and that is the standing argument for
/// this shape. Nothing here may reproduce executor logic — it may only parameterise it.
///
/// The first test is the instrument's own calibration: replay at the recorded shape must return
/// the recorded `hitFiles` SETS exactly. A sweep whose zero point does not reproduce the run it
/// extends is measuring its own bugs.
final class SearchBudgetSweepTests: XCTestCase {

    // MARK: - Request

    private struct Request: Decodable {
        /// The trainer results JSON to replay.
        let results: String
        /// Files modified after this UNIX time are excluded from the walk — the trainer writes
        /// its own output INTO the tree it greps, so a later replay sees a tree the run did not.
        let cutoffEpoch: Double?
        /// Defaults to the repository this source file lives in.
        let root: String?
    }

    private static let requestURL = URL(fileURLWithPath: "/tmp/nt_search_sweep.json")
    private static let reportURL = URL(fileURLWithPath: "/tmp/nt_search_sweep.txt")

    /// Both halves of the gate SKIP rather than fail, and the second half is the one that
    /// matters: a request file outlives the run it points at — it sits in `/tmp`, while the
    /// recorded results are routinely deleted between trainer runs — so "the recording is gone"
    /// is an ordinary state of a developer's machine, not a broken instrument. Failing on it
    /// turned an ordinary full test run red three times over.
    private func loadRequest() throws -> (Request, URL, Recorded) {
        guard let data = try? Data(contentsOf: Self.requestURL) else {
            throw XCTSkip("write \(Self.requestURL.path) to run the sweep")
        }
        let request = try JSONDecoder().decode(Request.self, from: data)
        guard let recordedData = try? Data(contentsOf: URL(fileURLWithPath: request.results)),
              let recorded = try? JSONDecoder().decode(Recorded.self, from: recordedData)
        else {
            throw XCTSkip("no readable trainer run at \(request.results) — nothing to replay")
        }
        let root = try request.root.map { URL(fileURLWithPath: $0) } ?? repoRoot()

        // The instrument's precondition, checked rather than assumed: a replay describes the
        // tree AS IT WAS. A file edited since the recording matched then with content it no
        // longer has, and excluding it by mtime loses those matches instead of restoring them —
        // so a moved tree cannot be replayed at all, only detected.
        //
        // Skipped, not failed: an ordinary developer editing the repository after a trainer run
        // is the normal case, and the request file in `/tmp` outlives both.
        if let cutoff = request.cutoffEpoch {
            let moved = movedSinceRecording(root: root, cutoff: cutoff)
            guard moved.isEmpty else {
                throw XCTSkip(
                    "\(moved.count) file(s) changed since the recording — the tree cannot be "
                        + "replayed. First: \(moved.prefix(3).joined(separator: ", "))")
            }
        }
        return (request, root, recorded)
    }

    /// Repository files modified after the recording, excluding the trainer's own artifacts.
    private func movedSinceRecording(root: URL, cutoff: Double) -> [String] {
        // Deliberately NOT `.skipsHiddenFiles`: `.claude/` is hidden and the grep reads all of
        // it — `RUN_HISTORY.md` and the engineering-lessons prose are among the biggest match
        // sources in the tree, so hiding them here would make the precondition lie.
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: []) else { return [] }
        var moved: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if WalkSkipRules.shouldSkip(name: name) {
                enumerator.skipDescendants()
                continue
            }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative.hasPrefix(".nanoteams/internal") || isTrainerArtifact(relative) {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified.timeIntervalSince1970 > cutoff else { continue }
            moved.append(relative)
            if moved.count >= 32 { break }
        }
        return moved.sorted()
    }

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("NanoTeams.xcodeproj").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("repo root not found from \(#filePath)")
    }

    // MARK: - The recorded run

    private struct Recorded: Decodable {
        struct Case: Decodable {
            struct Grep: Decodable {
                let combinedTerms: [String]?
                let expectedHitFiles: [String]?
                /// The UNION of both channels since 2026-09-12.
                let hitFiles: [String]?
                /// The grep channel alone. Absent in runs recorded before the trainer learned
                /// to score both channels — for those, `hitFiles` WAS the content channel.
                let contentHitFiles: [String]?

                /// What this harness can calibrate against: it replays the content path, so it
                /// must be compared with the content channel and never with the union.
                var contentChannel: [String]? { contentHitFiles ?? hitFiles }
            }
            let tag: String
            let query: String
            let grep: Grep?
        }
        let cases: [Case]
    }

    // MARK: - One configuration

    /// What a single (terms, budget, cap) configuration produced.
    private struct Outcome {
        let pagePaths: [String]
        let collected: Int
        let walkComplete: Bool
        let filesSeen: Int
    }

    /// Replays `queries` through the real walk and the real per-file scanner.
    ///
    /// `perFileDedup` is the one behavioural VARIANT this harness can express, and it is
    /// expressed OUTSIDE the executor — by post-filtering each bucket — so the measurement says
    /// what the rule would be worth without anyone having to ship it first.
    private func replay(
        root: URL,
        queries: [String],
        maxResults: Int,
        capOverride: Int? = nil,
        perFileDedup: Bool = false,
        cutoff: Double?
    ) -> Outcome {
        let collectBudget = maxResults + 1
        let count = max(1, queries.count)
        let cap = capOverride ?? max(1, (collectBudget + count - 1) / count)
        let internalDir = root.appendingPathComponent(".nanoteams/internal", isDirectory: true)

        let plan = SearchScanPlan(
            needles: queries.map { LineScanner.CompiledNeedle($0) },
            regexes: Array(repeating: nil, count: queries.count),
            contextBefore: 0,
            contextAfter: 0,
            perQueryCap: cap,
            // Per-file dedup needs headroom: a bucket that drops repeats must be allowed to
            // collect them first, or the rule would be measured against a shorter walk.
            collectBudget: perFileDedup ? Int.max / 4 : collectBudget,
            asciiFoldMatchesLocale: LineScanner.asciiFoldMatchesLocale)

        var results = SearchScanResults(queryCount: queries.count)
        var walker = SearchDirectoryWalker(
            fileManager: .default,
            workFolderRoot: root,
            canonicalRoot: root.resolvingSymlinksInPath().standardizedFileURL,
            internalCanonical: internalDir.resolvingSymlinksInPath().standardizedFileURL,
            internalRelPrefix: ".nanoteams/internal",
            compiledGlob: nil,
            listMode: false,
            collectTarget: Int.max,
            roots: [.entry(url: root)])

        var filesSeen = 0
        var walkComplete = true
        while let step = walker.next() {
            guard case .candidate(let url, let relative) = step.event else { continue }
            if let cutoff, let modified = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
                modified.timeIntervalSince1970 > cutoff {
                continue
            }
            filesSeen += 1
            if results.budgetExhausted(plan) { walkComplete = false; break }
            SearchExecutor.scanFile(at: url, relativePath: relative, plan: plan, into: &results)
        }

        var buckets = results.perQueryMatches
        if perFileDedup {
            for index in buckets.indices {
                var seen = Set<String>()
                buckets[index] = buckets[index]
                    .filter { seen.insert($0.path).inserted }
                    .prefix(cap)
                    .map { $0 }
            }
        }

        // Round-robin assembly and the page cut, mirroring `SearchExecutor.run`.
        var combined: [SearchMatch] = []
        var heads = Array(repeating: 0, count: buckets.count)
        outer: while combined.count < collectBudget {
            var progress = false
            for index in buckets.indices {
                if combined.count >= collectBudget { break outer }
                guard heads[index] < buckets[index].count else { continue }
                combined.append(buckets[index][heads[index]])
                heads[index] += 1
                progress = true
            }
            if !progress { break }
        }
        let page = combined.prefix(maxResults)

        var seen = Set<String>()
        var paths: [String] = []
        for match in page where seen.insert(match.path).inserted { paths.append(match.path) }

        return Outcome(pagePaths: paths, collected: combined.count,
                       walkComplete: walkComplete, filesSeen: filesSeen)
    }

    /// Paths the TRAINER itself writes into the tree it greps.
    ///
    /// Excluded from both sides of the calibration, because they are not part of the repository
    /// under test and their content depends on which run wrote them last. This is not a
    /// convenience: `.nanoteams/exploratory_search_results_real.json` is 65 KB of the very terms
    /// being searched for, and with it on disk the same replay scores materially differently —
    /// so a harness that silently included it would be measuring the trainer, not the search.
    private func isTrainerArtifact(_ path: String) -> Bool {
        // `NanoTeams.xctestplan` belongs here for the same reason: `run_exploratory_search_trainer.sh`
        // rewrites it to carry the config path and restores it on exit (as `run_headless.sh` does),
        // so running the trainer bumps its mtime while leaving its bytes identical.
        path.hasPrefix(".nanoteams/exploratory_search_") || path == "NanoTeams.xctestplan"
    }

    private func recall(_ hit: [String], expected: [String]) -> Double? {
        guard !expected.isEmpty else { return nil }
        let found = Set(hit)
        return Double(expected.filter { found.contains($0) }.count) / Double(expected.count)
    }

    // MARK: - Calibration

    /// The instrument's zero point: the same terms at the same page size must return the same
    /// FILES the recorded run returned — as sets, not as a count and not as a recall average.
    ///
    /// RED: change `collectBudget` to `maxResults` (dropping the +1 that makes `has_more`
    /// honest) → the last match of a full page disappears and the sets stop matching, which is
    /// the class of off-by-one that would silently bias every sweep row below.
    func testReplayReproducesTheRecordedRunExactly() throws {
        let (request, root, recorded) = try loadRequest()

        var report = "calibration — replay at the recorded shape (maxResults 200)\n"
        var exact = 0
        var scored = 0
        for entry in recorded.cases {
            guard let grep = entry.grep,
                  let terms = grep.combinedTerms,
                  let hits = grep.contentChannel else { continue }
            scored += 1
            let outcome = replay(root: root, queries: terms, maxResults: 200,
                                 cutoff: request.cutoffEpoch)
            let same = Set(outcome.pagePaths.filter { !isTrainerArtifact($0) })
                == Set(hits.filter { !isTrainerArtifact($0) })
            if same { exact += 1 }
            report += String(
                format: "%-26@ terms=%2d recorded=%3d got=%3d %@\n",
                entry.tag as NSString, terms.count,
                hits.filter { !isTrainerArtifact($0) }.count,
                outcome.pagePaths.filter { !isTrainerArtifact($0) }.count,
                same ? "EXACT" : "DIFF" as NSString)
        }
        try? report.write(to: Self.reportURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(exact, scored,
                       "the sweep is only worth reading if its zero point reproduces the run")
    }

    // MARK: - The sweep

    /// What D-44 actually needs: recall as a function of the page budget, and of the one
    /// variant rule worth pricing — at most one match per (term, FILE).
    ///
    /// Writes an artifact rather than asserting a number: the point is a table to decide from,
    /// and a threshold asserted here would be a number nobody measured.
    func testSweepBudgetAndDedup() throws {
        let (request, root, recorded) = try loadRequest()

        // The QUERY is carried separately from the terms on purpose: `combinedTerms[0]` is the
        // first TOKEN (`search`), not the phrase (`exploratory search`), and a "query only" row
        // built from the term list would silently measure a one-word search.
        let scored = recorded.cases.compactMap { entry -> (String, [String], [String])? in
            guard let grep = entry.grep,
                  let terms = grep.combinedTerms,
                  let expected = grep.expectedHitFiles, !expected.isEmpty else { return nil }
            return (entry.query, terms, expected)
        }

        var report = "sweep over \(scored.count) scored cases — root \(root.path)\n\n"
        report += "config                         recall  perfect  files/page\n"

        func row(_ label: String, _ make: (String, [String], [String]) -> Outcome) {
            var recalls: [Double] = []
            var files = 0
            for (query, terms, expected) in scored {
                let outcome = make(query, terms, expected)
                files += outcome.pagePaths.count
                if let value = recall(outcome.pagePaths, expected: expected) {
                    recalls.append(value)
                }
            }
            let mean = recalls.isEmpty ? 0 : recalls.reduce(0, +) / Double(recalls.count)
            report += String(format: "%-30@ %6.3f  %7d  %10.1f\n", label as NSString, mean,
                             recalls.filter { $0 >= 1.0 }.count,
                             Double(files) / Double(max(1, scored.count)))
        }

        for budget in [100, 200, 300, 400, 800, 1500] {
            row("page \(budget)") { _, terms, _ in
                replay(root: root, queries: terms, maxResults: budget,
                       cutoff: request.cutoffEpoch)
            }
        }
        for budget in [100, 200, 300] {
            row("page \(budget) + per-file dedup") { _, terms, _ in
                replay(root: root, queries: terms, maxResults: budget,
                       perFileDedup: true, cutoff: request.cutoffEpoch)
            }
        }
        // The literal query alone: the floor any expansion has to beat, at 1/N the scan.
        for budget in [100, 200, 300] {
            row("page \(budget), query only") { query, _, _ in
                replay(root: root, queries: [query], maxResults: budget,
                       cutoff: request.cutoffEpoch)
            }
        }

        try? report.write(to: Self.reportURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(scored.isEmpty, "no scored cases — the recorded run carried no expectations")
    }

    /// The channel the trainer throws away.
    ///
    /// `exploratory_search` returns TWO lists: grep `matches` and `filename_matches` from
    /// `FilenameMatcher` over the whole index roster, fed by `[query] + tokens + expanded`.
    /// `ExploratorySearchTrainer.grepHitFiles` returns only the first, so every recall number
    /// above describes one half of what the model is handed.
    ///
    /// That matters for the DECISION, not just for the bookkeeping: expansion feeds the name
    /// channel too, so "drop the expansion" cannot be judged on the content channel alone.
    ///
    /// RED: pass only `[query]` to the union while still labelling the row "with expansion" →
    /// the two rows converge and the sweep stops being able to tell the channels apart.
    func testNameChannelRecall() async throws {
        let (request, root, recorded) = try loadRequest()

        let internalDir = root.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let index = await SearchIndexService(
            workFolderRoot: root, internalDir: internalDir, fileManager: .default).loadOrBuild()
        let roster = index.files.map(\.path)

        var report = (try? String(contentsOf: Self.reportURL, encoding: .utf8)) ?? ""
        report += "\nname channel — FilenameMatcher over \(roster.count) roster paths\n"
        report += "config                         recall  perfect\n"

        func row(_ label: String, terms: (String, [String]) -> [String]) {
            var recalls: [Double] = []
            for entry in recorded.cases {
                guard let grep = entry.grep,
                      let combined = grep.combinedTerms,
                      let expected = grep.expectedHitFiles, !expected.isEmpty else { continue }
                let hits = FilenameMatcher.match(
                    candidates: roster, queries: terms(entry.query, combined), limit: 100)
                if let value = recall(hits.map(\.path), expected: expected) {
                    recalls.append(value)
                }
            }
            let mean = recalls.isEmpty ? 0 : recalls.reduce(0, +) / Double(recalls.count)
            report += String(format: "%-30@ %6.3f  %7d\n", label as NSString, mean,
                             recalls.filter { $0 >= 1.0 }.count)
        }

        row("names, query + expansion") { query, combined in [query] + combined }
        row("names, query only") { query, _ in [query] }

        // What the model is ACTUALLY handed: both lists in one envelope. Every other row in
        // this file is half a measurement, and the halves disagree about whether expansion
        // helps — so this is the only row a decision may be taken on.
        report += "\nunion of both channels — what the envelope delivers\n"
        report += "config                         recall  perfect\n"
        for page in [100, 200, 300] {
            for withExpansion in [true, false] {
                var recalls: [Double] = []
                for entry in recorded.cases {
                    guard let grep = entry.grep,
                          let combined = grep.combinedTerms,
                          let expected = grep.expectedHitFiles, !expected.isEmpty else { continue }
                    let terms = withExpansion ? combined : [entry.query]
                    let union = withExpansion ? [entry.query] + combined : [entry.query]
                    let content = replay(root: root, queries: terms, maxResults: page,
                                         cutoff: request.cutoffEpoch).pagePaths
                    let names = FilenameMatcher.match(
                        candidates: roster, queries: union, limit: page).map(\.path)
                    if let value = recall(content + names, expected: expected) {
                        recalls.append(value)
                    }
                }
                let mean = recalls.isEmpty ? 0 : recalls.reduce(0, +) / Double(recalls.count)
                report += String(
                    format: "%-30@ %6.3f  %7d\n",
                    "page \(page), \(withExpansion ? "expansion" : "query only")" as NSString,
                    mean, recalls.filter { $0 >= 1.0 }.count)
            }
        }

        try? report.write(to: Self.reportURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(roster.isEmpty, "the index roster must not be empty")
    }
}
