import AppKit
import XCTest
@testable import NanoTeams

/// Behavioral tests for `QuickCapturePanel.runFocusRetry` — the loop that
/// drives the focus-restoration retry after `makeKeyAndOrderFront`. The
/// pure-decision step (`FocusRetryDecision.step`) is already pinned by
/// `QuickCapturePanelFocusRetryDecisionTests`; this suite exercises the loop
/// composition: layout-force per attempt, sleep between attempts, cancellation
/// short-circuits, and final outcome classification.
///
/// Dependencies are injected so we don't need a real NSPanel / NSHostingView.
@MainActor
final class QuickCapturePanelFocusRetryLoopTests: XCTestCase {

    // MARK: - Test Doubles

    private func makeEditableField() -> NSTextField {
        let field = NSTextField()
        field.isEditable = true
        return field
    }

    // MARK: - Happy Path

    func testRunFocusRetry_focusesFieldOnFirstAttempt_returnsSuccess() async {
        let contentView = NSView()
        let field = makeEditableField()
        contentView.addSubview(field)

        var layoutCalls = 0
        var responderCalls = 0
        var sleepCalls = 0

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 5,
            provideContentView: { contentView },
            layoutForce: { _ in layoutCalls += 1 },
            makeFirstResponder: { _ in responderCalls += 1; return .accepted },
            sleep: { sleepCalls += 1 },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(layoutCalls, 1, "Layout forced exactly once on the successful attempt")
        XCTAssertEqual(responderCalls, 1, "makeFirstResponder called exactly once on success")
        XCTAssertEqual(sleepCalls, 0, "No sleep on first-attempt success")
    }

    func testRunFocusRetry_findsButRefusedTwice_thenSucceeds() async {
        let contentView = NSView()
        let field = makeEditableField()
        contentView.addSubview(field)

        var responderCalls = 0
        var sleepCalls = 0

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 5,
            provideContentView: { contentView },
            layoutForce: { _ in },
            makeFirstResponder: { _ in
                responderCalls += 1
                return responderCalls >= 3 ? .accepted : .refused  // refuse first two, accept third
            },
            sleep: { sleepCalls += 1 },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(responderCalls, 3)
        XCTAssertEqual(sleepCalls, 2, "Sleep fires between attempts, not after success")
    }

    // MARK: - Exhaustion

    func testRunFocusRetry_neverFindsField_returnsExhaustedWithSawFieldFalse() async {
        let contentView = NSView()  // empty subtree

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 3,
            provideContentView: { contentView },
            layoutForce: { _ in },
            makeFirstResponder: { _ in .accepted },  // unreachable
            sleep: { },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .exhausted(sawFieldEver: false))
    }

    func testRunFocusRetry_findsButAlwaysRefused_returnsExhaustedWithSawFieldTrue() async {
        let contentView = NSView()
        contentView.addSubview(makeEditableField())

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 3,
            provideContentView: { contentView },
            layoutForce: { _ in },
            makeFirstResponder: { _ in .refused },  // always refused
            sleep: { },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .exhausted(sawFieldEver: true))
    }

    func testRunFocusRetry_fieldAppearsMidLoop_thenStaysRefused_reportsSawFieldTrue() async {
        // Field is added before attempt 2; mock makeFirstResponder refuses
        // throughout. Loop should exhaust with sawFieldEver=true so the caller
        // surfaces the silent-caret banner.
        let contentView = NSView()
        var attempts = 0

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 4,
            provideContentView: {
                if attempts == 2 { contentView.addSubview(self.makeEditableField()) }
                attempts += 1
                return contentView
            },
            layoutForce: { _ in },
            makeFirstResponder: { _ in .refused },
            sleep: { },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .exhausted(sawFieldEver: true))
    }

    // MARK: - Cancellation

    func testRunFocusRetry_contentViewGoesNil_returnsCancelled() async {
        var lookupCount = 0

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 5,
            provideContentView: { () -> NSView? in
                lookupCount += 1
                return lookupCount == 1 ? nil : NSView()  // nil on first lookup
            },
            layoutForce: { _ in },
            makeFirstResponder: { _ in .accepted },
            sleep: { },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(lookupCount, 1, "Loop exits immediately on nil contentView, no further iterations")
    }

    func testRunFocusRetry_isCancelledFlagFires_returnsCancelled() async {
        let contentView = NSView()  // no field, would force retry path
        var iterations = 0

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 10,
            provideContentView: { contentView },
            layoutForce: { _ in iterations += 1 },
            makeFirstResponder: { _ in .refused },
            sleep: { },
            isCancelled: { iterations >= 2 }  // cancel after second iteration completes
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(iterations, 10, "Loop short-circuits before exhausting")
    }

    // MARK: - ResponderResult semantics

    /// When `makeFirstResponder` returns `.cancelled` (the wrapping `[weak self]`
    /// closure observed a dead panel), the outcome must be `.cancelled`, not
    /// `.exhausted(sawFieldEver: true)`. Pre-fix: closure returned `false` for
    /// dead-self → flowed through `focusSucceeded: false` while `foundField: true`
    /// → on the final attempt produced `.exhausted(sawFieldEver: true)` →
    /// `onFocusRestorationFailed` fired on a panel that no longer exists.
    func testRunFocusRetry_makeFirstResponderReturnsCancelled_returnsCancelled() async {
        let contentView = NSView()
        contentView.addSubview(makeEditableField())

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 5,
            provideContentView: { contentView },
            layoutForce: { _ in },
            makeFirstResponder: { _ in .cancelled },  // dead-self signal
            sleep: { },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .cancelled)
    }

    /// Mid-loop cancellation: after some `.refused` attempts the panel gets
    /// torn down. The next `makeFirstResponder` call returns `.cancelled`
    /// and the loop must exit `.cancelled` (not `.exhausted(sawFieldEver: true)`,
    /// which would fire the silent-caret banner on a dead panel).
    func testRunFocusRetry_makeFirstResponderReturnsCancelledOnLaterAttempt_returnsCancelled() async {
        let contentView = NSView()
        contentView.addSubview(makeEditableField())
        var responderCalls = 0

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 10,
            provideContentView: { contentView },
            layoutForce: { _ in },
            makeFirstResponder: { _ in
                responderCalls += 1
                return responderCalls >= 3 ? .cancelled : .refused
            },
            sleep: { },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(responderCalls, 3, "Loop must exit on first .cancelled, not exhaust")
    }

    // MARK: - Edge Cases

    func testRunFocusRetry_zeroAttempts_returnsExhaustedImmediately() async {
        var anyCall = false

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 0,
            provideContentView: { anyCall = true; return NSView() },
            layoutForce: { _ in anyCall = true },
            makeFirstResponder: { _ in anyCall = true; return .accepted },
            sleep: { anyCall = true },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .exhausted(sawFieldEver: false))
        XCTAssertFalse(anyCall, "Zero-attempts loop runs no iterations and invokes no dependencies")
    }

    /// Boundary case: cancellation must win over exhaustion when `.cancelled`
    /// is received on the FINAL attempt. The `respondResult == .cancelled`
    /// check runs BEFORE the `FocusRetryDecision.step` classifier, so even at
    /// `attempt == maxAttempts - 1` the outcome must be `.cancelled` rather
    /// than `.exhausted(sawFieldEver: true)`.
    func testRunFocusRetry_cancelledAtFinalAttempt_returnsCancelledNotExhausted() async {
        let contentView = NSView()
        contentView.addSubview(makeEditableField())
        var attempt = 0

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 3,
            provideContentView: { contentView },
            layoutForce: { _ in },
            makeFirstResponder: { _ in
                attempt += 1
                return attempt < 3 ? .refused : .cancelled
            },
            sleep: { },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .cancelled)
    }

    // MARK: - Outcome → Banner Routing

    /// `.exhausted(sawFieldEver: false)` is ambiguous: either the panel is in
    /// loader-only working mode (legitimate, silent OK) or the form is broken
    /// (real silent-caret regression). The caller's mode is the disambiguator —
    /// `expectsFocusableField: true` for overlay/answer/chat-working,
    /// `false` for plain working-mode. The routing rule lives on
    /// `FocusRetryOutcome` per GRASP Information Expert.

    func testOutcomeShouldReportFailure_success_neverReports() {
        XCTAssertFalse(QuickCapturePanel.FocusRetryOutcome.success.shouldReportFailure(expectsFocusableField: true))
        XCTAssertFalse(QuickCapturePanel.FocusRetryOutcome.success.shouldReportFailure(expectsFocusableField: false))
    }

    func testOutcomeShouldReportFailure_cancelled_neverReports() {
        XCTAssertFalse(QuickCapturePanel.FocusRetryOutcome.cancelled.shouldReportFailure(expectsFocusableField: true))
        XCTAssertFalse(QuickCapturePanel.FocusRetryOutcome.cancelled.shouldReportFailure(expectsFocusableField: false))
    }

    func testOutcomeShouldReportFailure_exhaustedSawFieldTrue_alwaysReports() {
        // Field was found but AppKit refused — this is the silent-caret bug.
        // Always surface to the user regardless of expected-field flag.
        XCTAssertTrue(QuickCapturePanel.FocusRetryOutcome.exhausted(sawFieldEver: true).shouldReportFailure(expectsFocusableField: true))
        XCTAssertTrue(QuickCapturePanel.FocusRetryOutcome.exhausted(sawFieldEver: true).shouldReportFailure(expectsFocusableField: false))
    }

    func testOutcomeShouldReportFailure_exhaustedSawFieldFalse_reportsOnlyWhenExpected() {
        // No field ever appeared — legitimate for loader-only working mode.
        // Only report when caller said it expected one.
        XCTAssertTrue(QuickCapturePanel.FocusRetryOutcome.exhausted(sawFieldEver: false).shouldReportFailure(expectsFocusableField: true))
        XCTAssertFalse(QuickCapturePanel.FocusRetryOutcome.exhausted(sawFieldEver: false).shouldReportFailure(expectsFocusableField: false))
    }

    // MARK: - Edge Cases — single attempt

    func testRunFocusRetry_singleAttempt_findsAndFocuses_returnsSuccess() async {
        let contentView = NSView()
        contentView.addSubview(makeEditableField())

        let outcome = await QuickCapturePanel.runFocusRetry(
            maxAttempts: 1,
            provideContentView: { contentView },
            layoutForce: { _ in },
            makeFirstResponder: { _ in .accepted },
            sleep: { },
            isCancelled: { false }
        )

        XCTAssertEqual(outcome, .success)
    }
}
