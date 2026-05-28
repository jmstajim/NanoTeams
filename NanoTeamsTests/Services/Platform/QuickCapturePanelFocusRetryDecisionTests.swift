import XCTest
@testable import NanoTeams

/// Pins the pure decision logic that drives `QuickCapturePanel.show(expectsFocusableField:)`'s
/// focus-restoration retry loop. The loop must:
///  1. Stop on the first successful `makeFirstResponder` (Bool == true).
///  2. Keep retrying when a field was found but AppKit refused it
///     (this was the silent-caret bug: a `false` return was being treated
///     as success and exited the loop).
///  3. After exhausting all attempts, report whether a focusable field was
///     ever seen — so the caller can distinguish:
///       - `.exhausted(sawFieldEver: false)` — expected for working-mode
///         panel (only a loader, no field). Fall back silently.
///       - `.exhausted(sawFieldEver: true)` — real silent-focus failure.
///         Surface to the user.
final class QuickCapturePanelFocusRetryDecisionTests: XCTestCase {

    private let max = 5

    func testFoundAndFocused_immediately_returnsSuccess() {
        let step = QuickCapturePanel.FocusRetryDecision.step(
            attempt: 0, maxAttempts: max,
            sawFieldEver: false, foundField: true, focusSucceeded: true
        )
        XCTAssertEqual(step, .success)
    }

    func testFoundButRefused_midLoop_continuesToRetry() {
        let step = QuickCapturePanel.FocusRetryDecision.step(
            attempt: 0, maxAttempts: max,
            sawFieldEver: false, foundField: true, focusSucceeded: false
        )
        XCTAssertEqual(step, .retry)
    }

    func testNoField_midLoop_continuesToRetry() {
        let step = QuickCapturePanel.FocusRetryDecision.step(
            attempt: 2, maxAttempts: max,
            sawFieldEver: false, foundField: false, focusSucceeded: false
        )
        XCTAssertEqual(step, .retry)
    }

    func testFoundButRefused_onLastAttempt_exhaustsWithSawFieldTrue() {
        let step = QuickCapturePanel.FocusRetryDecision.step(
            attempt: max - 1, maxAttempts: max,
            sawFieldEver: false, foundField: true, focusSucceeded: false
        )
        XCTAssertEqual(step, .exhausted(sawFieldEver: true))
    }

    func testNeverFoundField_exhaustsWithSawFieldFalse() {
        let step = QuickCapturePanel.FocusRetryDecision.step(
            attempt: max - 1, maxAttempts: max,
            sawFieldEver: false, foundField: false, focusSucceeded: false
        )
        XCTAssertEqual(step, .exhausted(sawFieldEver: false))
    }

    func testSawFieldEarlier_lastAttemptHasNoField_stillReportsSawFieldTrue() {
        // Field appeared mid-loop but was refused; last attempt finds nothing.
        // Carrier flag must persist so caller still treats this as a failure
        // worth surfacing — not silent fallback.
        let step = QuickCapturePanel.FocusRetryDecision.step(
            attempt: max - 1, maxAttempts: max,
            sawFieldEver: true, foundField: false, focusSucceeded: false
        )
        XCTAssertEqual(step, .exhausted(sawFieldEver: true))
    }

    func testSuccess_eclipsesSawFieldFlag_evenOnLastAttempt() {
        // If focus lands on the final attempt, that's still success — no
        // exhausted-failure path even though we're at attempt == max - 1.
        let step = QuickCapturePanel.FocusRetryDecision.step(
            attempt: max - 1, maxAttempts: max,
            sawFieldEver: false, foundField: true, focusSucceeded: true
        )
        XCTAssertEqual(step, .success)
    }
}
