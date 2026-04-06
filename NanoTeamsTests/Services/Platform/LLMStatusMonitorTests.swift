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
        sut.startMonitoring(baseURLProvider: { "http://127.0.0.1:9" }, interval: 60)

        // Give the initial probe time to complete — check timeout is 2s, invalid port fails fast.
        try? await Task.sleep(for: .seconds(3))

        XCTAssertNotNil(sut.lastCheckedAt, "First poll should have set lastCheckedAt")
        XCTAssertFalse(sut.isReachable, "Invalid port must not report reachable")

        sut.stopMonitoring()
    }

    /// Re-entrant start must cancel the previous task (no leaked poll loop).
    func testStartMonitoring_calledTwice_replacesActiveTask() async {
        sut.startMonitoring(baseURLProvider: { "http://127.0.0.1:9" }, interval: 60)
        sut.startMonitoring(baseURLProvider: { "http://127.0.0.1:10" }, interval: 60)

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
        sut.startMonitoring(baseURLProvider: { "http://127.0.0.1:9" }, interval: 60)
        try? await Task.sleep(for: .seconds(3))
        let frozen = sut.lastCheckedAt

        sut.stopMonitoring()
        try? await Task.sleep(for: .milliseconds(200))

        // No further updates after stop
        XCTAssertEqual(sut.lastCheckedAt, frozen)
    }
}
