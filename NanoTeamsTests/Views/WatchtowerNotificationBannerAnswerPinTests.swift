import XCTest

@testable import NanoTeams

/// `WatchtowerNotificationBanner.submitAnswer` must NOT dismiss on success.
///
/// The answer is consumed by `NTMSOrchestrator.answerSupervisorQuestion`, which retires
/// this banner's dismissal and un-marks the task "seen"; `WatchtowerView`'s
/// `onSubmitAnswer` then refreshes the inbox synchronously, so by the time the banner's
/// success branch runs the banner is already gone. An `onDismiss()` there re-inserted the
/// key the orchestrator had just retired (`WatchtowerView.dismissNotification`) and
/// re-marked the task read — one remaining door for a text-keyed escalation dismissal to
/// outlive its answer and mask the next same-text question.
///
/// A source pin, because the decision is inside a SwiftUI `View`'s `@State` method with
/// no seam to call. Comment-stripped (CLAUDE.md #89: prose describing code is not code).
final class WatchtowerNotificationBannerAnswerPinTests: XCTestCase {

    /// RED: re-add `onDismiss()` inside the `if success {` block of `submitAnswer` →
    /// the dismissal assertion fails.
    func testSubmitAnswer_successBranch_doesNotDismissTheBanner() throws {
        let body = try submitAnswerBody()
        XCTAssertTrue(body.contains("answerText = \"\""),
                      "anti-vacuum: this IS the success branch — the draft is cleared here")
        XCTAssertTrue(body.contains("onSubmitAnswer("),
                      "anti-vacuum: the branch runs after the orchestrator consumed the answer")
        XCTAssertFalse(body.contains("onDismiss("),
                       "success must not re-dismiss: the orchestrator retired the key and the inbox was refreshed")
    }

    /// The X button keeps its dismiss — the pin above forbids the call in ONE method, not
    /// the affordance. Without this, deleting `onDismiss` from the banner altogether would
    /// read as green.
    ///
    /// RED: `DismissButton(onDismiss: onDismiss)` → `DismissButton(onDismiss: {})` in
    /// `WatchtowerNotificationBanner.swift` → this assertion fails and the pin above stays
    /// green, which is exactly the hole it is here to cover.
    func testDismissButton_stillWiredToOnDismiss() throws {
        let banner = try source("NanoTeams/Views/Watchtower/WatchtowerNotificationBanner.swift")
        XCTAssertTrue(banner.contains("DismissButton(onDismiss: onDismiss)"))
    }

    // MARK: - Scaffolding

    private func submitAnswerBody() throws -> String {
        let code = RatchetSourceScan.strippingLineComments(
            try source("NanoTeams/Views/Watchtower/WatchtowerNotificationBanner+Content.swift"))
        return try XCTUnwrap(
            RatchetSourceScan.functionBody(after: "func submitAnswer(stepID: String)", in: code),
            "submitAnswer(stepID:) must still be declared in +Content.swift")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: RatchetSourceScan.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
