import AppKit
import XCTest
@testable import NanoTeams

@MainActor
final class QuickCapturePanelRefocusInputFieldTests: XCTestCase {

    func testRefocusInputField_incrementsInvocationCounter() {
        let panel = QuickCapturePanel()
        XCTAssertEqual(panel._testRefocusInvocationCount, 0)

        panel.refocusInputField()
        XCTAssertEqual(panel._testRefocusInvocationCount, 1)

        panel.refocusInputField()
        panel.refocusInputField()
        XCTAssertEqual(panel._testRefocusInvocationCount, 3,
                       "Counter must increment on every call.")
    }

    /// Dismiss-race: panel never shown → `isVisible == false`. The retry
    /// loop's `provideContentView` must short-circuit so the outcome is
    /// `.cancelled`, not `.exhausted(sawFieldEver: true)`. The latter would
    /// fire `onFocusRestorationFailed` and surface the silent-caret banner.
    ///
    /// An editable `NSTextField` is added so that a missing visibility guard
    /// WOULD find a field and report failure — without the field, an
    /// `.exhausted(sawFieldEver: false)` outcome is also silent for the
    /// `expectsFocusableField: true` path, and the test would pass for the
    /// wrong reason.
    func testRefocusInputField_whenPanelHidden_doesNotFireOnFocusRestorationFailed() async {
        let panel = QuickCapturePanel()
        let field = NSTextField()
        field.isEditable = true
        panel.contentView?.addSubview(field)
        // Do NOT call show() — panel.isVisible stays false.

        let failureExpectation = expectation(description: "onFocusRestorationFailed must NOT fire")
        failureExpectation.isInverted = true
        panel.onFocusRestorationFailed = { failureExpectation.fulfill() }

        panel.refocusInputField()

        // 15 attempts × 16ms ≈ 240ms — wait 400ms to cover the full budget.
        await fulfillment(of: [failureExpectation], timeout: 0.4)
    }

    /// Regression guard for the `show()` → `startFocusRetry` extraction:
    /// the spy must still record the `expectsFocusableField` parameter on
    /// both branches. Pinned at panel level so a panel-only refactor can't
    /// break the wiring silently.
    func testShow_afterRefocusExtraction_stillForwardsExpectsFocusableField() {
        let panel = QuickCapturePanel()

        panel.show(expectsFocusableField: false)
        XCTAssertEqual(panel._testLastShowExpectsFocusableField, false)

        panel.show(expectsFocusableField: true)
        XCTAssertEqual(panel._testLastShowExpectsFocusableField, true)
    }

    /// Positive failure-path: a visible panel whose `makeFirstResponder`
    /// always refuses must fire `onFocusRestorationFailed` exactly once
    /// per `refocusInputField()` call. Symmetric counterpart to the
    /// dismiss-race inverted-expectation test — if a future change always
    /// returns `.cancelled` from the refocus path, this fails.
    func testRefocusInputField_whenMakeFirstResponderRefuses_firesOnFocusRestorationFailed() async {
        let panel = AlwaysRefusingPanel()
        let field = NSTextField()
        field.isEditable = true
        panel.contentView?.addSubview(field)
        panel._testForceIsVisible = true  // bypass dismiss-race guard

        let exp = expectation(description: "onFocusRestorationFailed fires once")
        panel.onFocusRestorationFailed = { exp.fulfill() }

        panel.refocusInputField()

        await fulfillment(of: [exp], timeout: 0.4)
    }

    /// Key-window re-acquire: clicking the sidebar `+` makes the main
    /// NanoTeams window key, so the panel becomes visible-but-not-key.
    /// `makeFirstResponder` succeeds on a non-key panel but the caret won't
    /// blink — user perceives the button as broken. `refocusInputField`
    /// must call `makeKeyAndOrderFront(nil)` first to pull key back.
    /// (`.nonactivatingPanel` style means no app-level activation.)
    func testRefocusInputField_callsMakeKeyAndOrderFront() {
        let panel = KeyWindowSpyPanel()
        XCTAssertEqual(panel.makeKeyAndOrderFrontCallCount, 0)

        panel.refocusInputField()

        XCTAssertEqual(panel.makeKeyAndOrderFrontCallCount, 1,
                       "refocusInputField must re-key the panel — otherwise the caret stays invisible after a repeat `+` press.")
    }

    /// Each refocus must re-key — between spam-taps the user may have
    /// dragged the main window over the panel, or focused another app,
    /// dropping panel's key status. A future "debounce key-window" change
    /// would silently break recovery from those states.
    func testRefocusInputField_spamTap_reKeysEveryTime() {
        let panel = KeyWindowSpyPanel()
        panel.refocusInputField()
        panel.refocusInputField()
        panel.refocusInputField()
        XCTAssertEqual(panel.makeKeyAndOrderFrontCallCount, 3,
                       "Each refocus call must re-key — no implicit debounce.")
    }

    /// Spam-tap concurrency: three rapid `refocusInputField()` calls against
    /// a panel whose `makeFirstResponder` always refuses must NOT fire
    /// `onFocusRestorationFailed` three times — otherwise the user sees the
    /// error banner flicker (it auto-dismisses, but the rapid re-sets stack).
    /// Pre-Task-tracking, each call spawned an independent retry Task that
    /// exhausted independently and all fired the callback.
    func testRefocusInputField_spamTap_coalescesIntoSingleFailureCallback() async {
        let panel = AlwaysRefusingPanel()
        let field = NSTextField()
        field.isEditable = true
        panel.contentView?.addSubview(field)
        panel._testForceIsVisible = true

        let exp = expectation(description: "onFocusRestorationFailed fires at most once")
        exp.expectedFulfillmentCount = 1
        exp.assertForOverFulfill = true
        panel.onFocusRestorationFailed = { exp.fulfill() }

        panel.refocusInputField()
        panel.refocusInputField()
        panel.refocusInputField()

        await fulfillment(of: [exp], timeout: 0.5)
    }
}

/// Test panel that always refuses `makeFirstResponder` so the retry loop
/// exhausts with `sawFieldEver: true`, driving the failure-callback path.
/// Also forces `isVisible` true so refocus's dismiss-race guard doesn't
/// short-circuit before AppKit has a chance to refuse.
private final class AlwaysRefusingPanel: QuickCapturePanel {
    var _testForceIsVisible: Bool = false
    override var isVisible: Bool { _testForceIsVisible || super.isVisible }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool { false }
}

/// Spy panel for the key-window pin: counts `makeKeyAndOrderFront` calls
/// without actually ordering on screen (unit-test runner has no display).
private final class KeyWindowSpyPanel: QuickCapturePanel {
    var makeKeyAndOrderFrontCallCount = 0
    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKeyAndOrderFrontCallCount += 1
        super.makeKeyAndOrderFront(sender)
    }
}
