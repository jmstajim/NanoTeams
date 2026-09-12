import Foundation
#if DEBUG
import Synchronization
#endif

// MARK: - "Someone is waiting on the Supervisor's answer"

nonisolated extension StepExecution {
    /// Single source of truth for "this step has an unanswered `ask_supervisor`
    /// question that the docked composer should own". Shared by `emitItems`'s
    /// supervisor-input skip, `SupervisorQuestionInbox.pending`, the
    /// `supervisorInputCount` fingerprint, the Watchtower inbox, and
    /// `TaskSummary.hasPendingSupervisorInput` — all of them must agree,
    /// otherwise the composer chip, the feed skip, the rebuild trigger and the
    /// sidebar indicator fall out of sync (which is exactly the bug the
    /// multi-round race produced).
    ///
    /// Criterion: the trailing tool call — skipping any refused asks at the tail, which
    /// asked nobody anything (`StepToolCall.isRefusedAsk`) — is a parking tool AND no
    /// RESOLVING message has landed AFTER it (`MessageSourceContext.resolvesSupervisorAsk`;
    /// `MonotonicClock` makes `createdAt` a strict order, so "after" is well-defined).
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
        // The O(1) flag first: `activeAskCall` still walks the conversation TAIL
        // after the trailing ask, and this predicate runs per step per recompute
        // tick (fingerprint key, emitItems, the composer-chip guard).
        needsSupervisorInput || activeAskCall != nil
    }

    /// The trailing `ask_supervisor` call while it is still unanswered — the
    /// question the docked composer owns. Nil when the last tool call is not an
    /// ask, or when a resolving message landed after it.
    ///
    /// Every path that unparks the step appends a resolving message in the same
    /// mutation that delivers its text — including attachments-only answers and the
    /// `[ Ask as form ]` directive (`StepMessagingService.answerSupervisorQuestion`,
    /// one seam, `SupervisorAnswerOrigin` picking the context) — so "nothing
    /// resolving after the call" is equivalent to "still owed".
    private var activeAskCall: StepToolCall? {
        // Membership in the closed parking set, not equality with one name: a step parked by
        // `ask_supervisor_form` must resolve to ITS call, or the question has no persisted
        // identity and `activeSupervisorQuestionID` hands the Watchtower dismissal its
        // question TEXT instead — under which a re-asked identical headline is born dismissed.
        //
        // A refused ask (`QUESTIONNAIRE_REQUIRED`, `INVALID_ARGS`) is walked over: on a step
        // still running it opened nothing, and beside the form that parked the step it must
        // not take that park's identity. The walk is O(refused asks at the tail) — zero on
        // every step but the one mid-repair (MeditationApp task 52 run 9, 2026-09-11: the
        // composer showed a chip for ~8 s after each refusal, on a `.running` step).
        guard let last = toolCalls.last(where: { !$0.isRefusedAsk }),
              last.isSupervisorAsk
        else { return nil }
        // REVERSE, stopping at the first message not newer than the ask.
        //
        // The predicate only cares about messages created AFTER the trailing ask,
        // and `llmConversation` is `createdAt`-ascending: it is append-only, and
        // the two writers that re-stamp (`applyRetryNotice`,
        // `commitStreamingContent`) both move the TAIL element forward. So the
        // candidates are a suffix, and everything before the break is provably
        // older than the ask.
        //
        // The forward `contains` this replaces read the WHOLE conversation, and
        // its cost was not per-answer but per-BODY-PASS: `activeSupervisorQuestionID`
        // has no `needsSupervisorInput` short-circuit and is reached from
        // `MainLayoutView.activeTaskObservation`, an `onChange` KEY — evaluated on
        // every pass, i.e. on every `mutateTask`. Θ(messages) per append is Θ(N²)
        // across a chat session, on the MainActor.
        //
        // Failure direction if the ordering invariant is ever broken: the walk
        // stops early and MISSES an out-of-place answer, i.e. it reads "still
        // waiting". It can never invent an answer, so the question stays on screen
        // and the human can still reply. Pinned by
        // `testAnswerScan_outOfOrderConversation_failsTowardStillWaiting`.
        for message in llmConversation.reversed() {
            #if DEBUG
            SupervisorInputScanProbe.noteExamined()
            #endif
            guard message.createdAt > last.createdAt else { break }
            if message.sourceContext?.resolvesSupervisorAsk == true { return nil }
        }
        return last
    }

    /// What last RESOLVED a park on this step — `.supervisorAnswer` when someone answered,
    /// `.questionnaireRequest` when the Supervisor sent the role back to ask as a form, nil
    /// when nothing has.
    ///
    /// Read by the prompt builders, which quote `supervisorAnswer` under the Supervisor's
    /// name: the directive is not a decision and must not be replayed to OTHER roles as one
    /// (`PromptBuilder+PipelineContext`), nor to this role with the `Supervisor answer: `
    /// marker the live wire never attaches (`PromptBuilder`, replayed ask envelope).
    ///
    /// Reverse scan stopping at the first resolution, the same idiom as `activeAskCall` — and
    /// paid on the same cadence as the thing that reads it, once per request rather than per
    /// body pass.
    var lastSupervisorAskResolution: MessageSourceContext? {
        for message in llmConversation.reversed() {
            if let context = message.sourceContext, context.resolvesSupervisorAsk {
                return context
            }
        }
        return nil
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

    /// HOW MANY steps are still owed a Supervisor answer.
    ///
    /// The same per-step predicate as `hasActiveSupervisorInput`, deliberately: the flag is
    /// this count's `> 0` and nothing else, so no surface can claim a task is waiting while
    /// its counter says nobody is. That the two are one fact in two shapes is what
    /// `NTMSTask.toSummary` relies on when it computes the count once and derives the flag.
    ///
    /// It exists because "waiting" is a Bool only for a team with one role. Parallel roles
    /// (CLAUDE.md #45) routinely park two or three steps on the same task at the same moment,
    /// and until the composer grew a chip row the extra questions were not merely uncounted —
    /// they were unreachable. The sidebar is the one surface that sees a task the Supervisor
    /// has NOT opened, so it is the one place the number can arrive before the click does.
    ///
    /// `count(where:)` rather than `contains`: the short-circuit `contains` buys is at most a
    /// few `toolCalls.last` name checks (a step whose trailing call is not an ask answers in
    /// O(1); only a waiting one walks its conversation tail), which is why the summary can
    /// afford one pass for both facts instead of two passes for one each.
    var activeSupervisorInputCount: Int {
        steps.count { $0.hasActiveSupervisorInput }
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

    /// How many questions the task is waiting on — the same two gates
    /// `hasPendingSupervisorInput` applies, so a closed task counts zero and a superseded
    /// run counts nothing at all.
    ///
    /// `hasPendingSupervisorInput == (pendingSupervisorQuestionCount > 0)` is an invariant,
    /// not a coincidence: both delegate to `StepExecution.hasActiveSupervisorInput`, and
    /// `SupervisorInputCountAgreementTests` pins it across the shapes where a hand-written
    /// second predicate would drift (closed task, superseded run, flag-only escalation).
    var pendingSupervisorQuestionCount: Int {
        guard closedAt == nil else { return 0 }
        return runs.last?.activeSupervisorInputCount ?? 0
    }

    /// Identities of the active questions on the active run — empty for a closed task.
    var activeSupervisorQuestionIDs: Set<UUID> {
        guard closedAt == nil else { return [] }
        return runs.last?.activeSupervisorQuestionIDs ?? []
    }
}

#if DEBUG
/// Work-bound seam for `activeAskCall`'s answer scan: how many conversation
/// messages the scan EXAMINED since the last reset.
///
/// It lives inside the scan's closure, not beside a call site, for the reason
/// CLAUDE.md #62 records: the defect being pinned is the scan reading the WHOLE
/// conversation instead of the tail after the trailing ask, and a counter placed
/// outside would report the conversation's length no matter what the scan
/// actually walked.
///
/// A regression here is invisible in OUTPUT — a forward whole-conversation scan
/// returns exactly the same answers, just Θ(N²) slower across a chat session,
/// because this predicate is re-evaluated on every SwiftUI body pass through
/// `MainLayoutView`'s `activeTaskObservation` `onChange` key.
nonisolated enum SupervisorInputScanProbe {
    private static let _examined = Atomic<Int>(0)
    static func noteExamined() { _examined.wrappingAdd(1, ordering: .relaxed) }
    static func _testExamined() -> Int { _examined.load(ordering: .relaxed) }
    static func _testResetExamined() { _examined.store(0, ordering: .relaxed) }
}
#endif
