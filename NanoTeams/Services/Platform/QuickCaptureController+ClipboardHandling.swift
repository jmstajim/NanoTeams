import SwiftUI

// MARK: - Clipboard Capture & Attachment Staging
//
// Captures the frontmost app's selection (files → attachments, text → clips)
// via `ClipboardCaptureService` and stages it onto the active draft. Routed to
// answer-mode vs task-mode fields by the caller (`showPanel(withClip:)`).

extension QuickCaptureController {

    func captureClipboardContent(mode: QuickCaptureMode, needsAnswerMode: Bool) async {
        ClipboardCaptureService.requestAccessibilityIfNeeded()
        let workFolderRoot = store?.hasRealWorkFolder == true ? store?.workFolderURL : nil
        let captured = await ClipboardCaptureService.captureSelection(workFolderRoot: workFolderRoot)

        if needsAnswerMode, case .supervisorAnswer = mode {
            stageCapturedContent(captured, to: formState.draftID, answerMode: true)
        } else {
            stageCapturedContent(captured, to: formState.draftID, answerMode: false)
        }
    }

    private func stageCapturedContent(
        _ captured: ClipboardCaptureResult,
        to draftID: UUID,
        answerMode: Bool
    ) {
        if !captured.fileURLs.isEmpty, let store {
            var stagedCount = 0
            for url in captured.fileURLs {
                if let staged = store.stageAttachment(url: url, draftID: draftID) {
                    if answerMode {
                        if !formState.answerAttachments.contains(staged) {
                            formState.answerAttachments.append(staged)
                            stagedCount += 1
                        }
                    } else {
                        if !formState.attachments.contains(staged) {
                            formState.attachments.append(staged)
                            stagedCount += 1
                        }
                    }
                }
            }
            if stagedCount < captured.fileURLs.count {
                let skipped = captured.fileURLs.count - stagedCount
                store.lastErrorMessage = "\(skipped) of \(captured.fileURLs.count) files could not be attached."
            }
        } else if let text = captured.text, !text.isEmpty {
            if answerMode {
                formState.answerClippedTexts.append(text)
            } else {
                formState.clippedTexts.append(text)
            }
        }
    }
}
