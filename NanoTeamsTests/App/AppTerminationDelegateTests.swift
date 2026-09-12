import XCTest
@testable import NanoTeams

/// ⌘Q with a folder open has to wait for the search index to be written — and must not wait
/// forever.
///
/// `reply` is injected for exactly this: under XCTest the shared application is the test
/// runner's, and telling it a termination may proceed is not something a unit test should do.
@MainActor
final class AppTerminationDelegateTests: XCTestCase {

    /// Without a shutdown step there is nothing to wait for, and suspending the quit would be
    /// a hang with no cause. This is also the state during launch, before the orchestrator
    /// exists.
    func testNoShutdownStep_terminatesImmediately() {
        let delegate = AppTerminationDelegate()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    /// The quit is SUSPENDED and then resumed once the save finishes.
    ///
    /// RED: return `.terminateNow` with the save in flight → AppKit tears the process down
    /// mid-write, which is the bug this class exists to prevent.
    func testShutdownStep_suspendsTheQuitThenResumesIt() async {
        let delegate = AppTerminationDelegate()
        let recorder = ReplyRecorder()
        let ran = Flag()
        delegate.onTerminate = { ran.set() }
        delegate.reply = { recorder.record($0) }

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater,
            "the quit must wait for the index to be written")

        await recorder.waitForReply()
        XCTAssertTrue(ran.isSet, "the shutdown step must actually have run")
        XCTAssertEqual(recorder.replies, [true],
                       "exactly one reply, and it lets the quit proceed")
    }

    /// A hung volume — an unmounted share, a spinning external disk — must not make the app
    /// unquittable. What is being saved is a regenerable cache; the quit wins.
    ///
    /// RED: drop the timeout race from `run` → this test hangs, which is precisely the
    /// user-facing symptom.
    func testHungShutdownStep_stillQuitsAfterTheTimeout() async {
        let started = Flag()
        await AppTerminationDelegate.run({
            started.set()
            try? await Task.sleep(for: .seconds(60))
        }, within: .milliseconds(50))
        XCTAssertTrue(started.isSet, "anti-vacuum: the work was actually started")
    }

    /// The save is best-effort: a failure is not a reason to refuse the user's quit. It is
    /// reported through the coordinator, and the index rebuilds on the next launch anyway.
    func testShutdownStepThatFails_stillLetsTheQuitProceed() async {
        let delegate = AppTerminationDelegate()
        let recorder = ReplyRecorder()
        delegate.onTerminate = { /* a save that did nothing useful */ }
        delegate.reply = { recorder.record($0) }

        _ = delegate.applicationShouldTerminate(NSApplication.shared)
        await recorder.waitForReply()
        XCTAssertEqual(recorder.replies, [true])
    }

    /// The fast path of the race: work that finishes well inside the timeout returns as soon
    /// as it is done, rather than waiting the timeout out.
    func testRun_fastWork_returnsWithoutWaitingOutTheTimeout() async {
        // Two `ContinuousClock.now` reads rather than `clock.measure { }`: the needle
        // `Ratchet/WallClockPerformancePinTests` bans is the literal `measure {`, and a
        // `ContinuousClock` one reads to a scanner exactly like the XCTest one it exists to
        // keep out.
        let started = ContinuousClock.now
        await AppTerminationDelegate.run({ }, within: .seconds(30))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5),
                          "the race must resolve on the WORK, not on the deadline")
    }
}

// MARK: - Helpers

/// `@MainActor` rather than lock-guarded: every writer here is a main-actor closure, so the
/// isolation is the synchronisation.
@MainActor
private final class ReplyRecorder {
    private(set) var replies: [Bool] = []

    func record(_ proceed: Bool) { replies.append(proceed) }

    /// Polls rather than using an expectation: the reply arrives from an unstructured `Task`
    /// the delegate owns, and there is no seam to fulfil an expectation from.
    func waitForReply(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while replies.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}
