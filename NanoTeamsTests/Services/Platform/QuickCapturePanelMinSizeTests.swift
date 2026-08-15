import AppKit
import XCTest

@testable import NanoTeams

/// Pins the Quick Capture panel resize floor. The clamp is read by
/// `windowWillResize`, `windowDidResize`, and every overridden `setFrame` /
/// `setContentSize` site — `QuickCapturePanel.panelMinSize` is the single
/// source of truth. These tests guarantee the contract so a future tweak
/// to the constant cannot silently drift the floor across the various
/// resize paths.
@MainActor
final class QuickCapturePanelMinSizeTests: XCTestCase {

    var sut: QuickCapturePanel!

    /// Convenience aliases so tests read against the production constant
    /// rather than a hardcoded literal — keeps the file from needing edits
    /// every time the floor moves.
    private var floor: NSSize { QuickCapturePanel.panelMinSize }
    private var floorW: CGFloat { QuickCapturePanel.panelMinSize.width }
    private var floorH: CGFloat { QuickCapturePanel.panelMinSize.height }

    override func setUp() async throws {
        try await super.setUp()
        sut = QuickCapturePanel()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - clampSize

    func testClampSize_raisesBothDimensions_whenBelowFloor() {
        let clamped = sut._testClampSize(NSSize(width: 1, height: 1))
        XCTAssertEqual(clamped, floor)
    }

    func testClampSize_raisesHeightOnly_whenWidthAboveFloor() {
        let wide = floorW + 50
        let clamped = sut._testClampSize(NSSize(width: wide, height: 1))
        XCTAssertEqual(clamped, NSSize(width: wide, height: floorH))
    }

    func testClampSize_raisesWidthOnly_whenHeightAboveFloor() {
        let tall = floorH + 50
        let clamped = sut._testClampSize(NSSize(width: 1, height: tall))
        XCTAssertEqual(clamped, NSSize(width: floorW, height: tall))
    }

    func testClampSize_isNoop_whenBothAboveFloor() {
        let input = NSSize(width: floorW + 250, height: floorH + 250)
        XCTAssertEqual(sut._testClampSize(input), input)
    }

    func testClampSize_handlesZero() {
        XCTAssertEqual(sut._testClampSize(.zero), floor)
    }

    func testClampSize_atFloor_isUnchanged() {
        XCTAssertEqual(sut._testClampSize(floor), floor)
    }

    // MARK: - clampRect

    func testClampRect_preservesOrigin_whenSizeClamped() {
        let input = NSRect(x: 50, y: 75, width: 1, height: 1)
        let clamped = sut._testClampRect(input)
        XCTAssertEqual(clamped.origin, input.origin, "origin must not move")
        XCTAssertEqual(clamped.size, floor)
    }

    func testClampRect_isNoop_whenAboveFloor() {
        let input = NSRect(
            x: 100, y: 100,
            width: floorW + 150, height: floorH + 150
        )
        XCTAssertEqual(sut._testClampRect(input), input)
    }

    // MARK: - Configured floor matches contract

    func testMinSize_isAtLeastPanelMinSize() {
        // Direct read of the AppKit property. If a future change drops
        // `minSize` below `panelMinSize`, live-resize stops honoring the
        // contract — this pin catches that.
        XCTAssertGreaterThanOrEqual(sut.minSize.width, floorW)
        XCTAssertGreaterThanOrEqual(sut.minSize.height, floorH)
    }

    func testContentMinSize_isAtLeastPanelMinSize() {
        XCTAssertGreaterThanOrEqual(sut.contentMinSize.width, floorW)
        XCTAssertGreaterThanOrEqual(sut.contentMinSize.height, floorH)
    }

    // MARK: - Resilience to AppKit minSize reset

    func testMinSize_remainsAtFloor_evenAfterExternalReset() {
        // Observed in production: ~2.5s after panel show, AppKit zeroes out
        // `minSize`/`contentMinSize` for the `.nonactivatingPanel + .titled +
        // .fullSizeContentView` style combo. The override must clamp back to
        // the floor so live-resize keeps respecting it.
        sut.minSize = .zero
        XCTAssertGreaterThanOrEqual(sut.minSize.width, floorW)
        XCTAssertGreaterThanOrEqual(sut.minSize.height, floorH)
    }

    func testContentMinSize_remainsAtFloor_evenAfterExternalReset() {
        sut.contentMinSize = .zero
        XCTAssertGreaterThanOrEqual(sut.contentMinSize.width, floorW)
        XCTAssertGreaterThanOrEqual(sut.contentMinSize.height, floorH)
    }

    func testClampSize_usesConstantFloor_notMutableMinSizeProperty() {
        // Even if `minSize` is somehow zeroed (despite our property override),
        // `clampSize` reads the static constant, not the property — so
        // `windowWillResize`/`windowDidResize`/`setFrame` overrides keep working.
        sut.minSize = .zero
        XCTAssertEqual(sut._testClampSize(NSSize(width: 1, height: 1)), floor)
    }

    // MARK: - User lock capture (windowDidEndLiveResize path)

    func testCaptureUserLock_clampsSubFloorSizeToFloor() {
        // If AppKit zeros `super.minSize` mid-drag, `frame.size` at drag-end
        // can be sub-floor. The capture path must clamp so the lock can't
        // pin the panel below the floor on subsequent shows.
        sut._testCaptureUserLock(size: NSSize(width: 1, height: 1))
        XCTAssertEqual(sut._testUserLockedSize, floor)
    }

    func testCaptureUserLock_aboveFloor_storesAsIs() {
        let above = NSSize(width: floorW + 100, height: floorH + 200)
        sut._testCaptureUserLock(size: above)
        XCTAssertEqual(sut._testUserLockedSize, above)
    }

    func testCaptureUserLock_atFloor_storesFloor() {
        sut._testCaptureUserLock(size: floor)
        XCTAssertEqual(sut._testUserLockedSize, floor)
    }
}
