import SwiftUI

// MARK: - Clipboard Capture & Attachment Staging
//
// Captures the frontmost app's selection (files → attachments, text → clips)
// via `ClipboardCaptureService` and stages it into whichever bucket pair the composer
// for the resolved mode is bound to (`QuickCaptureMode.composerBindsAnswerBuckets`).

extension QuickCaptureController {

    /// Captures the frontmost selection and files it into whichever bucket pair the
    /// composer for `mode` is bound to.
    ///
    /// The mode is the only input: both call sites used to derive a `needsAnswerMode` flag
    /// from it and pass both, so the pair could never disagree in production — while the
    /// disagreeing pair was the only case a test could construct, which is how the wrong
    /// routing for chat-mode `.taskWorking` came to be pinned as correct.
    func captureClipboardContent(mode: QuickCaptureMode) async {
        selectionCapturer.requestAccessibilityIfNeeded()
        let workFolderRoot = store?.hasRealWorkFolder == true ? store?.workFolderURL : nil
        let captured = await selectionCapturer.captureSelection(workFolderRoot: workFolderRoot)

        // Reported BEFORE staging so a staging failure (the more actionable message) can overwrite
        // it in the single `lastErrorMessage` slot rather than be overwritten by it.
        if captured.restoreFailed {
            store?.lastErrorMessage = "Your previous clipboard contents could not be restored "
                + "after the capture. Re-copy them if you still need them."
        }

        stageCapturedContent(
            captured,
            to: formState.draftID,
            answerMode: mode.composerBindsAnswerBuckets)
    }

    /// Files the routed capture into the answer-mode or task-mode bucket.
    ///
    /// `internal`, not `private`, so tests can call it: the only production route in is
    /// `captureClipboardContent`, which simulates a real ⌘C via CGEvent and rewrites the
    /// pasteboard. Which bucket a capture lands in is silent when wrong — the card appears
    /// either way, just attached to something the user never meant.
    func stageCapturedContent(
        _ captured: ClipboardCaptureResult,
        to draftID: UUID,
        answerMode: Bool
    ) {
        let outcome = ClipboardStagingPolicy.plan(
            fileURLs: captured.fileURLs,
            text: captured.text,
            existing: answerMode ? formState.answerAttachments : formState.attachments,
            stage: store.map { store in { store.stageAttachment(url: $0, draftID: draftID) } })

        if answerMode {
            formState.answerAttachments.append(contentsOf: outcome.staged)
            if let clip = outcome.clip { formState.answerClippedTexts.append(Clip(text: clip)) }
        } else {
            formState.attachments.append(contentsOf: outcome.staged)
            if let clip = outcome.clip { formState.clippedTexts.append(Clip(text: clip)) }
        }
        if let failure = outcome.failureMessage { store?.lastErrorMessage = failure }
    }
}
