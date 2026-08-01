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
    @discardableResult
    static func answerSupervisorQuestion(
        stepID: String,
        answer: String,
        attachmentPaths: [String] = [],
        isAutoAnswer: Bool = false,
        in task: inout NTMSTask
    ) -> Bool {
        guard let location = task.locateStepInLatestRun(stepID: stepID) else { return false }

        let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswer = clean.isEmpty ? nil : clean
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerAttachmentPaths = attachmentPaths
        // `isAutoAnswer` marks answers produced by an automated path (delegating
        // parent role, Autovisor) — drives the feed's "Auto-answered" badge.
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerWasAuto = isAutoAnswer
        // This answer has NOT reached the model yet — the step's re-entry
        // (`LLMExecutionService+StepLifecycle`) appends it to the replayed transcript and
        // `persistWireTranscript` consumes the flag. Keyed on real content so an empty
        // answer with no attachments (which also leaves `supervisorAnswer` nil) can't
        // arm a delivery that has nothing to deliver.
        task.runs[location.runIndex].steps[location.stepIndex].supervisorAnswerPendingDelivery =
            StepExecution.inferPendingDelivery(answer: clean, attachmentPaths: attachmentPaths)
        task.runs[location.runIndex].steps[location.stepIndex].needsSupervisorInput = false

        // Append the supervisor answer to llmConversation in the SAME mutation
        // that clears `needsSupervisorInput`. Without this, the count-based
        // active-input predicate (`ActivityFeedBuilder.stepHasActiveSupervisorInput`)
        // sees `askCalls.count > answerMessages.count` between this mutation and
        // the engine's subsequent runStep continuation — the Watchtower banner
        // and feed composer chip would re-surface for ~one event-loop tick after
        // the user already answered. Empty answer skips the append (no
        // "Supervisor answer: " noise).
        if !clean.isEmpty {
            let answerMessage = LLMMessage(
                role: .user,
                content: "\(MessageSourceContext.supervisorAnswerPrefix)\(clean)",
                sourceRole: .supervisor,
                sourceContext: .supervisorAnswer
            )
            task.runs[location.runIndex].steps[location.stepIndex].llmConversation.append(answerMessage)
        }

        // Normal flow: status was .needsSupervisorInput → .pending so the engine's
        // reconcileAfterPause picks it up. After app restart, StatusRecoveryService has
        // already flipped .needsSupervisorInput → .paused, but the user can still answer
        // (the Answer chip surfaces while `needsSupervisorInput` flag is true). Treat
        // .paused identically here so resumeRun's continuation path is invariant.
        let s = task.runs[location.runIndex].steps[location.stepIndex].status
        if s == .needsSupervisorInput || s == .paused {
            task.runs[location.runIndex].steps[location.stepIndex].status = .pending
        }
        return true
    }
}
