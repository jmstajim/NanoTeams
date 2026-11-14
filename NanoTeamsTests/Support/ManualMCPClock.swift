import Foundation

@testable import NanoTeams

/// An `MCPClock` whose time moves only when a test moves it.
///
/// The client's two timers race a budget against the server's progress reports. Raced on the
/// wall clock, a test proves a 5-second budget survived only if three sleeps of 1.2 s each also
/// came back on time — on a loaded machine they do not, and the test fails for a reason that
/// has nothing to do with the rule (MCPClientCorrelationTests, 2026-09-23). Here the budget
/// and the reports are ordered by the test itself: nothing wakes until `advance`, and a sleeper
/// cancelled in between is released at once.
final class ManualMCPClock: MCPClock, @unchecked Sendable {

    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: Sleeper] = [:]

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = start
    }

    func now() -> Date { lock.withLock { current } }

    /// How many timers are waiting on this clock — how a test knows a watchdog has armed
    /// before it moves the time past its deadline.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Date) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if deadline <= current || Task.isCancelled { return true }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.continuation.resume()
        }
    }

    /// Moves the time on and wakes every sleeper whose deadline it passed.
    func advance(by seconds: TimeInterval) {
        let due: [Sleeper] = lock.withLock {
            current = current.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits — on the WALL clock, bounded — until a timer sleeps on this one due exactly
    /// `seconds` from now, and says whether one did. How a test tells one timer from another
    /// that happens to be armed at the same moment — a retry waiting out its backoff step from
    /// the watchdog of the request it just made — since each is due at a time of its own.
    @discardableResult
    func waitForSleeper(dueIn seconds: TimeInterval, within wait: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let found: Bool = lock.withLock {
                let due = current.addingTimeInterval(seconds)
                return sleepers.values.contains { $0.deadline == due }
            }
            if found { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    /// Waits — on the WALL clock, bounded — until `count` timers sleep on this one: the
    /// watchdog of a call is armed from a task the test does not control.
    func waitForSleepers(_ count: Int, within seconds: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while sleeperCount < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
