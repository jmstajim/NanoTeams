import XCTest

@testable import NanoTeams

/// Refusal tally, held separately from the `FileManager` subclass because
/// `SearchIndexService.init` takes its file manager as a `sending` parameter — the double
/// itself cannot be read back after being handed over.
private final class RefusalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func bump() { lock.withLock { _count += 1 } }
}

/// Adds a PHANTOM entry to every directory listing — a file the walk is told exists and then
/// cannot characterise.
///
/// It used to refuse `attributesOfItem(atPath:)` instead, and that seam is gone: the walk now
/// reads mTime and size from the resource values `contentsOfDirectory(at:)` prefetched, because
/// one `attributesOfItem` per file ran on EVERY `loadOrBuild` — cache hits included — to hand
/// back two of the dictionary's values.
///
/// So the double moved to the seam production actually has (CLAUDE.md #126: a fixture must
/// describe a shape production can create). A phantom URL is that shape: the directory read
/// returns it, and every later question about it fails, which is what an entry deleted between
/// the read and the visit looks like.
private final class PhantomEntryFileManager: FileManager {
    private let phantomName: String
    private let counter: RefusalCounter

    init(phantom name: String, counter: RefusalCounter) {
        self.phantomName = name
        self.counter = counter
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        var entries = try super.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: mask)
        // One directory only — the root — so the phantom cannot be reported twice.
        if entries.contains(where: { $0.lastPathComponent == "readable.txt" }) {
            counter.bump()
            entries.append(url.appendingPathComponent(phantomName))
        }
        return entries
    }
}

/// The failure arms of `SearchIndexService` that report *why* the index is unusable.
///
/// The distinction they draw is the whole point of `lastLoadError`: "no index yet" is the
/// first-launch case and silent, while "there is an index and I cannot read it" is a
/// condition the user has to be told about, because search keeps returning nothing and
/// looks merely empty. Both were uncovered, so nothing had checked the service tells them
/// apart.
///
/// Inducement is measured rather than assumed. `search_index.json` is created as a
/// DIRECTORY: `fileExists(atPath:)` returns true for it while `Data(contentsOf:)` throws
/// (verified on APFS/macOS 26, NSError 256), which is exactly the shape the `do/catch` is
/// written against, and it needs no permission games that would also break the surrounding
/// writes.
///
/// Two further arms — the persist failure and the walk's attribute-read failure — were
/// previously covered only BY ACCIDENT by this file, appearing and disappearing between
/// coverage runs depending on whether a rebuild happened to persist during an unrelated
/// test. They are now driven on purpose: a coverage number that oscillates is one nobody
/// trusts, and both arms carry real contracts (a permanently unwritable index must be
/// reported; an unstattable file must be SKIPPED rather than stored with a `.distantPast`
/// mTime that poisons the signature into rebuilding forever).
final class SearchIndexFailureCoverageTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var internalDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("searchidx-\(UUID().uuidString)", isDirectory: true)
        internalDir = tempDir.appendingPathComponent("internal", isDirectory: true)
        try FileManager.default.createDirectory(at: internalDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        try super.tearDownWithError()
    }

    private func makeService() -> SearchIndexService {
        SearchIndexService(workFolderRoot: tempDir, internalDir: internalDir, fileManager: .default)
    }

    /// A missing index is NOT an error — it is what every first launch looks like. If this arm
    /// ever started reporting, the Exploratory Search settings pane would show a permanent
    /// failure on a healthy folder.
    ///
    /// RED: set `lastLoadError` in the `!fileExists` branch → this fails.
    func testMissingIndexFile_reportsNoError() async {
        let service = makeService()
        _ = await service.files(containing: ["anything"])
        let error = await service.lastLoadError
        XCTAssertNil(error, "a missing index is the first-launch case and must stay silent")
    }

    /// An index that exists and cannot be read must SAY so, naming the file. Without it, search
    /// returns nothing and is indistinguishable from an empty project.
    ///
    /// RED: drop the `lastLoadError = ...` assignment in the `Data(contentsOf:)` catch → this
    /// fails, and an unreadable index becomes silent emptiness.
    func testUnreadableIndexFile_reportsWhichFileAndWhy() async throws {
        // A directory at the index path: fileExists() is true, Data(contentsOf:) throws.
        let indexPath = internalDir.appendingPathComponent("search_index.json", isDirectory: true)
        try FileManager.default.createDirectory(at: indexPath, withIntermediateDirectories: true)

        let service = makeService()
        let hits = await service.files(containing: ["anything"])
        XCTAssertTrue(hits.isEmpty, "an unreadable index yields no results")

        let error = await service.lastLoadError
        XCTAssertNotNil(error, "an index that exists but cannot be read must be reported, or "
            + "search looks merely empty")
        XCTAssertTrue(error?.contains("search_index.json") == true,
                      "the message must name the file so it can be deleted: \(error ?? "nil")")
        XCTAssertTrue(error?.localizedCaseInsensitiveContains("unreadable") == true,
                      "'unreadable' distinguishes an I/O failure from 'corrupt' (a decode failure) "
                          + "and 'version mismatch' — three different remedies: \(error ?? "nil")")
    }

    /// A corrupt-but-readable index takes a DIFFERENT arm with a different word, and conflating
    /// the two would send the user looking for a permissions problem they do not have.
    ///
    /// RED: make both arms produce the same string → the distinctness assertion fails.
    func testCorruptIndexFile_isReportedDifferentlyFromAnUnreadableOne() async throws {
        let indexPath = internalDir.appendingPathComponent("search_index.json")
        try Data("{ not json at all".utf8).write(to: indexPath)

        let service = makeService()
        _ = await service.files(containing: ["anything"])
        let corruptError = await service.lastLoadError

        XCTAssertNotNil(corruptError)
        XCTAssertTrue(corruptError?.localizedCaseInsensitiveContains("corrupt") == true,
                      "a decode failure is 'corrupt', not 'unreadable': \(corruptError ?? "nil")")
        XCTAssertFalse(corruptError?.localizedCaseInsensitiveContains("unreadable") == true,
                       "the two failure modes need different words — they have different remedies")
    }

    // MARK: - Persist failure

    /// The index is best-effort on disk: a write failure must not break search (the
    /// in-memory cache still serves) but must be REPORTED, because the alternative is an
    /// index that silently rebuilds from scratch on every launch — slow, and invisible.
    ///
    /// Induced with the same directory-at-the-index-path trick as the read failures above,
    /// which makes `Data.write(to:options:.atomic)` fail deterministically.
    ///
    /// This arm was previously reached only as a side effect of the read-failure tests,
    /// depending on whether a rebuild happened to persist during them — so it appeared and
    /// disappeared between coverage runs. A coverage number that oscillates is a coverage
    /// number nobody trusts, which is reason enough to drive it on purpose.
    ///
    /// RED: drop the `lastPersistError = error.localizedDescription` assignment → this fails
    /// and a permanently unwritable index becomes silent.
    func testPersistFailure_isReportedAndSearchStillWorks() async throws {
        // Something to index, so the rebuild has content worth persisting.
        try Data("alpha beta gamma".utf8)
            .write(to: tempDir.appendingPathComponent("notes.txt"))
        // A directory where the index file belongs: the write cannot succeed.
        let indexPath = internalDir.appendingPathComponent("search_index.json", isDirectory: true)
        try FileManager.default.createDirectory(at: indexPath, withIntermediateDirectories: true)

        let service = makeService()
        _ = await service.loadOrBuild(force: true)

        let persistError = await service.lastPersistError
        XCTAssertNotNil(persistError,
                        "an index that cannot be written must be reported — otherwise every "
                            + "launch silently pays a full rebuild")

        // …and the in-memory index still answers, which is why this is a warning and not
        // a failure.
        // Exact token, not a prefix: `files(containing:)` is a posting lookup, unlike
        // the retired `vocabulary(matching:)` ranker this used to call.
        let hits = await service.files(containing: ["alpha"])
        XCTAssertFalse(hits.isEmpty,
                       "search must keep working off the in-memory cache: \(hits)")
    }

    /// A successful persist must CLEAR a previous error, or one transient failure leaves the
    /// warning on screen for the rest of the session.
    ///
    /// RED: delete the `lastPersistError = nil` on the success path → this fails.
    func testPersistSuccess_clearsAPreviousError() async throws {
        try Data("alpha beta".utf8).write(to: tempDir.appendingPathComponent("notes.txt"))
        let indexPath = internalDir.appendingPathComponent("search_index.json", isDirectory: true)
        try FileManager.default.createDirectory(at: indexPath, withIntermediateDirectories: true)

        let service = makeService()
        _ = await service.loadOrBuild(force: true)
        let firstError = await service.lastPersistError
        XCTAssertNotNil(firstError, "arrange: the write failed")

        // Clear the obstruction and rebuild.
        try FileManager.default.removeItem(at: indexPath)
        _ = await service.loadOrBuild(force: true)

        let recovered = await service.lastPersistError
        XCTAssertNil(recovered,
                     "a recovered write must clear the warning, or it is permanent")
    }

    // MARK: - Attribute-read failure during the walk

    /// A file the walk is told exists but cannot characterise contributes NOTHING — not a
    /// filename-token entry with a `.distantPast` mTime and size 0.
    ///
    /// The reason is the signature, not tidiness: `IndexSignature` is (fileCount, maxMTime,
    /// totalSize), so a placeholder entry makes the count disagree with the next walk's forever
    /// and the whole index rebuilds on every `loadOrBuild` for the life of the folder.
    ///
    /// The phantom is the reachable shape for this: an entry that was in the directory read and
    /// is not there when the walk asks about it — which is what a file deleted mid-walk looks
    /// like. It is also the only shape a test can arrange, now that the attributes come from the
    /// enumerator's prefetch rather than a `FileManager` call a double could refuse.
    ///
    /// RED: drop the `guard let attributes … else { continue }` and default the missing values →
    /// `phantom.txt` appears in the roster and the count assertion fails.
    func testPhantomEntry_contributesNothingToTheIndex() async throws {
        try Data("alpha beta".utf8).write(to: tempDir.appendingPathComponent("readable.txt"))

        let counter = RefusalCounter()
        let service = SearchIndexService(
            workFolderRoot: tempDir, internalDir: internalDir,
            fileManager: PhantomEntryFileManager(phantom: "phantom.txt", counter: counter))

        let index = await service.loadOrBuild(force: true)

        // The healthy file's vocabulary is present…
        let readable = await service.files(containing: ["alpha"])
        XCTAssertFalse(readable.isEmpty, "the healthy file must still be indexed")

        // …and the phantom contributed neither a roster entry nor its filename tokens.
        XCTAssertFalse(index.files.contains { $0.path == "phantom.txt" },
                       "an entry that cannot be characterised must not reach the roster: "
                           + "\(index.files.map(\.path))")
        let phantomTokens = await service.files(containing: ["phantom"])
        XCTAssertTrue(phantomTokens.isEmpty, "not even its filename tokens may be indexed")
        XCTAssertEqual(index.signature.fileCount, 1,
                       "the signature must count only files the walk could actually read")
        let warnings = await service.lastIndexWarnings
        XCTAssertTrue(warnings.contains { $0.contains("phantom.txt") },
                      "skipping is right, but a walk that quietly drops entries is "
                          + "indistinguishable from a small tree — got: \(warnings)")
        XCTAssertGreaterThan(counter.count, 0,
                             "arrange: the phantom was never injected, so this test proves "
                                 + "nothing")
    }

    /// `files(containing:)` shares the same load path, so it must surface the same diagnosis
    /// rather than silently returning nothing on its own.
    func testFilesContaining_sharesTheLoadDiagnosis() async throws {
        let indexPath = internalDir.appendingPathComponent("search_index.json", isDirectory: true)
        try FileManager.default.createDirectory(at: indexPath, withIntermediateDirectories: true)

        let service = makeService()
        let files = await service.files(containing: ["token"])
        XCTAssertTrue(files.isEmpty)
        let error = await service.lastLoadError
        XCTAssertNotNil(error, "both query entry points go through loadFromDisk and must report it")
    }
}
