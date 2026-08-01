import XCTest
@testable import NanoTeams

/// Performance regression pins expressed as WORK DONE, not wall-clock.
///
/// Why not `measure {}`: the test target runs parallel, CI hardware is thermally variable, and
/// a threshold loose enough not to flake is too loose to catch these regressions. Counters are
/// machine-independent, run in milliseconds, and say *why* something got slower.
///
/// A counter pin also catches something a timer structurally cannot — losing the early stop. A
/// parallel or eager scan can be WALL-CLOCK FASTER while reading ten times as many files; only
/// `filesRead` / `linesScanned` show that.
final class SearchExecutorCounterTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    var resolver: SandboxPathResolver!
    let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempDir, internalDir: internalDir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        resolver = nil
        try super.tearDownWithError()
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func run(
        _ queries: [String], fileGlob: String? = nil, maxResults: Int = 100
    ) throws -> SearchExecutorOutput {
        try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: queries, fileGlob: fileGlob, maxResults: maxResults,
            internalDir: internalDir))
    }

    // MARK: - Glob compilation

    /// With no `file_glob` the executor must not build a regex at all. The pre-rewrite code
    /// passed `input.fileGlob ?? "*"` into a function that escaped, rewrote and compiled `^.*$`
    /// for EVERY walked file.
    func testNoGlob_compilesZeroRegexes() throws {
        for i in 0..<25 { try write("f\(i).swift", content: "NEEDLE\n") }

        let out = try run(["NEEDLE"])
        XCTAssertEqual(out.stats.globCompilations, 0)
    }

    /// With a glob, exactly one compile per run — not one per candidate.
    func testGlob_compiledExactlyOncePerRun() throws {
        for i in 0..<25 { try write("f\(i).swift", content: "NEEDLE\n") }

        let out = try run(["NEEDLE"], fileGlob: "*.swift")
        XCTAssertEqual(out.stats.globCompilations, 1)
        XCTAssertEqual(out.matches.count, 25, "and the glob still selects correctly")
    }

    // MARK: - Reading

    /// Binaries are classified from an 8 KB sniff, so their bytes never reach the scanner. The
    /// old path read every `.png` in full and UTF-8-validated it just to increment a counter.
    func testBinaryFiles_areNotFullyRead() throws {
        try write("small.txt", content: "NEEDLE\n")
        // 64 KB of NUL-bearing bytes — far more than the 8 KB sniff window.
        var blob = Data([0xFF, 0xFE, 0x00, 0xFD])
        blob.append(Data(repeating: 0x41, count: 65_536))
        try blob.write(to: tempDir.appendingPathComponent("blob.bin"))

        let out = try run(["NEEDLE"])
        XCTAssertEqual(out.skippedBinaryCount, 1)
        XCTAssertLessThan(out.stats.bytesScanned, 1_000,
                          "the 64 KB blob must not reach the scanner")
    }

    /// A `file_glob` must exclude files from being READ, not merely from the results.
    func testGlob_excludesFilesFromBeingRead() throws {
        try write("keep.swift", content: "NEEDLE\n")
        for i in 0..<20 { try write("drop\(i).md", content: String(repeating: "filler\n", count: 200)) }

        let out = try run(["NEEDLE"], fileGlob: "*.swift")
        XCTAssertEqual(out.stats.filesRead, 1, "the 20 .md files must never be opened")
    }

    /// Directories in `WalkSkipRules` are not descended into.
    func testSkippedDirectories_areNotEnumerated() throws {
        try write("a.swift", content: "NEEDLE\n")
        try write("node_modules/pkg/deep/x.js", content: "NEEDLE\n")
        try write("__pycache__/y.pyc", content: "NEEDLE\n")
        try write("src/b.swift", content: "NEEDLE\n")

        let out = try run(["NEEDLE"])
        // root + src only. `.nanoteams` and `.nanoteams/internal` are excluded by prefix, but
        // the walk still enumerates `.nanoteams` itself before rejecting its child.
        XCTAssertLessThanOrEqual(out.stats.dirsEnumerated, 3,
                                 "node_modules and __pycache__ subtrees must not be walked")
        XCTAssertEqual(Set(out.matches.map(\.path)), ["a.swift", "src/b.swift"])
    }

    // MARK: - Early stop

    /// The one pin a stopwatch cannot replace: a scan that lost its early stop can still be
    /// faster in wall-clock while doing far more work.
    func testEarlyStop_stopsScanningOncePageIsFull() throws {
        // 60 files of 200 matching lines each — 12,000 potential matches.
        for i in 0..<60 {
            try write(String(format: "f%02d.swift", i),
                      content: String(repeating: "NEEDLE\n", count: 200))
        }

        let out = try run(["NEEDLE"], maxResults: 5)
        XCTAssertEqual(out.matches.count, 5)
        XCTAssertTrue(out.truncated)
        XCTAssertEqual(out.stats.filesRead, 1, "5 matches all live in the first file")
        XCTAssertLessThan(out.stats.linesScanned, 400,
                          "the walk must stop, not index all 12,000 lines")
    }

    /// Paging deeper costs proportionally more work — and still stops.
    func testEarlyStop_offsetScansOnlyAsFarAsNeeded() throws {
        for i in 0..<60 {
            try write(String(format: "f%02d.swift", i),
                      content: String(repeating: "NEEDLE\n", count: 200))
        }

        let deep = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["NEEDLE"], maxResults: 5, offset: 400, internalDir: internalDir))

        XCTAssertEqual(deep.matches.count, 5)
        XCTAssertLessThanOrEqual(deep.stats.filesRead, 4,
                                 "offset 400 needs ~3 files of 200 lines, not all 60")
    }

    // MARK: - The ICU slow path

    /// Pure-ASCII content must never reach ICU — that is the whole point of the byte scan.
    func testASCIICorpus_makesNoICUCalls() throws {
        for i in 0..<20 {
            try write("f\(i).swift", content: "let value = \(i)\nfunc run() {}\nNEEDLE\n")
        }

        let out = try run(["NEEDLE"])
        XCTAssertEqual(out.stats.icuComparisons, 0)
        XCTAssertEqual(out.matches.count, 20)
    }

    /// ICU is entered per NON-ASCII LINE, not per file. A per-file rule would send whole files
    /// down the slow path over a single accented character in a comment.
    func testMixedFile_onlyNonASCIILinesReachICU() throws {
        try write("mixed.swift", content: """
            let a = 1
            let b = 2
            // комментарий
            let c = 3
            NEEDLE
            """)

        let out = try run(["NEEDLE"])
        XCTAssertEqual(out.stats.icuComparisons, 1, "exactly the one Cyrillic line")
        XCTAssertEqual(out.stats.linesScanned, 5)
    }

    /// The whole-buffer prefilter must eliminate files that cannot match, without a per-line pass.
    func testPrefilter_skipsFilesThatCannotMatch() throws {
        for i in 0..<20 {
            try write("f\(i).swift", content: String(repeating: "unrelated content\n", count: 100))
        }
        try write("hit.swift", content: "NEEDLE\n")

        let out = try run(["NEEDLE"])
        XCTAssertEqual(out.stats.filesPrefiltered, 20, "all 20 non-matching files short-circuit")
        XCTAssertEqual(out.matches.count, 1)
    }
}
