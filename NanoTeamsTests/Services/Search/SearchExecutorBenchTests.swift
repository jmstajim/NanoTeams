import XCTest
@testable import NanoTeams

/// On-demand benchmark for `SearchExecutor` against the checked-out repository.
///
/// NOT a CI test — it is skipped unless `NANOTEAMS_SEARCH_BENCH=1` is set, because wall-clock
/// numbers on a parallel, thermally variable test runner are noise (see the counter pins in
/// `SearchExecutorCounterTests` for the regression protection that IS deterministic).
///
///     NANOTEAMS_SEARCH_BENCH=1 xcodebuild test-without-building \
///       -project NanoTeams.xcodeproj -scheme NanoTeams -destination 'platform=macOS' \
///       -only-testing:NanoTeamsTests/SearchExecutorBenchTests
final class SearchExecutorBenchTests: XCTestCase {

    private func repoRoot() throws -> URL {
        // Walk up from this source file to the directory holding the Xcode project.
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

    func testBench_realCorpus() async throws {
        guard ProcessInfo.processInfo.environment["NANOTEAMS_SEARCH_BENCH"] == "1" else {
            throw XCTSkip("set NANOTEAMS_SEARCH_BENCH=1 to run")
        }
        let root = try repoRoot()
        let internalDir = root.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolver = SandboxPathResolver(workFolderRoot: root, internalDir: internalDir)

        // The test host's stdout does not reach `xcodebuild`'s, so results go to a file.
        let reportURL = URL(fileURLWithPath: "/tmp/nt_search_bench.txt")
        var report = "corpus: \(root.path)\n"

        func measure(
            _ label: String, queries: [String], maxResults: Int = 100,
            scanConcurrency: Int? = nil
        ) async throws {
            // One warm-up so the page cache is not what is being measured.
            _ = try await SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: root, resolver: resolver, fileManager: .default,
                queries: queries, maxResults: maxResults, internalDir: internalDir,
                scanConcurrency: scanConcurrency))

            let started = ContinuousClock.now
            let out = try await SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: root, resolver: resolver, fileManager: .default,
                queries: queries, maxResults: maxResults, internalDir: internalDir,
                scanConcurrency: scanConcurrency))
            let ms = (ContinuousClock.now - started).milliseconds

            let st = out.stats
            report += String(
                format: "%-26@ %8.1f ms | files=%d prefiltered=%d lines=%d icu=%d dirs=%d globs=%d MB=%.1f\n",
                label as NSString, ms, st.filesRead, st.filesPrefiltered, st.linesScanned,
                st.icuComparisons, st.dirsEnumerated, st.globCompilations,
                Double(st.bytesScanned) / 1_048_576)
        }

        try await measure("1 query, zero hits", queries: ["zzz_no_such_token_anywhere"])
        try await measure("5 queries, zero hits", queries: (0..<5).map { "zzz_absent_\($0)" })
        try await measure("1 query, common token", queries: ["mutateTask"])
        // Equal-WORK comparison for the common-token row. The pre-rewrite executor stopped at 7
        // matches (the hardcoded 40-line budget against context 2+3), so comparing it against a
        // 100-match page measures different amounts of output, not different speeds.
        try await measure("1 query, common (7 results)", queries: ["mutateTask"], maxResults: 7)
        try await measure("31 queries (exploratory)", queries: (0..<31).map { "zzz_absent_\($0)" })

        // The point of the whole exercise, on one line of the artifact: the same corpus and
        // the same query, scanned one file at a time and `defaultScanConcurrency` at a time.
        // Sequential is the BASELINE row, not a legacy path — `scanConcurrency: 1` drives the
        // identical pipeline with a window of one, so the pair measures the width and nothing
        // else.
        try await measure("1 query, zero hits (serial)",
                          queries: ["zzz_no_such_token_anywhere"], scanConcurrency: 1)
        try await measure("1 query, zero hits (parallel)",
                          queries: ["zzz_no_such_token_anywhere"],
                          scanConcurrency: SearchExecutor.defaultScanConcurrency)

        // The INDEX walk, which feeds exploratory search and re-runs on every FS event. Its
        // signature probe additionally runs on every `loadOrBuild`, cache hit included, so both
        // are measured: `matchesFolder` is what a warm exploratory search actually pays.
        let indexService = SearchIndexService(
            workFolderRoot: root, internalDir: internalDir, fileManager: .default)
        _ = await indexService.loadOrBuild(force: true)
        var started = ContinuousClock.now
        let rebuilt = await indexService.loadOrBuild(force: true)
        report += String(
            format: "%-26@ %8.1f ms | files=%d tokens=%d\n",
            "index rebuild" as NSString, (ContinuousClock.now - started).milliseconds,
            rebuilt.files.count, rebuilt.tokens.count)

        started = ContinuousClock.now
        _ = await indexService.loadOrBuild(force: false)
        report += String(
            format: "%-26@ %8.1f ms | (signature probe only — every warm search pays this)\n",
            "index cache hit" as NSString, (ContinuousClock.now - started).milliseconds)

        try report.write(to: reportURL, atomically: true, encoding: .utf8)
    }
}
