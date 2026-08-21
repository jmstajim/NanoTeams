import XCTest

/// Skips a test whose path makes `QuickCaptureController.updatePanelContent` actually BUILD
/// the panel's SwiftUI form — `QuickCaptureFormView` inside a real `NSHostingView`.
///
/// That build aborts the XCTest worker on the public mirror's CI runner (`macos-15` with
/// Xcode 26.3 selected); it is clean on macOS 26. Three properties pin the trigger to the
/// FORM rather than to SwiftUI hosting, to the language mode, or to the fixtures:
///
/// - A panel handed a bare `Text` hosts fine there — `QuickCapturePanelContentTests` does
///   exactly that and is green, so `NSHostingView` itself works on the runner.
/// - The full suite compiled in CI's language mode (`SWIFT_VERSION=5.0`) runs green
///   locally: 15 419 passed, zero worker restarts. The mode is not the discriminator.
/// - Three separate classes split cleanly along "does this test supply panel + store +
///   dictation": the tests that do crashed, their siblings that do not passed.
///
/// Until wave 22 (2026-08-10) no test reached this body at all — `updatePanelContent`'s
/// `guard let panel, let store, let dictation` always skipped, which the production comment
/// on that guard states outright ("SFSpeechRecognizer can't safely construct on CI",
/// CLAUDE.md #47). The waves supplied the missing `dictation`, and the path ran on CI for
/// the first time.
///
/// The blast radius is why this matters more than the test count suggests: the worker
/// *aborts* rather than the test failing, so everything else it held is reported as crashed
/// too. First exposure was 24 failures across 6 suites, of which only ~13 were these tests —
/// `QuickCaptureQueueTests` and `FilePickerConfigurationTests` supply no prerequisites and
/// were pure collateral.
///
/// `macOS 26` is a PROXY for "a runtime that can host this form", not a claim about which
/// API is missing. It is the line the app's own dictation stack — which the form embeds — is
/// already gated on, and it is the line that separates the runner from every machine where
/// the path is known to work. Whether the abort is a CI-session artifact or a real macOS 15
/// defect is UNRESOLVED and recorded in DEBTS.md D-7; the deployment target is 15.0, so the
/// second reading would be a product bug, and this skip must not be read as ruling it out.
enum PanelHostingAvailability {

    /// Call BEFORE the prerequisites are wired, not after: the abort happens while the form
    /// is built, so a skip placed after `updatePanelContent` never runs.
    static func skipUnlessTheFormCanBeHosted(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if #available(macOS 26, *) { return }
        throw XCTSkip(
            "Building QuickCaptureFormView in an NSHostingView aborts the XCTest worker on "
                + "macOS < 26 (the mirror's CI runner). See DEBTS.md D-7.",
            file: file,
            line: line
        )
    }
}
