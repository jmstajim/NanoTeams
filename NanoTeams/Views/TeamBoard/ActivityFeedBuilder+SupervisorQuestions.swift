import Foundation

// Active supervisor-question extraction for the docked composer.
// Pure static helpers split out of ActivityFeedBuilder; the core
// builder (emitItems) shares StepExecution.hasActiveSupervisorInput with these.
nonisolated extension ActivityFeedBuilder {

    // MARK: - Active Supervisor Questions (for banner)

    /// Data for an active (unanswered) supervisor question, displayed as a banner.
    ///
    /// `paired` identifies the assistant turn that emitted the question. It is
    /// always populated when such a turn exists; what varies is whether the turn
    /// is SUPPRESSIBLE — `PairedAssistantMessage.isFullyRenderedByQuestionCard`
    /// decides that, and only a turn with no prose qualifies. For those,
    /// `emitItems` drops the bubble (the card is then the sole surface) and the
    /// composer shows the turn's `thinking` in its disclosure row; convention is
    /// `active = hidden from feed, answered = visible` (see "Answered
    /// supervisor-input notifications" branch in `emitItems`). A turn that also
    /// carried prose keeps its bubble and yields the disclosure to it, so no
    /// model output is hidden without a surface.
    ///
    /// `paired == nil` covers the case where no assistant turn precedes the tool
    /// call (e.g. ask landed on turn 1 with no preamble) — composer falls back
    /// to rendering `question` alone, and there's no bubble to suppress.
    struct ActiveSupervisorQuestion {
        let stepID: String
        let role: Role
        let question: String
        let paired: PairedAssistantMessage?
        let toolCallID: UUID
        /// Timestamp of the active `ask_supervisor` tool call (i.e. the LAST one in
        /// the step's tool-call list, not the first — a role can ask twice). Builder
        /// emits results sorted ascending by this field; UI ordering is the consumer's
        /// concern (e.g. `TeamActivityComposer.computeChipOptions` preserves order).
        let askedAt: Date
    }

    /// Extracts active (unanswered) supervisor questions from steps. Result is sorted
    /// ascending by `askedAt`, with `stepID` as a deterministic tie-breaker — two
    /// `ask_supervisor` calls landing in the same monotonic tick must produce a stable
    /// order across recomputes, otherwise the leftmost chip flips and any draft typed
    /// into the auto-selected recipient would silently retarget on the next refresh.
    ///
    /// Uses `StepExecution.hasActiveSupervisorInput` for the active-state check.
    ///
    /// Two surfacing paths:
    /// 1. **Trailing `ask_supervisor` tool call** — normal path. Question text
    ///    parsed from the call's argumentsJSON; `toolCallID`/`askedAt` come
    ///    from that call; `paired` is the assistant turn that emitted it.
    /// 2. **Escalation path** (no tool call) — the engine's drift / refusal-
    ///    loop / parse-failure caps in `LLMExecutionService+StepFlowControl.swift`
    ///    call `setNeedsSupervisorInput(stepID:question:sessionID:)` directly,
    ///    flipping the flag without appending a tool call. Without this branch,
    ///    `activeSupervisorQuestions` silently returned `[]` for these steps
    ///    even though `hasActiveSupervisorInput` agreed they were waiting —
    ///    composer chip never appeared, question card never rendered, and the
    ///    user had to switch tasks to force a fresh view rebuild.
    ///    Pinned by `ActivityFeedBuilderTests.testEscalationPath_emptyAskCalls_flagSet_surfacesStoredQuestion`.
    static func activeSupervisorQuestions(steps: [StepExecution]) -> [ActiveSupervisorQuestion] {
        var result: [ActiveSupervisorQuestion] = []
        for step in steps {
            guard step.hasActiveSupervisorInput else { continue }
            // `last(where:)`, not `filter{}.last`: this runs from `recomputeSteps`
            // on every runDataVersion tick, and the materialized filter was an
            // O(toolCalls) pass per tick that grows without bound in chat-mode
            // steps — only the LAST ask is ever read here.
            let lastAskCall = step.toolCalls.last(where: { $0.name == ToolNames.askSupervisor })

            let question: String
            let toolCallID: UUID
            let askedAt: Date
            let paired: PairedAssistantMessage?

            if let lastCall = lastAskCall {
                // Normal path: trailing ask_supervisor tool call.
                //
                // Preference order:
                //   1. `step.supervisorQuestion` when `step.needsSupervisorInput == true`
                //      — only `setNeedsSupervisorInput` / `recordAutoSupervisorAnswer`
                //      write both fields atomically, so the flag-true state guarantees
                //      `supervisorQuestion` is the CURRENT text (covers escalation
                //      overwriting an earlier `ask_supervisor` arg).
                //   2. Otherwise the tool-call `argumentsJSON` — fresher than a flag-
                //      false `supervisorQuestion`, which is STALE from the previous
                //      round (`StepMessagingService.answerSupervisorQuestion` doesn't
                //      clear it on user answer). This is the transient window
                //      between `appendToolCalls(newAsk)` and the matching
                //      `setNeedsSupervisorInput` — without the flag gate, the prior
                //      round's question text would flash for a frame before snapping
                //      to the new one.
                //   3. Last-resort fallback: even a possibly-stale `supervisorQuestion`
                //      beats showing `"?"` to the user.
                //
                // Pinned by `testActiveSupervisorQuestions_prefersStepSupervisorQuestionOverStaleToolCallArg`
                // (case 1 — escalation) and
                // `testActiveSupervisorQuestions_transientWindow_staleSupervisorQuestion_doesNotShadowNewToolCall`
                // (case 2 — mid-round flicker). Both surfaces must agree with
                // `DefaultQuickCaptureModeCoordinator.resolveMode`, which reads
                // `step.supervisorQuestion` directly but is itself gated by
                // `step.needsSupervisorInput == true`.
                let storedQ = step.supervisorQuestion?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if step.needsSupervisorInput, !storedQ.isEmpty {
                    question = storedQ
                } else if let parsed = lastCall.parsedSupervisorQuestion {
                    question = parsed
                } else if !storedQ.isEmpty {
                    question = storedQ
                } else {
                    question = "?"
                }
                toolCallID = lastCall.id
                askedAt = lastCall.createdAt
                // Pair with the most-recent assistant turn at or before the
                // active ask. `id` identifies the bubble in `emitItems`;
                // `content` decides whether that bubble may be suppressed;
                // `thinking` feeds the composer's thinking disclosure.
                paired = step.llmConversation
                    .last(where: { $0.role == .assistant && $0.createdAt <= lastCall.createdAt })
                    .map {
                        PairedAssistantMessage(id: $0.id, thinking: $0.thinking, content: $0.content)
                    }
            } else {
                // Escalation path: `setNeedsSupervisorInput` from drift /
                // refusal-loop / parse-failure cap. No tool call, so the
                // question text lives only on `step.supervisorQuestion`. If
                // that's also empty/nil (future engine paths could regress —
                // the companion guard at LLMExecutionService+TaskStateMutations.swift
                // only protects today's writer), fall back to a canonical
                // placeholder. Silently `continue`ing here would wedge the
                // engine in `.needsSupervisorInput` forever — defense-in-depth.
                let trimmedQ = step.supervisorQuestion?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                question = trimmedQ.isEmpty ? Self.escalationFallbackQuestion : trimmedQ
                toolCallID = UUID()  // synthetic — escalation path has no real tool call
                askedAt = step.updatedAt
                // Pair with the last assistant turn (the one that triggered
                // the cap). If it carried no prose, its bubble is suppressed and
                // its thinking shows in the composer's disclosure; if it did,
                // the bubble stays and keeps the reasoning with it.
                paired = step.llmConversation
                    .last(where: { $0.role == .assistant })
                    .map {
                        PairedAssistantMessage(id: $0.id, thinking: $0.thinking, content: $0.content)
                    }
            }

            result.append(ActiveSupervisorQuestion(
                stepID: step.id, role: step.role,
                question: question,
                paired: paired,
                toolCallID: toolCallID,
                askedAt: askedAt
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.askedAt != rhs.askedAt { return lhs.askedAt < rhs.askedAt }
            return lhs.stepID < rhs.stepID
        }
    }
}
