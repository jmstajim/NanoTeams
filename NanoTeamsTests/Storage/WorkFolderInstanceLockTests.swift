import Darwin
import XCTest
@testable import NanoTeams

/// `WorkFolderInstanceLock` (F6 C1, 2026-11-12). A second descriptor in this process conflicts
/// with the first exactly as another process would — `flock` belongs to the open file description —
/// so a second `acquire` here stands for a second NanoTeams.
final class WorkFolderInstanceLockTests: XCTestCase {

    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("instance-lock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        super.tearDown()
    }

    func testSecondHolder_isRefusedNamingTheFirst() throws {
        let since = Date(timeIntervalSince1970: 1_762_560_400)
        let first = try WorkFolderInstanceLock.acquire(workFolderRoot: folder, processID: 4242, now: since)
        defer { first.release() }

        XCTAssertThrowsError(try WorkFolderInstanceLock.acquire(workFolderRoot: folder)) { error in
            guard case .heldByAnotherProcess(let holder) = error as? WorkFolderInstanceLock.AcquireError else {
                return XCTFail("expected heldByAnotherProcess, got \(error)")
            }
            XCTAssertEqual(holder.pid, 4242)
            XCTAssertEqual(holder.since, since)
            XCTAssertTrue(error.localizedDescription.contains("PID 4242"), error.localizedDescription)
        }
    }

    func testAfterRelease_theNextHolderSucceeds() throws {
        let first = try WorkFolderInstanceLock.acquire(workFolderRoot: folder)
        first.release()
        XCTAssertFalse(first.isHeld)
        first.release() // idempotent

        let second = try WorkFolderInstanceLock.acquire(workFolderRoot: folder, processID: 7)
        XCTAssertTrue(second.isHeld)
        second.release()
    }

    /// A holder that died: its descriptor closed without `release()` — what the kernel does to a
    /// process that crashed or was killed. The lock went with it.
    func testADeadHoldersLock_doesNotBlock() throws {
        let paths = NTMSPaths(workFolderRoot: folder)
        try WorkFolderInstanceLock.acquire(workFolderRoot: folder).release()
        let fd = open(paths.instanceLockFile.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "anti-vacuum: the stand-in for the dead process holds it")
        close(fd)

        let next = try WorkFolderInstanceLock.acquire(workFolderRoot: folder, processID: 11)
        defer { next.release() }
        XCTAssertTrue(next.isHeld)
    }

    /// Dropping the object without `release()` — the orchestrator going away — lets the folder go.
    func testDeinit_releases() throws {
        var first: WorkFolderInstanceLock? = try WorkFolderInstanceLock.acquire(workFolderRoot: folder)
        XCTAssertNotNil(first)
        first = nil
        let second = try WorkFolderInstanceLock.acquire(workFolderRoot: folder)
        second.release()
    }

    /// The first open of a folder: `.nanoteams/internal/` does not exist yet, and is created
    /// owner-only, as the repository's layout makes it.
    func testFreshFolder_createsTheInternalDirectoryOwnerOnly() throws {
        let lock = try WorkFolderInstanceLock.acquire(workFolderRoot: folder)
        defer { lock.release() }
        let internalDir = NTMSPaths(workFolderRoot: folder).internalDir
        let permissions = try FileManager.default.attributesOfItem(atPath: internalDir.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
        XCTAssertEqual(lock.fileURL, NTMSPaths(workFolderRoot: folder).instanceLockFile)
    }

    /// The record names the CURRENT holder, never a previous one's leftovers.
    func testRecordIsRewrittenByEachHolder() throws {
        try WorkFolderInstanceLock.acquire(workFolderRoot: folder, processID: 999_999).release()
        let second = try WorkFolderInstanceLock.acquire(workFolderRoot: folder, processID: 12)
        defer { second.release() }
        XCTAssertThrowsError(try WorkFolderInstanceLock.acquire(workFolderRoot: folder)) { error in
            guard case .heldByAnotherProcess(let holder) = error as? WorkFolderInstanceLock.AcquireError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(holder.pid, 12)
        }
    }

    /// An unreadable record still refuses — the holder is what matters, the text only names it.
    func testUnreadableRecord_stillRefusesWithoutAPID() throws {
        let lockFile = NTMSPaths(workFolderRoot: folder).instanceLockFile
        let first = try WorkFolderInstanceLock.acquire(workFolderRoot: folder)
        defer { first.release() }
        try Data("not json".utf8).write(to: lockFile)

        XCTAssertThrowsError(try WorkFolderInstanceLock.acquire(workFolderRoot: folder)) { error in
            XCTAssertEqual(error as? WorkFolderInstanceLock.AcquireError, .heldByAnotherProcess(.init()))
            XCTAssertFalse(error.localizedDescription.contains("PID"))
        }
    }

    /// A symlink at the lock's path is not followed: nothing elsewhere gets truncated.
    func testSymlinkAtTheLockPath_isRefusedNotFollowed() throws {
        let paths = NTMSPaths(workFolderRoot: folder)
        try FileManager.default.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        let victim = folder.appendingPathComponent("victim.txt")
        try Data("keep me".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: paths.instanceLockFile, withDestinationURL: victim)

        XCTAssertThrowsError(try WorkFolderInstanceLock.acquire(workFolderRoot: folder)) { error in
            guard case .unavailable = error as? WorkFolderInstanceLock.AcquireError else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep me")
    }

    // MARK: - The folder must exist (D-M18 R4)

    /// A folder deleted or moved while NanoTeams ran is not brought back by its lock: no root, no
    /// `.nanoteams/`, and the open hears the folder is not accessible.
    func testMissingFolder_isNotCreated() throws {
        let gone = folder.appendingPathComponent("deleted-project", isDirectory: true)
        for acquire in [
            { try WorkFolderInstanceLock.acquire(workFolderRoot: gone) },
            { try WorkFolderInstanceLocking.system.acquire(gone) },
            { try WorkFolderInstanceLocking.isolatingDefaultStorage().acquire(gone) },
        ] as [() throws -> WorkFolderInstanceLock] {
            XCTAssertThrowsError(try acquire()) { error in
                guard case .invalidProjectFolder(let url) = error as? NTMSRepositoryError else {
                    return XCTFail("expected invalidProjectFolder, got \(error)")
                }
                XCTAssertEqual(url, gone)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), "the folder is not recreated")
        }
    }

    /// A file where the folder was is not a folder.
    func testAFileAtTheFoldersPath_isRefused() throws {
        let file = folder.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try WorkFolderInstanceLock.acquire(workFolderRoot: file)) {
            guard case .invalidProjectFolder = $0 as? NTMSRepositoryError else { return XCTFail("\($0)") }
        }
    }

    // MARK: - A volume without advisory locks (D-M18 R6)

    /// `flock` answering that the file system has no advisory locks opens the folder unlocked:
    /// held by this object, keeping nobody out, writing no record. Any other failure still refuses.
    func testVolumeWithoutAdvisoryLocks_opensWithoutExcludingOthers() throws {
        for code in [ENOTSUP, EOPNOTSUPP, ENOLCK] {
            let lock = try WorkFolderInstanceLock.acquire(
                workFolderRoot: folder, processID: 51, lockOperation: { _, _ in code })
            XCTAssertTrue(lock.isHeld, "errno \(code)")
            XCTAssertFalse(lock.excludesOtherProcesses, "errno \(code)")
            XCTAssertEqual(try Data(contentsOf: lock.fileURL), Data(), "no holder record — errno \(code)")
            lock.release()
        }
        XCTAssertThrowsError(try WorkFolderInstanceLock.acquire(
            workFolderRoot: folder, lockOperation: { _, _ in EIO })) {
            guard case .unavailable = $0 as? WorkFolderInstanceLock.AcquireError else { return XCTFail("\($0)") }
        }
        let real = try WorkFolderInstanceLock.acquire(workFolderRoot: folder)
        defer { real.release() }
        XCTAssertTrue(real.excludesOtherProcesses, "a volume with locks")
    }

    /// The gate agrees with the opener: on such a volume it cannot tell a holder, and passes.
    func testGate_onAVolumeWithoutAdvisoryLocks_passes() throws {
        try WorkFolderInstanceLock.acquire(workFolderRoot: folder).release()
        let locking = WorkFolderInstanceLocking(
            lockFile: { NTMSPaths(workFolderRoot: $0).instanceLockFile }, lockOperation: { _, _ in ENOTSUP })
        XCTAssertNoThrow(try locking.refuseIfHeldByAnotherProcess(folder))
    }

    // MARK: - Whether the hold is still on the file at its path

    func testLocksTheFileAtItsPath_untilTheFileIsDeletedOrReplaced() throws {
        let lock = try WorkFolderInstanceLock.acquire(workFolderRoot: folder)
        defer { lock.release() }
        XCTAssertTrue(lock.locksTheFileAtItsPath)

        try FileManager.default.removeItem(at: lock.fileURL)
        XCTAssertFalse(lock.locksTheFileAtItsPath, "deleted under it")
        try Data().write(to: lock.fileURL)
        XCTAssertFalse(lock.locksTheFileAtItsPath, "replaced by another file")
        lock.release()
        XCTAssertFalse(lock.locksTheFileAtItsPath, "released")
    }

    // MARK: - The write gate

    func testGate_noLockFile_passes() throws {
        XCTAssertNoThrow(try WorkFolderInstanceLocking.system.refuseIfHeldByAnotherProcess(folder))
    }

    func testGate_aLockThisProcessHolds_passes() throws {
        let lock = try WorkFolderInstanceLock.acquire(workFolderRoot: folder)
        defer { lock.release() }
        XCTAssertNoThrow(try WorkFolderInstanceLocking.system.refuseIfHeldByAnotherProcess(folder))
    }

    /// Another process's descriptor — a raw `flock`, not a lock this process registered — is refused,
    /// naming it; once it closes the gate passes, and the probe left nothing that blocks a holder.
    func testGate_aLockAnotherProcessHolds_isRefused_untilItGoes() throws {
        try WorkFolderInstanceLock.acquire(workFolderRoot: folder, processID: 31).release()
        let fd = open(NTMSPaths(workFolderRoot: folder).instanceLockFile.path, O_RDWR)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        XCTAssertThrowsError(try WorkFolderInstanceLocking.system.refuseIfHeldByAnotherProcess(folder)) { error in
            guard case .heldByAnotherProcess(let holder) = error as? WorkFolderInstanceLock.AcquireError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(holder.pid, 31, "the record the last holder wrote")
        }
        close(fd)

        XCTAssertNoThrow(try WorkFolderInstanceLocking.system.refuseIfHeldByAnotherProcess(folder))
        let next = try WorkFolderInstanceLock.acquire(workFolderRoot: folder)
        next.release()
    }

    /// The isolating variant keeps default storage on a private file and every other folder on its own.
    func testIsolatingVariant_movesOnlyDefaultStorage() {
        let isolated = WorkFolderInstanceLocking.isolatingDefaultStorage()
        XCTAssertEqual(isolated.lockFile(folder), NTMSPaths(workFolderRoot: folder).instanceLockFile)
        XCTAssertNotEqual(isolated.lockFile(NTMSPaths.defaultStorageURL),
                          NTMSPaths(workFolderRoot: NTMSPaths.defaultStorageURL).instanceLockFile)
        XCTAssertNotEqual(isolated.lockFile(NTMSPaths.defaultStorageURL),
                          WorkFolderInstanceLocking.isolatingDefaultStorage().lockFile(NTMSPaths.defaultStorageURL),
                          "each factory call is its own")
    }
}
