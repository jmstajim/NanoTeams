import XCTest
import SwiftUI
@testable import NanoTeams

/// Pins the shared `TeamEngineState.display` descriptor — the single source of
/// truth for the Team Board navbar badge (`TeamBoardTopBar`) and the
/// delegation-layer graph pills (`GraphPanelView`). Before extraction the two
/// hardcoded their own mappings and diverged (running=info vs success,
/// needsSupervisorInput=gold vs warning, done=success vs textSecondary).
final class TeamEngineStateDisplayTests: XCTestCase {

    func testGlyphAndLabel_perState() {
        XCTAssertEqual(TeamEngineState.display(for: .running).glyph, TerminalGlyph.working)
        XCTAssertEqual(TeamEngineState.display(for: .running).label, "working")
        XCTAssertEqual(TeamEngineState.display(for: .paused).label, "paused")
        XCTAssertEqual(TeamEngineState.display(for: .needsAcceptance).label, "review")
        XCTAssertEqual(TeamEngineState.display(for: .needsSupervisorInput).label, "needs input")
        XCTAssertEqual(TeamEngineState.display(for: .done).label, "done")
        XCTAssertEqual(TeamEngineState.display(for: .failed).label, "failed")
        XCTAssertEqual(TeamEngineState.display(for: .pending).label, "idle")
    }

    func testNil_resolvesToIdle() {
        let d = TeamEngineState.display(for: nil)
        XCTAssertEqual(d.label, "idle")
        XCTAssertEqual(d.glyph, TerminalGlyph.idle)
    }

    func testChatMode_swapsOnlyRunningLabel() {
        XCTAssertEqual(TeamEngineState.display(for: .running, isChatMode: true).label, "chat")
        XCTAssertEqual(TeamEngineState.display(for: .running, isChatMode: false).label, "working")
        // isChatMode must not affect any other state's label.
        XCTAssertEqual(TeamEngineState.display(for: .paused, isChatMode: true).label, "paused")
        XCTAssertEqual(TeamEngineState.display(for: .needsSupervisorInput, isChatMode: true).label, "needs input")
    }

    /// The point of the shared extension: colors match the established
    /// TaskStatus/StepStatus semantic palette, so the navbar and graph agree.
    func testColors_matchCanonicalSemantics() {
        XCTAssertSameColor(TeamEngineState.display(for: .running).color, Colors.info)
        XCTAssertSameColor(TeamEngineState.display(for: .paused).color, Colors.warning)
        XCTAssertSameColor(TeamEngineState.display(for: .needsAcceptance).color, Colors.purple)
        XCTAssertSameColor(TeamEngineState.display(for: .needsSupervisorInput).color, Colors.gold)
        XCTAssertSameColor(TeamEngineState.display(for: .done).color, Colors.success)
        XCTAssertSameColor(TeamEngineState.display(for: .failed).color, Colors.error)
    }

    /// Consistency pin: the engine-state color must resolve to the SAME value as
    /// the corresponding `TaskStatus` token, proving one shared semantic.
    func testColors_consistentWithTaskStatus() {
        XCTAssertSameColor(TeamEngineState.display(for: .running).color, TaskStatus.running.tintColor)
        XCTAssertSameColor(TeamEngineState.display(for: .failed).color, TaskStatus.failed.tintColor)
        XCTAssertSameColor(TeamEngineState.display(for: .needsSupervisorInput).color,
                           TaskStatus.needsSupervisorInput.tintColor)
    }
}
