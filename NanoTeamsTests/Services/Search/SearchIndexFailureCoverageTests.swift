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

/// Reports every file as existing but refuses to stat the named ones. `attributesOfItem`
/// is overridable on `FileManager`; `replaceItemAt` is not (it lives in an extension).
private final class AttributeRefusingFileManager: FileManager, @unchecked Sendable {
    private let refusedNames: Set<String>
    private let counter: RefusalCounter

    init(refusing names: Set<String>, counter: RefusalCounter) {
        self.refusedNames = names
        self.counter = counter
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if refusedNames.contains((path as NSString).lastPathComponent) {
            counter.bump()
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.attributesOfItem(atPath: path)
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
        _ = await service.vocabulary(matching: "anything", limit: 5)
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
        let vocabulary = await service.vocabulary(matching: "anything", limit: 5)
        XCTAssertTrue(vocabulary.isEmpty, "an unreadable index yields no results")

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
        _ = await service.vocabulary(matching: "anything", limit: 5)
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
        let vocabulary = await service.vocabulary(matching: "alph", limit: 5)
        XCTAssertFalse(vocabulary.isEmpty,
                       "search must keep working off the in-memory cache: \(vocabulary)")
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

    /// A file the walk can SEE but cannot stat is skipped entirely, and the reason is
    /// written down in the code: storing a `.distantPast` mTime and size 0 instead would
    /// silently poison the `IndexSignature`, so every later walk would believe the folder
    /// changed and rebuild the whole index forever.
    ///
    /// Needs an injected `FileManager`: the walk guards on `fileExists` first, and nothing
    /// real is visible-but-unstattable (a dangling symlink fails the guard, since
    /// `fileExists` follows links). `attributesOfItem` IS overridable, unlike
    /// `replaceItemAt` — CLAUDE.md records that asymmetry.
    ///
    /// RED: remove the `return` from the catch → the file is indexed with a poisoned
    /// signature and the skip assertion fails.
    func testAttributeReadFailure_skipsTheFileAndWarns() async throws {
        try Data("alpha beta".utf8).write(to: tempDir.appendingPathComponent("readable.txt"))
        try Data("gamma delta".utf8).write(to: tempDir.appendingPathComponent("unstattable.txt"))

        let counter = RefusalCounter()
        let service = SearchIndexService(
            workFolderRoot: tempDir, internalDir: internalDir,
            fileManager: AttributeRefusingFileManager(
                refusing: ["unstattable.txt"], counter: counter))

        _ = await service.loadOrBuild(force: true)

        // The stattable file's vocabulary is present…
        let readable = await service.vocabulary(matching: "alph", limit: 5)
        XCTAssertFalse(readable.isEmpty, "the healthy file must still be indexed")

        // …and the unstattable one contributed nothing, rather than a zero-size entry.
        let skipped = await service.files(containing: ["gamma"])
        XCTAssertTrue(skipped.isEmpty,
                      "a file whose attributes cannot be read must be skipped, not stored "
                      + "with a distantPast mTime that poisons the signature: \(skipped)")
        XCTAssertGreaterThan(counter.count, 0,
                             "arrange: the injected failure never fired, so this test proves "
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
