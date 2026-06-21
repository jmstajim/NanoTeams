import AppKit
import XCTest
@testable import NanoTeams

/// Pins the QuickCapture panel's window chrome after the CLAUDE.md #50 fix.
///
/// The panel previously rounded its corners by setting `masksToBounds = true`
/// + `cornerRadius` on the AppKit theme-frame layer — an ancestor of the hosted
/// composer `NSScrollView`, which forces a per-CA-frame offscreen mask pass
/// (the #50 scroll-lag trap). The fix removed that mask: the window background
/// is now `.clear` and the 4pt rounding is painted by the SwiftUI content's own
/// non-clipping rounded `.fill` background. These assertions guard the
/// window-level half of that contract (a revert to an opaque background or a
/// re-introduced layer mask would change these).
@MainActor
final class QuickCapturePanelChromeTests: XCTestCase {

    var sut: QuickCapturePanel!

    override func setUp() {
        super.setUp()
        sut = QuickCapturePanel()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    /// Clear window background — the rounded SwiftUI fill shows through; the
    /// corners outside the rounded rect stay transparent (so they read rounded,
    /// not square-opaque). A revert to `NSColor(Colors.surfacePrimary)` would
    /// paint the corners square.
    func testBackgroundColor_isClear() {
        XCTAssertEqual(sut.backgroundColor, .clear)
    }

    /// Non-opaque so the transparent corners + shadow render correctly.
    func testPanel_isNotOpaque() {
        XCTAssertFalse(sut.isOpaque)
    }

    /// Shadow stays on — it follows the rounded opaque content region.
    func testPanel_hasShadow() {
        XCTAssertTrue(sut.hasShadow)
    }
}
