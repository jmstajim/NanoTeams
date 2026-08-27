import XCTest

@testable import NanoTeams

/// The disk cache that turned skill DISCOVERY from something three surfaces did on
/// every interaction into something the user asks for.
///
/// Every test injects an isolated home directory, so nothing here depends on which
/// skills the developer happens to have installed, and its own temp directory, so
/// nothing here writes over the real
/// `~/Library/Application Support/NanoTeams/skills/`.
final class AgentSkillsCatalogueStoreTests: XCTestCase {

    private var tempDir: URL!
    private var storeDir: URL!
    private var home: URL!
    private var sut: AgentSkillsCatalogueStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-cat-\(UUID().uuidString)", isDirectory: true)
        storeDir = tempDir.appendingPathComponent("store", isDirectory: true)
        home = tempDir.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sut = AgentSkillsCatalogueStore(directory: storeDir)
    }

    override func tearDown() {
        sut = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil; storeDir = nil; home = nil
        super.tearDown()
    }

    /// Writes a project skill under `root` and returns its directory name.
    @discardableResult
    private func writeSkill(_ name: String, in root: URL, body: String = "body") throws -> String {
        let dir = root.appendingPathComponent(".claude/skills/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return name
    }

    private func project(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rescan(_ root: URL?, now: Date = Date()) -> AgentSkillsCatalogue {
        sut.rescan(projectRoot: root, homeDirectory: home, now: now)
    }

    // MARK: - Round trip

    func testRescan_thenLoad_returnsWhatWasScanned() throws {
        let root = try project("p1")
        try writeSkill("alpha", in: root)

        let written = rescan(root)
        let read = sut.load(projectRoot: root)

        XCTAssertEqual(read, written, "A load must return exactly the catalogue that was taken")
        XCTAssertTrue(written.items.contains { $0.name == "alpha" })
    }

    func testLoad_withNothingEverScanned_isNil() throws {
        let root = try project("p1")
        XCTAssertNil(sut.load(projectRoot: root))
    }

    /// The point of the cache: the second consumer does not pay for a walk.
    func testLoadOrScan_secondCall_reusesTheFirstScan() throws {
        let root = try project("p1")
        try writeSkill("alpha", in: root)
        let first = sut.loadOrScan(projectRoot: root, homeDirectory: home)

        // A skill installed AFTER the catalogue was taken is deliberately invisible
        // until someone asks for a rescan — that is the staleness the Refresh
        // control exists to resolve.
        try writeSkill("beta", in: root)
        let second = sut.loadOrScan(projectRoot: root, homeDirectory: home)

        XCTAssertEqual(second.scannedAt, first.scannedAt, "The second call must not re-walk")
        XCTAssertFalse(second.items.contains { $0.name == "beta" })
    }

    func testRescan_picksUpASkillInstalledSinceTheCacheWasTaken() throws {
        let root = try project("p1")
        try writeSkill("alpha", in: root)
        _ = sut.loadOrScan(projectRoot: root, homeDirectory: home)

        try writeSkill("beta", in: root)
        let rescanned = rescan(root)

        XCTAssertTrue(rescanned.items.contains { $0.name == "beta" },
                      "Refresh is the verb that pays for a walk")
        XCTAssertTrue(sut.load(projectRoot: root)?.items.contains { $0.name == "beta" } ?? false,
                      "…and it persists, so the next launch starts from it")
    }

    // MARK: - Per-root identity

    /// One install opens many folders, and a catalogue taken for folder A says
    /// nothing about folder B's project skills.
    func testRoots_areCachedIndependently() throws {
        let a = try project("a"), b = try project("b")
        try writeSkill("only-in-a", in: a)
        try writeSkill("only-in-b", in: b)

        _ = rescan(a)
        _ = rescan(b)

        XCTAssertTrue(sut.load(projectRoot: a)?.items.contains { $0.name == "only-in-a" } ?? false)
        XCTAssertFalse(sut.load(projectRoot: a)?.items.contains { $0.name == "only-in-b" } ?? true)
        XCTAssertTrue(sut.load(projectRoot: b)?.items.contains { $0.name == "only-in-b" } ?? false)
    }

    /// Default storage (no work folder) is a real root, not a missing one — the app
    /// boots into it and global skills are available there.
    func testDefaultStorage_hasItsOwnEntry() throws {
        let root = try project("p1")
        try writeSkill("proj", in: root)
        _ = rescan(root)

        _ = rescan(nil)

        XCTAssertNotNil(sut.load(projectRoot: nil))
        XCTAssertFalse(sut.load(projectRoot: nil)?.items.contains { $0.name == "proj" } ?? true,
                       "No work folder → no project skills")
        XCTAssertTrue(sut.load(projectRoot: root)?.items.contains { $0.name == "proj" } ?? false,
                      "…and taking one must not evict the other")
    }

    func testRoot_isKeyedByStandardizedPath() throws {
        let root = try project("p1")
        try writeSkill("alpha", in: root)
        _ = rescan(root)

        let trailingSlash = URL(fileURLWithPath: root.path + "/")
        XCTAssertNotNil(sut.load(projectRoot: trailingSlash),
                        "`/a/b` and `/a/b/` are the same folder")
    }

    func testRescan_replacesTheEntryForItsOwnRootOnly() throws {
        let a = try project("a"), b = try project("b")
        try writeSkill("first", in: a)
        _ = rescan(b)
        _ = rescan(a)
        let bBefore = sut.load(projectRoot: b)

        try writeSkill("second", in: a)
        _ = rescan(a)

        let aAfter = sut.load(projectRoot: a)
        XCTAssertEqual(aAfter?.items.filter { $0.name == "first" }.count, 1,
                       "Replaced, not appended")
        XCTAssertTrue(aAfter?.items.contains { $0.name == "second" } ?? false)
        XCTAssertEqual(sut.load(projectRoot: b), bBefore, "…and b is untouched")
    }

    // MARK: - Bound

    func testCache_keepsOnlyTheNewestRoots() throws {
        let overflow = AgentSkillsCatalogueStore.maxCachedRoots + 3
        var roots: [URL] = []
        for i in 0..<overflow {
            let root = try project("r\(i)")
            roots.append(root)
            // Ascending stamps so "newest" is unambiguous — `Date()` twice in a
            // tight loop can return the same instant.
            _ = rescan(root, now: Date(timeIntervalSince1970: Double(1000 + i)))
        }

        for root in roots.suffix(AgentSkillsCatalogueStore.maxCachedRoots) {
            XCTAssertNotNil(sut.load(projectRoot: root), "The newest roots stay cached")
        }
        for root in roots.prefix(overflow - AgentSkillsCatalogueStore.maxCachedRoots) {
            XCTAssertNil(sut.load(projectRoot: root), "The oldest fall out of the bound")
        }
    }

    // MARK: - Corner cases

    /// A corrupt cache is a cache MISS, never an error the caller has to handle:
    /// the consequence of getting this wrong is a picker that shows an error
    /// instead of the skills it could trivially re-derive.
    func testCorruptFile_readsAsAMissAndHealsOnTheNextWrite() throws {
        let root = try project("p1")
        try writeSkill("alpha", in: root)
        _ = rescan(root)

        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: sut.fileURL)

        XCTAssertNil(sut.load(projectRoot: root), "Unreadable cache → miss")
        let healed = sut.loadOrScan(projectRoot: root, homeDirectory: home)
        XCTAssertTrue(healed.items.contains { $0.name == "alpha" })
        XCTAssertNotNil(sut.load(projectRoot: root), "…and the file is usable again")
    }

    func testEmptyFile_readsAsAMiss() throws {
        let root = try project("p1")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try Data().write(to: sut.fileURL)

        XCTAssertNil(sut.load(projectRoot: root))
    }

    /// A folder with no skills at all caches an EMPTY catalogue rather than
    /// nothing — otherwise "I looked and there are none" is indistinguishable from
    /// "I never looked", and every load would re-walk.
    func testFolderWithNoSkills_stillCachesAnAnswer() throws {
        let root = try project("bare")

        let scanned = rescan(root)

        XCTAssertTrue(scanned.items.isEmpty)
        XCTAssertNotNil(sut.load(projectRoot: root),
                        "An empty answer is still an answer, and must not re-walk")
    }

    func testMissingDirectory_isCreatedOnFirstWrite() throws {
        let root = try project("p1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDir.path))

        _ = rescan(root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sut.fileURL.path))
    }
}
