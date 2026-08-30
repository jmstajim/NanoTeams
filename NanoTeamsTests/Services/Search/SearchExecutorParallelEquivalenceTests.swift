import XCTest
@testable import NanoTeams

/// The parallel scan must produce the SAME BYTES as the sequential walk it replaced — not
/// "equivalent results", the same ones, in the same order.
///
/// That standard is not perfectionism. `skipped_files` ships whole into the model's envelope, and
/// so do `matches`, `filename_matches` and the paging fields; a reordering is a visible change to
/// the tool's output. And `offset` paging re-scans from the start on EVERY page, so two calls
/// that disagree about order hand the model duplicates on one page and a hole on the next —
/// which is not a red test anywhere, just a worse answer.
///
/// `scanConcurrency: 1` is the baseline throughout. It is not a legacy code path: it drives the
/// identical pipeline with a window of one, so a comparison against it isolates the WIDTH and
/// nothing else.
final class SearchExecutorParallelEquivalenceTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    var resolver: SandboxPathResolver!
    let fm = FileManager.default

    /// Wide enough that the window is full many times over, so a merge that depended on
    /// completion order rather than walk order has room to expose itself.
    private let parallelWidth = 8

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

    // MARK: - Fixtures

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeBytes(_ relPath: String, _ data: Data) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func run(
        _ queries: [String],
        concurrency: Int,
        maxResults: Int = 100,
        offset: Int = 0,
        contextBefore: Int = 0,
        contextAfter: Int = 0,
        paths: [String]? = nil,
        fileGlob: String? = nil
    ) async throws -> SearchExecutorOutput {
        try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: queries, paths: paths, fileGlob: fileGlob,
            contextBefore: contextBefore, contextAfter: contextAfter,
            maxResults: maxResults, offset: offset,
            internalDir: internalDir, scanConcurrency: concurrency))
    }

    /// A tree with one of everything the walk and the scan can trip over.
    ///
    /// Deliberately NOT a flat pile of identical files: the merge is ordered by WALK position, so
    /// the fixture has to make walk order and completion order disagree. Depth varies (so a
    /// candidate's neighbours in the stream come from different directories), file SIZE varies by
    /// two orders of magnitude (so a small file dispatched later finishes before a large one
    /// dispatched earlier), and the omission kinds are interleaved with the matches.
    @discardableResult
    private func seedWideTree(matchesPerFile: Int = 2) throws -> Int {
        var candidates = 0
        for group in 0..<12 {
            for file in 0..<25 {
                let dir = "pkg\(group)/sub\(file % 4)"
                // Size varies ~100x across the tree so completion order cannot track walk order.
                let filler = String(repeating: "padding line with no needle in it\n",
                                    count: (file % 5 == 0) ? 400 : 4)
                var body = filler
                if file % 3 == 0 {
                    for m in 0..<matchesPerFile { body += "NEEDLE hit \(group)_\(file)_\(m)\n" }
                }
                // CRLF, non-ASCII and a Turkic-sensitive letter in the same corpus.
                if file % 7 == 0 { body += "windows\r\nline\r\nендинги NEEDLE\r\n" }
                if file % 11 == 0 { body += "Ünïcödé ışık NEEDLE\n" }
                try write("\(dir)/f\(file).swift", content: body)
                candidates += 1
            }
        }
        return candidates
    }

    /// The omissions, in three shapes the merge routes differently: a WALK skip emitted at
    /// directory entry (the cycle), a WALK skip emitted while building a directory's entry list
    /// (the outward link), and SCAN skips that ride their own candidate's result.
    private func seedOmissions() throws {
        try write("aaa/readable.swift", content: "NEEDLE in aaa\n")
        // Scan-side: one byte past the read cap. Reported, never counted as a binary.
        try writeBytes("aaa/oversize.txt", Data(
            repeating: UInt8(ascii: "a"), count: SearchExecutor.maxSearchableFileBytes + 1))
        // Scan-side: valid UTF-8 with a NUL in the sniff window -> binary, counted not listed.
        try write("bbb/blob.bin", content: "NEEDLE\u{0000}tail\n")
        // Walk-side, emitted at directory entry: an alias back to an already-visited directory.
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("ccc_alias"),
            withDestinationURL: tempDir.appendingPathComponent("aaa"))
        // Walk-side, emitted while building the root's entry list: a link out of the folder.
        let outside = fm.temporaryDirectory
            .appendingPathComponent("outside_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "NEEDLE outside\n".write(
            to: outside.appendingPathComponent("secret.swift"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("ddd_escape"), withDestinationURL: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
    }

    // MARK: - Assertions

    /// Full-output equality, field by field. `Stats` is compared member-wise rather than by
    /// synthesising `Equatable`, because exactly one member is EXPECTED to differ —
    /// `speculativeScansDiscarded` is the width's cost and is asserted separately.
    private func assertIdentical(
        _ serial: SearchExecutorOutput,
        _ parallel: SearchExecutorOutput,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(serial.matches.count, parallel.matches.count,
                       "\(label): match count", file: file, line: line)
        for (i, pair) in zip(serial.matches, parallel.matches).enumerated() {
            XCTAssertEqual(pair.0.path, pair.1.path, "\(label): match[\(i)].path",
                           file: file, line: line)
            XCTAssertEqual(pair.0.line, pair.1.line, "\(label): match[\(i)].line",
                           file: file, line: line)
            XCTAssertEqual(pair.0.text, pair.1.text, "\(label): match[\(i)].text",
                           file: file, line: line)
            XCTAssertEqual(pair.0.context_before?.map(\.line), pair.1.context_before?.map(\.line),
                           "\(label): match[\(i)].context_before", file: file, line: line)
            XCTAssertEqual(pair.0.context_after?.map(\.line), pair.1.context_after?.map(\.line),
                           "\(label): match[\(i)].context_after", file: file, line: line)
        }
        // Element-by-element AND in order: this is the assertion the whole `WalkEvent` stream
        // exists for. Collecting walk skips separately from scan skips would leave every other
        // field here green.
        XCTAssertEqual(serial.skipped.map(\.path), parallel.skipped.map(\.path),
                       "\(label): skipped paths, in order", file: file, line: line)
        XCTAssertEqual(serial.skipped.map(\.reason), parallel.skipped.map(\.reason),
                       "\(label): skipped reasons, in order", file: file, line: line)
        XCTAssertEqual(serial.skippedBinaryCount, parallel.skippedBinaryCount,
                       "\(label): skippedBinaryCount", file: file, line: line)
        XCTAssertEqual(serial.truncated, parallel.truncated, "\(label): truncated",
                       file: file, line: line)
        XCTAssertEqual(serial.totalMatches, parallel.totalMatches, "\(label): totalMatches",
                       file: file, line: line)
        XCTAssertEqual(serial.pageCount, parallel.pageCount, "\(label): pageCount",
                       file: file, line: line)
        XCTAssertEqual(serial.warnings, parallel.warnings, "\(label): warnings",
                       file: file, line: line)
        XCTAssertEqual(serial.filenameMatches.map(\.path), parallel.filenameMatches.map(\.path),
                       "\(label): filename_matches, in order", file: file, line: line)

        let a = serial.stats
        let b = parallel.stats
        XCTAssertEqual(a.dirsEnumerated, b.dirsEnumerated, "\(label): dirsEnumerated",
                       file: file, line: line)
        XCTAssertEqual(a.filesRead, b.filesRead, "\(label): filesRead", file: file, line: line)
        XCTAssertEqual(a.bytesScanned, b.bytesScanned, "\(label): bytesScanned",
                       file: file, line: line)
        XCTAssertEqual(a.linesScanned, b.linesScanned, "\(label): linesScanned",
                       file: file, line: line)
        XCTAssertEqual(a.icuComparisons, b.icuComparisons, "\(label): icuComparisons",
                       file: file, line: line)
        XCTAssertEqual(a.globCompilations, b.globCompilations, "\(label): globCompilations",
                       file: file, line: line)
        XCTAssertEqual(a.filesPrefiltered, b.filesPrefiltered, "\(label): filesPrefiltered",
                       file: file, line: line)
    }

    // MARK: - Whole-output equivalence

    /// The headline pin: 300 files, every omission kind, both widths, everything equal.
    ///
    /// RED: merge scan results in COMPLETION order (`arrived` drained as it arrives instead of
    /// waiting for `mergeCursor`) → `match[i].path` diverges within the first few matches.
    func testWideTree_serialAndParallelAgreeOnEveryField() async throws {
        try seedWideTree()
        try seedOmissions()

        let serial = try await run(["NEEDLE"], concurrency: 1, maxResults: 300)
        let parallel = try await run(["NEEDLE"], concurrency: parallelWidth, maxResults: 300)

        XCTAssertGreaterThan(serial.matches.count, 100,
                             "anti-vacuum: the fixture must actually saturate the comparison")
        XCTAssertFalse(serial.skipped.isEmpty, "anti-vacuum: omissions must be present")
        assertIdentical(serial, parallel, "wide tree")
    }

    /// Context windows are built from the scanning task's own byte buffer, so a candidate merged
    /// out of position would carry the RIGHT lines against the WRONG file.
    ///
    /// RED: same mutation as `testWideTree_serialAndParallelAgreeOnEveryField` (merge in
    /// completion order) → `match[i].context_before` pairs the right lines with the wrong file.
    func testWideTree_withContextWindows_agreeOnEveryField() async throws {
        try seedWideTree(matchesPerFile: 3)

        let serial = try await run(
            ["NEEDLE"], concurrency: 1, maxResults: 200, contextBefore: 2, contextAfter: 3)
        let parallel = try await run(
            ["NEEDLE"], concurrency: parallelWidth, maxResults: 200,
            contextBefore: 2, contextAfter: 3)

        XCTAssertNotNil(serial.matches.first?.context_before, "anti-vacuum: context must be on")
        assertIdentical(serial, parallel, "context windows")
    }

    /// The exploratory shape: several terms, one of them prolific enough to hit its per-query
    /// cap. A parallel scan sees EMPTY buckets, so it cannot know a bucket is full — which is
    /// what `SearchScanResults.canAdopt` detects and the in-order re-scan repairs.
    ///
    /// RED: make `canAdopt` return `true` unconditionally → the prolific term's bucket overfills,
    /// round-robin assembly interleaves differently, and `match[i].path` diverges.
    func testMultiQuerySaturation_agreesWithSerial() async throws {
        for i in 0..<40 {
            // ALPHA is everywhere and saturates its bucket; BETA is scarce and must still be
            // attributed to its own bucket rather than crowded out.
            var body = ""
            for line in 0..<12 { body += "ALPHA line \(i)_\(line)\n" }
            if i % 9 == 0 { body += "BETA rare \(i)\n" }
            try write("pkg\(i % 5)/f\(i).swift", content: body)
        }

        let serial = try await run(["ALPHA", "BETA"], concurrency: 1, maxResults: 20)
        let parallel = try await run(["ALPHA", "BETA"], concurrency: parallelWidth, maxResults: 20)

        XCTAssertNil(serial.totalMatches,
                     "anti-vacuum: a saturated bucket must suppress the exact total, which is "
                         + "the signal that this fixture reached the cap at all")
        assertIdentical(serial, parallel, "multi-query saturation")
    }

    /// `paths` + `file_glob` narrow the walk before any of this runs; the narrowed walk must
    /// parallelise the same way the whole-tree one does.
    ///
    /// RED: drop the glob filter from `SearchDirectoryWalker.advance(frame:)` → both runs return
    /// the `.md` hits, so the counts move together, but `filesRead` no longer matches the serial
    /// baseline recorded here.
    func testScopedWalk_pathsAndGlob_agreeWithSerial() async throws {
        try seedWideTree()
        try write("pkg0/sub0/notes.md", content: "NEEDLE in markdown\n")

        let serial = try await run(
            ["NEEDLE"], concurrency: 1, maxResults: 100, paths: ["pkg0", "pkg3"],
            fileGlob: "*.swift")
        let parallel = try await run(
            ["NEEDLE"], concurrency: parallelWidth, maxResults: 100, paths: ["pkg0", "pkg3"],
            fileGlob: "*.swift")

        XCTAssertFalse(serial.matches.isEmpty, "anti-vacuum: the scoped walk must find something")
        XCTAssertTrue(serial.matches.allSatisfy { $0.path.hasSuffix(".swift") })
        assertIdentical(serial, parallel, "scoped walk")
    }

    // MARK: - Skipped ordering

    /// A walk-side omission sits BETWEEN two scan-side ones, because its position is a step index
    /// rather than an append to whichever list finished first.
    ///
    /// The fixture spells the interleaving out: `a_dir` holds an oversize file (scan side),
    /// `b_alias` is a link back to `a_dir` (walk side, emitted at directory entry), `c_dir` holds
    /// another oversize file (scan side). Sorted walk order puts the alias in the middle.
    ///
    /// RED: append walk skips to a separate array and concatenate it after the scan skips →
    /// `skipped[1].path` is `c_dir/big2.txt`, not `b_alias`.
    func testSkippedOrder_walkSkipSitsBetweenTwoScanSkips() async throws {
        let big = Data(repeating: UInt8(ascii: "a"),
                       count: SearchExecutor.maxSearchableFileBytes + 1)
        try writeBytes("a_dir/big1.txt", big)
        try writeBytes("c_dir/big2.txt", big)
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("b_alias"),
            withDestinationURL: tempDir.appendingPathComponent("a_dir"))

        for concurrency in [1, parallelWidth] {
            let out = try await run(["NEEDLE"], concurrency: concurrency, maxResults: 50)
            XCTAssertEqual(
                out.skipped.map(\.path), ["a_dir/big1.txt", "b_alias", "c_dir/big2.txt"],
                "walk skip must keep its walk position at concurrency \(concurrency)")
            let alias = try XCTUnwrap(out.skipped.dropFirst().first)
            XCTAssertTrue(alias.reason.contains("already visited"), alias.reason)
        }
    }

    // MARK: - Early exit and speculation

    /// The early stop must survive the read-ahead: `filesRead` is the sequential count, not
    /// "however far the window happened to run".
    ///
    /// RED: drop the `stopStep` rollback and let `results` keep every merged candidate → the
    /// parallel `filesRead` exceeds the serial one.
    func testEarlyExit_filesReadMatchesSerial() async throws {
        // Every file matches, so a 5-result page fills within the first handful of candidates
        // while ~300 more remain — the largest possible gap between "stopped" and "walked".
        for i in 0..<300 { try write("pkg\(i % 10)/f\(i).swift", content: "NEEDLE \(i)\n") }

        let serial = try await run(["NEEDLE"], concurrency: 1, maxResults: 5)
        let parallel = try await run(["NEEDLE"], concurrency: parallelWidth, maxResults: 5)

        XCTAssertTrue(serial.truncated, "anti-vacuum: the fixture must trip the early exit")
        XCTAssertLessThan(serial.stats.filesRead, 20,
                          "anti-vacuum: the serial baseline must itself be an EARLY stop, not a "
                              + "full walk that happens to agree")
        assertIdentical(serial, parallel, "early exit")
    }

    /// The read-ahead is bounded by the window, and the counter says how much it cost.
    ///
    /// With one query the only candidate the merge can reject is the one that fills the page, so
    /// the waste is `at most` the window: up to `concurrency - 1` in flight past the stop, plus
    /// that one re-scan.
    ///
    /// RED: dispatch every walk candidate up-front instead of keeping `dispatched - harvested`
    /// under `concurrency` → the count jumps to the hundreds.
    func testSpeculation_isBoundedByTheWindow() async throws {
        for i in 0..<300 { try write("pkg\(i % 10)/f\(i).swift", content: "NEEDLE \(i)\n") }

        for concurrency in [1, 2, parallelWidth] {
            let out = try await run(["NEEDLE"], concurrency: concurrency, maxResults: 5)
            XCTAssertLessThanOrEqual(
                out.stats.speculativeScansDiscarded, concurrency,
                "waste must stay inside the window at concurrency \(concurrency)")
        }
    }

    /// A search that runs to completion wastes nothing at all — there is no tail to discard and,
    /// with one query, no cap for `canAdopt` to reject.
    ///
    /// RED: return `false` from `canAdopt` unconditionally (every candidate re-scanned) → the
    /// count equals the candidate count instead of zero.
    func testNoEarlyExit_wastesNothing() async throws {
        for i in 0..<60 { try write("pkg\(i % 6)/f\(i).swift", content: "no hits here\n") }
        try write("pkg0/one.swift", content: "NEEDLE once\n")

        let out = try await run(["NEEDLE"], concurrency: parallelWidth, maxResults: 100)

        XCTAssertFalse(out.truncated, "anti-vacuum: this run must NOT hit the early exit")
        XCTAssertEqual(out.stats.speculativeScansDiscarded, 0)
    }

    // MARK: - Paging

    /// Paging is the reason byte-identical matters rather than merely equivalent: no cursor is
    /// stored, so page 2 re-runs the whole scan. Two runs that disagree about order hand the
    /// model a duplicate on one page and a hole on the next — and nothing goes red.
    ///
    /// RED: merge in completion order → the union of the four pages contains a duplicate and is
    /// short of the full set.
    func testPaging_throughTheParallelPath_partitionsWithoutOverlap() async throws {
        for i in 0..<50 { try write("pkg\(i % 5)/f\(i).swift", content: "NEEDLE row \(i)\n") }

        var seen: [String] = []
        for page in 0..<4 {
            let out = try await run(
                ["NEEDLE"], concurrency: parallelWidth, maxResults: 10, offset: page * 10)
            seen += out.matches.map { "\($0.path):\($0.line)" }
        }

        XCTAssertEqual(seen.count, 40, "four full pages of ten")
        XCTAssertEqual(Set(seen).count, 40, "no result may appear on two pages")

        let whole = try await run(["NEEDLE"], concurrency: 1, maxResults: 50)
        XCTAssertEqual(seen, whole.matches.prefix(40).map { "\($0.path):\($0.line)" },
                       "the paged sequence must be the serial sequence, in order")
    }

    // MARK: - The sequential lane

    /// Document extraction is single-threaded on purpose: `NSAttributedString(url:options:
    /// documentAttributes:)` treats `.documentType` as a HINT, so a `.rtf` holding HTML starts
    /// AppKit's main-thread-only HTML importer. Off-main is already where these run today; the
    /// concurrency would be the new thing.
    ///
    /// Observed through the waste counter rather than a thread assertion: a lane that dispatches
    /// nothing can discard nothing, so an early exit over a documents-only tree costs zero — and
    /// costs `concurrency - 1` the moment documents join the parallel lane.
    ///
    /// RED: drop the `requiresSequentialScan` guard in `fillWindow` → the count is nonzero.
    func testDocuments_neverEnterTheParallelLane() async throws {
        for i in 0..<40 {
            try write("docs/d\(i).rtf", content: #"{\rtf1\ansi NEEDLE row \#(i)}"#)
        }

        let out = try await run(["NEEDLE"], concurrency: parallelWidth, maxResults: 3)

        XCTAssertTrue(out.truncated,
                      "anti-vacuum: without an early exit there is no tail to discard and the "
                          + "assertion below would hold for the wrong reason")
        XCTAssertEqual(out.stats.speculativeScansDiscarded, 0,
                       "documents must never be dispatched to the parallel lane")
    }

    /// The lane is defined by the set `scanFile` itself branches on, so a newly supported format
    /// cannot land on the parallel lane the day it is added.
    ///
    /// RED: hand-list a subset (say, drop `xlsx`) in `sequentialLaneExtensions` → the equality
    /// fails naming the missing extension.
    func testSequentialLane_coversEverySupportedDocumentFormat() {
        XCTAssertFalse(DocumentConstants.supportedReadExtensions.isEmpty,
                       "anti-vacuum: an empty set would make the equality below trivially true")
        XCTAssertEqual(
            SearchExecutor.sequentialLaneExtensions, DocumentConstants.supportedReadExtensions)
        for ext in DocumentConstants.supportedReadExtensions {
            XCTAssertTrue(
                SearchExecutor.requiresSequentialScan(URL(fileURLWithPath: "/tmp/a.\(ext)")),
                "\(ext) must take the sequential lane")
        }
        XCTAssertFalse(
            SearchExecutor.requiresSequentialScan(URL(fileURLWithPath: "/tmp/a.swift")),
            "anti-vacuum: a source file must NOT take the sequential lane, or the predicate "
                + "would be true for everything and the assertions above would prove nothing")
    }

    // MARK: - Cancellation

    /// Cancellation is inherited, not flagged: the scans are children of the search task, so a
    /// cancelled caller stops the walk at its first step and the counters never grow.
    ///
    /// The `Task.sleep` is the determinism, not a delay: `cancel()` is the very next statement,
    /// so by the time `run` executes the flag is already set — whether the body had started or
    /// not. The 500 ms is never actually waited.
    ///
    /// RED: delete the `Task.isCancelled` check in `SearchDirectoryWalker.advance()` → the walk
    /// runs to completion and `filesRead` is 300, not 0.
    func testCancelledTask_stopsTheWalkWithoutScanning() async throws {
        for i in 0..<300 { try write("pkg\(i % 10)/f\(i).swift", content: "NEEDLE \(i)\n") }
        // Only `URL`s cross into the task: `SearchExecutorInput` holds a `FileManager` and is
        // therefore not `Sendable`, so it is BUILT inside rather than captured.
        let root = tempDir!
        let internalPath = internalDir!
        let width = parallelWidth

        let task = Task { () -> SearchExecutorOutput in
            try? await Task.sleep(nanoseconds: 500_000_000)
            return try await SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: root,
                resolver: SandboxPathResolver(
                    workFolderRoot: root, internalDir: internalPath),
                fileManager: .default,
                queries: ["NEEDLE"], maxResults: 300, internalDir: internalPath,
                scanConcurrency: width))
        }
        task.cancel()
        let out = try await task.value

        XCTAssertEqual(out.stats.filesRead, 0, "a cancelled search must not read files")
        XCTAssertEqual(out.stats.dirsEnumerated, 0)
        XCTAssertTrue(out.matches.isEmpty)
    }

    // MARK: - Which thread the walk runs on

    /// Records the thread every directory enumeration ran on.
    ///
    /// Injected through `SearchExecutorInput.fileManager`, which is the seam the walk already
    /// takes — so this observes the REAL question ("did the grep occupy the main thread") rather
    /// than a proxy for it such as "is the attribute still written on that declaration".
    private final class ThreadProbeFileManager: FileManager {
        private let lock = NSLock()
        private var _calls = 0
        private var _sawMainThread = false
        private var _sawScanPool = false

        var calls: Int { lock.withLock { _calls } }
        var sawMainThread: Bool { lock.withLock { _sawMainThread } }
        var sawScanPool: Bool { lock.withLock { _sawScanPool } }

        override func contentsOfDirectory(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: FileManager.DirectoryEnumerationOptions = []
        ) throws -> [URL] {
            let onMain = Thread.isMainThread
            let onPool = BlockingIOTaskExecutor.isOnScanPool()
            lock.withLock {
                _calls += 1
                if onMain { _sawMainThread = true }
                if onPool { _sawScanPool = true }
            }
            return try super.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: mask)
        }
    }

    @MainActor
    private func walkThreadProbe(
        queries: [String], concurrency: Int, fileGlob: String? = nil
    ) async throws -> ThreadProbeFileManager {
        let probe = ThreadProbeFileManager()
        _ = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: probe,
            queries: queries, fileGlob: fileGlob, maxResults: 300,
            internalDir: internalDir, scanConcurrency: concurrency))
        XCTAssertTrue(Thread.isMainThread,
                      "the CALLER must itself be on the main actor, or this proves nothing "
                          + "about what the callee did")
        XCTAssertGreaterThan(probe.calls, 0,
                             "anti-vacuum: the probe must actually have been consulted")
        return probe
    }

    /// A whole-tree grep must never run on the main thread, whoever calls it.
    ///
    /// LIST MODE is the fixture on purpose. The project builds with
    /// `SWIFT_APPROACHABLE_CONCURRENCY = YES`, and SE-0461 makes a `nonisolated async` function
    /// run on the CALLER's executor — so reached from `LLMExecutionService` (`@MainActor`) the
    /// whole grep ran on the main thread and the UI froze for its duration. `@concurrent` on
    /// `SearchExecutor.run` states the requirement once, at the engine.
    ///
    /// A CONTENT-mode fixture would have proved nothing: the parallel drive runs inside
    /// `withTaskExecutorPreference`, which lands the walk on the scan pool no matter what
    /// isolation `run` itself inherited — two mechanisms, so neither single mutation reds it
    /// (CLAUDE.md #60). List mode never enters a task group, so `@concurrent` is the only thing
    /// holding it. Measured: with a content-mode fixture, deleting `@concurrent` stayed GREEN.
    ///
    /// RED: delete `@concurrent` from `SearchExecutor.run` → `sawMainThread` is true.
    @MainActor
    func testRun_listMode_calledFromTheMainActor_walksOffTheMainThread() async throws {
        try seedWideTree()

        let probe = try await walkThreadProbe(
            queries: [""], concurrency: parallelWidth, fileGlob: "*.swift")

        XCTAssertFalse(probe.sawMainThread,
                       "the list-mode walk ran on the main thread — a search would freeze the UI "
                           + "for its whole duration")
    }

    /// The other half of the same mechanism: a width of one takes `runSequentialScan`, which is
    /// likewise outside the task group and therefore outside the executor preference. On a
    /// single-core machine this is what `defaultScanConcurrency` resolves to.
    ///
    /// RED: same mutation as `testRun_listMode_calledFromTheMainActor_walksOffTheMainThread`
    /// (delete `@concurrent`) → `sawMainThread` is true here too.
    @MainActor
    func testRun_sequentialWidth_calledFromTheMainActor_walksOffTheMainThread() async throws {
        try seedWideTree()

        let probe = try await walkThreadProbe(queries: ["NEEDLE"], concurrency: 1)

        XCTAssertFalse(probe.sawMainThread,
                       "the sequential drive ran on the main thread")
    }

    /// The SECOND mechanism, pinned on its own (CLAUDE.md #60): the parallel drive's blocking
    /// reads belong on the dispatch pool, not the cooperative one.
    ///
    /// Off-main is not the property here — the cooperative pool is off-main too, and that is
    /// exactly the failure this catches: `concurrency` threads blocked in `read(2)` on a pool
    /// sized to the core count stalls every other async task in the process. Nothing goes wrong
    /// visibly, which is why the pool needs a marker to be observable at all.
    ///
    /// RED: drop `withTaskExecutorPreference` and call `withTaskGroup` directly → `sawScanPool`
    /// is false while every other assertion in this file stays green.
    @MainActor
    func testRun_parallelWidth_scansOnTheBlockingIOPool() async throws {
        try seedWideTree()

        let probe = try await walkThreadProbe(queries: ["NEEDLE"], concurrency: parallelWidth)

        XCTAssertFalse(probe.sawMainThread)
        XCTAssertTrue(probe.sawScanPool,
                      "the parallel drive must run on the blocking-I/O pool, which overcommits "
                          + "when a thread blocks; the cooperative pool does not")
    }

    /// The same requirement, one layer up and over a CLASS of sites rather than the two that
    /// exist today.
    ///
    /// The exploratory pipeline performs two O(index) passes before it greps anything — the
    /// posting intersection and filename matching over the whole roster — and both used to run
    /// on the main actor for the same reason the walk did. They have no injectable seam, so
    /// this reads the source: the calls are allowed only inside the `@concurrent` helper that
    /// exists to carry them off the main actor. A third such pass added next to them, on the
    /// main actor, is what this catches; asserting the attribute is still typed on the two
    /// declarations would not.
    ///
    /// RED: move `FilenameMatcher.match(` back to the `@MainActor` body of
    /// `appendExploratorySearchResult` → the call count outside the helper is 1, not 0.
    func testExploratory_indexWidePassesLiveOnlyInsideTheConcurrentHelper() throws {
        let source = try String(contentsOf: URL(
            fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("../../NanoTeams/Services/LLM/"
                + "LLMExecutionService+ExploratorySearch.swift")
            .standardizedFileURL, encoding: .utf8)

        let needles = ["FilenameMatcher.match(", "index.files(containing:"]
        for needle in needles {
            XCTAssertEqual(
                source.components(separatedBy: needle).count - 1, 1,
                "\(needle) must appear exactly once — inside `narrowAndMatchNames`")
        }
        // The helper's body is the only legal home, so both needles must sit after its
        // declaration and before the next `func` at the same depth.
        let marker = "nonisolated static func narrowAndMatchNames("
        let split = source.components(separatedBy: marker)
        XCTAssertEqual(split.count, 2, "anti-vacuum: the helper must exist under this name")
        let beforeHelper = split[0]
        for needle in needles {
            XCTAssertFalse(beforeHelper.contains(needle),
                           "\(needle) is called before `narrowAndMatchNames` — i.e. on the "
                               + "main actor")
        }
        XCTAssertTrue(beforeHelper.hasSuffix("@concurrent\n    "),
                      "the helper must carry `@concurrent`: plain `nonisolated` runs on the "
                          + "CALLER's executor under SE-0461, which is the main actor here")
    }

    // MARK: - List mode

    /// List mode never scans, so it never parallelises — and its stop condition lives in the
    /// walker rather than the driver. The width must therefore change nothing at all.
    ///
    /// RED: route list mode through `runParallelScan` → the roster runs past `maxResults`,
    /// because the driver's stop is a match budget list mode never accumulates.
    func testListMode_isIndifferentToWidth() async throws {
        try seedWideTree()

        let serial = try await run([""], concurrency: 1, maxResults: 30, fileGlob: "*.swift")
        let parallel = try await run(
            [""], concurrency: parallelWidth, maxResults: 30, fileGlob: "*.swift")

        XCTAssertEqual(serial.filenameMatches.count, 30, "anti-vacuum: the roster must be capped")
        XCTAssertTrue(serial.truncated)
        assertIdentical(serial, parallel, "list mode")
    }
}
