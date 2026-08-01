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

    func testBench_realCorpus() throws {
        guard ProcessInfo.processInfo.environment["NANOTEAMS_SEARCH_BENCH"] == "1" else {
            throw XCTSkip("set NANOTEAMS_SEARCH_BENCH=1 to run")
        }
        let root = try repoRoot()
        let internalDir = root.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let resolver = SandboxPathResolver(workFolderRoot: root, internalDir: internalDir)

        // The test host's stdout does not reach `xcodebuild`'s, so results go to a file.
        let reportURL = URL(fileURLWithPath: "/tmp/nt_search_bench.txt")
        var report = "corpus: \(root.path)\n"

        func measure(_ label: String, queries: [String], maxResults: Int = 100) throws {
            // One warm-up so the page cache is not what is being measured.
            _ = try SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: root, resolver: resolver, fileManager: .default,
                queries: queries, maxResults: maxResults, internalDir: internalDir))

            let started = ContinuousClock.now
            let out = try SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: root, resolver: resolver, fileManager: .default,
                queries: queries, maxResults: maxResults, internalDir: internalDir))
            let ms = (ContinuousClock.now - started).milliseconds

            let st = out.stats
            report += String(
                format: "%-26@ %8.1f ms | files=%d prefiltered=%d lines=%d icu=%d dirs=%d globs=%d MB=%.1f\n",
                label as NSString, ms, st.filesRead, st.filesPrefiltered, st.linesScanned,
                st.icuComparisons, st.dirsEnumerated, st.globCompilations,
                Double(st.bytesScanned) / 1_048_576)
        }

        try measure("1 query, zero hits", queries: ["zzz_no_such_token_anywhere"])
        try measure("5 queries, zero hits", queries: (0..<5).map { "zzz_absent_\($0)" })
        try measure("1 query, common token", queries: ["mutateTask"])
        // Equal-WORK comparison for the common-token row. The pre-rewrite executor stopped at 7
        // matches (the hardcoded 40-line budget against context 2+3), so comparing it against a
        // 100-match page measures different amounts of output, not different speeds.
        try measure("1 query, common (7 results)", queries: ["mutateTask"], maxResults: 7)
        try measure("31 queries (exploratory)", queries: (0..<31).map { "zzz_absent_\($0)" })

        try report.write(to: reportURL, atomically: true, encoding: .utf8)
    }
}
