import Foundation

/// Pure routing for a Context-Capture (⌃⌥⌘K) result: which bucket the captured selection lands
/// in, deduped, plus the error message for anything that genuinely failed to attach.
///
/// Lifted out of `QuickCaptureController.stageCapturedContent` for the same reason as
/// `MessageComposerFileStaging` (whose shape this mirrors): the decision is pure, the staging
/// side effect is not, and the only path into the original was `ClipboardCaptureService`
/// simulating a real ⌘C — which no test may do. `nonisolated` so it composes from anywhere.
nonisolated enum ClipboardStagingPolicy {

    struct Outcome: Equatable {
        /// New attachments to append, in input order, deduped against `existing` and within
        /// the batch (`StagedAttachment` equates by `stagedRelativePath`).
        var staged: [StagedAttachment] = []
        /// The captured text to append as a clip — set only when the capture carried no files.
        var clip: String?
        /// Banner text for files that could NOT be attached, or nil when none failed.
        var failureMessage: String?
    }

    /// Routes one capture.
    ///
    /// **Files take priority over text**, and the `else` is load-bearing rather than a
    /// preference: when Finder has a selection it puts the file PATHS on the pasteboard as
    /// `.string` too, so a fall-through would attach the files and *also* clip a block of raw
    /// paths. `stage == nil` means staging is impossible (no work folder / no orchestrator), in
    /// which case the text branch is the only one left.
    ///
    /// A file that staged fine but is ALREADY attached is a duplicate, not a failure. Counting
    /// it as one — which the original did, by deriving the count from how many were appended —
    /// meant capturing the same selection twice reported "1 of 1 files could not be attached",
    /// which is false, and which burns the single coalescing `lastErrorMessage` slot on a
    /// non-event.
    static func plan(
        fileURLs: [URL],
        text: String?,
        existing: [StagedAttachment],
        stage: ((URL) -> StagedAttachment?)?
    ) -> Outcome {
        if !fileURLs.isEmpty, let stage {
            var outcome = Outcome()
            var failedCount = 0
            for url in fileURLs {
                guard let attachment = stage(url) else {
                    failedCount += 1
                    continue
                }
                guard !existing.contains(attachment), !outcome.staged.contains(attachment) else {
                    continue   // already attached — not a failure
                }
                outcome.staged.append(attachment)
            }
            if failedCount > 0 {
                outcome.failureMessage =
                    "\(failedCount) of \(fileURLs.count) files could not be attached."
            }
            return outcome
        }
        if let text, !text.isEmpty {
            return Outcome(clip: text)
        }
        return Outcome()
    }
}
