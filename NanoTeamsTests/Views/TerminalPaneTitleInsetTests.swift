import SwiftUI
import XCTest
@testable import NanoTeams

/// The `┤ TITLE ├` chip straddles the pane's top border by its CENTRE, so a trailing control
/// taller than the 10 pt label (a `SettingsPillButton` — Add agent, Copy) hangs further into the
/// content than the label alone does. The pane pushes its content down by exactly that extra, and
/// by nothing else: a text-only chip — nearly every pane — must keep its layout (2026-11-08,
/// the AGENTS / CLIENT CONFIGURATION cards, whose first line touched the pill).
final class TerminalPaneTitleInsetTests: XCTestCase {

    func testNoTrailingControl_addsNothing() {
        XCTAssertEqual(TerminalPane<EmptyView>.trailingOverhang(titleHeight: 12, trailingHeight: 0), 0)
    }

    func testTrailingAsTallAsTitle_addsNothing() {
        XCTAssertEqual(TerminalPane<EmptyView>.trailingOverhang(titleHeight: 12, trailingHeight: 12), 0)
    }

    func testTrailingShorterThanTitle_addsNothing() {
        // An inline glyph smaller than the label stays inside the label's own overhang.
        XCTAssertEqual(TerminalPane<EmptyView>.trailingOverhang(titleHeight: 12, trailingHeight: 8), 0)
    }

    func testTallerTrailing_addsHalfTheDifference() {
        // Centred on the border, a chip grows equally up and down: only the lower half is in the
        // content's way.
        XCTAssertEqual(TerminalPane<EmptyView>.trailingOverhang(titleHeight: 12, trailingHeight: 24), 6)
    }

    func testBeforeFirstMeasurement_addsNothing() {
        // Both heights start at zero until `onGeometryChange` reports.
        XCTAssertEqual(TerminalPane<EmptyView>.trailingOverhang(titleHeight: 0, trailingHeight: 0), 0)
    }

    func testTrailingMeasuredBeforeTitle_isBounded() {
        // The two measurements arrive separately; a trailing height reported first must not
        // produce an inset larger than the control's own lower half.
        XCTAssertEqual(TerminalPane<EmptyView>.trailingOverhang(titleHeight: 0, trailingHeight: 24), 12)
    }
}
