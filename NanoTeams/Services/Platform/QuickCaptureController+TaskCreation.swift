import SwiftUI

// MARK: - Task Creation, Answer Submission & Cancel
//
// The three form-to-store submission paths. All bind to `formState` + `store`
// and reuse `AnswerTextBuilder` to fold clips/attachments into the prompt.
// `createTask` / `submitAnswer` drive the post-submit panel transition
// (working mode in chat or dismiss) via the panel internals declared on the
// main type.

extension QuickCaptureController {

    // MARK: - Task Creation

    /// Creates a task from the current form state and starts execution.
    func createTask() async {
        guard let store else { return }

        // Check if the selected team is chat mode before creating
        let teamID = formState.selectedTeamID ?? store.snapshot?.workFolder.activeTeamID
        let team: Team?
        if let teamID {
            team = store.snapshot?.workFolder.teams.first { $0.id == teamID }
        } else {
            team = store.snapshot?.workFolder.activeTeam
        }
        // `seedChatModeForNewTask`, not bare `isChatMode`: the Generated Team placeholder is
        // vacuously chat-mode, and this decides whether Quick Capture stays open (chat) or
        // dismisses and navigates to the task. Same predicate `createTask` persists, so the
        // panel's behaviour and the task's stored flag cannot disagree.
        let isChatMode = team?.seedChatModeForNewTask ?? false

        // Build the supervisor task text with optional file embedding
        let built = AnswerTextBuilder.build(
            text: formState.supervisorTask,
            clips: formState.clippedTexts,
            attachments: formState.attachments,
            embedFiles: embedFilesInPrompt
        )
        if !built.failedFiles.isEmpty {
            store.lastErrorMessage = "Could not embed \(built.failedFiles.count) file(s) as text: \(built.failedFiles.joined(separator: ", ")). They may be binary files."
        }
        // When clips were provided to the builder, they are always embedded into the text
        let remainingClips = formState.clippedTexts.isEmpty ? formState.clippedTexts : [String]()

        if await store.submitQuickCaptureForm(
            title: formState.title,
            supervisorTask: built.answer,
            teamID: formState.selectedTeamID,
            clippedTexts: remainingClips,
            attachments: formState.attachments,
            draftID: formState.draftID
        ) != nil {
            formState.clearTaskDraft()
            NotificationCenter.default.post(name: .navigateToActiveTask, object: nil)
            if keepOpenInChat && isChatMode {
                // Task just created — force working mode, refreshPanelIfVisible will update later
                forceNewTaskMode = false
                isTaskSelected = true
                pendingWorkingMode = true
                updatePanelContent()
            } else {
                dismissPanel()
            }
        }
    }

    // MARK: - Supervisor Answer

    /// Submits the supervisor answer. In chat mode with `keepOpenInChat`, stays open and shows loader.
    func submitAnswer() async {
        guard let payload = formState.pendingAnswer, let store else { return }
        let answer = formState.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasClips = !formState.answerClippedTexts.isEmpty
        guard !answer.isEmpty || !formState.answerAttachments.isEmpty || hasClips else { return }

        let result = AnswerTextBuilder.build(
            text: answer,
            clips: formState.answerClippedTexts,
            attachments: formState.answerAttachments,
            embedFiles: embedFilesInPrompt
        )
        let fullAnswer = result.answer
        if !result.failedFiles.isEmpty {
            store.lastErrorMessage = "Could not embed \(result.failedFiles.count) file(s) as text: \(result.failedFiles.joined(separator: ", ")). They may be binary files."
        }

        let isChatMode = payload.isChatMode

        let success = await store.answerSupervisorQuestion(
            stepID: payload.stepID,
            taskID: payload.taskID,
            answer: fullAnswer,
            attachments: formState.answerAttachments
        )
        guard success else { return }

        // Discard the per-task draft on successful submit
        formState.discardAnswerDraft(taskID: payload.taskID)
        formState.answerText = ""
        formState.answerAttachments = []
        formState.answerClippedTexts = []

        if keepOpenInChat && isChatMode {
            formState.exitAnswerMode()
            updatePanelContent()
        } else {
            formState.exitAnswerMode()
            dismissPanel()
        }
    }

    // MARK: - Cancel

    func cancelDraft() {
        if let payload = formState.pendingAnswer {
            // Answer mode: discard THIS answer's own staged copies, never the directory.
            // `formState.draftID` names one `.nanoteams/staged/<id>/` that the task draft and
            // every saved answer draft also write into, and none of their `StagedAttachment`
            // values — nor the chips rendered from them — are touched by a cancel here. Deleting
            // the directory therefore left the panel showing files that were no longer on disk,
            // and the first thing to notice was `finalizeAttachments`, minutes later, with
            // nothing connecting the failure to the Escape key.
            //
            // `removeStagedAttachment` and not a direct delete: an in-project attachment is a
            // reference to the user's own file, and refusing to delete those is its job.
            for attachment in formState.answerAttachments {
                store?.removeStagedAttachment(attachment)
            }
            formState.discardAnswerDraft(taskID: payload.taskID)
            formState.answerText = ""
            formState.answerAttachments = []
            formState.answerClippedTexts = []
            formState.exitAnswerMode()
        } else {
            // Task mode: original behavior
            let draftToCleanup = formState.draftID
            store?.discardStagedDraft(draftID: draftToCleanup)
            formState.clearTaskDraft()
        }
        dismissPanel()
    }
}
