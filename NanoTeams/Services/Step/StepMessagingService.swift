import Foundation

/// Service for managing step messaging operations (Supervisor comments, answers).
nonisolated enum StepMessagingService {
    static func setSupervisorCommentForNext(stepID: String, comment: String, in task: inout NTMSTask) {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return }
        let clean = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        task.runs[location.runIndex].steps[location.stepIndex].supervisorCommentForNext = clean.isEmpty ? nil : clean
    }

    /// Returns `true` when the answer was applied to a real pending step. Returns
    /// `false` when no step matches `stepID` — caller must surface this to the
    /// Supervisor instead of silently writing a no-op (CLAUDE.md §7: `mutateTask`
    /// returning `true` means "persisted", not "the mutation did something"; without
    /// this signal, an answer typed against a step that was restarted between chip
    /// render and submit would evaporate without any banner).
    /// - Parameter submission: the card's own state when the step parked on a questionnaire and
    ///   a HUMAN answered it — the decisions plus the prose they typed beside the form. The
    ///   automated answerers pass `nil` and reply in prose, which is read back against the
    ///   questionnaire here. One seam, because all four origins (human card, `.autonomous`
    ///   re-entry, the Autovisor's `answer_task_question`, a delegating parent role) funnel
    ///   through this function, and a second place that composed a form answer would be a
    ///   second default semantics. It is the PRESENCE of a submission that names the origin,
    ///   never the emptiness of the answer inside it: a Supervisor who decides nothing and
    ///   writes a sentence has still answered as a person.
    /// - Parameter origin: who is resolving the park — see ``SupervisorAnswerOrigin``. It names
    ///   the badge, the appended turn's attribution and its marker in one value, so the three
    ///   cannot be set to a combination that has no meaning.
    @discardableResult
    static func answerSupervisorQuestion(
        stepID: String,
        answer: String,
        attachmentPaths: [String] = [],
        origin: SupervisorAnswerOrigin = .supervisor,
        submission: SupervisorInquirySubmission? = nil,
        in task: inout NTMSTask
    ) -> Bool {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return false }

        // Composed BEFORE anything is written, from the questionnaire the step is parked on.
        // Returns the reply untouched when there is none, so the plain `ask_supervisor` path
        // is byte-for-byte what it was — which is the common path, and the one chat-mode
        // teams take on every single turn.
        let composed = SupervisorInquiryReply.compose(
            inquiry: task.runs[location.runIndex].steps[location.stepIndex].supervisorInquiry,
            reply: answer,
            submission: submission)
        let clean = composed.text
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswer = clean.isEmpty ? nil : clean
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerAttachmentPaths = attachmentPaths
        // `.automated` marks answers produced by an automated path (delegating
        // parent role, Autovisor) — drives the feed's "Auto-answered" badge.
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerWasAuto =
            origin.isAutomated
        // This answer has NOT reached the model yet — the step's re-entry
        // (`LLMExecutionService+StepLifecycle`) appends it to the replayed transcript and
        // `persistWireTranscript` consumes the flag. Keyed on real content so an empty
        // answer with no attachments (which also leaves `supervisorAnswer` nil) can't
        // arm a delivery that has nothing to deliver.
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerPendingDelivery =
            StepExecution.inferPendingDelivery(answer: clean, attachmentPaths: attachmentPaths)
        task.runs[location.runIndex].steps[location.stepIndex].needsSupervisorInput = false
        // The structure the prose above was rendered from — what the feed re-renders the
        // answered card from, and the record of which answers were decisions and which were
        // assumptions. Written after the delivery flag, not between it and the answer: the
        // two of those are one decision and `SupervisorAnswerDeliveryPinTests` reads their
        // adjacency as the evidence. Left untouched (rather than nil'd) when there was no
        // questionnaire — a plain answer says nothing about a form.
        if let structured = composed.answer {
            task.runs[location.runIndex].steps[location.stepIndex].supervisorInquiryAnswer = structured
        }

        // Append the resolving turn to llmConversation in the SAME mutation
        // that clears `needsSupervisorInput`. `StepExecution.hasActiveSupervisorInput`
        // reads "answered" as "a turn whose context `resolvesSupervisorAsk` landed AFTER the
        // trailing ask call", so this append IS the durable record that the question was
        // resolved — skipping it for any DELIVERED answer would leave the step
        // reading as waiting forever (the chat-shows-as-unanswered class). An
        // attachments-only answer is delivered (`supervisorAnswerPendingDelivery`
        // arms on it), so it must leave the same record; its recorded text is the
        // attachment section `effectiveSupervisorAnswer` composes — the same framing
        // the wire replay sends. Only a truly empty answer (no text, no attachments,
        // nothing delivered) skips the append.
        if task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerPendingDelivery {
            let recorded = clean.isEmpty
                ? (task.runs[location.runIndex].steps[location.stepIndex].effectiveSupervisorAnswer ?? "")
                : clean
            // `role` stays `.user` for every origin, the app's own directive included: the
            // feed drops `.system` turns unconditionally (`ActivityFeedBuilder`, debug mode
            // too), so "system" is carried by the CONTEXT here, never by the wire role — a
            // `.system` turn would render nowhere at all.
            let answerMessage = LLMMessage(
                role: .user,
                content: "\(origin.messageContentPrefix)\(recorded)",
                sourceRole: origin.messageSourceRole,
                sourceContext: origin.messageContext
            )
            task.runs[location.runIndex].steps[location.stepIndex].llmConversation.append(answerMessage)
        }

        // Normal flow: status was .needsSupervisorInput → .pending so the engine's
        // reconcileAfterPause picks it up. After app restart, StatusRecoveryService has
        // already flipped .needsSupervisorInput → .paused, but the user can still answer
        // (the Answer chip surfaces while `needsSupervisorInput` flag is true). Treat
        // .paused identically here so resumeRun's continuation path is invariant.
        let s = task.runs[location.runIndex].steps[location.stepIndex].status
        if s.acceptsSupervisorAnswer {
            task.runs[location.runIndex].steps[location.stepIndex].status = .pending
        }
        return true
    }
}
