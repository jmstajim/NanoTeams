import Darwin
import XCTest
@testable import NanoTeams

/// `WorkFolderHold` and the repository that asks it (`HeldWorkFolderRepository`, D-M18 R2,
/// 2026-11-12): an orchestrator writes only into the folder it holds — whoever else does or does
/// not hold the others.
final class WorkFolderHoldTests: XCTestCase {

    private var root: URL!
    private var folder: URL!
    private var other: URL!
    private var otherProcessFD: Int32 = -1

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hold-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("held", isDirectory: true)
        other = root.appendingPathComponent("other", isDirectory: true)
        for url in [folder!, other!] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        if otherProcessFD >= 0 { close(otherProcessFD) }
        otherProcessFD = -1
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    // MARK: - The hold

    func testNothingHeld_refusesEveryFolder_asNotHeld() {
        let hold = WorkFolderHold(locking: .system)
        XCTAssertFalse(hold.holds(folder))
        XCTAssertNil(hold.lock(for: folder))
        XCTAssertThrowsError(try hold.authorizeWrite(into: folder)) {
            XCTAssertEqual($0 as? WorkFolderHold.Refusal, .notHeld(folder))
            XCTAssertTrue($0.localizedDescription.contains("isn't open in this NanoTeams"), $0.localizedDescription)
        }
    }

    func testHeldFolder_passes_andEveryOtherIsRefused() throws {
        let hold = WorkFolderHold(locking: .system)
        hold.hold(try WorkFolderInstanceLocking.system.acquire(folder), for: folder)
        defer { hold.release() }

        XCTAssertTrue(hold.holds(folder))
        XCTAssertTrue(hold.holds(URL(fileURLWithPath: folder.path + "/")), "the same folder spelled with a slash")
        XCTAssertNoThrow(try hold.authorizeWrite(into: folder))
        XCTAssertThrowsError(try hold.authorizeWrite(into: other)) {
            XCTAssertEqual($0 as? WorkFolderHold.Refusal, .notHeld(other))
        }
        XCTAssertNil(hold.lock(for: other))
        XCTAssertNotNil(hold.lock(for: folder))
    }

    /// A folder another process holds is refused naming that process, as its open was.
    func testFolderAnotherProcessHolds_isRefusedNamingIt() throws {
        let paths = NTMSPaths(workFolderRoot: other)
        try FileManager.default.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        otherProcessFD = open(paths.instanceLockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(otherProcessFD, LOCK_EX | LOCK_NB), 0)
        let record = Data(#"{"pid":808}"#.utf8)
        _ = record.withUnsafeBytes { pwrite(otherProcessFD, $0.baseAddress, record.count, 0) }

        let hold = WorkFolderHold(locking: .system)
        XCTAssertThrowsError(try hold.authorizeWrite(into: other)) {
            XCTAssertEqual($0 as? WorkFolderInstanceLock.AcquireError, .heldByAnotherProcess(.init(pid: 808)))
        }
    }

    /// Holding a new folder lets the previous one go — another process can take it at once — and a
    /// released hold holds nothing. Both idempotent.
    func testHoldingAnother_releasesThePrevious_andReleaseHoldsNothing() throws {
        let hold = WorkFolderHold(locking: .system)
        let first = try WorkFolderInstanceLocking.system.acquire(folder)
        hold.hold(first, for: folder)
        hold.hold(first, for: folder)
        XCTAssertTrue(first.isHeld, "holding the same lock again keeps it")

        hold.hold(try WorkFolderInstanceLocking.system.acquire(other), for: other)
        XCTAssertFalse(first.isHeld)
        XCTAssertFalse(hold.holds(folder))
        XCTAssertTrue(hold.holds(other))
        try WorkFolderInstanceLock.acquire(workFolderRoot: folder).release()

        hold.release()
        hold.release()
        XCTAssertFalse(hold.holds(other))
        XCTAssertNil(hold.lock(for: other))
        try WorkFolderInstanceLock.acquire(workFolderRoot: other).release()
    }

    /// A lock released behind the hold's back holds nothing either.
    func testALockReleasedElsewhere_isNotAHold() throws {
        let hold = WorkFolderHold(locking: .system)
        let lock = try WorkFolderInstanceLocking.system.acquire(folder)
        hold.hold(lock, for: folder)
        lock.release()
        XCTAssertFalse(hold.holds(folder))
        XCTAssertNil(hold.lock(for: folder))
        XCTAssertThrowsError(try hold.authorizeWrite(into: folder))
    }

    // MARK: - The repository that asks it

    /// Every write of the wrapped repository is refused for a folder not held, before it touches
    /// the disk; reads pass. Then, held, the same writes go through.
    func testHeldRepository_writesOnlyIntoTheFolderHeld() throws {
        let hold = WorkFolderHold(locking: .system)
        let repository = HeldWorkFolderRepository(inner: NTMSRepository(), hold: hold)
        let nanoteams = NTMSPaths(workFolderRoot: folder).nanoteamsDir

        let writes: [(String, () throws -> Void)] = [
            ("openOrCreateWorkFolder", { _ = try repository.openOrCreateWorkFolder(at: self.folder) }),
            ("updateWorkFolderState", { _ = try repository.updateWorkFolderState(at: self.folder, activeTask: nil) { _ in } }),
            ("updateSettings", { _ = try repository.updateSettings(at: self.folder, activeTask: nil) { _ in } }),
            ("updateTeams", { _ = try repository.updateTeams(at: self.folder, activeTask: nil) { _ in } }),
            ("removeWorkFolderData", { try repository.removeWorkFolderData(at: self.folder) }),
            ("resetWorkFolderSettings", { _ = try repository.resetWorkFolderSettings(at: self.folder) }),
            ("createTask", { _ = try repository.createTask(
                at: self.folder, title: "t", supervisorTask: "b", preferredTeamID: nil, parentTaskID: nil,
                parentRoleID: nil, delegationDepth: 0, makeActive: true, origin: nil, requestKey: nil) }),
            ("setActiveTask", { _ = try repository.setActiveTask(at: self.folder, taskID: nil) }),
            ("setActiveTaskID", { try repository.setActiveTaskID(at: self.folder, taskID: nil) }),
            ("deleteTask", { _ = try repository.deleteTask(at: self.folder, taskID: 1) }),
            ("updateTaskOnly", { try repository.updateTaskOnly(
                at: self.folder, task: NTMSTask(id: 1, title: "t", supervisorTask: "b")) }),
            ("updateTools", { _ = try repository.updateTools(at: self.folder, tools: []) }),
            ("persistStepArtifactFile", { _ = try repository.persistStepArtifactFile(
                at: self.folder, taskID: 1, runID: 0, roleID: "r", artifactName: "A", content: "c") }),
            ("persistStepArtifactBinary", { _ = try repository.persistStepArtifactBinary(
                at: self.folder, taskID: 1, runID: 0, roleID: "r", artifactName: "A", data: Data(), fileExtension: "bin") }),
            ("stageAttachment", { _ = try repository.stageAttachment(
                at: self.folder, draftID: UUID(), sourceURL: self.other) }),
            ("finalizeAttachments", { _ = try repository.finalizeAttachments(
                at: self.folder, taskID: 1, stagedEntries: []) }),
            ("finalizeAutovisorGoalAttachment", { _ = try repository.finalizeAutovisorGoalAttachment(
                at: self.folder, stagedRelativePath: "x") }),
            ("removeStagedItem", { try repository.removeStagedItem(at: self.folder, relativePath: "x") }),
            ("cleanupStagedDraft", { try repository.cleanupStagedDraft(at: self.folder, draftID: UUID()) }),
            ("cleanupAllStagedDrafts", { try repository.cleanupAllStagedDrafts(at: self.folder) }),
        ]
        for (name, write) in writes {
            XCTAssertThrowsError(try write(), name) {
                XCTAssertEqual($0 as? WorkFolderHold.Refusal, .notHeld(self.folder), name)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nanoteams.path), "nothing was written")
        XCTAssertThrowsError(try repository.loadTask(at: folder, taskID: 1)) {
            XCTAssertNil($0 as? WorkFolderHold.Refusal, "a read is not refused by the hold")
        }

        hold.hold(try WorkFolderInstanceLocking.system.acquire(folder), for: folder)
        defer { hold.release() }
        XCTAssertNoThrow(try repository.openOrCreateWorkFolder(at: folder))
        let created = try repository.createTask(
            at: folder, title: "t", supervisorTask: "b", preferredTeamID: nil, parentTaskID: nil,
            parentRoleID: nil, delegationDepth: 0, makeActive: true, origin: nil, requestKey: nil)
        XCTAssertEqual(try repository.loadTask(at: folder, taskID: created.taskID).title, "t")
        XCTAssertNoThrow(try repository.removeWorkFolderData(at: folder))
    }

    // MARK: - The reset keeps the lock file (D-M18 R7)

    /// `.nanoteams/` goes, everything in it, but the lock file the folder's lock is on: the lock
    /// still holds the file at its path, and another process is kept out throughout.
    func testRemoveWorkFolderData_keepsOnlyTheLockFile() throws {
        let repository = NTMSRepository()
        let lock = try WorkFolderInstanceLock.acquire(workFolderRoot: folder)
        defer { lock.release() }
        _ = try repository.openOrCreateWorkFolder(at: folder)
        _ = try repository.createTask(at: folder, title: "gone", supervisorTask: "b")
        let paths = NTMSPaths(workFolderRoot: folder)
        XCTAssertGreaterThan(try FileManager.default.contentsOfDirectory(atPath: paths.internalDir.path).count, 1)

        try repository.removeWorkFolderData(at: folder)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.nanoteamsDir.path), ["internal"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.internalDir.path), ["instance.lock"])
        XCTAssertTrue(lock.locksTheFileAtItsPath, "the lock is on the file still at its path")
        XCTAssertThrowsError(try WorkFolderInstanceLock.acquire(workFolderRoot: folder))

        let reopened = try repository.openOrCreateWorkFolder(at: folder)
        XCTAssertTrue(reopened.tasksIndex.tasks.isEmpty)
        XCTAssertTrue(lock.locksTheFileAtItsPath)
    }

    /// A lock file kept outside the tree — default storage under `isolatingDefaultStorage` — and a
    /// folder with no lock file at all: the tree goes whole. A folder with no `.nanoteams/` is
    /// already empty.
    func testRemoveWorkFolderData_withNoLockFileInTheTree_removesItWhole() throws {
        let repository = NTMSRepository()
        try repository.removeWorkFolderData(at: folder)
        _ = try repository.openOrCreateWorkFolder(at: folder)
        try repository.removeWorkFolderData(at: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: NTMSPaths(workFolderRoot: folder).nanoteamsDir.path))
    }
}
