import XCTest

@testable import NanoTeams

// ============================================================================
// MARK: - Shared file-private doubles
// ============================================================================

/// Embedding client whose vector WIDTH is mutable between calls.
///
/// Every existing double in this suite is fixed-width, which is precisely why the
/// width-drift crash in `VocabVectorIndexBuilder` went unnoticed: no test could
/// express "the same model name started answering with a different number of
/// dimensions".
private final class ESearchWidthEmbedClient: EmbeddingClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _dims = 3
    private var _throwCancellation = false

    var callCount: Int { lock.withLock { _callCount } }
    var dims: Int {
        get { lock.withLock { _dims } }
        set { lock.withLock { _dims = newValue } }
    }
    /// Flipped between a build and a query so one client can serve both phases.
    var throwCancellation: Bool {
        get { lock.withLock { _throwCancellation } }
        set { lock.withLock { _throwCancellation = newValue } }
    }

    func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
        let (width, cancel): (Int, Bool) = lock.withLock {
            _callCount += 1
            return (_dims, _throwCancellation)
        }
        if cancel { throw CancellationError() }
        // Identical unit vectors: every token is maximally similar to every
        // other, so a nearest-neighbour assertion is about the plumbing rather
        // than about float luck. A zero vector would normalise to NaN.
        return texts.map { _ in
            var v = [Float](repeating: 0, count: width)
            v[0] = 1
            return v
        }
    }
}

/// Deterministic slow client — one batch per call, each parked long enough that
/// a test can observe a build IN FLIGHT and poke the coordinator while it is.
private final class ESearchSlowEmbedClient: EmbeddingClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    /// `let`, set at construction: a mutable field read from the embed task
    /// while the test writes it would be the data race `@unchecked` waives.
    private let delay: Duration

    init(delay: Duration = .milliseconds(120)) {
        self.delay = delay
    }

    var callCount: Int { lock.withLock { _callCount } }

    func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
        lock.withLock { _callCount += 1 }
        try await Task.sleep(for: delay)
        return texts.map { _ in [1, 0, 0] }
    }
}

/// Counts how many times the coordinator asked for an embedding config.
///
/// One invocation == one `performVectorBuild`, which is the only observable that
/// distinguishes "the FS-event refresh coalesced into a single follow-up build"
/// from "each request spawned its own" — the smart diff makes the follow-up
/// issue zero embed calls, so the client's own counter cannot tell them apart.
private final class ESearchConfigProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }

    func next() -> EmbeddingConfig {
        lock.withLock { _count += 1 }
        return EmbeddingConfig(
            baseURLString: "http://127.0.0.1:1234",
            modelName: "esearch-probe-model",
            batchSize: 1,
            requestTimeout: 5
        )
    }
}

// MARK: - Fixtures

/// Search index whose tokens all survive `VocabFilter.default` (the corpus is
/// below `nearUniversalSkipBelowFileCount`, so the filter accepts everything).
private func esearchIndex(tokens: [String], fileCount: Int = 10) -> SearchIndex {
    var postings: [String: [Int]] = [:]
    for token in tokens { postings[token] = [0, 1] }
    let files = (0..<fileCount).map {
        IndexedFile(path: "f\($0).swift",
                    mTime: Date(timeIntervalSince1970: 1_700_000_000),
                    size: 100)
    }
    // swiftlint:disable:next force_try
    return try! SearchIndex(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        signature: IndexSignature(
            fileCount: fileCount,
            maxMTime: Date(timeIntervalSince1970: 1_700_000_000),
            totalSize: Int64(fileCount * 100)
        ),
        files: files,
        tokens: tokens.sorted(),
        postings: postings
    )
}

private func esearchConfig(modelName: String = "esearch-model", batchSize: Int = 4) -> EmbeddingConfig {
    EmbeddingConfig(
        baseURLString: "http://127.0.0.1:1234",
        modelName: modelName,
        batchSize: batchSize,
        requestTimeout: 5
    )
}

// ============================================================================
// MARK: - SearchIndexCoordinator: the error-reporting arms and the FS coalescer
// ============================================================================

/// The coordinator is `@MainActor @Observable`, so this class is `@MainActor`
/// and every method is `async` — a synchronous method that constructs a
/// `@MainActor` type in its body aborts the whole test worker on this toolchain
/// (CLAUDE.md "Common API pitfalls when writing tests").
@MainActor
final class ESearchCoordinatorTailTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("esearch-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let internalDir { chmod(internalDir.path, 0o700) }
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        try await super.tearDown()
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeCoordinator(
        client: any EmbeddingClient,
        configProvider: (@MainActor () -> EmbeddingConfig)? = nil
    ) -> SearchIndexCoordinator {
        if let configProvider {
            return SearchIndexCoordinator(
                workFolderRoot: tempDir,
                internalDir: internalDir,
                embeddingConfigProvider: configProvider,
                embeddingClient: client,
                fileManager: fm,
                makeWatcher: FakeWatcherFactory.inert,
                watcherDebounce: 0.05
            )
        }
        return SearchIndexCoordinator(
            workFolderRoot: tempDir,
            internalDir: internalDir,
            embeddingClient: client,
            fileManager: fm,
            makeWatcher: FakeWatcherFactory.inert,
            watcherDebounce: 0.05
        )
    }

    /// A vector-clear failure has to reach the user under its OWN name.
    ///
    /// The two clear failures are not interchangeable: the token index and the
    /// vector index have separate files and separate remedies, and the vector
    /// arm only ever runs when the token clear SUCCEEDED — which is exactly the
    /// case the existing coverage (token index present, whole directory frozen)
    /// could never produce. A silent failure here is the expensive one: the next
    /// `load()` resurrects the stale vectors the user just asked to delete.
    ///
    /// RED: delete the `else if let vectorClearError` arm → `lastError` is nil
    /// and the surviving vectors are reported as a successful clear.
    func testClear_vectorFilesSurvive_reportedUnderTheVectorName() async throws {
        // Vector files present, token index deliberately ABSENT so the token
        // clear is a clean no-op and control reaches the vector arm.
        let bin = internalDir.appendingPathComponent("vocab_vectors.bin")
        let meta = internalDir.appendingPathComponent("vocab_vectors.meta.json")
        try Data([0x4E, 0x54, 0x56, 0x45]).write(to: bin)
        try Data("{}".utf8).write(to: meta)
        XCTAssertFalse(fm.fileExists(atPath:
            internalDir.appendingPathComponent("search_index.json").path),
            "arrange: the token index must be absent so its clear cannot fail")

        chmod(internalDir.path, 0o500)
        if (try? Data("probe".utf8).write(to: internalDir.appendingPathComponent("w.tmp"))) != nil {
            throw XCTSkip("this user can write to a 0o500 directory (root?); the arm is not inducible")
        }

        let c = makeCoordinator(client: ESearchSlowEmbedClient())
        await c.clear()

        let error = c.lastError
        XCTAssertNotNil(error, "surviving vector files must not be reported as a clean clear")
        XCTAssertTrue(error?.hasPrefix("Failed to clear vector index") ?? false,
                      "the message must name the VECTOR index — the token index cleared fine, "
                      + "and the two have different remedies: \(error ?? "nil")")
        XCTAssertTrue(error?.contains("vocab_vectors") ?? false,
                      "and name the file that survived: \(error ?? "nil")")
        XCTAssertEqual(c.vectorIndexState, .missing)
    }

    /// A persist failure outranks everything else on the status card, because it
    /// is the one that keeps coming back: the index is rebuilt from scratch on
    /// every single launch and nothing on screen says why.
    ///
    /// RED: delete the `if let persistError` arm → the chain falls through to
    /// "no warnings" and `lastError` is nil while the index never reaches disk.
    func testBuild_persistFailure_isSurfacedAheadOfEverythingElse() async throws {
        try write("A.swift", content: "class Alpha {}")
        chmod(internalDir.path, 0o500)
        if (try? Data("probe".utf8).write(to: internalDir.appendingPathComponent("w.tmp"))) != nil {
            throw XCTSkip("this user can write to a 0o500 directory (root?); the arm is not inducible")
        }

        let c = makeCoordinator(client: ESearchSlowEmbedClient())
        await c.start()
        _ = await c.awaitIndex()
        await c.stop()

        let persistError = await c.service.lastPersistError
        let loadError = await c.service.lastLoadError
        let warnings = await c.service.lastIndexWarnings
        XCTAssertNotNil(persistError, "arrange: the write into a read-only directory must fail")
        XCTAssertNil(loadError, "arrange: nothing was ever written, so there is nothing to fail loading")
        XCTAssertTrue(warnings.isEmpty, "arrange: the walk itself is clean")

        XCTAssertEqual(c.lastError, persistError,
                       "the coordinator must surface the persist failure verbatim — got: "
                       + "\(c.lastError ?? "nil")")
    }

    /// A corrupt on-disk index is regenerated silently unless the reason is
    /// surfaced; the settings card is the only place the user learns their index
    /// was thrown away and rebuilt.
    ///
    /// RED: delete the `else if let loadError` arm → `lastError` is nil and the
    /// corruption is invisible.
    func testBuild_corruptIndexOnDisk_reportsWhyItWasRegenerated() async throws {
        try write("A.swift", content: "class Alpha {}")
        try Data("{ not json at all".utf8)
            .write(to: internalDir.appendingPathComponent("search_index.json"))

        let c = makeCoordinator(client: ESearchSlowEmbedClient())
        await c.start()
        let index = await c.awaitIndex()
        await c.stop()

        // Hoisted: an `await` inside an XCTAssert autoclosure does not compile.
        let persistError = await c.service.lastPersistError
        XCTAssertEqual(index?.files.count, 1, "arrange: a corrupt index must still rebuild")
        XCTAssertNil(persistError,
                     "arrange: the rebuild persisted fine, so persist must not win the priority")

        let error = c.lastError
        XCTAssertNotNil(error, "a regenerated index must say why")
        XCTAssertTrue(error?.contains("search_index.json") ?? false,
                      "the message names the file: \(error ?? "nil")")
        XCTAssertTrue(error?.localizedCaseInsensitiveContains("corrupt") ?? false,
                      "'corrupt' is the decode-failure vocabulary, distinct from 'unreadable' "
                      + "and from a version mismatch: \(error ?? "nil")")
    }

    /// DEFECT REGRESSION. The corrupt-index message must not outlive the
    /// corruption.
    ///
    /// `lastLoadError` is written only by `loadFromDisk`, and once a rebuild has
    /// populated the in-memory cache every later `loadOrBuild(force: false)`
    /// returns on the cached fast path without attempting a load. The field was
    /// therefore never re-evaluated, so `performTokenBuild` re-read the same
    /// stale string on every subsequent build and pinned "search_index.json
    /// corrupt" on the settings card for the rest of the session — against an
    /// index that had been healthy on disk since the first rebuild. The
    /// `lastLoadError` doc comment promised the clearing; the code never did it.
    /// (`SearchTeamStorageTailTests.testLoadFromDisk_versionDrift_*` records the
    /// same disagreement and assumes it "self-heals on the next call" — that was
    /// true only for a FRESH actor, which is not what the coordinator holds.)
    ///
    /// RED: remove `lastLoadError = nil` from `loadOrBuild`'s cached fast path →
    /// the second assertion fails and the message is immortal.
    func testBuild_afterCorruptIndexIsRebuilt_theReasonIsRetiredNotRepeated() async throws {
        try write("A.swift", content: "class Alpha {}")
        try Data("{ not json at all".utf8)
            .write(to: internalDir.appendingPathComponent("search_index.json"))

        let c = makeCoordinator(client: ESearchSlowEmbedClient())
        await c.start()
        _ = await c.awaitIndex()
        XCTAssertNotNil(c.lastError, "arrange: the regeneration reports its reason once")
        // No `stop()` between the phases. It used to sit here to keep the watcher from
        // slipping an extra build in — a real concern back when the coordinator opened its
        // own FSEventStream, and impossible since `makeCoordinator` began injecting
        // `FakeWatcherFactory.inert`, which fires nothing. Leaving it made the test depend on
        // `stop()` NOT meaning teardown: the second phase drove a coordinator that had been
        // told to shut down, which is exactly the leak `SearchIndexCoordinatorStopGateTests`
        // now forbids.

        // A second build over an unchanged folder. The index on disk is now
        // valid, so there is nothing left to report.
        await c.ensureFresh()

        let residualLoadError = await c.service.lastLoadError
        XCTAssertNil(residualLoadError,
                     "a cache that still matches the folder proves the load problem is over")
        XCTAssertNil(c.lastError,
                     "a healthy index must not keep reporting a corruption that was already "
                     + "repaired — got: \(c.lastError ?? "nil")")
    }

    /// FS events must COALESCE into at most one follow-up vector build, not
    /// cancel-and-restart and not queue one build per event.
    ///
    /// This is the whole reason the vector pipeline is decoupled from the
    /// cancellable token pipeline: every batch already received from the
    /// embedding server is paid network work, and a burst of writes during a
    /// long build (an active run appending artifacts) previously looked like a
    /// rebuild-from-scratch loop.
    ///
    /// The config provider is the observable, not the embed client: the
    /// follow-up build sees an unchanged vocabulary and issues zero embed calls,
    /// so only "how many times did a vector build start" can tell the shapes
    /// apart.
    ///
    /// RED (either direction):
    ///  - make `requestVectorRefresh` always call `startVectorBuild` → 3 requests
    ///    start 3 builds and the count is 4, not 2;
    ///  - drop the `if pendingVectorRefresh` respawn at the end of
    ///    `startVectorBuild` → the drain never happens, the poll times out and
    ///    the count is 1.
    func testVectorRefresh_burstDuringBuild_drainsAsExactlyOneFollowUp() async throws {
        try write("A.swift", content: "class ScrollView { func makeScroll() {} }")
        try write("B.swift", content: "class ScrollView { func renderScroll() {} }")

        let probe = ESearchConfigProbe()
        let client = ESearchSlowEmbedClient(delay: .milliseconds(150))
        let c = makeCoordinator(client: client, configProvider: { probe.next() })

        await c.start()

        // Wait until a vector build is genuinely in flight, then poke it in the
        // SAME MainActor turn — there is no suspension point between the check
        // and the requests, so the build cannot finish underneath them.
        var sawBuilding = false
        let armDeadline = Date().addingTimeInterval(10)
        while Date() < armDeadline {
            if c.isBuildingVectorIndex {
                sawBuilding = true
                c._testRequestVectorRefresh()
                c._testRequestVectorRefresh()
                c._testRequestVectorRefresh()
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sawBuilding,
                      "arrange: no vector build was ever observed in flight, so nothing coalesced")

        // Let the drain land.
        let drainDeadline = Date().addingTimeInterval(10)
        while Date() < drainDeadline, probe.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        await c.stop()

        XCTAssertEqual(probe.count, 2,
                       "three refresh requests during one build must produce exactly one "
                       + "follow-up build — got \(probe.count) builds in total")
    }
}

// ============================================================================
// MARK: - SearchIndexService: a root that is not a directory
// ============================================================================

final class ESearchIndexServiceTailTests: XCTestCase, @unchecked Sendable {

    var tempDir: URL!
    var internalDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esearch-svc-\(UUID().uuidString)", isDirectory: true)
        internalDir = tempDir.appendingPathComponent("internal", isDirectory: true)
        try FileManager.default.createDirectory(at: internalDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        try super.tearDownWithError()
    }

    /// A root that is not a directory yields an EMPTY index rather than a crash —
    /// and, critically, an empty SIGNATURE, so the moment a real directory
    /// appears at that path the cache is invalidated and the folder is indexed.
    ///
    /// The second half is the part worth pinning: a walk that bailed while
    /// leaving a signature that still "matches" would wedge the index at empty
    /// forever, and search would report a populated project as having no
    /// content at all.
    ///
    /// It also has to stay SILENT. `lastIndexWarnings` means "the walk ran and
    /// parts of the tree were unreadable", and the coordinator turns it into
    /// "Some files may be missing from the index" — the wrong diagnosis entirely
    /// for a root that is not a folder, and one that sends the user hunting for
    /// an unreadable subtree that does not exist.
    ///
    /// RED: weaken the guard to `fileExists` alone (dropping `isDir.boolValue`),
    /// or remove it → `walkRecursive` calls `contentsOfDirectory` on a regular
    /// file, that throws, and the warning assertion fails.
    func testWalk_rootIsNotADirectory_yieldsASilentEmptyIndexThatStillInvalidates() async throws {
        let root = tempDir.appendingPathComponent("root")
        try Data("I am a file, not a folder".utf8).write(to: root)

        let service = SearchIndexService(
            workFolderRoot: root, internalDir: internalDir, fileManager: .default)
        let empty = await service.loadOrBuild(force: true)

        XCTAssertTrue(empty.files.isEmpty, "a non-directory root has nothing to walk")
        XCTAssertTrue(empty.tokens.isEmpty)
        XCTAssertEqual(empty.signature.fileCount, 0)
        XCTAssertEqual(empty.signature.totalSize, 0)

        let warnings = await service.lastIndexWarnings
        XCTAssertTrue(warnings.isEmpty,
                      "a missing/!directory root is a caller precondition, not a partial walk — "
                      + "got: \(warnings)")

        // Replace the file with a real folder holding one file.
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("class Alpha {}".utf8).write(to: root.appendingPathComponent("A.swift"))

        let rebuilt = await service.loadOrBuild(force: false)
        XCTAssertEqual(rebuilt.files.count, 1,
                       "the empty-root result must not pin the cache — a folder appearing at "
                       + "that path has to invalidate it")
        XCTAssertFalse(rebuilt.tokens.isEmpty)
    }
}

// ============================================================================
// MARK: - SearchFileReader / SearchFileScanner: unreadable candidates
// ============================================================================

final class ESearchFileScannerTailTests: XCTestCase, @unchecked Sendable {

    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esearch-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makePlan(_ query: String = "needle") -> SearchScanPlan {
        SearchScanPlan(
            needles: [LineScanner.CompiledNeedle(query)],
            regexes: [nil],
            contextBefore: 0,
            contextAfter: 0,
            perQueryCap: 10,
            collectBudget: 10,
            asciiFoldMatchesLocale: LineScanner.asciiFoldMatchesLocale
        )
    }

    /// A candidate the reader cannot OPEN must land in `skipped` with a reason,
    /// and must not touch the binary counter.
    ///
    /// The distinction is the entire justification for `StreamReadOutcome` having
    /// four cases: "skipped 1 binary" and "could not open notes.txt" send the
    /// reader of the envelope to completely different places, and a search that
    /// silently omits a file it could not read is indistinguishable from one that
    /// found no matches.
    ///
    /// Induced with a DIRECTORY carrying a non-document extension — measured on
    /// this toolchain, `FileHandle(forReadingFrom:)` throws for it. That needs no
    /// permission games, so it holds for any user including root.
    ///
    /// RED: route `.ioError` to `results.skippedBinaryCount += 1` → `skipped` is
    /// empty and the binary count is 1; both assertions fail.
    func testScanFile_candidateThatCannotBeOpened_isReportedNotCountedAsBinary() throws {
        let bogus = tempDir.appendingPathComponent("notes.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)

        var results = SearchScanResults(queryCount: 1)
        SearchExecutor.scanFile(
            at: bogus, relativePath: "notes.txt", plan: makePlan(), into: &results)

        XCTAssertEqual(results.skipped.count, 1,
                       "an unopenable candidate must be reported, not silently dropped")
        XCTAssertEqual(results.skipped.first?.path, "notes.txt")
        XCTAssertTrue(results.skipped.first?.reason.contains("could not open") ?? false,
                      "the reason must name the failing syscall so 'could not open' stays "
                      + "distinguishable from a mid-read failure: "
                      + "\(results.skipped.first?.reason ?? "nil")")
        XCTAssertEqual(results.skippedBinaryCount, 0,
                       "an I/O failure is not a binary file — collapsing them is what the "
                       + "four-case outcome exists to prevent")
        XCTAssertEqual(results.totalMatchCount, 0)
    }

    /// Same failure at the reader boundary: the outcome is `.ioError`, never
    /// `.binary` and never an empty `.text` that would read as "no matches here".
    ///
    /// RED: collapse the `FileHandle` catch into `return .binary` → the guard
    /// fails.
    func testReadUTF8Streaming_unopenableFile_classifiesAsIOErrorNotBinary() throws {
        let bogus = tempDir.appendingPathComponent("blob.dat", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)

        let outcome = SearchExecutor.readUTF8Streaming(url: bogus)
        guard case .ioError(let reason) = outcome else {
            return XCTFail("expected .ioError, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("could not open"), "got: \(reason)")
    }

    /// Cancellation must be its own outcome. It shares the reader's exit with
    /// `.binary`, and if the two were collapsed the binary-skip count would grow
    /// by one for every file the cancelled walk happened to reach — turning a
    /// paused step into a corpus that looks full of unreadable blobs.
    ///
    /// RED: return `.binary` (or `.text(buffer)`) from the `Task.isCancelled`
    /// check → the guard fails.
    func testReadUTF8Streaming_underCancellation_classifiesAsCancelled() async throws {
        let file = tempDir.appendingPathComponent("payload.txt")
        // Non-empty: a zero-byte file short-circuits to `.text` before the loop
        // that checks cancellation ever runs.
        try Data(String(repeating: "alpha beta\n", count: 64).utf8).write(to: file)

        // The outcome is reduced to a String inside the task: the point is the
        // classification, and a plain `String` sidesteps any question about the
        // outcome enum's Sendability across the task boundary.
        let task = Task { () -> String in
            var spins = 0
            while !Task.isCancelled && spins < 100_000 {
                spins += 1
                await Task.yield()
            }
            guard Task.isCancelled else { return "never-cancelled" }
            switch SearchExecutor.readUTF8Streaming(url: file) {
            case .cancelled: return "cancelled"
            case .binary: return "binary"
            case .text(let bytes): return "text(\(bytes.count))"
            case .ioError(let reason): return "ioError(\(reason))"
            case .tooLarge(let bytes): return "tooLarge(\(bytes))"
            }
        }
        task.cancel()

        let outcome = await task.value
        XCTAssertEqual(outcome, "cancelled",
                       "a cancelled read must be its own outcome — 'binary' would inflate "
                       + "skipped_binary_count once per file the cancel walked past")
    }

    // NOTE — `scanFile`'s "document extractor could not open file" arm is NOT
    // covered here on purpose. `extractText` returns `nil` for exactly one
    // reason (no registered extractor), and the arm sits behind
    // `isSupported(extension:)`, so it cannot fire while
    // `DocumentConstants.supportedReadExtensions` and the extractor registry
    // agree. That coupling is already pinned, verbatim and with the same
    // nonexistent-file trick, by
    // `DocumentFormatExtractorsTests.testFacade_everySupportedExtensionResolvesToAStrategy`
    // — a second copy here would cost a test and tell nobody anything new.
}

// ============================================================================
// MARK: - VocabVectorIndexBuilder: embedding width drifting under one model name
// ============================================================================

final class ESearchVectorBuilderTailTests: XCTestCase, @unchecked Sendable {

    /// DEFECT REGRESSION. The assembly loop's fallthrough was a
    /// `preconditionFailure` documented as "unreachable by construction". It is
    /// reachable: the smart diff keys on `meta.modelName` ALONE, so a server that
    /// answers the same model name with a different embedding width (Matryoshka
    /// truncation, a re-quantised model) leaves every REUSED token at the old
    /// width while the run's `dims` is the new one. The reused arm's
    /// `current.meta.dims == dims` fails, `embeddings` holds nothing for a reused
    /// token, and the process traps — then traps again on the next launch,
    /// because the on-disk index still carries the old width.
    ///
    /// RED: restore the `preconditionFailure` else-arm → this test traps instead
    /// of completing. A softer mutation — drop the token but do not record it —
    /// reds the `failedTokens` assertions here and the convergence test below.
    func testBuild_embeddingWidthChangesUnderTheSameModelName_dropsInsteadOfTrapping() async throws {
        let client = ESearchWidthEmbedClient()
        client.dims = 3
        let builder = VocabVectorIndexBuilder(
            client: client, batchRetries: 0, retryBackoffSeconds: [0])
        let config = esearchConfig()

        let first = try await builder.build(
            searchIndex: esearchIndex(tokens: ["alpha", "beta"]),
            current: nil, config: config, force: false)
        XCTAssertEqual(first.index.meta.dims, 3, "arrange: the stored index is 3-wide")
        XCTAssertEqual(Set(first.index.meta.tokenMap.keys), ["alpha", "beta"])

        // Same model NAME, different width, and one genuinely new token so the
        // diff cannot short-circuit.
        client.dims = 5
        let second = try await builder.build(
            searchIndex: esearchIndex(tokens: ["alpha", "beta", "gamma"]),
            current: first.index, config: config, force: false)

        XCTAssertEqual(second.index.meta.dims, 5, "the run adopts the new width")
        XCTAssertEqual(Set(second.index.meta.tokenMap.keys), ["gamma"],
                       "only the token embedded at the new width can be placed")
        XCTAssertEqual(second.index.vectors.count, 5,
                       "the flat buffer must stay tokenMap.count × dims")
        XCTAssertEqual(Set(second.index.meta.failedTokens), ["alpha", "beta"],
                       "the un-placeable tokens must be recorded, or nothing ever re-embeds them")
        XCTAssertEqual(second.failedCount, 2)
        XCTAssertEqual(second.addedCount, 1,
                       "`addedCount` must report what LANDED, not what was embedded")
        XCTAssertTrue(second.needsPersist)
    }

    /// …and the drop must be self-healing: a token absent from `tokenMap` is
    /// classified as `added` on the next build, so one extra build restores full
    /// coverage at the new width. Without that the index would stay permanently
    /// short of two thirds of its vocabulary.
    ///
    /// RED: keep the dropped tokens in `newTokenMap` (or record them nowhere) →
    /// the third build sees nothing to add and the coverage assertion fails.
    func testBuild_afterAWidthDrop_theNextBuildRestoresTheFullVocabulary() async throws {
        let client = ESearchWidthEmbedClient()
        client.dims = 3
        let builder = VocabVectorIndexBuilder(
            client: client, batchRetries: 0, retryBackoffSeconds: [0])
        let config = esearchConfig()
        let corpus = esearchIndex(tokens: ["alpha", "beta", "gamma"])

        let first = try await builder.build(
            searchIndex: esearchIndex(tokens: ["alpha", "beta"]),
            current: nil, config: config, force: false)
        client.dims = 5
        let second = try await builder.build(
            searchIndex: corpus, current: first.index, config: config, force: false)
        XCTAssertEqual(second.index.meta.tokenMap.count, 1, "arrange: two tokens were dropped")

        let third = try await builder.build(
            searchIndex: corpus, current: second.index, config: config, force: false)

        XCTAssertEqual(Set(third.index.meta.tokenMap.keys), ["alpha", "beta", "gamma"],
                       "the dropped tokens must come back as `added` and be re-embedded")
        XCTAssertEqual(third.index.meta.dims, 5)
        XCTAssertTrue(third.index.meta.failedTokens.isEmpty,
                      "nothing is left un-placeable once every vector is the same width")
        XCTAssertEqual(third.index.vectors.count, 15, "3 tokens × 5 dims")
    }
}

// ============================================================================
// MARK: - VocabVectorIndexService: a cancelled phrase embedding
// ============================================================================

final class ESearchVectorServiceTailTests: XCTestCase, @unchecked Sendable {

    var internalDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        internalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esearch-vec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: internalDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let internalDir { try? FileManager.default.removeItem(at: internalDir) }
        internalDir = nil
        try super.tearDownWithError()
    }

    /// Cancellation is not a failure of the expansion. The per-token tier is
    /// already complete and came out of the persisted index; only the optional
    /// whole-phrase call was interrupted, and the caller's own tree is being torn
    /// down anyway.
    ///
    /// Reporting it as `.transientError` would put a spurious `expansion_error`
    /// into the search envelope the LLM reads — on every pause — and would tell
    /// it to retry something that was never broken.
    ///
    /// RED: set `liveError` in the `catch is CancellationError` arm → the result
    /// becomes `.transientError` and both the equality and the `errorReason`
    /// assertion fail.
    func testExpand_phraseEmbeddingCancelled_stillReturnsThePerTokenTermsCleanly() async {
        let client = ESearchWidthEmbedClient()
        let service = VocabVectorIndexService(
            internalDir: internalDir, client: client, fileManager: .default)
        let config = esearchConfig(batchSize: 4)

        await service.rebuildIfNeeded(
            searchIndex: esearchIndex(tokens: ["alpha", "beta", "gamma"]),
            config: config, force: false)
        let builtState = await service.state
        guard case .ready = builtState else {
            return XCTFail("arrange: the index must be ready, got \(builtState)")
        }

        client.throwCancellation = true
        let result = await service.expand(
            query: "alpha beta", tokens: ["alpha", "beta"], config: config,
            perTokenThreshold: 0.1, phraseThreshold: 0.1)

        XCTAssertEqual(result, .expanded(terms: ["gamma"]),
                       "a cancelled phrase call keeps the per-token result and stays a clean "
                       + "success — got \(result)")
        XCTAssertNil(result.errorReason,
                     "cancellation must not surface as a retryable transient error")
        XCTAssertNil(result.unavailableReason)
        let finalState = await service.state
        guard case .ready = finalState else {
            return XCTFail("cancellation must not demote the index state, got \(finalState)")
        }
    }
}

// ============================================================================
// MARK: - VocabVectorBinaryCodec: on-disk format drift
// ============================================================================

final class ESearchVectorCodecTailTests: XCTestCase, @unchecked Sendable {

    /// A blob written by a future build carries our magic but a version we cannot
    /// read. It has to be rejected with its OWN error: the remedy is a full
    /// rebuild, whereas `badMagic` means "this is not our file at all" and
    /// `dimsMismatch` means "the meta and the bin disagree". Decoding it anyway
    /// would reinterpret whatever layout the next format uses as Float16 pairs
    /// and hand the search silently wrong vectors.
    ///
    /// RED: drop the `version == currentVersion` guard → `decode` succeeds and
    /// `XCTAssertThrowsError` fails.
    func testDecode_futureFormatVersion_isRejectedAsUnsupportedNotMisread() throws {
        var data = VocabVectorBinaryCodec.encode(vectors: [1, 0, 0], count: 1, dims: 3)
        let futureVersion = VocabVectorBinaryCodec.currentVersion + 99
        var patch = Data()
        withUnsafeBytes(of: futureVersion.littleEndian) { patch.append(contentsOf: $0) }
        // Bytes 4..<8 are the version field; the magic (0..<4) stays OURS, which
        // is what separates this from `badMagic`.
        data.replaceSubrange(4..<8, with: patch)

        XCTAssertThrowsError(
            try VocabVectorBinaryCodec.decode(data: data, expectedDims: 3, expectedCount: 1)
        ) { error in
            XCTAssertEqual(error as? VocabVectorBinaryCodec.DecodeError,
                           .unsupportedVersion(Int(futureVersion)),
                           "version drift needs its own diagnosis — got \(error)")
        }

        // Control: the unpatched blob still decodes, so the rejection above is
        // attributable to the version field and nothing else.
        let good = VocabVectorBinaryCodec.encode(vectors: [1, 0, 0], count: 1, dims: 3)
        XCTAssertEqual(
            try VocabVectorBinaryCodec.decode(data: good, expectedDims: 3, expectedCount: 1).count, 3)
    }
}

// ============================================================================
// MARK: - WorkFolderContextPromptPlanner: a capped read that fits whole
// ============================================================================

final class ESearchContextPlannerTailTests: XCTestCase, @unchecked Sendable {

    /// An excerpt whose RAW READ was capped must say the file continues, even
    /// when every line it holds fits in the budget.
    ///
    /// The two truncation reasons are different facts. "first N of M lines" means
    /// the planner trimmed a file it had whole; "first N lines; file continues"
    /// means nobody knows how long the file is, because the reader stopped at its
    /// byte window. Emitting no marker at all in the second case tells the model
    /// it has seen the entire file — which is how a 64 KB-truncated README gets
    /// summarised as though its tail did not exist.
    ///
    /// RED: delete the `else if excerpt.wasReadCapped` arm (leaving `marker =
    /// nil`) → the marker assertion fails while every line is still present.
    func testCompose_cappedReadThatFitsEntirely_stillSaysTheFileContinues() {
        let composed = WorkFolderContextPromptPlanner.compose(
            input: Self.makeInput(wasReadCapped: true), tokenBudget: 400)
        let message = composed.userMessage

        // Every line survived: the excerpt is below the line floor, so nothing
        // was trimmed and the marker cannot be the "first N of M" variant.
        // (Distinctive line text: "one"/"two" would also match inside
        // "Component…" in the file list.)
        XCTAssertTrue(message.contains("ZALPHALINE"), "arrange: the whole excerpt must be emitted")
        XCTAssertTrue(message.contains("ZBETALINE"))
        XCTAssertTrue(message.contains("ZGAMMALINE"))
        XCTAssertFalse(message.contains(" of 3 lines"),
                       "nothing was trimmed, so the 'first N of M' marker would be a lie")

        XCTAssertTrue(message.contains("lines; file continues]"),
                      "a capped read must be declared — got:\n\(message)")
        XCTAssertTrue(composed.trim.trimmedExcerptPaths.contains("README.md"),
                      "and the caller must be told which file was cut short")
    }

    /// Shared fixture: a file list far too large for the budget (so the
    /// byte-identical fast path cannot fire — it is the only route to the
    /// shaping code) plus one three-line excerpt.
    private static func makeInput(wasReadCapped: Bool) -> WorkFolderContextInput {
        WorkFolderContextInput(
            rootName: "Proj",
            fileList: (0..<400).map { "Sources/Deep/Nested/Component\($0).swift" },
            fileTypeCounts: ["swift": 400],
            excerpts: [
                WorkFolderContextInput.FileExcerpt(
                    path: "README.md",
                    content: "ZALPHALINE\nZBETALINE\nZGAMMALINE",
                    isPriority: false,
                    wasReadCapped: wasReadCapped
                )
            ]
        )
    }

    /// Control for the test above: the same excerpt WITHOUT the cap flag must
    /// carry no marker at all. Without this, a marker printed unconditionally
    /// would satisfy the assertions above while lying about every complete file.
    ///
    /// RED: emit the "file continues" marker regardless of `wasReadCapped` →
    /// this fails.
    func testCompose_uncappedExcerptThatFitsEntirely_carriesNoTruncationMarker() {
        let composed = WorkFolderContextPromptPlanner.compose(
            input: Self.makeInput(wasReadCapped: false), tokenBudget: 400)
        let message = composed.userMessage

        XCTAssertTrue(message.contains("ZGAMMALINE"), "arrange: the whole excerpt must be emitted")
        // Anchored on the EXCERPT markers only: the file list carries its own
        // "…truncated to fit the model's context window" line here, so a bare
        // `contains("truncated")` would be true no matter what.
        XCTAssertFalse(message.contains("file continues"),
                       "a complete excerpt must not claim its file continues:\n\(message)")
        XCTAssertFalse(message.contains(" of 3 lines"),
                       "…nor that it was trimmed:\n\(message)")
        XCTAssertFalse(composed.trim.trimmedExcerptPaths.contains("README.md"))
    }
}

// ============================================================================
// MARK: - CompiledGlob: the invalid-glob sentinel
// ============================================================================

final class ESearchFilenameMatcherTailTests: XCTestCase, @unchecked Sendable {

    /// Characterization of the PLATFORM, not of a production branch: the invalid-glob
    /// sentinel is rejected by the explicit `throw` in `CompiledGlob.init` and by
    /// nothing else.
    ///
    /// `CompiledGlob`'s doc comment used to claim a leading NUL trips
    /// `NSRegularExpression(pattern:options:)`. Measured on this toolchain it does
    /// not — `escapedPattern(for:)` neutralises it, and the same is true of `\Q`/`\E`,
    /// thousands of stars, U+FFFF, unbalanced parens and a lone backslash. That makes
    /// the `catch` arm below the throw a branch with no known input, which is why it
    /// is left uncovered rather than forced.
    ///
    /// This test does NOT pin a defect. Deleting the guard is already caught loudly by
    /// four pre-existing tests (`SearchExecutorEdgeCasesTests.testInvalidFileGlob_*`,
    /// `ToolsFileSystemTests.testListFiles_invalidNameGlob_returnsError`,
    /// `FilenameMatcherTests.testGlobValidate_uncompilable_throwsTypedInvalidFileGlob`).
    /// What it pins is the FACT the corrected comment now asserts — so if a future
    /// Foundation does start rejecting the sentinel, the comment gets a red test
    /// instead of quietly becoming wrong a second time.
    ///
    /// RED: none against production. This is a toolchain characterization; it reds only
    /// if `NSRegularExpression` changes behaviour or the DEBUG guard is deleted.
    func testUncompilableSentinel_isRejectedByTheExplicitGuardNotByTheRegexEngine() throws {
        let sentinel = CompiledGlob._testUncompilableGlobSentinel

        XCTAssertThrowsError(try CompiledGlob(glob: sentinel, caseInsensitive: false)) { error in
            guard let err = error as? SearchExecutorError,
                  case .invalidFileGlob(let pattern, _) = err else {
                return XCTFail("expected .invalidFileGlob, got \(error)")
            }
            XCTAssertEqual(pattern, sentinel)
        }

        // The load-bearing half: the regex engine itself is perfectly happy with
        // the sentinel, so the guard is the only thing standing between the test
        // suite and a silently-passing no-op glob.
        let escaped = NSRegularExpression.escapedPattern(for: sentinel)
        let pattern = escaped.replacingOccurrences(of: "\\*", with: ".*")
        XCTAssertNoThrow(try NSRegularExpression(pattern: "^\(pattern)$", options: []),
                         "if this ever starts throwing, the sentinel's rejection has a second "
                         + "source and the doc comment can be relaxed again")
    }

    /// A well-formed glob still compiles and still discriminates — otherwise the
    /// test above would pass against a `CompiledGlob` that rejects everything.
    func testCompiledGlob_ordinaryPattern_matchesByExtensionOnly() throws {
        let glob = try CompiledGlob(glob: "*.swift", caseInsensitive: false)
        XCTAssertTrue(glob.matches("Alpha.swift"))
        XCTAssertFalse(glob.matches("Alpha.swiftdoc"))
        XCTAssertFalse(glob.matches("Alpha.txt"))
    }
}

// ============================================================================
// MARK: - AgentInstructionsSnapshot.Item identity
// ============================================================================

final class ESearchAgentInstructionsTailTests: XCTestCase, @unchecked Sendable {

    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esearch-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func write(_ relPath: String, _ content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    /// `Item.id` is the ForEach identity for the Settings grid, and it must be
    /// the RELATIVE PATH — the one property that is unique per item by
    /// construction (the scan dedups on exactly it).
    ///
    /// Two instruction files sharing a basename in different directories is the
    /// ordinary shape of a monorepo, and a duplicate `ForEach` id there is
    /// undefined behaviour in SwiftUI, not a cosmetic issue — CLAUDE.md records
    /// the crash this exact scanner produced before it deduped.
    ///
    /// RED: return `lastPathComponent` (or the source, or a constant) from `id` →
    /// the uniqueness assertion fails on this fixture.
    func testItemID_isTheRelativePath_soNestedNamesakesStayDistinct() throws {
        try write("service-a/AGENTS.md", "Rules for service A")
        try write("service-b/AGENTS.md", "Rules for service B")

        let snapshot = AgentInstructionsScanner.scan(
            workFolderRoot: tempDir, fileManager: .default)

        XCTAssertEqual(snapshot.items.count, 2,
                       "arrange: both namesakes must be discovered — got "
                       + "\(snapshot.items.map(\.relativePath))")
        for item in snapshot.items {
            XCTAssertEqual(item.id, item.relativePath,
                           "the grid's identity must be the path, not the file name")
        }
        XCTAssertEqual(Set(snapshot.items.map(\.id)).count, snapshot.items.count,
                       "duplicate ids are undefined behaviour in a SwiftUI ForEach: "
                       + "\(snapshot.items.map(\.id))")
    }
}
