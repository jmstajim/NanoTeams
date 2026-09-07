import Foundation

/// Resolves the tool calls of a FINISHED reply — one the caller has already collected in
/// full and has no streaming state for — in the precedence the step's streaming resolver
/// applies (`LLMExecutionService+Streaming`, routes 1–3):
///
/// 1. provider-native `tool_calls` deltas, when the client produced any;
/// 2. the Harmony envelope the `## Tool Calling` block teaches, found in the CONTENT
///    channel — the prose the model wrote before the first marker stays the spoken
///    content and the envelope leaves it, because the wire re-materialises the call from
///    `ChatMessage.toolCalls` (`HarmonyToolCallEnvelope.appendedWireText`) and raw text
///    left in place would send it twice;
/// 3. `BareToolCallSalvage` for a reply carrying no sentinel at all.
///
/// It exists because the meeting turn had only route 1: `MeetingStreamingService` read
/// `toolCallDeltas` alone, which no shipping client emits (both providers render the tool
/// schema as text, so the model answers with `<|call|>…<|end|>` in `content`), and every
/// meeting call — `conclude_meeting` included — landed in the transcript as prose while the
/// meeting ended only at `maxMeetingTurns` (audit 2026-09-07, playbook R3.1.4 / R3.8.7).
///
/// Reasoning is never an input: a call written in the reasoning channel is a rehearsal,
/// not an action (playbook R2.3.3), and the caller that has both channels passes only
/// `content` here.
nonisolated enum FinishedReplyToolCallResolver {

    struct Resolution {
        /// What the model SAID — the content channel with the envelope removed.
        var content: String
        var toolCalls: [StepToolCall]
    }

    /// - Parameters:
    ///   - content: the assistant's content channel for this turn, verbatim.
    ///   - nativeCalls: what `ToolCallAccumulator.finalize()` produced from provider deltas.
    ///   - advertised: the schemas sent on this call — read by the bare salvage only, to
    ///     confirm the role really holds a tool named without an envelope.
    static func resolve(
        content: String,
        nativeCalls: [StepToolCall],
        advertised: [ToolSchema]
    ) -> Resolution {
        if !nativeCalls.isEmpty {
            return Resolution(
                content: content,
                toolCalls: LLMExecutionService.deduplicateToolCalls(nativeCalls))
        }

        // Repair a mangled opening sentinel before looking for one, the way the parser
        // does internally — the marker search below must see the same bytes the parser
        // will, or the prose cut and the parse disagree about where the envelope starts.
        let normalized = HarmonySentinelNormalizer.normalize(content)
        if let marker = earliestMarker(in: normalized) {
            let calls = HarmonyToolCallParser().extractAllToolCalls(from: normalized)
            guard !calls.isEmpty else {
                // A marker with no parseable envelope: the turn resolves nothing, and the
                // text stays whole so the reader sees what the model actually wrote.
                return Resolution(content: content, toolCalls: [])
            }
            let prose = String(normalized[..<marker])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Resolution(
                content: prose,
                toolCalls: LLMExecutionService.deduplicateToolCalls(calls))
        }

        if let salvaged = BareToolCallSalvage.salvage(from: content, advertised: advertised) {
            // The promoted payload leaves the content channel for the same reason the
            // envelope does: it is a call now, and the wire will carry it as one.
            return Resolution(content: "", toolCalls: [salvaged])
        }

        return Resolution(content: content, toolCalls: [])
    }

    private static func earliestMarker(in text: String) -> String.Index? {
        HarmonyToolCallParser.harmonyMarkers
            .compactMap { text.range(of: $0)?.lowerBound }
            .min()
    }
}
