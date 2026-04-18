import Foundation

// MARK: - Strategy Protocol

/// Strategy for parsing tool calls from a specific marker format.
/// Implement this protocol to add new marker-based parsing formats (OCP).
protocol ToolCallParsingStrategy: Sendable {
    func parse(from text: String) -> [StepToolCall]
}

// MARK: - Call Marker Strategy

/// Parses `<|call|>` format: `<|call|>{JSON}<|end|>` or `<|call|>tool_name {JSON}<|end|>`
struct CallMarkerStrategy: ToolCallParsingStrategy {
    static let callMarker = "<|call|>"
    static let endMarker = "<|end|>"

    func parse(from text: String) -> [StepToolCall] {
        guard let firstMarkerRange = text.range(of: Self.callMarker) else { return [] }

        let tail = text[firstMarkerRange.lowerBound...]
        var cursor = tail.startIndex
        var results: [StepToolCall] = []

        while let markerRange = tail.range(of: Self.callMarker, range: cursor..<tail.endIndex) {
            var idx = markerRange.upperBound
            idx = ToolCallParsingHelpers.skipWhitespace(in: tail, from: idx)

            if idx >= tail.endIndex { break }

            if tail[idx] == "{" {
                if let (jsonText, endIdx) = ToolCallParsingHelpers.extractJSONBracedValue(
                    in: tail, from: idx)
                {
                    if let call = ToolCallParsingHelpers.parseToolCallFromJSON(jsonText) {
                        results.append(call)
                    }
                    cursor = ToolCallParsingHelpers.advanceCursor(
                        in: tail, from: endIdx, endMarker: Self.endMarker)
                    continue
                }
            }

            if let (name, nameEnd) = ToolCallParsingHelpers.extractIdentifier(in: tail, from: idx),
               !ChannelMarkerStrategy.reservedChannelNames.contains(name.lowercased()) {
                let argsIdx = ToolCallParsingHelpers.skipWhitespace(in: tail, from: nameEnd)
                if argsIdx < tail.endIndex, tail[argsIdx] == "{" {
                    if let (jsonText, endIdx) = ToolCallParsingHelpers.extractJSONBracedValue(
                        in: tail, from: argsIdx)
                    {
                        let args = ToolCallParsingHelpers.normalizeArgumentsJSONString(
                            JSONUtilities.sanitizeJSONControlCharacters(jsonText))
                        results.append(
                            StepToolCall(providerID: nil, name: name, argumentsJSON: args))
                        cursor = ToolCallParsingHelpers.advanceCursor(
                            in: tail, from: endIdx, endMarker: Self.endMarker)
                        continue
                    }
                }
            }

            // This `<|call|>` couldn't be extracted (reserved channel name,
            // malformed JSON, missing identifier). Advance past it so subsequent
            // legitimate `<|call|>TOOL{...}<|end|>` blocks in the same message
            // can still be parsed instead of dropping the rest.
            cursor = ToolCallParsingHelpers.advanceCursor(
                in: tail, from: idx, endMarker: Self.endMarker)
        }

        return results
    }
}

// MARK: - Start Marker Strategy

/// Parses `<|start|>functions.TOOL_NAME<|message|>{JSON}` format.
struct StartMarkerStrategy: ToolCallParsingStrategy {
    static let startMarker = "<|start|>"
    static let messageMarker = "<|message|>"
    static let endMarker = "<|end|>"

    func parse(from text: String) -> [StepToolCall] {
        guard let firstMarkerRange = text.range(of: Self.startMarker) else { return [] }

        let tail = text[firstMarkerRange.lowerBound...]
        var cursor = tail.startIndex
        var results: [StepToolCall] = []

        while let markerRange = tail.range(of: Self.startMarker, range: cursor..<tail.endIndex) {
            var idx = markerRange.upperBound
            idx = ToolCallParsingHelpers.skipWhitespace(in: tail, from: idx)

            let prefix = "functions."
            guard tail[idx...].hasPrefix(prefix) else {
                cursor = ToolCallParsingHelpers.advanceCursor(
                    in: tail, from: idx, endMarker: Self.endMarker)
                continue
            }

            idx = tail.index(idx, offsetBy: prefix.count)
            guard let (name, nameEnd) = ToolCallParsingHelpers.extractIdentifier(in: tail, from: idx)
            else {
                cursor = ToolCallParsingHelpers.advanceCursor(
                    in: tail, from: idx, endMarker: Self.endMarker)
                continue
            }

            guard
                let messageRange = tail.range(
                    of: Self.messageMarker, range: nameEnd..<tail.endIndex)
            else {
                cursor = ToolCallParsingHelpers.advanceCursor(
                    in: tail, from: nameEnd, endMarker: Self.endMarker)
                continue
            }

            var argsIdx = messageRange.upperBound
            argsIdx = ToolCallParsingHelpers.skipWhitespace(in: tail, from: argsIdx)
            guard argsIdx < tail.endIndex, tail[argsIdx] == "{" else {
                cursor = ToolCallParsingHelpers.advanceCursor(
                    in: tail, from: messageRange.upperBound, endMarker: Self.endMarker)
                continue
            }

            if let (jsonText, endIdx) = ToolCallParsingHelpers.extractJSONBracedValue(
                in: tail, from: argsIdx)
            {
                let args = ToolCallParsingHelpers.normalizeArgumentsJSONString(
                    JSONUtilities.sanitizeJSONControlCharacters(jsonText))
                results.append(StepToolCall(providerID: nil, name: name, argumentsJSON: args))
                cursor = ToolCallParsingHelpers.advanceCursor(
                    in: tail, from: endIdx, endMarker: Self.endMarker)
                continue
            }

            cursor = ToolCallParsingHelpers.advanceCursor(
                in: tail, from: argsIdx, endMarker: Self.endMarker)
        }

        return results
    }
}

// MARK: - Channel Marker Strategy

/// Parses `<|channel|>` tool call formats:
/// - `<|channel|>commentary to=TOOL_NAME ...<|message|>{JSON}` (with optional quotes around TOOL_NAME)
/// - `<|channel|>final <|constrain|>TOOL_NAME<|message|>{JSON}` (tool name in constrain marker)
struct ChannelMarkerStrategy: ToolCallParsingStrategy {
    static let channelMarker = "<|channel|>"
    static let messageMarker = "<|message|>"
    static let constrainMarker = "<|constrain|>"

    /// Format keywords that appear after `<|constrain|>` but are NOT tool names.
    private static let constrainFormatKeywords: Set<String> = [
        "json", "text", "markdown", "xml", "html", "yaml",
    ]

    fileprivate static var reservedChannelNames: Set<String> {
        ToolCallParsingHelpers.reservedChannelNames
    }

    func parse(from text: String) -> [StepToolCall] {
        guard text.contains(Self.channelMarker) else { return [] }

        var results: [StepToolCall] = []
        var searchStart = text.startIndex

        while let channelRange = text.range(
            of: Self.channelMarker, range: searchStart..<text.endIndex)
        {
            let afterChannel = channelRange.upperBound

            // Determine the boundary for this channel block (next channel marker or end)
            let blockEnd =
                text.range(of: Self.channelMarker, range: afterChannel..<text.endIndex)?
                    .lowerBound ?? text.endIndex

            // Try to extract tool name from to= (supports quoted: to= "tool_name")
            var toolName: String?
            var nameEnd: String.Index = afterChannel

            if let toRange = text.range(of: "to=", range: afterChannel..<blockEnd) {
                let nameSearchStart = ToolCallParsingHelpers.skipWhitespace(
                    in: text[toRange.upperBound...], from: toRange.upperBound)
                if let (name, end) = ToolCallParsingHelpers.extractIdentifierOrQuoted(
                    in: text[nameSearchStart...], from: nameSearchStart)
                {
                    toolName = name
                    nameEnd = end
                }
            }

            // Fallback: extract tool name from <|constrain|>TOOL_NAME (if not a format keyword)
            if toolName == nil,
                let constrainRange = text.range(
                    of: Self.constrainMarker, range: afterChannel..<blockEnd)
            {
                let afterConstrain = constrainRange.upperBound
                if let (candidate, end) = ToolCallParsingHelpers.extractIdentifier(
                    in: text[afterConstrain...], from: afterConstrain)
                {
                    let lowered = candidate.lowercased()
                    if !Self.constrainFormatKeywords.contains(lowered),
                       !Self.reservedChannelNames.contains(lowered) {
                        toolName = candidate
                        nameEnd = end
                    }
                }
            }

            guard let resolvedName = toolName else {
                searchStart = afterChannel
                continue
            }

            // Strategy 1: Look for standard <|message|> marker
            if let messageRange = text.range(
                of: Self.messageMarker, range: afterChannel..<blockEnd)
            {
                var jsonStart = messageRange.upperBound
                jsonStart = ToolCallParsingHelpers.skipWhitespace(
                    in: text[jsonStart...], from: jsonStart)

                if jsonStart < text.endIndex, text[jsonStart] == "{" {
                    if let (jsonText, endIdx) = ToolCallParsingHelpers.extractJSONBracedValue(
                        in: text[jsonStart...], from: jsonStart)
                    {
                        let args = ToolCallParsingHelpers.normalizeArgumentsJSONString(
                            JSONUtilities.sanitizeJSONControlCharacters(jsonText))
                        results.append(
                            StepToolCall(
                                providerID: nil, name: resolvedName, argumentsJSON: args))
                        searchStart = endIdx
                        continue
                    }
                }
            }

            // Strategy 2: Fallback - look for JSON start '{' directly (bounded to this block)
            let fallbackSearchStart = ToolCallParsingHelpers.skipWhitespace(
                in: text[nameEnd..<blockEnd], from: nameEnd)
            if let firstBrace = text[fallbackSearchStart..<blockEnd].firstIndex(of: "{") {
                if let (jsonText, endIdx) = ToolCallParsingHelpers.extractJSONBracedValue(
                    in: text[firstBrace...], from: firstBrace)
                {
                    let args = ToolCallParsingHelpers.normalizeArgumentsJSONString(
                        JSONUtilities.sanitizeJSONControlCharacters(jsonText))
                    results.append(
                        StepToolCall(
                            providerID: nil, name: resolvedName, argumentsJSON: args))
                    searchStart = endIdx
                    continue
                }
            }

            searchStart = nameEnd
        }

        return results
    }
}

// MARK: - Composite Parser

struct HarmonyToolCallParser: Sendable {
    static let callMarker = CallMarkerStrategy.callMarker
    static let startFunctionPrefix = "<|start|>functions."
    static let channelMarker = ChannelMarkerStrategy.channelMarker

    private let strategies: [ToolCallParsingStrategy]

    static func defaultStrategies() -> [ToolCallParsingStrategy] {
        [CallMarkerStrategy(), StartMarkerStrategy(), ChannelMarkerStrategy()]
    }

    init(strategies: [ToolCallParsingStrategy] = HarmonyToolCallParser.defaultStrategies()) {
        self.strategies = strategies
    }

    func extractAllToolCalls(from text: String) -> [StepToolCall] {
        var results: [StepToolCall] = []

        func key(for call: StepToolCall) -> String {
            call.name.lowercased() + "|" + call.argumentsJSON
        }

        for strategy in strategies {
            let calls = strategy.parse(from: text)
            guard !calls.isEmpty else { continue }
            if results.isEmpty {
                results = calls
            } else {
                let existing = Set(results.map(key))
                for call in calls where !existing.contains(key(for: call)) {
                    results.append(call)
                }
            }
        }

        return results
    }
}
