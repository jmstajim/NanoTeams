import Foundation

/// Result of parsing a single tool call attempt.
nonisolated enum ToolCallParseResult {
    case success(StepToolCall)
    case unknownFormat(rawText: String)
}

/// Universal parser that attempts multiple strategies to extract tool calls.
nonisolated struct UniversalToolCallParser {
    private let harmonyParser: HarmonyToolCallParser

    init(
        harmonyParser: HarmonyToolCallParser = HarmonyToolCallParser()
    ) {
        self.harmonyParser = harmonyParser
    }

    /// Parse tool calls from model output.
    /// - Returns: Tuple of (parsed calls, unknown format texts)
    func parse(
        from text: String
    ) -> (calls: [StepToolCall], unknownFormats: [String]) {
        var results: [StepToolCall] = []
        var unknownFormats: [String] = []

        // Strategy 1: Use existing HarmonyToolCallParser
        let harmonyCalls = harmonyParser.extractAllToolCalls(from: text)

        results.append(contentsOf: harmonyCalls)

        // If no calls found, check if there's a tool call pattern we don't recognize
        if results.isEmpty && containsToolCallMarkers(in: text) {
            unknownFormats.append(text)
        }

        return (results, unknownFormats)
    }

    /// Check if text contains markers that suggest a tool call was attempted.
    /// Combines the canonical Harmony marker set (single source of truth on
    /// `HarmonyToolCallParser`) with broader "looks like a tool-call attempt"
    /// heuristics — the latter catch OpenAI-style payloads where the model
    /// emits raw JSON without Harmony framing.
    private func containsToolCallMarkers(in text: String) -> Bool {
        if HarmonyToolCallParser.harmonyMarkers.contains(where: { text.contains($0) }) {
            return true
        }
        let extraHeuristics = [
            "to=",
            "\"function\"",
            "\"tool\"",
            "\"name\":",
            "\"arguments\":",
        ]
        return extraHeuristics.contains { text.contains($0) }
    }
}
