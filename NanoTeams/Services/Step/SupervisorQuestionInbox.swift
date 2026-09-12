import Foundation

/// The one answer to "which supervisor questions are waiting right now".
///
/// Three surfaces used to derive that list independently, and the derivations were not
/// the same function written three times — they were three different functions:
///
/// | Surface | Predicate | Ordering | Text |
/// |---|---|---|---|
/// | composer | `hasActiveSupervisorInput` | `askedAt`, then `stepID` | flag-gated, then the call's args, then stored, then a placeholder |
/// | Quick Capture | `needsSupervisorInput && effectiveSupervisorAnswer == nil` | `steps` array order | `supervisorQuestion` only — no question, no panel |
/// | Watchtower | `hasActiveSupervisorInput` | `steps` array order | stored text, else the call's args — and no banner at all when both are empty |
///
/// The middle row is the one that cost something. `effectiveSupervisorAnswer == nil` is
/// the arithmetic reading of "unanswered" that `hasActiveSupervisorInput` documents as
/// broken: after the human answers round N, the round-N answer stays on the step until
/// `setNeedsSupervisorInput` runs for round N+1, so during that window Quick Capture
/// saw no question at all and offered the new-task composer instead of the answer field.
/// And `first(where:)` over the array picks whichever waiting step is stored first, which
/// with parallel roles (CLAUDE.md #45) is not the question the composer's leftmost chip
/// shows — panel and composer could point at different roles at the same instant.
///
/// So this is not a de-duplication for tidiness. Three surfaces answering "who is waiting"
/// differently is three definitions of waiting, and the user meets all three.
///
/// ## Identity is `TaskStepKey`, never the ask call's id
///
/// On the escalation branch there is no ask call, and the id this list used to carry there
/// was a `UUID()` minted inside the loop — a fresh value on every recompute tick, which is
/// the exact opposite of an identity. `askCallID` survives as an OPTIONAL, because the
/// Watchtower's dismissal genuinely needs "which question", and nil is the honest answer on
/// a branch that has no call (see `StepExecution.activeSupervisorQuestionID`).
nonisolated enum SupervisorQuestionInbox {

    /// Surfaced when a step was parked WITHOUT an ask call and `supervisorQuestion` is
    /// nil/whitespace. Silently dropping the entry instead would wedge the engine in
    /// `.needsSupervisorInput` with nothing on screen to answer.
    ///
    /// Every escalation writer interpolates a non-empty constant into the same closure
    /// that raises the flag, so this is defence against a writer that does not exist yet.
    static let escalationFallbackQuestion =
        "Role is waiting for input — original question text lost. Please advise."

    /// Surfaced when the ask call IS there but its arguments do not yet parse — which,
    /// mid-stream, means the question is still arriving rather than lost. A sentence
    /// claiming the text is gone would be a false statement about a payload three tokens
    /// from being complete, so this branch stays a placeholder and not a diagnosis.
    static let unparsedQuestionPlaceholder = "?"

    /// One waiting question, as every surface sees it.
    struct PendingQuestion: Identifiable, Equatable, Sendable {
        /// Identity. `stepID` alone would collide across concurrent tasks on the same
        /// team (invariant #5: `StepExecution.id` is the team role id).
        let key: TaskStepKey
        let role: Role
        /// The one line every surface renders. For a plain `ask_supervisor` it is the whole
        /// question; for `ask_supervisor_form` it is the headline standing over `inquiry`.
        let headline: String
        /// The questionnaire, when the step parked on one. Nil for a plain question — which
        /// is what lets a surface that renders no form behave exactly as it did before.
        let inquiry: SupervisorInquiry?
        /// The assistant turn that emitted the ask: which feed bubble it is, whether that
        /// bubble may be suppressed, and the reasoning the question card shows.
        ///
        /// Resolved HERE rather than per surface, because the two resolutions differed:
        /// Quick Capture took the last assistant turn outright, the composer took the last
        /// one at or before the ask. On a step that kept talking after asking, those are
        /// different turns, and the panel showed prose the question had not prompted.
        let paired: PairedAssistantMessage?
        /// Dismissal identity for the Watchtower banner: `StepExecution.activeSupervisorQuestionID`,
        /// never the id of the call this entry took its TEXT from.
        ///
        /// Those two are deliberately different questions. The text comes from the LAST ask
        /// anywhere in `toolCalls`, so a step that asked, did tool work and was then parked by
        /// a cap still shows that earlier ask (pinned, and "trailing call only" was refuted).
        /// The dismissal id comes from the TRAILING ask while it is still unanswered, and is
        /// nil otherwise — because handing a flag-only escalation the UUID of an ask the user
        /// already read, and possibly dismissed, would make its banner born-dismissed. Never
        /// list identity either way: that is `key`.
        let askCallID: UUID?
        /// When the ask landed, for ordering. `step.updatedAt` on the escalation branch,
        /// which is the closest thing that branch has to an ask time.
        let askedAt: Date

        var id: TaskStepKey { key }
        var stepID: String { key.stepID }
        var taskID: Int { key.taskID }

        /// The Watchtower banner this question raises, as the key a dismissal stores.
        ///
        /// Spelled from the SAME `headline` the banner renders. It used to be spelled from
        /// `StepExecution.supervisorQuestionText` while the banner rendered its own chain,
        /// and the two agreed only because they were the same expression — the moment the
        /// banner's text came from anywhere else, a dismissal would have keyed a string
        /// nothing on screen ever said. The text only enters the key on the branch that has
        /// no call to name, which is exactly the branch where it is the whole identity.
        var dismissKey: WatchtowerDismissKey {
            .supervisorInput(
                taskID: taskID, stepID: stepID, toolCallID: askCallID, question: headline)
        }
    }

    /// Dismiss identity of the banner `step` raises RIGHT NOW — nil when it raises none.
    ///
    /// Read it BEFORE an answer lands: `StepMessagingService.answerSupervisorQuestion`
    /// appends the `.supervisorAnswer` message that turns `activeSupervisorQuestionID` nil
    /// and clears `needsSupervisorInput` in one closure, after which the step no longer
    /// knows which banner it showed.
    static func dismissKey(forStep step: StepExecution, taskID: Int) -> WatchtowerDismissKey? {
        pending(taskID: taskID, steps: [step]).first?.dismissKey
    }

    /// Every waiting question on the task's active run, oldest ask first.
    ///
    /// Scoped to `runs.last` and empty for a closed task — the same two gates
    /// `NTMSTask.hasPendingSupervisorInput` applies, so the sidebar indicator and the
    /// surfaces cannot disagree about whether a task is waiting. Closing is the
    /// Supervisor's explicit "done": a step left holding the flag under a closed task is
    /// not a question anyone still owes an answer to.
    static func pending(in task: NTMSTask) -> [PendingQuestion] {
        guard task.closedAt == nil, let run = task.runs.last else { return [] }
        return pending(taskID: task.id, steps: run.steps)
    }

    /// The ids of the steps waiting RIGHT NOW, in `steps` order — an identity of the waiting
    /// SET, cheap enough to be a SwiftUI `onChange` key.
    ///
    /// Not the ordered inbox and deliberately not sorted: `askedAt` ordering needs each step's
    /// `AskCallIndex`, and an `onChange` key is evaluated on every body pass whether or not the
    /// handler fires (CLAUDE.md #113). `steps` order is stable across recomputes, which is all a
    /// key needs.
    ///
    /// It exists because the panel had nothing that fires when a SECOND question parks. The
    /// derived task STATUS does not move (the task was already waiting), and the seen-policy's
    /// observation keys on `activeSupervisorQuestionID`s — which an escalation park does not
    /// have. So the row of chips this whole switcher is made of could stay one chip long while
    /// two roles waited. It also covers the swap: one question answered and another parked in
    /// the same tick leaves the count unchanged and the SET different.
    static func waitingStepIDs(in task: NTMSTask) -> [String] {
        guard task.closedAt == nil, let run = task.runs.last else { return [] }
        return run.steps.filter { $0.hasActiveSupervisorInput }.map(\.id)
    }

    /// Every waiting question among `steps`, oldest ask first.
    ///
    /// Sorted ascending by `askedAt` with `stepID` as a deterministic tie-breaker — two
    /// asks landing in the same monotonic tick must produce a stable order across
    /// recomputes, otherwise the leftmost chip flips and a draft typed into the
    /// auto-selected recipient silently retargets on the next refresh.
    ///
    /// - Parameter askIndex: the step's `AskCallIndex`. The default scans `toolCalls`;
    ///   `TeamActivityFeedViewModel` passes its `TaskStepKey`-keyed cache so the per-tick
    ///   cost is O(appended calls) rather than a pass over the whole array.
    static func pending(
        taskID: Int,
        steps: [StepExecution],
        askIndex: (StepExecution) -> AskCallIndex = { AskCallIndex(toolCalls: $0.toolCalls) }
    ) -> [PendingQuestion] {
        var result: [PendingQuestion] = []
        for step in steps {
            guard step.hasActiveSupervisorInput else { continue }
            result.append(question(taskID: taskID, step: step, askIndex: askIndex))
        }
        return result.sorted { lhs, rhs in
            if lhs.askedAt != rhs.askedAt { return lhs.askedAt < rhs.askedAt }
            return lhs.stepID < rhs.stepID
        }
    }

    // MARK: - One step

    private static func question(
        taskID: Int,
        step: StepExecution,
        askIndex: (StepExecution) -> AskCallIndex
    ) -> PendingQuestion {
        // `lastParkedPosition(in:)` IS `lastIndex(where: parked)`: an earlier ask followed by
        // tool work and then a cap park still resolves to THAT ask (pinned by
        // `testEarlierAskThenToolWorkThenCapPark_findsTheEarlierAsk`; "trailing call only"
        // was proposed and refuted). Cost: this runs from `recomputeSteps` on every
        // runDataVersion tick, BEFORE the fingerprint short-circuit, and for a parked step
        // WITHOUT an ask (drift / refusal cap, Autovisor idle park) a `last(where:)` would
        // be an absence proof over the whole array on every tick — a gate that costs the
        // work it gates (CLAUDE.md #106). With the view model's cached index the per-tick
        // cost is O(delta), and while parked the delta is zero.
        // A refused ask (`StepToolCall.isRefusedAsk`) asked nobody anything, so the walk skips
        // it — read off the live array, since the refusal lands after the call is appended.
        let lastAskCall = askIndex(step).lastParkedPosition(in: step.toolCalls).map { position -> StepToolCall in
            let call = step.toolCalls[position]
            assert(call.isSupervisorAsk && !call.isRefusedAsk,
                   "AskCallIndex describes a different array — a `toolCalls` writer broke the closed set")
            return call
        }

        let storedHeadline = step.supervisorQuestion?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let lastCall = lastAskCall else {
            // Escalation branch: `setNeedsSupervisorInput` from a drift / refusal-loop /
            // parse-failure cap, or the Autovisor's idle park. No tool call, so the text
            // lives only on `step.supervisorQuestion`, and the pairing is the last assistant
            // turn — the one that triggered the cap.
            return PendingQuestion(
                key: TaskStepKey(taskID: taskID, stepID: step.id),
                role: step.role,
                headline: storedHeadline.isEmpty ? escalationFallbackQuestion : storedHeadline,
                inquiry: step.supervisorInquiry,
                paired: paired(in: step, atOrBefore: nil),
                askCallID: step.activeSupervisorQuestionID,
                askedAt: step.updatedAt
            )
        }

        // Normal branch, preference order:
        //   1. `step.supervisorQuestion` when `needsSupervisorInput == true` — only
        //      `setNeedsSupervisorInput` / `recordAutoSupervisorAnswer` write both fields
        //      atomically, so flag-true guarantees the stored text is CURRENT (this is what
        //      covers an escalation overwriting an earlier ask's argument).
        //   2. Otherwise the call's own `argumentsJSON` — fresher than a flag-false stored
        //      text, which is STALE from the previous round (`answerSupervisorQuestion` does
        //      not clear it). This is the transient window between `appendToolCalls(newAsk)`
        //      and the matching `setNeedsSupervisorInput`; without the flag gate the prior
        //      round's question would flash for a frame before snapping to the new one.
        //   3. Last resort: a possibly-stale stored text still beats a placeholder.
        let headline: String
        if step.needsSupervisorInput, !storedHeadline.isEmpty {
            headline = storedHeadline
        } else if let parsed = lastCall.parsedSupervisorQuestion {
            headline = parsed
        } else if !storedHeadline.isEmpty {
            headline = storedHeadline
        } else {
            headline = unparsedQuestionPlaceholder
        }

        return PendingQuestion(
            key: TaskStepKey(taskID: taskID, stepID: step.id),
            role: step.role,
            headline: headline,
            inquiry: step.supervisorInquiry,
            paired: paired(in: step, atOrBefore: lastCall.createdAt),
            askCallID: step.activeSupervisorQuestionID,
            askedAt: lastCall.createdAt
        )
    }

    /// The most recent assistant turn at or before `bound` (the whole conversation's last
    /// assistant turn when `bound` is nil — the escalation branch, which has no ask to
    /// bound by).
    ///
    /// The bound is the point: a role that asked and then kept streaming has a later
    /// assistant turn that the question did not prompt, and pairing the card with it
    /// attributes prose to a question that never asked for it.
    private static func paired(in step: StepExecution, atOrBefore bound: Date?) -> PairedAssistantMessage? {
        let turn = step.llmConversation.last { message in
            guard message.role == .assistant else { return false }
            guard let bound else { return true }
            return message.createdAt <= bound
        }
        return turn.map { PairedAssistantMessage(id: $0.id, thinking: $0.thinking, content: $0.content) }
    }
}
