import XCTest
@testable import NanoTeams

/// Pins the I4 invariant: when no dictation session is active
/// (`sessionState == .idle && engineStorage == nil`), `flushAndThen`
/// must run `action` synchronously without a Task hop. Pre-fix, the idle
/// branch existed but its doc claimed `engineStorage` could still hold an
/// engine — that's incorrect (`resetObservedState` always pairs both),
/// and the guard now reflects the real invariant.
@MainActor
final class DictationFlushAndThenIdleTests: XCTestCase {

    var sut: DictationService!

    override func setUp() {
        super.setUp()
        sut = DictationService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    /// On a freshly-constructed service (no engine ever started) the action
    /// must run synchronously: by the time `flushAndThen` returns, the flag
    /// is already true. A Task-hopped path would set the flag asynchronously.
    func testFlushAndThen_idleWithNoEngine_runsActionSynchronously() {
        var didRun = false
        sut.flushAndThen { didRun = true }
        XCTAssertTrue(
            didRun,
            "Idle service must run the action synchronously — a Task hop here would slow every submit click"
        )
    }

    /// Multiple consecutive submits while idle stay synchronous.
    func testFlushAndThen_idleRepeatedCalls_allRunSynchronously() {
        var counter = 0
        for _ in 0..<5 {
            sut.flushAndThen { counter += 1 }
        }
        XCTAssertEqual(counter, 5, "All idle-path actions must run before flushAndThen returns")
    }
}
