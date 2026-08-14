import XCTest

@testable import NanoTeams

/// Smoke tests for `LLMStatusMonitor` — polling lifecycle, cancellation, and
/// re-entrant start/stop. Uses an invalid URL so `LLMConnectionChecker.check`
/// returns `false` quickly without hitting a real server.
@MainActor
final class LLMStatusMonitorTests: XCTestCase {

    var sut: LLMStatusMonitor!

    override func setUp() {
        super.setUp()
        sut = LLMStatusMonitor()
    }

    override func tearDown() {
        sut.stopMonitoring()
        sut = nil
        super.tearDown()
    }

    func testInitialState() {
        XCTAssertFalse(sut.isReachable)
        XCTAssertNil(sut.lastCheckedAt)
    }

    func testStartMonitoring_probesOnce_updatesLastCheckedAt() async {
        sut.startMonitoring(endpointProvider: { ("http://127.0.0.1:9", .lmStudio) }, interval: 60)

        // Wait until the initial probe lands. Invalid port fails the connect
        // attempt fast (<<1s on localhost); poll-with-timeout avoids the prior
        // unconditional 3-second sleep.
        await waitUntilNotNil({ self.sut.lastCheckedAt }, timeoutSeconds: 5)

        XCTAssertNotNil(sut.lastCheckedAt, "First poll should have set lastCheckedAt")
        XCTAssertFalse(sut.isReachable, "Invalid port must not report reachable")

        sut.stopMonitoring()
    }

    /// Re-entrant start must cancel the previous task (no leaked poll loop).
    func testStartMonitoring_calledTwice_replacesActiveTask() async {
        sut.startMonitoring(endpointProvider: { ("http://127.0.0.1:9", .lmStudio) }, interval: 60)
        sut.startMonitoring(endpointProvider: { ("http://127.0.0.1:10", .lmStudio) }, interval: 60)

        // Not directly observable without injecting a mock checker, but we assert no
        // crash and that stopMonitoring cleanly tears down the latest task.
        sut.stopMonitoring()
        // Follow-up stop is idempotent
        sut.stopMonitoring()
    }

    /// After stopMonitoring, the monitor must not publish state from an in-flight probe.
    /// We can't directly observe the cancellation-after-await guard without a mock, but
    /// we can assert that stopMonitoring is idempotent and leaves state frozen.
    func testStopMonitoring_idempotent_afterStart() async {
        sut.startMonitoring(endpointProvider: { ("http://127.0.0.1:9", .lmStudio) }, interval: 60)
        await waitUntilNotNil({ self.sut.lastCheckedAt }, timeoutSeconds: 5)
        let frozen = sut.lastCheckedAt

        sut.stopMonitoring()
        try? await Task.sleep(for: .milliseconds(200))

        // No further updates after stop
        XCTAssertEqual(sut.lastCheckedAt, frozen)
    }

    // MARK: - checkNow: the on-demand probe behind the model picker

    /// No endpoint installed ⇒ nothing to probe. A `checkNow` that fabricated an
    /// endpoint would probe whatever the config happened to hold at wiring time.
    func testCheckNow_beforeStartMonitoring_issuesNoRequest() async {
        let session = CountingSession()
        let monitor = LLMStatusMonitor(session: session)

        let reachable = await monitor.checkNow()

        XCTAssertEqual(session.requestCount, 0, "No endpoint installed — must not probe")
        XCTAssertFalse(reachable)
        XCTAssertFalse(monitor.isChecking)
        XCTAssertNil(monitor.lastCheckedAt)
    }

    /// The whole point: a probe on demand, in addition to the loop's own.
    /// Mutation: make `checkNow` a no-op while `pollTask != nil` → count stays 1.
    func testCheckNow_whileIdleBetweenPolls_probesAgain() async {
        let session = CountingSession()
        session.statusCode = 200
        let monitor = LLMStatusMonitor(session: session)
        // Long interval so the loop probes once and then sleeps for the test's life.
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ monitor.lastCheckedAt != nil }, timeoutSeconds: 5)
        XCTAssertEqual(session.requestCount, 1)

        await monitor.checkNow()

        XCTAssertEqual(session.requestCount, 2, "checkNow must probe, not read a cache")
        XCTAssertTrue(monitor.isReachable)
        monitor.stopMonitoring()
    }

    /// Re-opening the picker while a probe is running must not fan out.
    /// Mutation: drop the `if let inFlight = probeTask` early return → count 3.
    func testCheckNow_concurrentCalls_coalesceOntoOneProbe() async {
        let session = CountingSession()
        session.statusCode = 200
        session.delay = .milliseconds(150)
        let monitor = LLMStatusMonitor(session: session)
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)

        // The loop's own probe is in flight; pile three manual ones onto it.
        async let a = monitor.checkNow()
        async let b = monitor.checkNow()
        async let c = monitor.checkNow()
        _ = await (a, b, c)

        XCTAssertEqual(session.requestCount, 1, "All callers must share the in-flight probe")
        monitor.stopMonitoring()
    }

    /// A probe cancelled by `stopMonitoring` resumes AFTER a newer probe has taken
    /// the slot. If it cleared `probeTask` unconditionally it would nil the LIVE
    /// handle, and the next `checkNow` would start a second concurrent probe.
    /// Mutation: replace the generation check with a bare `self.probeTask = nil`.
    func testCheckNow_staleProbeResuming_doesNotStealTheLiveSlot() async {
        let session = CountingSession()
        session.statusCode = 200
        session.delay = .milliseconds(400)
        let monitor = LLMStatusMonitor(session: session)

        // Probe A, genuinely in flight (the poll task starts asynchronously, so
        // wait for the request to actually reach the session).
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ session.requestCount == 1 }, timeoutSeconds: 5)

        // Cancel A and immediately install probe B.
        monitor.stopMonitoring()
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ session.requestCount == 2 }, timeoutSeconds: 5)

        // Cancelled A resumes here and tries to clear the slot B now owns.
        try? await Task.sleep(for: .milliseconds(120))
        await monitor.checkNow()

        XCTAssertEqual(
            session.requestCount, 2,
            "checkNow must have coalesced onto B, not started a third probe")
        monitor.stopMonitoring()
    }

    /// The cancelled probe's identity guard returns before clearing the flag, so
    /// the canceller owns it. Mutation: delete `isChecking = false` from
    /// `stopMonitoring` → the picker's footer reads "Checking server…" forever and
    /// `checkNow` is wedged behind a slot nobody clears.
    func testStopMonitoring_midProbe_clearsIsCheckingAndPublishesNothing() async {
        let session = CountingSession()
        session.statusCode = 200
        session.delay = .milliseconds(250)
        let monitor = LLMStatusMonitor(session: session)

        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ monitor.isChecking }, timeoutSeconds: 5)
        XCTAssertTrue(monitor.isChecking, "Probe should be in flight")
        monitor.stopMonitoring()

        XCTAssertFalse(monitor.isChecking, "The canceller must clear the flag")
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertNil(monitor.lastCheckedAt, "A cancelled probe must not publish")
        XCTAssertFalse(monitor.isReachable)
    }

    func testIsChecking_risesDuringProbe_andFallsAfter() async {
        let session = CountingSession()
        session.statusCode = 200
        session.delay = .milliseconds(150)
        let monitor = LLMStatusMonitor(session: session)

        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ monitor.isChecking }, timeoutSeconds: 5)
        XCTAssertTrue(monitor.isChecking, "raised for the duration of the probe")

        await waitUntil({ monitor.lastCheckedAt != nil }, timeoutSeconds: 5)
        XCTAssertFalse(monitor.isChecking, "cleared once the probe published")
        monitor.stopMonitoring()
    }

    /// `checkNow` reads the STORED provider, so a config change between calls is
    /// picked up — the contract `AppDependencyWiring.llmEndpointProvider` relies on.
    func testCheckNow_readsTheLiveEndpointProvider() async {
        let session = CountingSession()
        session.statusCode = 200
        let monitor = LLMStatusMonitor(session: session)
        var host = "http://127.0.0.1:1234"
        monitor.startMonitoring(endpointProvider: { (host, .lmStudio) }, interval: 3600)
        await waitUntil({ monitor.lastCheckedAt != nil }, timeoutSeconds: 5)

        host = "http://127.0.0.1:4321"
        await monitor.checkNow()

        XCTAssertEqual(session.lastRequestedURL?.absoluteString,
                       "http://127.0.0.1:4321/api/v1/models")
        monitor.stopMonitoring()
    }

    /// `stopMonitoring` nils the endpoint, so a later `checkNow` is a no-op rather
    /// than a resurrection of a torn-down monitor.
    func testCheckNow_afterStopMonitoring_isANoOp() async {
        let session = CountingSession()
        session.statusCode = 200
        let monitor = LLMStatusMonitor(session: session)
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ monitor.lastCheckedAt != nil }, timeoutSeconds: 5, "the first probe")
        // Absolute, not a delta off `requestCount`: a relative baseline lets this
        // pass as 0 == 0 if the wait above ever gives up having probed nothing.
        XCTAssertEqual(session.requestCount, 1)

        monitor.stopMonitoring()
        let result = await monitor.checkNow()

        XCTAssertEqual(session.requestCount, 1, "a stopped monitor must not probe")
        XCTAssertTrue(
            result,
            "with no endpoint installed `checkNow` reports the last known state, "
                + "it does not invent a `false` — this is a one-way evidence channel")
    }

    /// Coalescing is only sound against the SAME endpoint. A provider flip rewrites
    /// URL + model with no Test Connection, so a caller arriving inside the probe
    /// window would otherwise inherit a verdict about the server it just left.
    /// Mutation: drop the `probeEndpoint == endpoint` comparison → count stays 1 and
    /// the pill publishes the OLD host's reachability for a host never contacted.
    func testCheckNow_endpointChangedMidProbe_doesNotInheritTheOldVerdict() async {
        let session = CountingSession()
        session.statusCode = 200
        session.delay = .milliseconds(400)
        let monitor = LLMStatusMonitor(session: session)
        var host = "http://127.0.0.1:1234"
        monitor.startMonitoring(endpointProvider: { (host, .lmStudio) }, interval: 3600)
        await waitUntil({ session.requestCount == 1 }, timeoutSeconds: 5, "probe A to start")

        // The endpoint moves while A is still in flight.
        host = "http://127.0.0.1:4321"
        await monitor.checkNow()

        XCTAssertEqual(session.requestCount, 2, "the new endpoint must be probed on its own")
        XCTAssertEqual(session.lastRequestedURL?.absoluteString,
                       "http://127.0.0.1:4321/api/v1/models")
        monitor.stopMonitoring()
    }

    /// The same endpoint still coalesces — the guard must not cost a request per
    /// caller on the common path.
    func testCheckNow_sameEndpointMidProbe_stillCoalesces() async {
        let session = CountingSession()
        session.statusCode = 200
        session.delay = .milliseconds(300)
        let monitor = LLMStatusMonitor(session: session)
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ session.requestCount == 1 }, timeoutSeconds: 5, "the probe to start")

        await monitor.checkNow()

        XCTAssertEqual(session.requestCount, 1)
        monitor.stopMonitoring()
    }

    // MARK: - The two writers of `isReachable`, composed

    /// The picker fires a probe and a model fetch concurrently, and both publish
    /// into one bit. Pin the arbitration: the probe is authoritative for RED, so a
    /// probe landing after positive evidence still turns the pill off.
    func testProbeAfterNoteReachable_canStillTurnItRed() async {
        let session = CountingSession()
        session.statusCode = 500   // unreachable
        let monitor = LLMStatusMonitor(session: session)
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ monitor.lastCheckedAt != nil }, timeoutSeconds: 5, "the first probe")
        XCTAssertFalse(monitor.isReachable)

        monitor.noteReachable()
        XCTAssertTrue(monitor.isReachable)
        await monitor.checkNow()

        XCTAssertFalse(monitor.isReachable, "a probe is authoritative for the red direction")
        monitor.stopMonitoring()
    }

    /// And the other order: evidence arriving after a failed probe wins, which is
    /// the case the feature exists for (a 2 s probe times out, the 5 s model fetch
    /// succeeds — the pill must not sit red beside a populated list).
    func testNoteReachableAfterAFailedProbe_turnsItGreen() async {
        let session = CountingSession()
        session.statusCode = 500
        let monitor = LLMStatusMonitor(session: session)
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ monitor.lastCheckedAt != nil }, timeoutSeconds: 5, "the first probe")
        XCTAssertFalse(monitor.isReachable)

        monitor.noteReachable()

        XCTAssertTrue(monitor.isReachable)
        monitor.stopMonitoring()
    }

    // MARK: - noteReachable: one-way positive evidence

    func testNoteReachable_publishesReachableAndStampsTime() async {
        let monitor = LLMStatusMonitor(session: CountingSession())

        monitor.noteReachable()

        XCTAssertTrue(monitor.isReachable)
        XCTAssertNotNil(monitor.lastCheckedAt)
    }

    /// One-way by construction. A failed model fetch proves nothing (401 =
    /// reachable but unauthorized), so only a probe may turn the pill red.
    /// Mutation: give `noteReachable` a `Bool` parameter and pass `false`.
    func testNoteReachable_cannotTurnReachabilityOff() async {
        let session = CountingSession()
        session.statusCode = 200
        let monitor = LLMStatusMonitor(session: session)
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ monitor.isReachable }, timeoutSeconds: 5)

        monitor.noteReachable()

        XCTAssertTrue(monitor.isReachable)
        monitor.stopMonitoring()
    }

    /// `noteReachable` issues no request — it reports evidence someone else paid for.
    func testNoteReachable_issuesNoRequest() async {
        let session = CountingSession()
        let monitor = LLMStatusMonitor(session: session)

        monitor.noteReachable()

        XCTAssertEqual(session.requestCount, 0)
    }

    // MARK: - noteProbeOutcome: both directions of a foreign probe (Test Connection)

    /// Positive foreign evidence publishes directly, paying for no request — and
    /// works with NO endpoint provider installed. Mutation: route the `true`
    /// branch through `checkNow` (its no-provider guard would no-op and the pill
    /// would stay red).
    func testNoteProbeOutcome_reachable_publishesWithoutARequest() async {
        let session = CountingSession()
        let monitor = LLMStatusMonitor(session: session)

        await monitor.noteProbeOutcome(reachable: true)

        XCTAssertTrue(monitor.isReachable)
        XCTAssertEqual(session.requestCount, 0)
    }

    /// The case the method exists for: a failed Test Connection turns the pill
    /// red within one self-probe instead of holding green until the next poll
    /// tick. Mutation: make the `false` branch a no-op (the pre-fix production
    /// behavior) — the pill stays green and the request count stays at 1.
    func testNoteProbeOutcome_unreachable_probesAndTurnsRed() async {
        let session = CountingSession()
        session.statusCode = 500   // the monitor's own probe fails too
        let monitor = LLMStatusMonitor(session: session)
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        // Let the initial poll probe land first, or the self-probe below would
        // coalesce onto it and the request-count assert would flake.
        await waitUntil({ monitor.lastCheckedAt != nil }, timeoutSeconds: 5, "the first probe")
        XCTAssertFalse(monitor.isReachable)
        monitor.noteReachable()
        XCTAssertTrue(monitor.isReachable, "green precondition — the transition is the point")

        await monitor.noteProbeOutcome(reachable: false)

        XCTAssertFalse(monitor.isReachable, "a failed Test Connection must reach the pill")
        XCTAssertEqual(session.requestCount, 2, "negative evidence pays for a self-probe")
        monitor.stopMonitoring()
    }

    /// Negative foreign evidence is NOT trusted as a verdict: the foreign probe's
    /// bearer token can differ from the Keychain-resolved one the monitor uses,
    /// so when the monitor's OWN probe succeeds the pill stays green. Mutation:
    /// have the `false` branch `publish(false)` directly.
    func testNoteProbeOutcome_unreachable_whenOwnProbeSucceeds_staysGreen() async {
        let session = CountingSession()
        session.statusCode = 200
        let monitor = LLMStatusMonitor(session: session)
        monitor.startMonitoring(endpointProvider: { (self.baseURL, .lmStudio) }, interval: 3600)
        await waitUntil({ monitor.isReachable }, timeoutSeconds: 5)

        await monitor.noteProbeOutcome(reachable: false)

        XCTAssertTrue(monitor.isReachable, "the self-probe is authoritative, not the foreign failure")
        XCTAssertEqual(session.requestCount, 2, "it must PROBE, not silently keep the old verdict")
        monitor.stopMonitoring()
    }

    /// With no endpoint provider (never wired, or stopped), negative evidence has
    /// nothing authoritative to consult — state stays frozen and no request is
    /// issued (`checkNow`'s no-provider guard). Mutation: publish `false` when
    /// the guard trips.
    func testNoteProbeOutcome_unreachable_beforeStartMonitoring_isANoOp() async {
        let session = CountingSession()
        let monitor = LLMStatusMonitor(session: session)
        monitor.noteReachable()

        await monitor.noteProbeOutcome(reachable: false)

        XCTAssertTrue(monitor.isReachable)
        XCTAssertEqual(session.requestCount, 0)
    }

    // MARK: - Helpers

    private let baseURL = "http://127.0.0.1:1234"

    /// Counts probes so coalescing can be asserted as "how many requests reached
    /// the server", not "did the state change".
    private final class CountingSession: NetworkSession, @unchecked Sendable {
        private let lock = NSLock()
        private var _requestCount = 0
        private var _lastRequestedURL: URL?

        var statusCode: Int = 500
        var delay: Duration?

        var requestCount: Int { lock.withLock { _requestCount } }
        var lastRequestedURL: URL? { lock.withLock { _lastRequestedURL } }

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.withLock {
                _requestCount += 1
                _lastRequestedURL = request.url
            }
            if let delay { try? await Task.sleep(for: delay) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    /// Polls `predicate` every 50ms until it returns a non-nil value or the
    /// deadline expires. Replaces the prior unconditional `Task.sleep` waits
    /// for `lastCheckedAt` — the probe completes well under a second on an
    /// invalid port, so the test no longer pays a fixed 3s.
    private func waitUntilNotNil<T>(
        _ predicate: @MainActor () -> T?, timeoutSeconds: Double,
        _ what: String = "value", file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() != nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Returning silently on timeout lets a test that measures a DELTA pass
        // having observed nothing at all (0 == 0). Fail where the wait gave up,
        // not later under an unrelated assertion's message.
        XCTFail("timed out after \(timeoutSeconds)s waiting for \(what)", file: file, line: line)
    }

    private func waitUntil(
        _ predicate: @MainActor () -> Bool, timeoutSeconds: Double,
        _ what: String = "condition", file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out after \(timeoutSeconds)s waiting for \(what)", file: file, line: line)
    }
}
