import XCTest
@testable import NanoTeams

/// Pins `TeamBoardRunControl.select` — which run button the Team Board navbar
/// shows for each engine state. Restores the branch coverage the deleted
/// `WatchtowerQuickActionFactoryTests` had for the old `QuickAction.makeActions`
/// pause/resume/start gating (now living in `TeamBoardTopBar.playPauseControl`).
final class TeamBoardRunControlTests: XCTestCase {

    private func select(_ state: TeamEngineState?, historical: Bool = false) -> TeamBoardRunControl? {
        TeamBoardRunControl.select(engineState: state, isHistoricalRun: historical)
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
}
