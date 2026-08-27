import XCTest
@testable import NanoTeams

/// Pins `TeamBoardRunControl.select` — which run button the Team Board navbar
/// shows for each engine state. Restores the branch coverage the deleted
/// `WatchtowerQuickActionFactoryTests` had for the old `QuickAction.makeActions`
/// pause/resume/start gating (now living in `TeamBoardTopBar.playPauseControl`).
final class TeamBoardRunControlTests: XCTestCase {

    private func select(
        _ state: TeamEngineState?, historical: Bool = false, initializing: Bool = false
    ) -> TeamBoardRunControl? {
        TeamBoardRunControl.select(
            engineState: state, isHistoricalRun: historical, isInitializingRun: initializing)
    }

    // MARK: - Live run: every state maps to the right control

    func testRunning_showsPause() {
        XCTAssertEqual(select(.running), .pause)
    }

    func testNeedsSupervisorInput_showsPause() {
        // A run parked for Supervisor input is still active — can be paused.
        XCTAssertEqual(select(.needsSupervisorInput), .pause)
    }

    func testNeedsAcceptance_showsPause() {
        XCTAssertEqual(select(.needsAcceptance), .pause)
    }

    func testPaused_showsResume() {
        XCTAssertEqual(select(.paused), .resume)
    }

    func testPending_showsStart() {
        XCTAssertEqual(select(.pending), .start)
    }

    func testNilState_showsStart() {
        // No engine yet (never started / torn down) → offer Start.
        XCTAssertEqual(select(nil), .start)
    }

    func testDone_showsNothing() {
        XCTAssertNil(select(.done))
    }

    func testFailed_showsNothing() {
        XCTAssertNil(select(.failed))
    }

    // MARK: - Historical run: never shows a control

    /// A historical (read-only) run is the strongest guard — it must suppress the
    /// control for EVERY engine state, including the otherwise-actionable ones.
    func testHistoricalRun_suppressesControlForEveryState() {
        for state in TeamEngineState.allCases {
            XCTAssertNil(select(state, historical: true),
                         "historical run must show no run button for \(state.rawValue)")
        }
        XCTAssertNil(select(nil, historical: true),
                     "historical run must show no run button for a nil engine state")
    }

    /// Sanity: the live path is NOT universally suppressed (guards against a
    /// `select` that always returns nil regardless of `isHistoricalRun`).
    func testLiveRun_isNotUniversallySuppressed() {
        XCTAssertNotNil(select(.running, historical: false))
        XCTAssertNotNil(select(.paused, historical: false))
        XCTAssertNotNil(select(.pending, historical: false))
    }

    // MARK: - A run start in flight

    /// The window between the Supervisor pressing Send / Play and `engine.start()`. No
    /// engine exists yet, so the mirror reads `nil` and the navbar used to offer `start`
    /// — an action `claimRunStart` then refused in silence, on a run that was already
    /// starting. `pause` is the honest control: it aborts the start.
    ///
    /// RED: drop the `isInitializingRun` branch from `select` → this fails; every other
    /// test in this file stays green, because none of them passes the flag.
    func testInitializing_withNoEngineYet_showsPause() {
        XCTAssertEqual(select(nil, initializing: true), .pause)
        XCTAssertEqual(select(.pending, initializing: true), .pause,
                       "`.pending` is the engineless state too — an engine object that has "
                           + "not started is not a run in progress")
    }

    /// The control, and the reason the branch is scoped to the engineless states: the two
    /// facts overlap by a tick (CLAUDE.md #95), and where they disagree the ENGINE is the
    /// better answer. A flag that overrode `.needsAcceptance` or `.paused` would replace a
    /// meaningful control with the same word or the wrong one.
    func testInitializing_neverOverridesALiveEngineState() {
        XCTAssertEqual(select(.paused, initializing: true), .resume,
                       "A paused run still resumes — the stale claim must not hijack it")
        XCTAssertEqual(select(.needsAcceptance, initializing: true), .pause)
        XCTAssertNil(select(.done, initializing: true),
                     "Terminal stays terminal: a leftover claim must not resurrect a control")
        XCTAssertNil(select(.failed, initializing: true))
    }

    /// A historical run outranks everything, this flag included.
    func testInitializing_isStillSuppressedOnAHistoricalRun() {
        XCTAssertNil(select(nil, historical: true, initializing: true))
    }
}
