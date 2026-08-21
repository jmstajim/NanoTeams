import XCTest

@testable import NanoTeams

/// File-backed, so it uses a temp directory per test. Not `@MainActor` — the store is a
/// `nonisolated` class and nothing here touches the app's state.
final class BenchmarkHistoryStoreTests: XCTestCase {

    private var directory: URL!
    private var sut: BenchmarkHistoryStore!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-history-\(UUID().uuidString)", isDirectory: true)
        sut = BenchmarkHistoryStore(directory: directory)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        sut = nil
        directory = nil
        try await super.tearDown()
    }

    // MARK: - Append

    func testAppendRun_thenLoad_roundTrips() throws {
        let run = makeRun(model: "qwen3.6", providerVersion: "0.32.14")
        sut.append(run: run)
        let loaded = sut.loadRuns()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.modelName, "qwen3.6")
        XCTAssertEqual(loaded.first?.providerVersion, "0.32.14")
    }

    /// RED: a whole-array rewrite (the `NetworkLogger` shape) → drops or duplicates earlier rows on
    /// the second call. Appending must leave what is already on disk untouched.
    func testAppendTwice_keepsBothRows() {
        sut.append(run: makeRun(model: "a"))
        sut.append(run: makeRun(model: "b"))
        XCTAssertEqual(sut.loadRuns().map(\.modelName).sorted(), ["a", "b"])
    }

    func testAppendSamples_writesOneLinePerSample() throws {
        let run = makeRun(model: "m")
        sut.append(samples: (0..<3).map { makeSample(runID: run.id, index: $0) })
        XCTAssertEqual(sut.loadSamples().count, 3)

        let text = try String(contentsOf: sut.samplesURL, encoding: .utf8)
        let lines = text.split(separator: "\n").count
        XCTAssertEqual(lines, 3, "JSONL must be one line per record, not a pretty-printed array")
    }

    func testAppendEmptySamples_writesNothing() {
        sut.append(samples: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sut.samplesURL.path))
    }

    // MARK: - Corruption

    /// RED: decoding the file as one document (`try? decode ?? []`) → loses EVERY row when one line
    /// is malformed. A history that erases itself on a single bad byte is not a history.
    func testCorruptLine_costsOnlyItsOwnRow() throws {
        sut.append(run: makeRun(model: "before"))
        try "{ this is not json\n".data(using: .utf8)!.append(to: sut.runsURL)
        sut.append(run: makeRun(model: "after"))

        XCTAssertEqual(sut.loadRuns().map(\.modelName).sorted(), ["after", "before"])
    }

    func testMissingFile_loadsEmpty() {
        XCTAssertTrue(sut.loadRuns().isEmpty)
        XCTAssertTrue(sut.loadSamples().isEmpty)
    }

    // MARK: - Schema

    /// A row written by an older build lacks the newer keys and must still decode, and the
    /// in-memory version must be raised so a rewrite never persists the stale one (CLAUDE.md #48).
    func testLegacyRowWithoutOptionalKeys_decodes_andVersionIsRaised() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","runID":"\(UUID().uuidString)",\
        "recordedAt":"2026-08-18T12:00:00.000Z","phase":"measured","sampleIndex":0,\
        "outputTokens":401,"generationMs":10000}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (legacy + "\n").data(using: .utf8)!.write(to: sut.samplesURL)

        let loaded = sut.loadSamples()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded.first?.prefillSource)
        XCTAssertEqual(
            loaded.first?.schemaVersion, GenerationBenchmarkSample.currentSchemaVersion,
            "a legacy row must come back at the CURRENT version, or the legacy branch re-fires "
                + "forever after the next rewrite")
    }

    /// RED: `min` instead of `max` → downgrades a row written by a newer build, so a forward-rolled
    /// binary silently rewrites it at the older schema.
    func testRowFromNewerBuild_keepsItsHigherVersion() throws {
        let future = GenerationBenchmarkSample.currentSchemaVersion + 5
        let line = """
        {"schemaVersion":\(future),"id":"\(UUID().uuidString)","runID":"\(UUID().uuidString)",\
        "recordedAt":"2026-08-18T12:00:00.000Z","phase":"measured","sampleIndex":0}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (line + "\n").data(using: .utf8)!.write(to: sut.samplesURL)

        XCTAssertEqual(sut.loadSamples().first?.schemaVersion, future)
    }

    // MARK: - Prune

    func testPrune_keepsTheNewestRuns_andTheirSamples() {
        let runs = (0..<5).map { index in
            makeRun(model: "m\(index)", startedAt: Date(timeIntervalSince1970: 1000 + Double(index)))
        }
        for run in runs {
            sut.append(run: run)
            sut.append(samples: [makeSample(runID: run.id, index: 0)])
        }

        sut.prune(limit: 2)

        XCTAssertEqual(sut.loadRuns().map(\.modelName).sorted(), ["m3", "m4"])
        let keptIDs = Set(sut.loadRuns().map(\.id))
        XCTAssertEqual(sut.loadSamples().count, 2)
        XCTAssertTrue(sut.loadSamples().allSatisfy { keptIDs.contains($0.runID) })
    }

    /// RED: dropping the `count > limit` guard → rewrites a file that did not need it, paying the
    /// risk window of a replace for nothing.
    ///
    /// Asserts the file IDENTITY, not its bytes. Comparing content here is vacuous by
    /// construction — a decode/re-encode round trip through the same encoder is byte-identical,
    /// so "rewrote it" and "left it alone" are indistinguishable that way (measured: the mutation
    /// produced zero reds). `replaceItemAt` swaps in a new file, so the inode is the thing that
    /// actually changes.
    func testPrune_underTheLimit_doesNotTouchTheFile() throws {
        sut.append(run: makeRun(model: "only"))
        let before = try fileIdentity(of: sut.runsURL)
        sut.prune(limit: 10)
        XCTAssertEqual(try fileIdentity(of: sut.runsURL), before)
    }

    /// The companion to the test above: when pruning IS warranted the file really is replaced,
    /// so the identity check above is measuring something that can change.
    func testPrune_overTheLimit_doesReplaceTheFile() throws {
        for index in 0..<3 {
            sut.append(
                run: makeRun(model: "m\(index)",
                             startedAt: Date(timeIntervalSince1970: 1000 + Double(index))))
        }
        let before = try fileIdentity(of: sut.runsURL)
        sut.prune(limit: 1)
        XCTAssertNotEqual(try fileIdentity(of: sut.runsURL), before)
    }

    private func fileIdentity(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    /// The rewrite must land as a complete file, with no temp file left behind.
    func testPrune_leavesNoTempFiles() throws {
        for index in 0..<4 {
            sut.append(
                run: makeRun(model: "m\(index)",
                             startedAt: Date(timeIntervalSince1970: 1000 + Double(index))))
        }
        sut.prune(limit: 1)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "orphan temp files: \(leftovers)")
    }

    // MARK: - Delete

    func testDelete_removesTheRunAndItsSamples_andKeepsTheOthers() {
        let doomed = makeRun(model: "doomed")
        let keeper = makeRun(model: "keeper")
        sut.append(run: doomed)
        sut.append(run: keeper)
        sut.append(samples: (0..<2).map { makeSample(runID: doomed.id, index: $0) })
        sut.append(samples: [makeSample(runID: keeper.id, index: 0)])

        sut.delete(runIDs: [doomed.id])

        XCTAssertEqual(sut.loadRuns().map(\.modelName), ["keeper"])
        XCTAssertEqual(sut.loadSamples().map(\.runID), [keeper.id])
    }

    /// RED: delete only the run row and leave the samples → the history keeps orphan samples
    /// forever, and re-recording the same model would summarise them into the new run's figures.
    func testDelete_leavesNoOrphanSamplesBehind() {
        let doomed = makeRun(model: "doomed")
        sut.append(run: doomed)
        sut.append(samples: (0..<3).map { makeSample(runID: doomed.id, index: $0) })

        sut.delete(runIDs: [doomed.id])

        XCTAssertTrue(sut.loadRuns().isEmpty)
        XCTAssertTrue(sut.loadSamples().isEmpty, "samples outlived the run they belong to")
    }

    /// RED: rewrite unconditionally → deleting a run that is not in the file replaces both files
    /// with a decoded round-trip of themselves, so an unrelated delete can cost a corrupt line.
    func testDelete_ofAnUnknownID_doesNotRewriteEitherFile() throws {
        let run = makeRun(model: "m")
        sut.append(run: run)
        sut.append(samples: [makeSample(runID: run.id, index: 0)])
        let runsBefore = try fileIdentity(of: sut.runsURL)
        let samplesBefore = try fileIdentity(of: sut.samplesURL)

        sut.delete(runIDs: [UUID()])

        XCTAssertEqual(try fileIdentity(of: sut.runsURL), runsBefore)
        XCTAssertEqual(try fileIdentity(of: sut.samplesURL), samplesBefore)
    }

    func testDelete_ofAnEmptySet_isANoOp() throws {
        sut.append(run: makeRun(model: "m"))
        let before = try fileIdentity(of: sut.runsURL)
        sut.delete(runIDs: [])
        XCTAssertEqual(try fileIdentity(of: sut.runsURL), before)
        XCTAssertEqual(sut.loadRuns().count, 1)
    }

    /// The JSONL promise is that one bad line costs one row — including across a delete. RED:
    /// filter decoded ROWS the way `prune` does → every line this build cannot read is silently
    /// dropped by an unrelated deletion.
    func testDelete_keepsALineItCannotDecode() throws {
        let doomed = makeRun(model: "doomed")
        sut.append(run: doomed)
        try Data("{ not json\n".utf8).append(to: sut.runsURL)
        sut.append(run: makeRun(model: "keeper"))

        sut.delete(runIDs: [doomed.id])

        XCTAssertEqual(sut.loadRuns().map(\.modelName), ["keeper"])
        let text = try String(contentsOf: sut.runsURL, encoding: .utf8)
        XCTAssertTrue(text.contains("{ not json"), "the unreadable line was purged: \(text)")
    }

    func testDelete_leavesNoTempFiles() throws {
        let run = makeRun(model: "m")
        sut.append(run: run)
        sut.append(samples: [makeSample(runID: run.id, index: 0)])
        sut.delete(runIDs: [run.id])
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "orphan temp files: \(leftovers)")
    }

    /// Deleting the last run empties the file rather than removing it — and an empty file must
    /// load as an empty history, not as a decode failure.
    func testDelete_ofEveryRun_loadsAsAnEmptyHistory() {
        let run = makeRun(model: "m")
        sut.append(run: run)
        sut.delete(runIDs: [run.id])
        XCTAssertTrue(sut.loadRuns().isEmpty)
    }

    /// RED: keep `delete` returning `Void` (or always report success) → a permission error leaves
    /// the rows on screen with nothing said, and the user re-clicks a button that cannot work.
    func testDelete_reportsSuccess() {
        let run = makeRun(model: "m")
        sut.append(run: run)
        XCTAssertEqual(sut.delete(runIDs: [run.id]), .removed)
    }

    /// Nothing matched is not a failure: the history is in the state the caller asked for.
    func testDelete_ofAnUnknownID_reportsRemovedRatherThanAFailure() {
        sut.append(run: makeRun(model: "m"))
        XCTAssertEqual(sut.delete(runIDs: [UUID()]), .removed)
    }

    /// RED: swallow the rewrite error the way `append` does → the card claims a delete that never
    /// touched the disk.
    func testDelete_intoAnUnwritableDirectory_saysNothingWasWritten() throws {
        let run = makeRun(model: "m")
        sut.append(run: run)
        sut.append(samples: [makeSample(runID: run.id, index: 0)])
        // The files stay readable; the DIRECTORY loses write permission, so the temp file the
        // atomic rewrite needs cannot be created.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let outcome = sut.delete(runIDs: [run.id])

        guard case .nothingWritten = outcome else {
            return XCTFail("expected .nothingWritten, got \(outcome)")
        }
        // And the claim must be true: the run is still there.
        XCTAssertEqual(sut.loadRuns().count, 1)
    }

    // MARK: - Clear

    func testClear_reportsSuccess() {
        sut.append(run: makeRun(model: "m"))
        XCTAssertEqual(sut.clear(), .removed)
    }

    /// RED: swallow the removal error → "Delete all" reports success over a history that is still
    /// entirely on disk.
    func testClear_intoAnUnwritableDirectory_saysNothingWasWritten() throws {
        sut.append(run: makeRun(model: "m"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        guard case .nothingWritten = sut.clear() else {
            return XCTFail("expected .nothingWritten")
        }
        XCTAssertEqual(sut.loadRuns().count, 1, "the claim must be true: nothing was removed")
    }

    /// The torn state, and the one this order is chosen to produce: runs gone, samples not. RED:
    /// remove the samples file FIRST → a failure leaves runs whose samples are gone, and every
    /// table renders them as measurements that produced nothing.
    func testClear_whenTheSamplesFileResists_leavesTheRunsGoneAndSaysHowMuchRemains() throws {
        let run = makeRun(model: "m")
        sut.append(run: run)
        sut.append(samples: (0..<3).map { makeSample(runID: run.id, index: $0) })
        try FileManager.default.setAttributes(
            [.immutable: true], ofItemAtPath: sut.samplesURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: sut.samplesURL.path)
        }

        guard case .samplesLeftBehind(let rows, _) = sut.clear() else {
            return XCTFail("expected .samplesLeftBehind")
        }
        XCTAssertEqual(rows, 3, "the message must say how many rows are still there")
        XCTAssertTrue(sut.loadRuns().isEmpty, "the runs pass ran first and succeeded")
    }

    /// Same tear on the id-based path. RED: report `.removed` when only the runs pass landed →
    /// the sample rows accumulate silently, run after run.
    func testDelete_whenTheSamplesFileResists_saysTheRunsAreGoneAnyway() throws {
        let run = makeRun(model: "m")
        sut.append(run: run)
        sut.append(samples: [makeSample(runID: run.id, index: 0)])
        try FileManager.default.setAttributes(
            [.immutable: true], ofItemAtPath: sut.samplesURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: sut.samplesURL.path)
        }

        guard case .samplesLeftBehind(let rows, _) = sut.delete(runIDs: [run.id]) else {
            return XCTFail("expected .samplesLeftBehind")
        }
        XCTAssertEqual(rows, 1)
        XCTAssertTrue(sut.loadRuns().isEmpty)
    }

    func testClear_removesBothFiles() {
        let run = makeRun(model: "m")
        sut.append(run: run)
        sut.append(samples: [makeSample(runID: run.id, index: 0)])

        sut.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sut.runsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sut.samplesURL.path))
        XCTAssertTrue(sut.loadRuns().isEmpty)
        XCTAssertTrue(sut.loadSamples().isEmpty)
    }

    /// RED: leave the samples file in place → the next run's model summarises samples from runs
    /// the user believes they destroyed.
    func testClear_takesTheSamplesFileToo() {
        let run = makeRun(model: "m")
        sut.append(run: run)
        sut.append(samples: [makeSample(runID: run.id, index: 0)])
        sut.clear()
        XCTAssertTrue(sut.loadSamples().isEmpty)
    }

    /// Clearing is not a teardown: the very next measurement has to be recordable.
    func testClear_thenAppend_startsAFreshHistory() {
        sut.append(run: makeRun(model: "old"))
        sut.clear()
        sut.append(run: makeRun(model: "new"))
        XCTAssertEqual(sut.loadRuns().map(\.modelName), ["new"])
    }

    func testClear_onAnUntouchedHistory_isANoOp() {
        sut.clear()
        XCTAssertTrue(sut.loadRuns().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sut.runsURL.path))
    }

    /// The directory carries owner-only permissions this app set, and re-creating it is the one
    /// part of the layout that can fail. RED: remove the directory instead of the two files → the
    /// next append has to rebuild it, and on a machine where that fails the history silently stops
    /// recording.
    func testClear_keepsTheDirectory() {
        sut.append(run: makeRun(model: "m"))
        sut.clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Unwritable destination

    /// A benchmark must never fail because its RECORD could not be written — the measurement is
    /// the point and the history is bookkeeping. RED: propagate the error → a full-disk or
    /// permission problem takes down a run that had already produced its numbers.
    func testAppend_toAnUnwritableLocation_isSwallowed() throws {
        // A regular file where the directory should be: `createDirectory` cannot succeed here.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let store = BenchmarkHistoryStore(directory: blocker.appendingPathComponent("history"))
        store.append(run: makeRun(model: "m"))
        store.append(samples: [makeSample(runID: UUID(), index: 0)])

        XCTAssertTrue(store.loadRuns().isEmpty)
        XCTAssertTrue(store.loadSamples().isEmpty)
    }

    /// Same contract for the rewrite path: pruning is housekeeping, and housekeeping that cannot
    /// run must not take anything else down with it.
    func testPrune_withAnUnwritableLocation_isSwallowed() throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let store = BenchmarkHistoryStore(directory: blocker.appendingPathComponent("history"))
        store.prune(limit: 1)
        XCTAssertTrue(store.loadRuns().isEmpty)
    }

    // MARK: - Directory

    /// The history sits beside the default work folder's `.nanoteams/`, never inside it — it is a
    /// machine-scoped fact, not a work-folder one.
    func testDefaultDirectory_isBesideTheNanoteamsTree() {
        let path = BenchmarkHistoryStore.defaultDirectory.path
        XCTAssertTrue(path.hasSuffix("/NanoTeams/benchmarks"), path)
        XCTAssertFalse(path.contains(".nanoteams"), path)
    }

    /// RED: creating the directory with default attributes → leaves benchmark history world-readable
    /// where every other directory this app creates under Application Support is owner-only.
    func testDirectoryIsCreatedOwnerOnly() throws {
        sut.append(run: makeRun(model: "m"))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value, 0o700)
    }

    // MARK: - Builders

    private func makeRun(
        model: String,
        providerVersion: String? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> GenerationBenchmarkRun {
        GenerationBenchmarkRun(
            startedAt: startedAt,
            provider: .lmStudio,
            baseURLString: "http://127.0.0.1:1234",
            modelName: model,
            providerVersion: providerVersion,
            serverFields: ["format": "gguf"],
            samplingParameters: ["temperature": "1"],
            requestTimeoutSeconds: 600,
            promptID: "prose-ru-en",
            promptVersion: 1,
            repeats: 5,
            thermalState: BenchmarkThermalState.nominal,
            lowPowerMode: false,
            modelWasResident: true,
            appVersion: "1.8.8")
    }

    private func makeSample(runID: UUID, index: Int) -> GenerationBenchmarkSample {
        GenerationBenchmarkSample(
            runID: runID,
            recordedAt: Date(timeIntervalSince1970: 1000 + Double(index)),
            phase: .measured,
            sampleIndex: index,
            inputTokens: 800,
            outputTokens: 401,
            timeToFirstTokenMs: 600,
            generationMs: 10_000,
            prefillMs: 400,
            prefillSource: .serverPromptEval)
    }
}

private extension Data {
    /// Appends to an existing file — used to plant a corrupt line between two good ones.
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
