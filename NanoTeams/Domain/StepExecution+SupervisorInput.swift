import Foundation

// MARK: - "Someone is waiting on the Supervisor's answer"

nonisolated extension StepExecution {
    /// Single source of truth for "this step has an unanswered `ask_supervisor`
    /// question that the docked composer should own". Shared by `emitItems`'s
    /// supervisor-input skip, `activeSupervisorQuestions`, the
    /// `supervisorInputCount` fingerprint, the Watchtower inbox, and
    /// `TaskSummary.hasPendingSupervisorInput` — all of them must agree,
    /// otherwise the composer chip, the feed skip, the rebuild trigger and the
    /// sidebar indicator fall out of sync (which is exactly the bug the
    /// multi-round race produced).
    ///
    /// Criterion: the trailing tool call is `ask_supervisor` AND no
    /// `Supervisor answer: …` message has landed AFTER it (`MonotonicClock`
    /// makes `createdAt` a strict order, so "after" is well-defined).
    /// `needsSupervisorInput` is OR'd in as the backstop for engine paths that
    /// set the flag without appending a call (drift / refusal-loop escalation).
    ///
    /// Answer-after-ask, deliberately NOT an ask/answer count. The count law
    /// broke on two real shapes: a model that BATCHES several `ask_supervisor`
    /// calls in one response gets ONE answer for the batch, so asks outrun
    /// answers forever and every later round reads as waiting; and an answer
    /// to a flag-only escalation appends an answer message with no matching
    /// call, silently pre-paying for the NEXT ask. Both are order questions,
    /// not arithmetic ones: the trailing ask is resolved exactly when an
    /// answer follows it.
    ///
    /// The multi-round race stays covered: after the supervisor answers iter
    /// N, `step.supervisorAnswer` retains the iter-N answer until
    /// `setNeedsSupervisorInput` runs for iter N+1, but the iter-N answer
    /// MESSAGE precedes the iter-N+1 call, so the new call reads unanswered. A
    /// `supervisorAnswer == nil` guard would misclassify that window (see
    /// `LLMExecutionService+StepLifecycle.swift`).
    var hasActiveSupervisorInput: Bool {
        // The O(1) flag first: `activeAskCall`'s forward scan is O(conversation)
        // exactly in the active case, and this predicate runs per step per
        // recompute tick (fingerprint key, emitItems, the composer-chip guard).
        needsSupervisorInput || activeAskCall != nil
    }

    /// The trailing `ask_supervisor` call while it is still unanswered — the
    /// question the docked composer owns. Nil when the last tool call is not an
    /// ask, or when a Supervisor-answer message landed after it.
    ///
    /// Every answer path appends a `.supervisorAnswer` message in the same
    /// mutation that delivers the answer — including attachments-only answers
    /// (`StepMessagingService.answerSupervisorQuestion`) — so "no answer after
    /// the call" is equivalent to "still owed".
    private var activeAskCall: StepToolCall? {
        guard let last = toolCalls.last, last.name == ToolNames.askSupervisor else { return nil }
        let answeredAfter = llmConversation.contains {
            $0.sourceContext == .supervisorAnswer && $0.createdAt > last.createdAt
        }
        return answeredAfter ? nil : last
    }

    /// Identity of the active `ask_supervisor` call, when there is one.
    ///
    /// `StepToolCall.id` is a persisted `UUID` with a synthesized `Codable`, so
    /// this survives a relaunch — which is what lets a dismissal target ONE
    /// question rather than "whatever this step is currently asking". Nil on
    /// EVERY flag-only escalation — including on a step with earlier, answered
    /// ask calls: returning the trailing call's id there would hand the
    /// escalation the identity of a question the user already read (and
    /// possibly dismissed), so its banner would be born-dismissed. With nil,
    /// `WatchtowerNotificationType.dismissID` falls back to the question text —
    /// the documented escalation identity.
    var activeSupervisorQuestionID: UUID? {
        activeAskCall?.id
    }

    /// Owed an answer AND reachable right now — the gate for delivering one.
    var canReceiveSupervisorAnswer: Bool {
        hasActiveSupervisorInput && status.acceptsSupervisorAnswer
    }
}

nonisolated extension StepStatus {
    /// Statuses a Supervisor answer can actually be delivered into.
    ///
    /// `.paused` belongs here because `StatusRecoveryService` parks a waiting
    /// step at launch WITHOUT clearing `needsSupervisorInput` — the human is
    /// still owed a reply and the answer must still land. Every site that gates
    /// on "can I answer this now" reads this one property; asking
    /// `status == .needsSupervisorInput` instead is what silently dropped a
    /// queued Quick Capture message after a relaunch.
    var acceptsSupervisorAnswer: Bool {
        self == .needsSupervisorInput || self == .paused
    }
}

nonisolated extension Run {
    /// True when ANY step in this run is still owed a Supervisor answer.
    /// Parallel roles mean several steps can wait at once (CLAUDE.md #45).
    var hasActiveSupervisorInput: Bool {
        steps.contains { $0.hasActiveSupervisorInput }
    }

    /// Identities of every active `ask_supervisor` call in this run.
    var activeSupervisorQuestionIDs: Set<UUID> {
        Set(steps.compactMap(\.activeSupervisorQuestionID))
    }
}

nonisolated extension NTMSTask {
    /// Durable, restart-stable "this task is waiting on the Supervisor".
    ///
    /// Scoped to the active run (`runs.last`) so a flag left on a superseded run
    /// cannot resurrect an indicator, and false for a closed task — closing is
    /// the Supervisor's explicit "done", regardless of what the last run holds.
    var hasPendingSupervisorInput: Bool {
        guard closedAt == nil else { return false }
        return runs.last?.hasActiveSupervisorInput ?? false
    }

    /// Identities of the active questions on the active run — empty for a closed task.
    var activeSupervisorQuestionIDs: Set<UUID> {
        guard closedAt == nil else { return [] }
        return runs.last?.activeSupervisorQuestionIDs ?? []
    }
}
