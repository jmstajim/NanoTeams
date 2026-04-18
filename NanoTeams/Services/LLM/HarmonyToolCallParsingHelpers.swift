import Foundation

// MARK: - Shared Parsing Helpers

/// Stateless utilities shared across all parsing strategies.
enum ToolCallParsingHelpers {

    static func skipWhitespace(in s: Substring, from index: String.Index) -> String.Index {
        var i = index
        while i < s.endIndex, s[i].isWhitespace {
            i = s.index(after: i)
        }
        return i
    }

    /// Like `extractIdentifier`, but also handles quoted identifiers: `"tool_name"` or `'tool_name'`.
    static func extractIdentifierOrQuoted(in s: Substring, from index: String.Index) -> (
        String, String.Index
    )? {
        guard index < s.endIndex else { return nil }
        let ch = s[index]
        if ch == "\"" || ch == "'" {
            let innerStart = s.index(after: index)
            guard let closeIdx = s[innerStart...].firstIndex(of: ch) else { return nil }
            let inner = String(s[innerStart..<closeIdx])
            guard !inner.isEmpty,
                  inner.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
            else { return nil }
            return (inner, s.index(after: closeIdx))
        }
        return extractIdentifier(in: s, from: index)
    }

    static func extractIdentifier(in s: Substring, from index: String.Index) -> (
        String, String.Index
    )? {
        var i = index
        var out = ""
        while i < s.endIndex {
            let ch = s[i]
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." {
                out.append(ch)
                i = s.index(after: i)
                continue
            }
            break
        }
        guard !out.isEmpty else { return nil }
        return (out, i)
    }

    /// Maximum imbalance we are willing to repair via synthetic closers in
    /// `extractJSONBracedValue`. Tool-call envelopes nest at most ~3 levels
    /// (call object → `arguments` → one nested value), so imbalance beyond
    /// this bound signals truly garbled input rather than the known qwen bug.
    static let maxSalvageDepth = 3

    static func extractJSONBracedValue(in s: Substring, from index: String.Index) -> (
        String, String.Index
    )? {
        let i = index
        guard i < s.endIndex else { return nil }

        let startChar = s[i]
        guard startChar == "{" || startChar == "[" else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        // Track the index *after* the last closing `}`/`]` we processed (any depth, not
        // only the outer one). When the walker exits unbalanced, we truncate there and
        // pad with synthetic closers — anything after the last close is junk (e.g.
        // trailing `<|end|>`).
        var lastCloseEnd: String.Index?

        var end = i
        while end < s.endIndex {
            let ch = s[end]

            if inString {
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" || ch == "[" {
                    depth += 1
                } else if ch == "}" || ch == "]" {
                    depth -= 1
                    lastCloseEnd = s.index(after: end)
                    if depth == 0 {
                        let jsonText = String(s[i...end])
                        let next = s.index(after: end)
                        return (jsonText, next)
                    }
                }
            }

            end = s.index(after: end)
        }

        // Walker reached end with unbalanced braces. Some models (e.g. qwen3.5-4b-mlx)
        // emit `<|call|>{"name":"X","arguments":{…}<|end|>` — missing the outer `}`.
        // Salvage by truncating at the last `}`/`]` we saw (any depth) and padding with
        // synthetic closers. `maxSalvageDepth` guards against truly garbled input;
        // `lastCloseEnd != nil` guards against input with no observed structure.
        if !inString, depth > 0, depth <= Self.maxSalvageDepth, let truncate = lastCloseEnd {
            let salvaged = String(s[i..<truncate]) + String(repeating: "}", count: depth)
            return (salvaged, truncate)
        }

        return nil
    }

    static func advanceCursor(
        in s: Substring, from index: String.Index, endMarker: String
    ) -> String.Index {
        if let endRange = s.range(of: endMarker, range: index..<s.endIndex) {
            return endRange.upperBound
        }
        return index
    }

    static func normalizeArgumentsJSONString(_ jsonText: String) -> String {
        guard let data = jsonText.data(using: .utf8) else { return jsonText }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return jsonText
        }
        if let dict = object as? [String: Any], let s = stableJSONString(from: dict) { return s }
        if let arr = object as? [Any], let s = stableJSONString(from: arr) { return s }
        return jsonText
    }

    static func stableJSONString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: options) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// Harmony channel names that must never surface as tool names. Reserved-name
    /// leaks happened when the model emitted `<|channel|>commentary<|message|>{...}`
    /// without a `to=functions.X` routing — the bare channel name would otherwise
    /// be dispatched as a tool (Run 6).
    static let reservedChannelNames: Set<String> = [
        "commentary", "analysis", "final", "thinking",
    ]

    static func parseToolCallFromJSON(_ jsonText: String) -> StepToolCall? {
        let sanitized = JSONUtilities.sanitizeJSONControlCharacters(jsonText)
        guard let data = sanitized.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let dict = object as? [String: Any]
        else {
            return nil
        }

        let providerID = stringValue(dict["id"]) ?? stringValue(dict["call_id"])

        // Reserved-name guard applies to every shape below, not just the bare-identifier
        // path in `CallMarkerStrategy`. Without this, `{"name":"commentary",...}`
        // would bypass the marker-level filter and reach dispatch as a tool call.
        func acceptingName(_ name: String) -> String? {
            reservedChannelNames.contains(name.lowercased()) ? nil : name
        }

        if let name = stringValue(dict["name"]).flatMap(acceptingName) {
            let args = dict["arguments"] ?? dict["args"] ?? dict["parameters"] ?? dict["params"]
            return StepToolCall(
                providerID: providerID, name: name, argumentsJSON: normalizeArgumentsJSON(args))
        }

        if let toolName = (stringValue(dict["tool_name"]) ?? stringValue(dict["tool"])
            ?? stringValue(dict["function_name"])).flatMap(acceptingName)
        {
            let args = dict["arguments"] ?? dict["args"] ?? dict["parameters"] ?? dict["params"]
            return StepToolCall(
                providerID: providerID, name: toolName, argumentsJSON: normalizeArgumentsJSON(args))
        }

        if let fnDictAny = dict["function"] as? [String: Any],
            let fnName = stringValue(fnDictAny["name"]).flatMap(acceptingName)
        {
            let argsAny = fnDictAny["arguments"] ?? fnDictAny["args"]
            return StepToolCall(
                providerID: providerID, name: fnName, argumentsJSON: normalizeArgumentsJSON(argsAny)
            )
        }

        return nil
    }

    private static func normalizeArgumentsJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        if let dict = value as? [String: Any] {
            return stableJSONString(from: dict) ?? ""
        }
        if let arr = value as? [Any] {
            return stableJSONString(from: arr) ?? ""
        }
        return String(describing: value)
    }

    private static func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String, !s.isEmpty { return s }
        return nil
    }
}
