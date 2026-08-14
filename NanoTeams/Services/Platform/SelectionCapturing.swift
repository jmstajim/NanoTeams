import Foundation

// MARK: - Selection Capture Seam

/// The frontmost-app selection capture that ⌃⌥⌘K performs, as an injectable seam.
///
/// Production is `SystemSelectionCapturer` over `ClipboardCaptureService`, which
/// synthesizes a real ⌘C through `CGEvent` and rewrites the system pasteboard. That
/// is why the routing underneath it had no coverage: the only production route into
/// `stageCapturedContent` is `captureClipboardContent`, and calling it from a test
/// would copy from whatever app happened to be frontmost and clobber the developer's
/// clipboard. So `stageCapturedContent` carried a comment explaining it was
/// `internal` purely so tests could bypass its caller — and the caller itself,
/// including which bucket a capture is routed to, stayed unverified.
///
/// The bucket decision is the part worth testing: a capture filed against the
/// task-mode fields while the panel is in answer mode still renders a card, just
/// attached to something the user never meant.
@MainActor
protocol SelectionCapturing {
    /// Prompts for Accessibility trust if it has not been granted. Separate from the
    /// capture itself because production calls it first and unconditionally.
    func requestAccessibilityIfNeeded()

    /// Captures the frontmost app's selection: file URLs when the selection is files,
    /// text otherwise. `workFolderRoot` non-nil enables the `// Source:` enrichment
    /// for selections that came from a file inside the work folder.
    func captureSelection(workFolderRoot: URL?) async -> ClipboardCaptureResult
}

/// Production conformance — the real ⌘C synthesis.
@MainActor
struct SystemSelectionCapturer: SelectionCapturing {
    func requestAccessibilityIfNeeded() {
        ClipboardCaptureService.requestAccessibilityIfNeeded()
    }

    func captureSelection(workFolderRoot: URL?) async -> ClipboardCaptureResult {
        await ClipboardCaptureService.captureSelection(workFolderRoot: workFolderRoot)
    }
}

/// The seam's default, and deliberately inert rather than live.
///
/// `QuickCaptureController.init` leaves every dependency optional because
/// `QuickCaptureController.shared` is constructed with no arguments, so a seam that
/// defaulted OUTWARD would hand the real ⌘C synthesis to any of the ~79 test sites
/// that omit the argument — the shape CLAUDE.md §49 records as a 93-site disaster
/// in the orchestrator. Defaulting inward inverts the failure: a forgotten injection
/// yields "no selection", which is visible and harmless, instead of a keystroke sent
/// into someone else's app.
///
/// Production names its capturer explicitly at the single `shared` construction site;
/// `QuickCaptureSelectionCoverageTests.testDefaultCapturer_isInertAndProductionOverridesIt`
/// fails if that stops being true, which is what keeps the inward default from silently
/// disabling ⌃⌥⌘K for every user.
@MainActor
struct InertSelectionCapturer: SelectionCapturing {
    func requestAccessibilityIfNeeded() {}
    func captureSelection(workFolderRoot: URL?) async -> ClipboardCaptureResult {
        ClipboardCaptureResult(text: nil, fileURLs: [])
    }
}
