import Foundation

/// The one folder an orchestrator holds — the `WorkFolderInstanceLock` it took, and the root it took
/// it for — and the rule every write of that orchestrator passes: it writes only into the folder it
/// holds (D-M18 R2, 2026-11-12).
///
/// Until then the rule was the write gate's alone — "no other process holds it" — which a process
/// whose open was refused passed the moment the holder quit: the refused process kept the folder's
/// URL with nothing loaded, a Quick Capture submit created a task there, the snapshot that write
/// returned was applied, and the run started, with no lock taken. The holder's next open then found
/// the folder free, and two processes ran it again. A rule about who ELSE holds the folder cannot
/// close that; a rule about who holds it here can.
///
/// Thread-safe: the orchestrator takes and releases on the main actor, and its repository writes
/// from detached tasks (`HeldWorkFolderRepository`).
nonisolated final class WorkFolderHold: @unchecked Sendable {

    /// Why a write was refused.
    enum Refusal: LocalizedError, Equatable {
        /// This orchestrator does not hold the folder: its open was refused or failed, or it has
        /// moved to another folder since.
        case notHeld(URL)

        var errorDescription: String? {
            switch self {
            case .notHeld:
                "This work folder isn't open in this NanoTeams, so nothing was written to it. "
                    + "Open the folder again to work in it."
            }
        }
    }

    /// How folders are locked here — what tells the refusal apart from another process's hold.
    let locking: WorkFolderInstanceLocking
    private let stateLock = NSLock()
    private var held: (root: String, lock: WorkFolderInstanceLock)?

    init(locking: WorkFolderInstanceLocking) {
        self.locking = locking
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Holds `lock` as `root`'s, letting go of whatever was held before.
    func hold(_ lock: WorkFolderInstanceLock, for root: URL) {
        let previous = stateLock.withLock { () -> WorkFolderInstanceLock? in
            let previous = held?.lock
            held = (Self.key(root), lock)
            return previous
        }
        if let previous, previous !== lock { previous.release() }
    }

    /// Lets go of the held folder. Idempotent.
    func release() {
        let previous = stateLock.withLock { () -> WorkFolderInstanceLock? in
            defer { held = nil }
            return held?.lock
        }
        previous?.release()
    }

    /// Whether the folder at `root` is the one held, and its lock is still held.
    func holds(_ root: URL) -> Bool {
        stateLock.withLock {
            guard let held, held.root == Self.key(root) else { return false }
            return held.lock.isHeld
        }
    }

    /// The lock held for `root`, if `root` is the folder held.
    func lock(for root: URL) -> WorkFolderInstanceLock? {
        stateLock.withLock {
            guard let held, held.root == Self.key(root), held.lock.isHeld else { return nil }
            return held.lock
        }
    }

    /// The rule: passes for the folder held, refuses every other. A folder another process holds
    /// is refused naming it (`WorkFolderInstanceLock.AcquireError.heldByAnotherProcess`), as the
    /// refused open was; any other folder with `Refusal.notHeld`.
    func authorizeWrite(into root: URL) throws {
        guard !holds(root) else { return }
        try locking.refuseIfHeldByAnotherProcess(root)
        throw Refusal.notHeld(root)
    }
}
