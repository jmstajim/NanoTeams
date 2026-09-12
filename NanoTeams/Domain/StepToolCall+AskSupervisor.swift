import Foundation

nonisolated extension StepToolCall {
    /// Whether this call is one of the parking tools — `ask_supervisor` or its questionnaire
    /// sibling — by NAME. Membership in the closed set, not equality with one name: a step
    /// parked by `ask_supervisor_form` must resolve to ITS call, or the question has no
    /// persisted identity and `activeSupervisorQuestionID` hands the Watchtower dismissal its
    /// question TEXT instead — under which a re-asked identical headline is born dismissed.
    ///
    /// `name` is written once, at append, and no writer rewrites it (the closed set pinned by
    /// `AskCallIndexTests.testToolCallsWriterSet_isClosed`) — which is what lets `AskCallIndex`
    /// cache the answer.
    var isSupervisorAsk: Bool { ToolNames.supervisorAskTools.contains(name) }

    /// An ask the runtime REFUSED: named like a question, it asked nobody anything. The plain
    /// ask refusing the questionnaire's shape (`QUESTIONNAIRE_REQUIRED`), the form refusing its
    /// own JSON (`INVALID_ARGS`), a tool the role does not hold (`tool_not_authorized`) — each
    /// returns an error envelope and no park, and the loop goes on.
    ///
    /// Not an ask, for every reader. The feed pairs answer k with PARK k, so a refused call
    /// counted as a park took the answer meant for the form that followed it and drew an
    /// "asked … (answered)" card of its own for every refused retry; the composer read a
    /// trailing refused call as a live question on a step that was still running
    /// (MeditationApp task 52 run 9, 2026-09-11). `isError` lands with the RESULT, after the
    /// call was appended (`appendToolCalls` → `updateToolCallResult`), so this is read off the
    /// live record and never cached — see `AskCallIndex.parkedPositions(in:)`. `nil` is not a
    /// refusal: the call is in flight, or the record predates the field.
    var isRefusedAsk: Bool { isSupervisorAsk && isError == true }

    /// The one-line question text this call carries, for either parking tool.
    ///
    /// In chat mode the assistant's whole reply rides in `ask_supervisor`'s `question`
    /// field — every chat template ends with "Reply by calling `ask_supervisor` with your
    /// full response in its `question` field" — so this is the text the Watchtower banner
    /// and the composer card both render.
    ///
    /// `ask_supervisor_form` spells the same slot `headline`, and that is the WHOLE reason
    /// the form carries a mandatory headline: every surface that renders a supervisor
    /// question renders a `String`, and a form that had only structure would have gone
    /// blank on all of them at once.
    var parsedSupervisorQuestion: String? {
        Self.parseSupervisorQuestion(from: argumentsJSON)
    }

    /// The argument keys that carry a parking call's one-line text, in preference order.
    /// A call is never both, so the order only decides which is tried first.
    private static let questionTextKeys = ["question", "headline"]

    /// Extracts the question string from a parking tool call's argumentsJSON.
    /// Handles both valid JSON and malformed/truncated JSON from streaming.
    ///
    /// The truncated-stream branch is not a nicety: the card renders while the call is
    /// still arriving, and without it a form shows `"?"` for as long as its (much larger)
    /// JSON body takes to stream. `headline` is declared first in the form's contract so
    /// that branch reaches it early.
    static func parseSupervisorQuestion(from text: String) -> String? {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for key in questionTextKeys {
                if let value = json[key] as? String, !value.isEmpty { return value }
            }
        }

        for key in questionTextKeys {
            if let extracted = truncatedStringValue(forKey: key, in: text) { return extracted }
        }
        return nil
    }

    /// Pulls `"<key>": "…"` out of JSON too truncated to parse, unescaping the three
    /// sequences a streamed string can carry.
    private static func truncatedStringValue(forKey key: String, in text: String) -> String? {
        guard let prefixRange = text.range(
            of: #""\#(key)"\s*:\s*""#, options: .regularExpression
        ) else { return nil }

        var extracted = String(text[prefixRange.upperBound...])
        // A complete value inside a larger object ends at its own quote, not at the object's
        // brace — so stop at the first unescaped quote when there is one, and otherwise take
        // the whole tail (the mid-stream case this branch exists for).
        if let end = unescapedQuoteIndex(in: extracted) {
            extracted = String(extracted[extracted.startIndex..<end])
        } else if extracted.hasSuffix("\"}") {
            extracted = String(extracted.dropLast(2))
        } else if extracted.hasSuffix("\"") {
            extracted = String(extracted.dropLast(1))
        }
        extracted = extracted
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return extracted.isEmpty ? nil : extracted
    }

    /// Index of the first `"` not preceded by an odd run of backslashes, or nil when the
    /// string never closes (truncated mid-value).
    private static func unescapedQuoteIndex(in text: String) -> String.Index? {
        var backslashes = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" && backslashes % 2 == 0 { return index }
            backslashes = character == "\\" ? backslashes + 1 : 0
            index = text.index(after: index)
        }
        return nil
    }
}
