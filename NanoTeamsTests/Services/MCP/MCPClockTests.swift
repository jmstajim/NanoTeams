import XCTest

@testable import NanoTeams

/// The wall clock the client's timers run on in the app, and the budget every courtesy frame is
/// sent under.
final class MCPClockTests: XCTestCase {

    // MARK: - MCPSystemClock

    func testTheSystemClockReadsTheWallClock() {
        let before = Date()
        let now = MCPSystemClock().now()
        XCTAssertGreaterThanOrEqual(now, before)
        XCTAssertLessThan(now.timeIntervalSince(before), 1)
    }

    /// A deadline already past returns at once — the watchdog re-checks a request whose budget
    /// ran out while it was busy, and must not sleep on it.
    func testSleepingUntilAPastDeadlineReturnsAtOnce() async {
        let started = Date()
        await MCPSystemClock().sleep(until: started.addingTimeInterval(-5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testSleepingUntilAFutureDeadlineWaitsForIt() async {
        let started = Date()
        await MCPSystemClock().sleep(until: started.addingTimeInterval(0.1))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.09)
    }

    /// Cancelling the sleeper ends the sleep — a settled request's watchdog is cancelled, and it
    /// must not live on for the rest of its budget.
    func testCancellingTheSleeperEndsTheSleep() async {
        let started = Date()
        let sleeper = Task { await MCPSystemClock().sleep(until: Date().addingTimeInterval(30)) }
        sleeper.cancel()
        await sleeper.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: - MCPBudget

    func testWorkThatFinishesInTimeReportsSo() async throws {
        let finished = try await MCPBudget.run(within: 5) { }
        XCTAssertTrue(finished)
    }

    /// Past its budget the work is cancelled — over HTTP, that closes the request — and the
    /// caller hears `false` rather than the error the cancellation made the work throw.
    func testWorkPastItsBudgetIsCancelledAndReportsSo() async throws {
        let cancelled = CancellationMark()
        let started = Date()
        let finished = try await MCPBudget.run(within: 0.1) {
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                cancelled.set()
                throw error
            }
        }
        XCTAssertFalse(finished)
        XCTAssertTrue(cancelled.isSet, "the work was left running")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A budget of zero — `close(budget: 0)` — still lets work that needs no time finish, and
    /// a negative one reads as zero.
    func testAZeroOrNegativeBudgetCancelsWorkThatWaits() async throws {
        for budget in [0.0, -1.0] {
            let finished = try await MCPBudget.run(within: budget) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
            XCTAssertFalse(finished, "budget \(budget)")
        }
    }

    /// An error the work throws on its own, inside the budget, is the caller's to see.
    func testAnErrorTheWorkThrowsOnItsOwnIsRethrown() async {
        struct Refused: Error {}
        do {
            _ = try await MCPBudget.run(within: 5) { throw Refused() }
            XCTFail("the work's own error must reach the caller")
        } catch {
            XCTAssertTrue(error is Refused, "\(error)")
        }
    }

    /// Cancelling the caller cancels the work too: a budget is a ceiling, not a detachment.
    func testCancellingTheCallerCancelsTheWork() async {
        let cancelled = CancellationMark()
        let caller = Task {
            try await MCPBudget.run(within: 30) {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    cancelled.set()
                    throw error
                }
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        caller.cancel()
        _ = try? await caller.value
        XCTAssertTrue(cancelled.isSet, "the work outlived its caller")
    }
}

private final class CancellationMark: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
