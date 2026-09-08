import Foundation

/// The one extra LLM call a compaction epoch spends: asks the model to summarise its own
/// conversation, and streams the answer into the step's live bubble as it is written.
///
/// **Why not `performStreamingCall`,** the tool loop's own send:
/// - it resolves the reply's Harmony envelope into `resolvedToolCalls` and the caller then
///   DISPATCHES them — a summary that mentions a tool would run it;
/// - it feeds `LoopScanner`, which can break the stream mid-summary as a repetition;
/// - on cancellation it COMMITS the partial text as a turn, and this reply must never
///   become a turn: the wire it summarises is about to be replaced by it;
/// - it registers the call against the step's own prefix chain, while this one is a
///   one-shot interleave that deliberately owns nothing.
///
/// So this is the shape `SupervisorAutoAnswerService` uses — `client.streamChat` with an
/// empty tool array, both channels collected, `CancellationClassifier` separating a Pause
/// from a failure — plus the streaming delegate call that makes the write VISIBLE.
///
/// Visible as a DISCLOSURE, never as prose: the caller has exactly one buffer to write into,
/// the one the "Compacting…" row opens, so this service hands it a single joined delta rather
/// than two channels. The bubble is discarded when the epoch ends, because the durable record
/// is the collapsed feed row and the seed on the wire, not a turn the model never took.
///
/// `nonisolated` because the app target defaults types to `@MainActor` and the delegate
/// calls are individually awaited on it.
nonisolated enum ContextCompactionSummaryService {

    /// What the epoch got back.
    struct Outcome {
        /// The summary prose, or `nil` when the model produced nothing usable.
        let summary: String?
        /// True when the call was CANCELLED rather than failed — the caller must then leave
        /// the wire alone and post no banner, exactly as a Pause requires.
        let wasCancelled: Bool
    }

    /// Streams one summary request.
    ///
    /// - Parameters:
    ///   - wire: the conversation to summarise. Sent as-is with the rubric appended; never
    ///     mutated, and the reply is never appended to it.
    ///   - onDelta: called on the main actor with the epoch's DISCLOSURE delta — reasoning
    ///     and summary joined in arrival order — so the caller can drive the live bubble with
    ///     one append. Joined HERE because the channel flip is only detectable against the
    ///     accumulators, which live here; a caller doing it would need state of its own. Not
    ///     called for an event carrying neither channel. The caller owns the epoch gate — this
    ///     service does not know whether its epoch is still the current one.
    static func summarize(
        wire: [ChatMessage],
        client: any LLMClient,
        config: LLMConfig,
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?,
        onDelta: @MainActor @Sendable (_ disclosureDelta: String) async -> Void
    ) async -> Outcome {
        let messages =
            wire + [ChatMessage(role: .user, content: CompactionPolicy.summaryRequestTurn())]

        var collected = ""
        var reasoning = ""
        do {
            // prefix-cache-owner: registered by the caller —
            // `LLMExecutionService+ContextCompaction` notes `.oneShot("context compaction")`.
            // An interleave rather than an owner: the step's own chain must survive the
            // epoch, and this request's prefix is thrown away with the wire it carries.
            for try await event in client.streamChat(
                config: config, messages: messages, tools: [],
                logger: logger, stepID: stepID, roleName: roleName)
            {
                var disclosure = event.thinkingDelta
                if !event.contentDelta.isEmpty {
                    // One blank line at the channel flip, and only there. The detail window
                    // renders one flat `Text` and the model does not end its reasoning with a
                    // paragraph break, so without this the summary runs straight on from the
                    // last thought. `collected` is still empty on the flip event, and the
                    // reasoning test spans this event too — a first event carrying BOTH
                    // channels still needs the separator between them.
                    if collected.isEmpty && !(reasoning.isEmpty && event.thinkingDelta.isEmpty) {
                        disclosure += "\n\n"
                    }
                    disclosure += event.contentDelta
                    collected += event.contentDelta
                }
                // Reasoning models put the whole summary here and leave `content` empty —
                // the same channel asymmetry every other one-shot caller recovers from.
                if !event.thinkingDelta.isEmpty { reasoning += event.thinkingDelta }
                if !disclosure.isEmpty { await onDelta(disclosure) }
            }
        } catch {
            // A Pause, a work-folder switch or a re-entry cancels this task, and none of
            // them is a failure: the caller must leave the conversation exactly as it found
            // it. Distinguished here rather than by the caller inspecting the error, for the
            // same reason the auto-answerer distinguishes it — returning a "failed" outcome
            // would let the caller post a banner about a click the user already took back.
            if CancellationClassifier.isCancellation(error) {
                return Outcome(summary: nil, wasCancelled: true)
            }
            return Outcome(summary: nil, wasCancelled: false)
        }

        // Cleaned for the reason every one-shot reply is: this string is written into a
        // `.user` turn that is resent on every remaining request of the step, and a stray
        // `<|channel|>` token there is read by the next request as a malformed envelope.
        let reply = ModelReplyChannels.answer(
            content: collected,
            reasoning: reasoning,
            prepare: { ConversationRepairService.cleanHarmonyTokens(ModelTokenCleaner.clean($0)) })

        // A model told "write prose, do not call a tool" still sometimes calls one — its
        // system prompt carries the whole catalog. The resolver recovers the prose the model
        // wrote before the envelope; `summaryText` then digs into the call's arguments when
        // it wrote nothing else, rather than discarding a summary that exists.
        let resolution = FinishedReplyToolCallResolver.resolve(
            content: reply, nativeCalls: [], advertised: [])
        return Outcome(
            summary: CompactionPolicy.summaryText(from: resolution), wasCancelled: false)
    }
}
