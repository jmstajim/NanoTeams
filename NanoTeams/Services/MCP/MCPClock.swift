import Foundation

/// Where the MCP layer reads the time and waits on it: `MCPClient`'s request budgets, the
/// transport's timers, and the connection's reconnect schedule, failure accounting, staleness
/// and listing retry.
///
/// A seam, not an abstraction for its own sake: the client's two budgets race a server's
/// progress reports, and a test raced on the wall clock proves a rule only if every one of its own sleeps
/// comes back on time — on a loaded machine they do not, and such a test failed for a reason
/// that had nothing to do with the rule (2026-09-23). A test drives its own clock instead; the
/// app uses `MCPSystemClock`.
nonisolated protocol MCPClock: Sendable {
    func now() -> Date
    /// Returns at `deadline`, or as soon as the calling task is cancelled — whichever is first.
    func sleep(until deadline: Date) async
}

/// The wall clock.
nonisolated struct MCPSystemClock: MCPClock {

    init() {}

    func now() -> Date { Date() }

    func sleep(until deadline: Date) async {
        let seconds = deadline.timeIntervalSinceNow
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Work that may not hold its caller past a budget.
///
/// Each use is a COURTESY or a bound on one: the legacy `DELETE` at close, the legacy
/// `notifications/cancelled`, a reply to a server's `ping`, the `notifications/initialized` a
/// handshake sends. A server too busy to take one within its budget does not get it — the
/// work is cancelled, which over HTTP closes the request — because waiting longer would make
/// the server's slowness the caller's.
nonisolated enum MCPBudget {

    /// Runs `work`, cancelling it once `budget` seconds have passed on `clock`. `true` when it
    /// finished on its own; `false` when the budget ran out first. An error `work` throws before
    /// then is rethrown; whatever it throws BECAUSE the budget cancelled it is not — that is the
    /// `false`. Cancelling the caller cancels the work too.
    ///
    /// `clock` is the caller's own (`MCPClient`'s, the transport's), so a test that drives that
    /// clock drives the budget too: until 2026-10-28 the budget slept on the wall clock whatever
    /// the caller ran on, and every test of a courtesy waited its two real seconds out. The
    /// default is the wall clock, for a caller that has no clock of its own.
    @discardableResult
    static func run(
        within budget: TimeInterval, clock: any MCPClock = MCPSystemClock(),
        _ work: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        let overran = Flag()
        // Read before the timer starts, so the budget counts from the call — not from whenever
        // the timer's task first runs, which a driven clock may already have moved past.
        let deadline = clock.now().addingTimeInterval(max(0, budget))
        let task = Task<Void, any Error> { try await work() }
        let timer = Task {
            await clock.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            overran.set()
            task.cancel()
        }
        defer { timer.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return true
        } catch {
            if overran.isSet { return false }
            throw error
        }
    }

    /// Set once by the timer, read once by the waiter — two tasks, so a lock.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
