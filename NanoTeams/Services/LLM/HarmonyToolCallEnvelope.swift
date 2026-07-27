import Foundation

/// Renders the Harmony tool-call envelope — the RENDER half of the format whose PARSE half is
/// `HarmonyToolCallParser`, and whose markers that type owns.
///
/// It exists because the envelope has to be re-materialized at all. The streaming path commits
/// an assistant turn by truncating everything from the first Harmony marker onwards out of the
/// content (`LLMExecutionService+Streaming.swift`, `assistantCollected = preMarker`) and filing
/// the calls under `ChatMessage.toolCalls` instead. That path is shared by both providers, and
/// `wireTranscript` persists the same shape. So an envelope-only turn has `content == nil`, and
/// a stateless full-history resend that renders only `content` shows the model an empty
/// assistant turn followed by an orphan `[Tool Result]` — tool results for calls it has no
/// record of making, on every remaining iteration of the step.
///
/// One owner rather than one copy per builder, because FOUR surfaces have to agree on these
/// bytes and disagreeing is silent: `OllamaClient.buildRequest`, `NativeLMStudioClient
/// .buildRequest`, `ContextBudgetPolicy.estimateTokens` (an under-count keeps the overflow
/// banner quiet while the server truncates the prompt head) and `PromptPrefixFingerprint
/// .segmentText` (hashing bytes the wire does not carry reports a cache miss the server cannot
/// see). Same lesson as `NativeLMStudioClient.toolSchemaTextForMeasurement`, one level down:
/// there the measurement MIRRORS the wire, here it shares the wire's own function.
///
/// `nonisolated` because the app target defaults types to `@MainActor`; pure value-in /
/// value-out (house pattern: `ContextBudgetPolicy`, `PromptPrefixFingerprint`).
nonisolated enum HarmonyToolCallEnvelope {

    /// One envelope, byte-identical to what the model emits and what `HarmonyToolCallParser`
    /// reads back.
    ///
    /// Key order is always `name` then `arguments`. Deliberately assembled by hand rather than
    /// via `JSONEncoder`: `.sortedKeys` would put `arguments` first and silently change the
    /// bytes of every tool call in the app, invalidating every server prompt-prefix cache.
    static func text(name: String, argumentsJSON: String) -> String {
        HarmonyToolCallParser.callMarker
            + "{\"name\":\(jsonStringLiteral(name)),\"arguments\":\(arguments(from: argumentsJSON))}"
            + HarmonyToolCallParser.endMarker
    }

    /// The text a request builder APPENDS to `message.content` on the wire: a `"\n"` separator
    /// plus one envelope per call.
    ///
    /// Returns the appended TAIL rather than the whole assistant content so it composes
    /// additively — `ContextBudgetPolicy.estimateTokens` already prices `content`, and
    /// `PrefixCachePolicy.discardedTokens` prices an arbitrary message SLICE. Both stay
    /// role-blind because the role gate lives here.
    ///
    /// `""` for any non-`.assistant` role: `ChatMessage` permits `toolCalls` on any role, but
    /// neither builder reads the field outside its `.assistant` branch, so nothing else may
    /// price or hash it either.
    static func appendedWireText(for message: ChatMessage) -> String {
        guard message.role == .assistant,
              let calls = message.toolCalls, !calls.isEmpty
        else { return "" }

        // Mirrors the builder's accumulate-then-test semantics exactly: the separator goes in
        // when the content so far is non-empty, which after the first envelope it always is.
        // So nil/empty content with N calls yields N-1 separators, non-empty content yields N.
        // The test is `isEmpty`, not trimmed — whitespace-only content gets a separator.
        var precedingIsEmpty = (message.content ?? "").isEmpty
        var out = ""
        for call in calls {
            if !precedingIsEmpty { out += "\n" }
            out += text(name: call.name, argumentsJSON: call.argumentsJSON)
            precedingIsEmpty = false
        }
        return out
    }

    // MARK: - Private

    /// The arguments value, spliced VERBATIM — it is already JSON, and the model's whitespace
    /// and key order are part of the bytes the server cached, so re-encoding would break the
    /// prefix.
    ///
    /// The one exception is an empty value, which is reachable and used to emit invalid JSON:
    /// a model calling a zero-argument tool as `{"name":"git_status"}` leaves
    /// `ToolCallShapeRecognizer` with nothing to promote, `normalizeArgumentsJSON` returns `""`,
    /// and splicing that produced `"arguments":` with no value at all — resent to the model as
    /// an example of its own prior call, on a pipeline whose tool calling IS prompt-based.
    private static func arguments(from argumentsJSON: String) -> String {
        argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : argumentsJSON
    }

    /// `value` as a quoted, escaped JSON string literal.
    ///
    /// The name is model-controlled — `ToolCallShapeRecognizer` accepts whatever string the
    /// envelope decoded — so interpolating it raw into a string literal, as this did, let a
    /// name containing `"` or `\` produce unparseable JSON that then rode every later resend.
    /// Foundation does the escaping so the rules are not re-implemented here; it leaves
    /// non-ASCII as UTF-8, which keeps a Cyrillic tool name byte-stable.
    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let wrapped = String(data: data, encoding: .utf8),
              wrapped.hasPrefix("["), wrapped.hasSuffix("]")
        else {
            // Unreachable: a `[String]` is always serializable. Falling back to the raw
            // interpolation keeps the call renderable rather than dropping it silently.
            return "\"\(value)\""
        }
        return String(wrapped.dropFirst().dropLast())
    }
}
