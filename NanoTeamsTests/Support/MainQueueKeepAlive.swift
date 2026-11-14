import Foundation

/// The test bundle's principal class. XCTest instantiates the bundle's `NSPrincipalClass` once per
/// test host — on the main thread, before the first test — which makes it the one hook that reaches
/// every test class without any of them saying so. Its only job is `MainQueueKeepAlive.install()`.
///
/// The key is `INFOPLIST_KEY_NSPrincipalClass = NanoTeamsTestBundlePrincipal` in both NanoTeamsTests
/// configurations of `project.pbxproj`, and it names the `@objc` name below: rename one, rename the
/// other (`Ratchet/MainQueueKeepAlivePinTests` reds on a one-sided rename). The public mirror does
/// not sync the pbxproj (DEBTS.md D-31), so there this class compiles and is never instantiated —
/// the mirror runs the slower, equally correct status quo.
@objc(NanoTeamsTestBundlePrincipal)
final class TestBundlePrincipal: NSObject {
    override init() {
        super.init()
        MainQueueKeepAlive.install()
    }
}

/// A 1 ms timer on the MAIN dispatch queue, kept for the life of the test host. Without it XCTest
/// sleeps out a 0.1 s slice after nearly every async phase of a `@MainActor` test class, and on
/// 2026-10-28 that was half the suite's time.
///
/// **The mechanism.** XCTest runs an async phase (`setUp() async`, an async test body,
/// `tearDown() async`) and waits for it in `+[XCTWaiter _synchronouslyWaitForTimeInterval:]`, which
/// runs the main run loop in `kCFRunLoopDefaultMode` one ~0.1 s run at a time
/// (`returnAfterSourceHandled`) and re-checks the phase's expectation only when a run RETURNS. A
/// phase whose last job runs on the main actor ends inside a main-queue callout; that run returns,
/// XCTWaiter finds the expectation not yet fulfilled — the async thunk fulfils it from the
/// cooperative pool a few µs later — and re-enters. The fulfilment lands in that gap (traced:
/// exit → entry 15 µs, entry → sleep 18 µs), outside any sleeping run, and is lost there, so the
/// new run sleeps the whole slice. A fulfilment that arrives while a run sleeps does end it: a
/// phase that ends off the main actor costs 0.001 s, and in one trace (async lifecycle and body)
/// 13 of 20 lifecycle sleeps ended after 3–4 ms. Which primitive the fulfilment uses was not
/// identified, so why the gap loses it is inferred, not traced. Each lost race costs ~0.1 s; an
/// async setUp and tearDown, ~0.2 s per test.
///
/// **Why a main-QUEUE timer, and not anything cheaper-looking** (CLAUDE.md #359). A run returns
/// early only for a handled SOURCE — a main-dispatch-queue item, a version-0 or version-1 source —
/// a stop, or its timeout. A run-loop timer firing is none of those, and neither is
/// `CFRunLoopWakeUp`: both wake the loop, which goes straight back to sleep. A main-queue timer
/// item IS a handled source, so a lost fulfilment now costs at most 1 ms. Measured per test on an
/// async setUp/tearDown cell (median, 2026-10-28): nothing 0.2062 s; a 1 ms `CFRunLoopTimer` in
/// the common modes 0.2025 s; a thread calling `CFRunLoopWakeUp(main)` every 1 ms 0.2032 s; a
/// `[.userInitiated, .latencyCritical]` activity 0.2062 s; this timer 0.0017 s. Do not
/// "simplify" it to a run-loop timer — `MainQueueKeepAlivePinTests` watches exactly that run and
/// reds on one, even one that keeps this enum's counter and `source` to look installed.
///
/// **What it bought, and what it did not touch.** Whole plan, Xcode 27.1, median of three
/// second-of-pair runs (2026-10-28): xcodebuild wall 154.3 → 79.1 s, sum of per-test durations
/// 1625.5 → 778.3 s (−52 %), the outcome identical name by name (21 155 passing, the same 18
/// skipped), and the 71 run-loop-sensitive classes 20 times over without a failure. No test file
/// changed and no code moved between executors: bodies and lifecycles stay on the main actor and
/// only the wake changes, so the 2026-08-15 abort class (a sync entry into main-actor code) cannot
/// come back through it. A `RunLoop.main.run(until:)` still spins its full date, in 1 ms steps.
/// Not verified on macOS 15 + Xcode 26.3, the mirror CI's runtime (DEBTS.md D-31).
enum MainQueueKeepAlive {
    /// Written once, on the main thread, by the principal's `init` before the first test; read on
    /// the main thread by the pin. Nothing else touches it.
    nonisolated(unsafe) private static var source: DispatchSourceTimer?

    /// Whether this test host runs the keep-alive — the pin's subject, never a switch.
    static var isInstalled: Bool { source != nil }

    /// Times the handler ran. Counting is the handler's only work, and it is there for the pin:
    /// anything a run handles ends it, so timing a run cannot tell this timer from whatever else
    /// a fresh test host is doing (measured 2026-10-28: with no keep-alive at all, the first test
    /// of a fresh host saw 21 runs end in 0.036 s; the source of that traffic was not identified).
    /// The count can. It does not move while the main thread is blocked, which rules out a timer
    /// on any other queue, and the pin notes it at every wake of the run loop, which tells a
    /// firing that ends its run from a run-loop timer's, which does not. Written only by the
    /// handler, on main.
    nonisolated(unsafe) private(set) static var firings = 0

    /// Idempotent: a second call keeps the first timer.
    static func install() {
        guard source == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .nanoseconds(0))
        timer.setEventHandler { firings &+= 1 }
        timer.resume()
        source = timer
    }
}
