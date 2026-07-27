import Foundation

/// Pure resolution of "what conversation should a RE-ENTERING step continue from".
///
/// A step suspends whenever it needs the Supervisor (an `ask_supervisor` question, the
/// Autovisor's `wait_for_events` idle park, a pause) and re-enters once answered. The
/// in-memory conversation array dies with the step's `Task`, so re-entry has to recover
/// it from disk.
///
/// Recovering it by re-synthesizing through `PromptBuilder` — what the code did before —
/// is wrong twice over. `PromptBuilder` reads `step.messages` and never
/// `step.llmConversation` or `step.toolCalls`, and in a Harmony tool loop almost every
/// assistant turn is envelope-only, so no `StepMessage` is written for it and tool
/// results are not written there at all: the model wakes with no memory of the work it
/// already did. And the synthesized prompt diverges from the one already processed
/// within the first message or two, so the server's prompt-prefix cache misses and the
/// whole context is re-evaluated (measured on this project's models: ~7 s instead of
/// ~350 ms at 13k tokens).
///
/// `nonisolated` because the app target defaults types to `@MainActor`; this is pure
/// value-in / value-out (house pattern: `PlanningPhasePolicy`, `LoopRecoveryPolicy`,
/// `TeamResolution`).
nonisolated enum ConversationReplay {

    /// Where a replayed conversation came from. Reported so callers can tell a faithful
    /// replay from a degraded one without re-deriving the condition.
    enum Source: Equatable {
        /// Byte-faithful: exactly the `[ChatMessage]` array last sent. Prefix cache hits.
        case wireTranscript
        /// Best-effort rebuild from the display record, for steps persisted before
        /// `wireTranscript` existed. Semantically complete — `llmConversation` does carry
        /// every tool call and result — but not byte-identical to what was sent, so the
        /// prefix cache will miss once. Self-heals: the next suspend writes a real
        /// transcript.
        case legacyConversation
    }

    /// The conversation to continue from, or `nil` when the step has no history and the
    /// caller should build a fresh prompt.
    static func resume(from step: StepExecution) -> (messages: [ChatMessage], source: Source)? {
        if !step.wireTranscript.isEmpty {
            return (step.wireTranscript, .wireTranscript)
        }
        let rebuilt = rebuildFromDisplayRecord(step.llmConversation)
        guard !rebuilt.isEmpty else { return nil }
        return (rebuilt, .legacyConversation)
    }

    /// Maps the display record onto wire messages for the legacy path.
    ///
    /// Display-only entries are dropped — they were never sent, so replaying them would
    /// both mislead the model and guarantee a prefix miss:
    /// - `.serverError` retry notices (`TaskMutationService.appendOrReplaceRetryNotice`),
    /// - the delegation Q/A pairs recorded purely for activity-feed visibility.
    ///
    /// `.tool` entries keep their `[CALL] … Arguments: … [RESULT] …` composite verbatim.
    /// It is self-describing, so a model reading it recovers which call produced which
    /// result — which matters because `providerID` is nil in essentially all production
    /// traffic (no client emits `toolCallDeltas`; the Harmony parser hard-codes nil), so
    /// there is no `tool_call_id` to pair on and never was.
    static func rebuildFromDisplayRecord(_ conversation: [LLMMessage]) -> [ChatMessage] {
        conversation.compactMap { message -> ChatMessage? in
            switch message.sourceContext {
            case .serverError, .delegatedQuestion, .delegationEscalation:
                return nil
            default:
                break
            }
            guard let role = MessageRole(rawValue: message.role.rawValue) else { return nil }
            // An assistant turn that carried only a tool-call envelope persists with empty
            // content (the streaming path truncates at the Harmony marker). Dropping it
            // keeps the replay from showing the model a run of blank assistant turns; the
            // following `.tool` composite still names the call.
            if role == .assistant, message.content.isEmpty { return nil }
            return ChatMessage(role: role, content: message.content)
        }
    }
}
