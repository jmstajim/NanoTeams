import XCTest

/// `boundedValue(of:within:)`: the value or the error of a task that ends, and a recorded failure
/// with the cap's own error — not a hang — for one that does not, whether or not it answers to
/// cancellation.
final class BoundedTaskValueTests: XCTestCase {

    func testATaskThatEndsGivesItsValue() async throws {
        let value = try await boundedValue(of: Task { 42 }, within: 5)
        XCTAssertEqual(value, 42)
    }

    func testATaskThatThrowsRethrowsItsOwnError() async {
        do {
            _ = try await boundedValue(of: Task<Int, any Error> { throw Refused() }, within: 5)
            XCTFail("the task's own error was swallowed")
        } catch {
            XCTAssertTrue(error is Refused, "\(error)")
        }
    }

    /// A task that would run for an hour: the wait comes back at its cap, reports where it was
    /// called, throws the cap's error rather than whatever the cancelled task then throws, and
    /// cancels the task.
    func testATaskThatOutlivesTheCapIsReportedAndCancelled() async {
        var reports: [String] = []
        let hanging = Task<Void, any Error> { try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }
        do {
            try await boundedValue(of: hanging, within: 0.2, "the call", reportingTo: { message, _, _ in
                reports.append(message)
            })
            XCTFail("a task that never ended gave a value")
        } catch {
            XCTAssertEqual(error as? BoundedTaskValueTimedOut, BoundedTaskValueTimedOut(seconds: 0.2), "\(error)")
        }
        XCTAssertEqual(reports, ["the call was still running after 0.2 s of wall time"])
        XCTAssertTrue(hanging.isCancelled, "the task was left running past its cap")
    }

    /// The cap does not lean on cancellation: a task that ignores it still leaves the wait at the
    /// cap — why the helper races the task instead of putting it in a task group, which waits for
    /// every child before it returns.
    func testATaskDeafToCancellationStillLeavesTheWaitAtTheCap() async {
        let gate = Gate()
        let deaf = Task<Void, any Error> { await gate.passed() }
        var reported = 0
        do {
            try await boundedValue(of: deaf, within: 0.2, reportingTo: { _, _, _ in reported += 1 })
            XCTFail("a task that never ended gave a value")
        } catch {
            XCTAssertTrue(error is BoundedTaskValueTimedOut, "\(error)")
        }
        XCTAssertEqual(reported, 1)
        gate.open()
        _ = await deaf.result
    }

    private struct Refused: Error {}

    /// Passed only once opened — cancellation does not open it.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func passed() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let goes: Bool = lock.withLock {
                    if isOpen { return true }
                    waiting.append(continuation)
                    return false
                }
                if goes { continuation.resume() }
            }
        }

        func open() {
            let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            for continuation in resumed { continuation.resume() }
        }
    }
}
