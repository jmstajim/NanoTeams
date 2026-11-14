import XCTest

/// The value of `task`, awaited for at most `seconds` of WALL time: past that the task is
/// cancelled, the wait records a failure where it was called, and it throws
/// `BoundedTaskValueTimedOut` — so a `catch` for the error the test expects cannot read the cap
/// as that error, and the test ends there instead of hanging the run.
///
/// The shape it bounds: a test on a `ManualMCPClock` starts a call in a `Task`, waits for the
/// call's timer to arm, moves the clock past it and awaits the task. A regression that arms the
/// timer for a later deadline — or never resumes the call when it fires — leaves that await
/// with nothing to end it, and `NanoTeams.xctestplan` sets no per-test timeout: the run hangs
/// until the mutation harness's watchdog, which records a TIME-OUT, not a kill. The wall-clock
/// test it replaced failed such a regression in about a minute (until 2026-10-28).
///
/// A race, not a task group: a group waits for every child before it returns, so a child
/// awaiting a task that never ends would hang the very wait meant to bound it.
func boundedValue<T: Sendable, Failure: Error>(
    of task: Task<T, Failure>,
    within seconds: TimeInterval = 10,
    _ what: @autoclosure () -> String = "the task",
    file: StaticString = #filePath,
    line: UInt = #line,
    reportingTo report: (String, StaticString, UInt) -> Void = { XCTFail($0, file: $1, line: $2) }
) async throws -> T {
    let race = BoundedTaskRace<Result<T, Failure>>()
    let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Failure>?, Never>) in
        race.start(continuation)
        race.arm(Task { race.finish(await task.result) })
        race.arm(Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            race.finish(nil)
        })
    }
    guard let outcome else {
        task.cancel()
        report("\(what()) was still running after \(seconds) s of wall time", file, line)
        throw BoundedTaskValueTimedOut(seconds: seconds)
    }
    return try outcome.get()
}

/// What `boundedValue(of:within:)` throws when the cap ran out first.
struct BoundedTaskValueTimedOut: Error, Equatable {
    let seconds: TimeInterval
}

/// The first of the two to finish resumes the wait; the other, the timer included, is cancelled.
private final class BoundedTaskRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var racers: [Task<Void, Never>] = []

    func start(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func arm(_ racer: Task<Void, Never>) {
        let done: Bool = lock.withLock {
            guard continuation != nil else { return true }
            racers.append(racer)
            return false
        }
        if done { racer.cancel() }
    }

    func finish(_ value: Value?) {
        let (waiting, others): (CheckedContinuation<Value?, Never>?, [Task<Void, Never>]) = lock.withLock {
            defer { continuation = nil; racers = [] }
            return (continuation, racers)
        }
        guard let waiting else { return }
        for racer in others { racer.cancel() }
        waiting.resume(returning: value)
    }
}
