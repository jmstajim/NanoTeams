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
        #if DEBUG
        SubmitLatencyProbe.begin()
        #endif

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
            clips: formState.clippedTexts.texts,
            attachments: formState.attachments,
            embedFiles: embedFilesInPrompt
        )
        if !built.failedFiles.isEmpty {
            store.lastErrorMessage = "Could not embed \(built.failedFiles.count) file(s) as text: \(built.failedFiles.joined(separator: ", ")). They may be binary files."
        }
        // When clips were provided to the builder, they are always embedded into the text
        let remainingClips = formState.clippedTexts.isEmpty ? formState.clippedTexts.texts : [String]()

        if await store.submitQuickCaptureForm(
            title: formState.title,
            supervisorTask: built.answer,
            teamID: formState.selectedTeamID,
            clippedTexts: remainingClips,
            attachments: formState.attachments,
            draftID: formState.draftID
        ) != nil {
            formState.clearTaskDraft()
            // The chat opens HERE. `submitQuickCaptureForm` now returns once the task
            // and its first run exist, so this is no longer downstream of the run's
            // prompt warm-up — see `createPreparedTaskAndStart`.
            NotificationCenter.default.post(name: .navigateToActiveTask, object: nil)
            #if DEBUG
            SubmitLatencyProbe.markNavigation()
            #endif
            if keepOpenInChat && isChatMode {
                // The run start is claimed by now, so `resolveMode` returns
                // `.taskInitializing` on its own and holds it until the engine reports
                // `.running` — no placeholder mode to force, and no window in which a
                // refresh drops the panel back to the new-task composer.
                forceNewTaskMode = false
                isTaskSelected = true
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
        // The row of waiting questions as it stands BEFORE this answer lands. That row is what
        // "the next question" is measured from, and it is the last moment the question being
        // answered still has a position in it. Whether it still DESCRIBES the panel is decided
        // once, after the await, where the decision is actually made.
        let session = resolveMode().answerSession
        let answer = formState.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasClips = !formState.answerClippedTexts.isEmpty
        // The questionnaire counts as content on its own: ticking options and pressing send
        // without typing a word is the ordinary way a form is answered, and a gate that only
        // knew about prose would refuse it silently.
        //
        // Only the form THIS payload is asking, though. The bucket follows the panel across
        // branches that continue one conversation, so the ticks in hand can belong to another
        // role's form or to a round the role has already replaced with a plain question — and
        // an answer that is scoped away downstream would unpark the step having said nothing.
        let inquiryAnswer = formState.answerInquiry?.answer(for: payload.inquiry)
        let hasInquiryAnswer = !(inquiryAnswer?.isEmpty ?? true)
        guard !answer.isEmpty || !formState.answerAttachments.isEmpty || hasClips
            || hasInquiryAnswer
        else { return }

        let result = AnswerTextBuilder.build(
            text: answer,
            clips: formState.answerClippedTexts.texts,
            attachments: formState.answerAttachments,
            embedFiles: embedFilesInPrompt
        )
        let fullAnswer = result.answer
        if !result.failedFiles.isEmpty {
            store.lastErrorMessage = "Could not embed \(result.failedFiles.count) file(s) as text: \(result.failedFiles.joined(separator: ", ")). They may be binary files."
        }

        let isChatMode = payload.isChatMode

        // A submission is minted whenever the step is parked on a questionnaire, EVEN when the
        // card was never touched: its presence is what says a person answered, and without it
        // their prose is read back with the grammar written for a model's `Q2: 1, 3` reply.
        // `answer` and not `fullAnswer` is the note — the words they typed, not the reply
        // assembled for the model with clip and attached-file sections in it.
        let submission = payload.inquiry.map { _ in
            SupervisorInquirySubmission(
                answer: inquiryAnswer ?? SupervisorInquiryAnswer(), note: answer)
        }

        let success = await store.answerSupervisorQuestion(
            stepID: payload.stepID,
            taskID: payload.taskID,
            answer: fullAnswer,
            attachments: formState.answerAttachments,
            submission: submission
        )
        guard success else { return }

        advanceAfterQuestionResolved(
            payload: payload, session: session, isChatMode: isChatMode, store: store)
    }

    /// Asks the role to re-ask its plain question as a form, instead of answering it.
    ///
    /// No content gate: the directive itself is the content, and anything typed rides along as
    /// the note narrowing the form. Attachments and clips stay where they are — they belong to
    /// the answer the Supervisor may still write once the form comes back.
    func requestQuestionnaire() async {
        guard let payload = formState.pendingAnswer, let store else { return }
        let session = resolveMode().answerSession
        let note = formState.answerText.trimmingCharacters(in: .whitespacesAndNewlines)

        let success = await store.requestQuestionnaire(
            stepID: payload.stepID, taskID: payload.taskID, note: note)
        guard success else { return }

        formState.discardAnswerDraft(for: QuickCaptureFormState.draftKey(for: payload))
        formState.clearAnswerFields()
        advanceAfterQuestionResolved(
            payload: payload, session: session, isChatMode: payload.isChatMode, store: store)
    }

    /// What the panel does once a waiting question stops waiting — answered, or sent back to
    /// be asked as a form. Both unpark the step, so both leave the same row one question
    /// shorter, and the panel has the same three moves: re-point at the next question, stay
    /// open for a chat that is still going, or dismiss.
    ///
    /// - Parameter session: the row as it stood BEFORE the await that resolved the question —
    ///   the last moment that question still had a position in it.
    private func advanceAfterQuestionResolved(
        payload: SupervisorAnswerPayload,
        session: SupervisorAnswerSession?,
        isChatMode: Bool,
        store: NTMSOrchestrator
    ) {
        // Discard this branch's draft on successful submit
        formState.discardAnswerDraft(for: QuickCaptureFormState.draftKey(for: payload))
        formState.clearAnswerFields()

        // Another question is still waiting on this task: move to it rather than dismissing.
        // The panel is the only surface with no second route to those questions, so closing it
        // on the first answer is what made the rest of them unreachable in the first place —
        // and the setting that governs staying open ("keep open in chat") is about a
        // CONVERSATION continuing, not about a queue of questions that has not emptied.
        //
        // The `await` above is a window, and `session` describes the panel as it was BEFORE it.
        // Escape dismisses (leaving answer mode), and a task switch re-resolves the panel onto
        // another task — after either, moving "to the next question" would arm `pendingAnswer`
        // on a panel that is gone, or point the send button at a row belonging to a task the
        // Supervisor has already left.
        let panelStillOnThisQuestion =
            isPanelVisible && formState.isInAnswerMode
                && store.activeTaskID == payload.taskID
                && session?.selected.taskID == payload.taskID
        let next = panelStillOnThisQuestion
            ? session.flatMap {
                SupervisorAnswerFocus.next(after: payload.stepID, among: $0.stepIDs)
            }
            : nil
        // Only the aim naming the question just ANSWERED is retired here. Overwriting it
        // unconditionally would discard an aim the panel acquired on another task while this
        // answer was in flight.
        if formState.aimedQuestion == TaskStepKey(taskID: payload.taskID, stepID: payload.stepID) {
            formState.aimedQuestion = next.map {
                TaskStepKey(taskID: payload.taskID, stepID: $0)
            }
        }
        if let next, let nextPayload = session?.questions.first(where: { $0.stepID == next }) {
            // Stays in answer mode and re-points, so the hand-off runs: the (now empty) fields
            // are released from the answered branch and whatever was parked under the arriving
            // one comes back. `enterAnswerMode` rather than `updateAnswerPayload`: it delegates
            // to that one when already in answer mode and sets the flag when not, so the mode
            // and the payload can never disagree about whether the panel is answering.
            formState.enterAnswerMode(payload: nextPayload)
            updatePanelContent()
        } else if keepOpenInChat && isChatMode {
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
            formState.discardAnswerDraft(for: QuickCaptureFormState.draftKey(for: payload))
            formState.clearAnswerFields()
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
