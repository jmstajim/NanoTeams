import AppKit
import XCTest

@testable import NanoTeams

/// Pins the no-animation contract on `QuickCapturePanel`. The panel is built
/// for instant show/hide — `show(expectsFocusableField:)` and `hide()` perform
/// no `NSAnimationContext` work, and the AppKit-level default fade is disabled
/// at init via `animationBehavior = .none`. A future tweak that re-introduces
/// fade (whether through explicit animation blocks or by flipping the behavior
/// flag to `.default`/`.utilityWindow`) trips this pin.
@MainActor
final class QuickCapturePanelAnimationInvariantTests: XCTestCase {

    var sut: QuickCapturePanel!

    override func setUp() async throws {
        try await super.setUp()
        sut = QuickCapturePanel()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    func testPanel_animationBehavior_isNoneAtInit() {
        XCTAssertEqual(sut.animationBehavior, .none,
                       "AppKit's default window-appearance fade must stay disabled. Re-enabling it would surface as a perceived 'appearance animation' even though no NSAnimationContext block exists in show/hide.")
    }

    func testHide_doesNotMutateAlphaValue() {
        // Pre-set a non-default value so this test actually exercises "no
        // mutation" — `NSWindow.alphaValue` defaults to 1.0, so asserting
        // `== 1` after pre-setting `= 1` would tautologically pass even if
        // `hide()` defensively reset alpha. The arbitrary 0.37 is mid-fade-like
        // — a defensive reset to 1 or a fade to 0 would both mutate this value.
        sut.alphaValue = 0.37
        sut.hide()
        XCTAssertEqual(sut.alphaValue, 0.37, accuracy: 0.0001,
                       "`hide()` must not touch alpha — there's no fade in either direction.")
    }

    func testPanel_animationBehavior_staysNoneAfterShowHideCycle() {
        // Defends against a future AppKit path (e.g. becomeKey, certain style
        // mask flips, orderOut+orderFront cycles) that could implicitly re-arm
        // `animationBehavior`. The init-only pin would miss such regressions.
        sut.show(expectsFocusableField: true)
        sut.hide()
        XCTAssertEqual(sut.animationBehavior, .none)
    }
}
