import Darwin
import Foundation

/// One NanoTeams process per work folder: an exclusive advisory `flock` on
/// `.nanoteams/internal/instance.lock`, held for as long as the folder is open in this process.
///
/// On 8 November two NanoTeams processes held the same folder for three and a half hours. The
/// auto-off timer of one wrote `autovisorEnabled = false` into `settings.json`; the other read the
/// file back on a task create and ran an agent's task as if a person were present (F6 C1). Nothing
/// in the folder's files is safe from that: each process keeps its own snapshot, its own timer, its
/// own scheduler, and writes what it holds. So the second process does not open the folder at all.
///
/// `flock`, not `fcntl` record locks and not a PID file: the kernel drops a `flock` the moment the
/// holding descriptor closes — `release()`, the object's `deinit`, or the process dying in any way —
/// so a lock left by a crashed or killed NanoTeams never blocks the next one, and there is no PID to
/// check for liveness. The lock belongs to the open file description, so even a second descriptor
/// in the SAME process conflicts (what the tests use to stand for a second process). The file is
/// never deleted: unlinking a lock file another process may be opening is the classic race that
/// lets two holders lock two different inodes.
///
/// The PID and the time inside are for the refusal's text only.
nonisolated final class WorkFolderInstanceLock: @unchecked Sendable {

    /// What the file says about the process that holds the folder. Both are what that process
    /// wrote, and either is `nil` when it could not be read — a holder caught mid-write, or an
    /// older layout.
    struct Holder: Codable, Equatable, Sendable {
        var pid: Int32?
        var since: Date?
    }

    enum AcquireError: LocalizedError, Equatable {
        /// Another descriptor holds the lock — another NanoTeams process has this folder open.
        case heldByAnotherProcess(Holder)
        /// The lock file could not be created, opened or locked for a reason other than another
        /// holder or a volume without advisory locks (a read-only volume, permissions). The folder
        /// is not opened either: nothing would keep a second process out.
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .heldByAnotherProcess(let holder):
                var who = "another NanoTeams process"
                if let pid = holder.pid { who += " (PID \(pid))" }
                return "This work folder is already open in \(who), so this NanoTeams leaves it alone: "
                    + "it runs nothing in it and writes nothing to it. Quit the other NanoTeams, or "
                    + "close the folder there, then open it here again."
            case .unavailable(let reason):
                return "Couldn't take this work folder's lock (\(reason)), so it was not opened."
            }
        }
    }

    let fileURL: URL
    /// Whether this lock keeps other processes out. `false` on a volume whose file system has no
    /// advisory locks (`flock` answers `ENOTSUP`, `EOPNOTSUPP` or `ENOLCK` — NFS mounted without
    /// locks, some SMB and WebDAV setups): the folder opens all the same, and the opener says so
    /// (D-M18 R6, 2026-11-12).
    let excludesOtherProcesses: Bool
    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(fileURL: URL, descriptor: Int32, excludesOtherProcesses: Bool) {
        self.fileURL = fileURL
        self.descriptor = descriptor
        self.excludesOtherProcesses = excludesOtherProcesses
        Self.registry.withLock { _ = $0.insert(Self.key(fileURL)) }
    }

    deinit {
        if descriptor >= 0 {
            close(descriptor)
            Self.registry.withLock { _ = $0.remove(Self.key(fileURL)) }
        }
    }

    /// The lock files this process holds — what tells a write of this process apart from one of
    /// another (`refuseIfHeldByAnotherProcess`) without a system call.
    private static let registry = LockedPathSet()

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// `flock(2)` with its outcome as a value: `0`, or the `errno` it failed with. The seam a test
    /// takes to stand for a volume without advisory locks.
    typealias LockOperation = @Sendable (_ descriptor: Int32, _ operation: Int32) -> Int32

    static let systemLockOperation: LockOperation = { descriptor, operation in
        flock(descriptor, operation) == 0 ? 0 : errno
    }

    /// The `errno`s with which a file system says it has no advisory locks at all.
    static func meansNoAdvisoryLocks(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == ENOLCK
    }

    /// The work folder must already be a directory: the lock never makes one. Until 2026-11-12 the
    /// lock created `.nanoteams/` with its intermediate directories, so a folder deleted or moved
    /// while NanoTeams ran — still named by the recents — came back as an empty, freshly
    /// bootstrapped project where the person used to be told it was gone (D-M18 R4).
    static func requireDirectory(_ root: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NTMSRepositoryError.invalidProjectFolder(root)
        }
    }

    /// Takes the lock of the folder at `workFolderRoot`, creating `.nanoteams/internal/` (owner-only,
    /// as `NTMSRepository.ensureLayout` makes it) and the lock file when they are missing — the only
    /// thing this writes before the lock is held. The folder itself must exist
    /// (`NTMSRepositoryError.invalidProjectFolder` otherwise).
    static func acquire(
        workFolderRoot: URL,
        fileManager: FileManager = .default,
        processID: Int32 = getpid(),
        now: Date = Date(),
        lockOperation: LockOperation = systemLockOperation
    ) throws -> WorkFolderInstanceLock {
        try requireDirectory(workFolderRoot, fileManager: fileManager)
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        do {
            if !fileManager.fileExists(atPath: paths.nanoteamsDir.path) {
                try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: false)
            }
            if !fileManager.fileExists(atPath: paths.internalDir.path) {
                try fileManager.createDirectory(
                    at: paths.internalDir, withIntermediateDirectories: true,
                    attributes: NTMSRepository.internalDirAttributes)
            }
        } catch {
            throw AcquireError.unavailable(error.localizedDescription)
        }
        return try acquire(lockFile: paths.instanceLockFile, processID: processID, now: now,
                           lockOperation: lockOperation)
    }

    /// Takes the lock on `lockFile` itself, whose directory must exist.
    static func acquire(
        lockFile: URL,
        processID: Int32 = getpid(),
        now: Date = Date(),
        lockOperation: LockOperation = systemLockOperation
    ) throws -> WorkFolderInstanceLock {
        // O_NOFOLLOW: a symlink planted at the lock's path is refused, never followed to a file
        // elsewhere that this would then truncate. O_CLOEXEC: a child process (bash, git) never
        // inherits the descriptor — it would hold the folder after NanoTeams exits.
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AcquireError.unavailable(String(cString: strerror(errno))) }
        // A few short tries: the write gate of a process that does not hold the folder takes a
        // SHARED lock for the length of one system call (`refuseIfHeldByAnotherProcess`), and an
        // open landing in that instant is not a second NanoTeams.
        var attempt = 0
        while true {
            let code = lockOperation(fd, LOCK_EX | LOCK_NB)
            if code == 0 { break }
            attempt += 1
            if code == EWOULDBLOCK, attempt < 4 {
                usleep(5_000)
                continue
            }
            // No advisory locks on this volume: the folder opens with nothing keeping a second
            // process out, and the opener says so. Refusing it instead left a folder on such a
            // share unopenable with no remedy the person has (D-M18 R6). No record is written —
            // nothing can read it as a holder's.
            if meansNoAdvisoryLocks(code) {
                return WorkFolderInstanceLock(fileURL: lockFile, descriptor: fd, excludesOtherProcesses: false)
            }
            defer { close(fd) }
            if code == EWOULDBLOCK {
                throw AcquireError.heldByAnotherProcess(readHolder(fd: fd))
            }
            throw AcquireError.unavailable(String(cString: strerror(code)))
        }
        writeHolder(Holder(pid: processID, since: now), fd: fd)
        return WorkFolderInstanceLock(fileURL: lockFile, descriptor: fd, excludesOtherProcesses: true)
    }

    /// The write gate: throws `heldByAnotherProcess` when a process other than this one holds the
    /// lock at `lockFile`. A lock this process holds answers from memory; otherwise a non-blocking
    /// SHARED lock is tried and dropped at once — it fails only against an exclusive holder, and no
    /// lock file at all means no holder.
    ///
    /// Any other answer of `flock` passes — a volume without advisory locks among them, where
    /// `acquire` opens the folder unlocked too: neither half can tell a holder there.
    static func refuseIfHeldByAnotherProcess(
        lockFile: URL, lockOperation: LockOperation = systemLockOperation
    ) throws {
        if registry.withLock({ $0.contains(key(lockFile)) }) { return }
        let fd = open(lockFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let code = lockOperation(fd, LOCK_SH | LOCK_NB)
        guard code != 0 else { return }
        if code == EWOULDBLOCK { throw AcquireError.heldByAnotherProcess(readHolder(fd: fd)) }
    }

    /// Whether this object still holds the lock.
    var isHeld: Bool { stateLock.withLock { descriptor >= 0 } }

    /// Whether the file this lock holds is still the one at `fileURL` — `false` once the lock file
    /// was deleted or replaced under it (a `.nanoteams/` removed in the Finder), when the hold is on
    /// a file no other process can open any more and keeps nobody out.
    var locksTheFileAtItsPath: Bool {
        stateLock.withLock {
            guard descriptor >= 0 else { return false }
            var held = stat()
            var named = stat()
            guard fstat(descriptor, &held) == 0, lstat(fileURL.path, &named) == 0 else { return false }
            return held.st_dev == named.st_dev && held.st_ino == named.st_ino
        }
    }

    /// Lets the folder go: the descriptor closes and the kernel drops the lock. Idempotent.
    func release() {
        stateLock.withLock {
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
            Self.registry.withLock { _ = $0.remove(Self.key(fileURL)) }
        }
    }

    // MARK: - The holder record

    private static func writeHolder(_ holder: Holder, fd: Int32) {
        guard let data = try? JSONCoderFactory.makePersistenceEncoder().encode(holder) else { return }
        _ = ftruncate(fd, 0)
        _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, 0) }
    }

    private static func readHolder(fd: Int32) -> Holder {
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0,
              let holder = try? JSONCoderFactory.makeDateDecoder().decode(
                Holder.self, from: Data(buffer[0..<count]))
        else { return Holder() }
        return holder
    }
}


/// A `Set<String>` behind an `NSLock` — the registry of the lock files this process holds.
nonisolated final class LockedPathSet: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func withLock<T>(_ body: (inout Set<String>) -> T) -> T {
        lock.withLock { body(&paths) }
    }
}

/// Where a folder's lock lives, for the orchestrator that takes it and the repository that
/// refuses to write into a folder another process holds — one value, so the two can never
/// disagree about which file it is.
///
/// `.system` is the folder's own `.nanoteams/internal/instance.lock`, default storage included. A
/// test host and a preview canvas run inside the developer's account, where
/// `~/Library/Application Support/NanoTeams` is the default storage of the NanoTeams the developer
/// is running — and of every parallel test worker at once — so the factories that build their
/// orchestrators take `isolatingDefaultStorage()`: the same `flock`, on a lock file of their own for
/// that one folder.
nonisolated struct WorkFolderInstanceLocking: Sendable {
    /// The lock file of the folder at a root.
    let lockFile: @Sendable (URL) -> URL
    /// `flock(2)`, or what a test puts in its place (`WorkFolderInstanceLock.LockOperation`).
    let lockOperation: WorkFolderInstanceLock.LockOperation

    init(
        lockFile: @escaping @Sendable (URL) -> URL,
        lockOperation: @escaping WorkFolderInstanceLock.LockOperation = WorkFolderInstanceLock.systemLockOperation
    ) {
        self.lockFile = lockFile
        self.lockOperation = lockOperation
    }

    static let system = WorkFolderInstanceLocking(lockFile: { NTMSPaths(workFolderRoot: $0).instanceLockFile })

    /// The folder's own lock file for every folder but default storage, whose lock file is in a
    /// private temporary directory made per call of this function.
    static func isolatingDefaultStorage() -> WorkFolderInstanceLocking {
        let privateLockFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanoteams-default-storage-lock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("instance.lock", isDirectory: false)
        return WorkFolderInstanceLocking(lockFile: { root in
            root.standardizedFileURL == NTMSPaths.defaultStorageURL.standardizedFileURL
                ? privateLockFile
                : NTMSPaths(workFolderRoot: root).instanceLockFile
        })
    }

    /// Takes the lock of the folder at `root`, which must be an existing directory
    /// (`WorkFolderInstanceLock.requireDirectory`). The folder's own `.nanoteams/internal/` is
    /// created owner-only when missing, as `NTMSRepository.ensureLayout` makes it; any other
    /// directory a lock file lives in is created plainly.
    func acquire(_ root: URL, processID: Int32 = getpid(), now: Date = Date()) throws -> WorkFolderInstanceLock {
        let file = lockFile(root)
        let ownFile = NTMSPaths(workFolderRoot: root).instanceLockFile
        if file.standardizedFileURL == ownFile.standardizedFileURL {
            return try WorkFolderInstanceLock.acquire(
                workFolderRoot: root, processID: processID, now: now, lockOperation: lockOperation)
        }
        try WorkFolderInstanceLock.requireDirectory(root)
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw WorkFolderInstanceLock.AcquireError.unavailable(error.localizedDescription)
        }
        return try WorkFolderInstanceLock.acquire(
            lockFile: file, processID: processID, now: now, lockOperation: lockOperation)
    }

    /// Throws when another process holds the folder at `root` (`refuseIfHeldByAnotherProcess`).
    func refuseIfHeldByAnotherProcess(_ root: URL) throws {
        try WorkFolderInstanceLock.refuseIfHeldByAnotherProcess(lockFile: lockFile(root), lockOperation: lockOperation)
    }
}
