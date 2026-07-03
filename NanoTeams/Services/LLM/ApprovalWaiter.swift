import Foundation

/// Thread-safe one-shot bridge between a gate's `await` and the resolution that ends it (a human
/// Allow/Deny tap, or a Pause cancellation). The continuation is resumed EXACTLY once — whichever
/// resolution arrives first wins; later calls and a `resolve` that races ahead of `attach` are
/// absorbed. `@unchecked Sendable` because the lock serializes all access to the mutable state.
///
/// The lock/race semantics here are safety-critical (early-resolve-before-attach, single resume),
/// so both the `bash` gate (`BashApprovalWaiter`) and the computer-use gate
/// (`ComputerUseApprovalWaiter`) share this single generic rather than each keeping a byte-clone
/// that could drift if the concurrency logic is ever fixed in one place only.
nonisolated final class ApprovalWaiter<Decision: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Decision, Never>?
    private var settled: Decision?

    /// Registers the gate's continuation. If a decision already arrived (resolve raced ahead of
    /// the await registering), resume immediately with it.
    func attach(_ cont: CheckedContinuation<Decision, Never>) {
        let early: Decision? = lock.withLock {
            if let settled { return settled }
            continuation = cont
            return nil
        }
        if let early { cont.resume(returning: early) }
    }

    func resolve(_ decision: Decision) {
        let toResume: CheckedContinuation<Decision, Never>? = lock.withLock {
            guard settled == nil else { return nil }
            settled = decision
            defer { continuation = nil }
            return continuation
        }
        toResume?.resume(returning: decision)
    }
}
