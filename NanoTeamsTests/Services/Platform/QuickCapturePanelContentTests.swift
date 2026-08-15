import AppKit
import SwiftUI
import XCTest

@testable import NanoTeams

/// Covers `QuickCapturePanel.setContent(_:)` — the one panel member with no
/// call site anywhere in the test target. Its only production caller is
/// `QuickCaptureController.updatePanelContent`, which always early-returns in
/// tests (`dictation` is nil), so the hosting-view install had never run.
///
/// Nothing here shows a window: the panel is constructed and its `contentView`
/// swapped, but `show(...)` / `makeKeyAndOrderFront` are never called. Every
/// assertion re-checks `isVisible == false`.
@MainActor
final class QuickCapturePanelContentTests: XCTestCase {

    var sut: QuickCapturePanel!

    override func setUp() async throws {
        try await super.setUp()
        sut = QuickCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500))
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    func testSetContent_installsAHostingView() {
        sut.setContent(Text("hello"))

        guard let installed = sut.contentView else {
            return XCTFail("setContent must install a content view.")
        }
        XCTAssertTrue(
            String(describing: type(of: installed)).contains("NSHostingView"),
            "Expected an NSHostingView, got \(type(of: installed))."
        )
        XCTAssertFalse(sut.isVisible, "setContent must not order the panel on screen.")
    }

    func testSetContent_replacingContent_swapsTheInstalledView() {
        sut.setContent(Text("first"))
        let first = sut.contentView
        sut.setContent(Text("second"))
        let second = sut.contentView

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second, "Each setContent must install a fresh hosting view.")
    }

    /// The load-bearing half of `setContent`: `hosting.sizingOptions = []`
    /// together with the user-lock override chain is what stops SwiftUI's
    /// intrinsic content size from driving the window. Without it the
    /// composer's auto-grow measurements feed a preferred size up through
    /// `NSHostingView` and the autosaved frame oscillates (CLAUDE.md #50).
    ///
    /// Asserted behaviourally rather than by reading `sizingOptions` — the
    /// hosting view's generic parameter is unnameable from here, and the frame
    /// is the thing the user actually sees.
    func testSetContent_withOversizedContent_doesNotResizeALockedPanel() {
        sut._testCaptureUserLock(size: NSSize(width: 400, height: 500))
        let before = sut.frame

        sut.setContent(
            VStack {
                ForEach(0..<80, id: \.self) { i in
                    Text("a very long line of content number \(i) that would widen any auto-sizing host")
                }
            }
            .frame(width: 4000, height: 6000)
        )

        XCTAssertEqual(sut.frame, before,
                       "Content intrinsic size must not move a user-locked panel.")
        XCTAssertFalse(sut.isVisible)
    }

    /// Same guarantee on the un-locked path, where the resize decision falls
    /// through to the requested size clamped to the floor. A content swap is
    /// not a resize request at all, so the frame must still be untouched.
    func testSetContent_withNoUserLock_stillLeavesTheFrameAlone() {
        XCTAssertNil(sut._testUserLockedSize, "Precondition: no lock yet.")
        let before = sut.frame

        sut.setContent(Text("x").frame(width: 3000, height: 3000))

        XCTAssertEqual(sut.frame, before)
    }

    /// A degenerate content view must not drag the panel under the resize
    /// floor — sub-floor frames are unrecoverable by drag for this style combo.
    func testSetContent_withZeroSizedContent_keepsThePanelAtOrAboveTheFloor() {
        sut.setContent(Color.clear.frame(width: 0, height: 0))

        XCTAssertGreaterThanOrEqual(sut.frame.width, QuickCapturePanel.panelMinSize.width)
        XCTAssertGreaterThanOrEqual(sut.frame.height, QuickCapturePanel.panelMinSize.height)
    }

    /// `setContent` drops the AppKit first responder (the hosting view is
    /// replaced wholesale) — which is exactly why `showNewTask` follows it with
    /// `panel.refocusInputField()`. Pin that the swap really does clear it, so
    /// the refocus call can't be "optimised away" as redundant.
    func testSetContent_leavesNoStaleFirstResponderFromThePreviousContent() {
        sut.setContent(Text("first"))
        let stale = sut.contentView
        sut.setContent(Text("second"))

        XCTAssertFalse(sut.firstResponder === stale,
                       "The replaced hosting view must not remain first responder.")
        XCTAssertFalse(sut.isVisible)
    }
}
