import AppKit
import XCTest

@testable import NanoTeams

/// Pins how `QuickCapturePanel.cancelOperation` (AppKit's Escape-key route)
/// dispatches.
///
/// Background: SwiftUI's `.background { Button("", action: handleCancel).keyboardShortcut(.cancelAction).hidden() }`
/// pattern in `QuickCaptureFormView.taskCreationBody` previously caught Escape
/// to dispatch `cancelDraft` (cleanup of staged attachments + form reset). The
/// SwiftUI hidden-Button wrapper sat as a `.background` ViewBuilder around the
/// scrolling representable, which made it participate in every CoreAnimation
/// frame the inner NSScrollView emitted during trackpad-scroll — exactly the
/// failure mode catalogued in CLAUDE.md Swift Style #50 (background as
/// ViewBuilder ancestor → per-frame re-evaluation).
///
/// The fix moves Escape handling to the panel host: `cancelOperation` fires
/// the wired `onCancelKeyPressed` callback (which `QuickCaptureController`
/// hooks to its `cancelDraft()`), and falls back to plain `orderOut(_:)` when
/// no callback is wired (panel used in a context that doesn't own a draft).
@MainActor
final class QuickCapturePanelCancelOperationTests: XCTestCase {

    var sut: QuickCapturePanel!

    override func setUp() async throws {
        try await super.setUp()
        sut = QuickCapturePanel()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    /// When a host wires `onCancelKeyPressed`, Escape (cancelOperation) must
    /// route through it instead of going straight to `orderOut`. The host owns
    /// dismissal — see `QuickCaptureController.cancelDraft`, which performs
    /// the staged-draft cleanup BEFORE calling `dismissPanel`.
    func testCancelOperation_callsOnCancelKeyPressed_whenWired() {
        var didFire = false
        sut.onCancelKeyPressed = { didFire = true }

        sut.cancelOperation(nil)

        XCTAssertTrue(didFire, "cancelOperation must invoke the wired onCancelKeyPressed callback so the controller can clean up the staged draft before dismissal.")
    }

    /// When `onCancelKeyPressed` is NOT wired, fall back to the legacy
    /// `orderOut(_:)` behavior so contexts that don't own a draft (tests,
    /// previews) still get Escape-to-close.
    func testCancelOperation_callsOrderOut_whenCallbackNotWired() {
        // Make the panel visible so `orderOut` has something to undo.
        sut.orderFront(nil)
        XCTAssertTrue(sut.isVisible, "Precondition: panel must be visible for the orderOut assertion to be meaningful.")

        sut.cancelOperation(nil)

        XCTAssertFalse(sut.isVisible, "Without an onCancelKeyPressed callback, cancelOperation must fall back to orderOut so Escape still closes the panel.")
    }

    /// Wiring an `onCancelKeyPressed` callback intentionally bypasses
    /// `orderOut` — the controller is now responsible for invoking
    /// `dismissPanel` as part of its cancel flow. Without this contract, the
    /// callback would race with `orderOut` and the panel could close before
    /// `cancelDraft` finishes its synchronous cleanup.
    func testCancelOperation_whenCallbackWired_doesNotCallOrderOut() {
        sut.orderFront(nil)
        XCTAssertTrue(sut.isVisible, "Precondition: panel must be visible.")
        sut.onCancelKeyPressed = { /* host owns dismissal */ }

        sut.cancelOperation(nil)

        XCTAssertTrue(sut.isVisible, "When onCancelKeyPressed is wired, cancelOperation must NOT call orderOut — the host's callback owns dismissal.")
    }
}
