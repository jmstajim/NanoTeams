import Foundation

nonisolated extension StepToolCall {
    /// The question text this call carries, when it is an `ask_supervisor` call.
    ///
    /// In chat mode the assistant's whole reply rides in this field — every chat
    /// template ends with "Reply by calling `ask_supervisor` with your full
    /// response in its `question` field" — so this is the text the Watchtower
    /// banner and the composer card both render.
    var parsedSupervisorQuestion: String? {
        Self.parseSupervisorQuestion(from: argumentsJSON)
    }

    /// Extracts the question string from an `ask_supervisor` tool call's argumentsJSON.
    /// Handles both valid JSON and malformed/truncated JSON from streaming.
    static func parseSupervisorQuestion(from text: String) -> String? {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let question = json["question"] as? String,
           !question.isEmpty
        {
            return question
        }

        guard let prefixRange = text.range(
            of: #""question"\s*:\s*""#, options: .regularExpression
        ) else { return nil }

        var extracted = String(text[prefixRange.upperBound...])
        if extracted.hasSuffix("\"}") {
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
}
