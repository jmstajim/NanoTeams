import Foundation

/// Centralized JSON parsing and serialization utilities.
nonisolated enum JSONUtilities {

    /// Parses a JSON string into a dictionary.
    /// - Parameter json: The JSON string to parse.
    /// - Returns: A dictionary if parsing succeeds, nil otherwise.
    static func parseJSONDictionary(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    /// Converts a dictionary to a JSON string.
    /// - Parameter dict: The dictionary to serialize.
    /// - Returns: A JSON string, or "{}" if serialization fails.
    static func jsonStringForToolArgs(_ dict: [String: Any]) -> String {
        if dict.isEmpty { return "{}" }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
            let s = String(data: data, encoding: .utf8)
        {
            return s
        }
        return "{}"
    }

    /// Escapes a string for use in JSON.
    /// - Parameter string: The string to escape.
    /// - Returns: The escaped string suitable for JSON embedding.
    static func escapeForJSON(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for char in string {
            switch char {
            case "\"":
                result.append(contentsOf: "\\\"")
            case "\\":
                result.append(contentsOf: "\\\\")
            case "\n":
                result.append(contentsOf: "\\n")
            case "\r":
                result.append(contentsOf: "\\r")
            case "\t":
                result.append(contentsOf: "\\t")
            default:
                result.append(char)
            }
        }
        return result
    }

    /// Characters that may legally follow a backslash inside a JSON string escape.
    private static let validJSONEscapeCharacters: Set<Character> = [
        "\"", "\\", "/", "b", "f", "n", "r", "t", "u",
    ]

    /// Whether `ch` is a raw control character (0x00–0x1F) that JSON strings may not
    /// contain literally.
    private static func isControlCharacter(_ ch: Character) -> Bool {
        guard let code = ch.asciiValue else { return false }
        return code < 0x20
    }

    /// Appends `ch`, escaping it when it is a raw control character that JSON strings may
    /// not contain literally.
    private static func appendEscapingControlCharacter(_ ch: Character, into result: inout String) {
        guard let code = ch.asciiValue, code < 0x20 else {
            result.append(ch)
            return
        }
        switch ch {
        case "\n": result.append("\\n")
        case "\r": result.append("\\r")
        case "\t": result.append("\\t")
        default: result.append(String(format: "\\u%04x", code))
        }
    }

    /// Cleans up JSON string values that LLMs commonly mangle, so `JSONSerialization`
    /// accepts the payload. Two defects are repaired, both only inside quoted strings:
    ///
    /// 1. **Raw control characters** (0x00–0x1F) emitted literally instead of as `\n`/`\t`
    ///    — escaped to their valid form.
    /// 2. **A backslash directly before a raw control character** — e.g. gemma-4-26b-a4b
    ///    emitting a hallucinated Python line-continuation `\` before a real newline
    ///    (`...range(n):` + `\` + <newline>). This is *unambiguously* broken (valid JSON
    ///    never contains a raw control char), so the stray `\` is turned into a literal
    ///    `\\` and the control char escaped — always recovering to parseable JSON.
    ///
    /// Deliberately NOT repaired: a backslash before an ordinary non-escape char (`\U`,
    /// `\d`, …). That is ambiguous (literal `\` vs the model's intent) and "fixing" it can
    /// silently corrupt an *adjacent* valid escape — e.g. `C:\Users\foo`, where doubling
    /// `\U` makes the whole value parse and leaves `\f` decoding to a form-feed. Those are
    /// left for strict parse to reject so the model retries (fail closed) rather than
    /// dispatching a corrupted argument.
    ///
    /// Both repaired defects are unreachable for well-formed JSON (valid JSON has no raw
    /// control chars inside strings), so this is a pure superset of passing valid input
    /// through unchanged. Uses inString/escape tracking so only string contents are
    /// touched, never structural punctuation.
    static func sanitizeJSONControlCharacters(_ jsonText: String) -> String {
        var result = ""
        result.reserveCapacity(jsonText.count + 64)
        var inString = false
        var escape = false

        for ch in jsonText {
            if inString {
                if escape {
                    escape = false
                    if validJSONEscapeCharacters.contains(ch) {
                        // Valid escape sequence (\" \\ \/ \b \f \n \r \t \u…) — keep as-is.
                        result.append(ch)
                    } else if Self.isControlCharacter(ch) {
                        // `\` directly before a RAW control char (the observed line-
                        // continuation-before-newline defect). The stray `\` was emitted on
                        // the previous iteration (the `ch == "\\"` branch); emit a second to
                        // make a literal escaped backslash `\\`, then escape the control char.
                        result.append("\\")
                        Self.appendEscapingControlCharacter(ch, into: &result)
                    } else {
                        // `\` before an ordinary non-escape char (e.g. `\U`, `\d`). Ambiguous
                        // and corruption-prone (see doc) — leave it for strict parse to
                        // reject so the model retries. Fail closed.
                        result.append(ch)
                    }
                } else if ch == "\\" {
                    escape = true
                    result.append(ch)
                } else if ch == "\"" {
                    inString = false
                    result.append(ch)
                } else {
                    Self.appendEscapingControlCharacter(ch, into: &result)
                }
            } else {
                if ch == "\"" { inString = true }
                result.append(ch)
            }
        }
        return result
    }

    /// Extracts a nested value from a JSON dictionary using a key path.
    /// - Parameters:
    ///   - dict: The root dictionary.
    ///   - keyPath: Dot-separated key path (e.g., "data.result.value").
    /// - Returns: The value at the key path, or nil if not found.
    static func value(in dict: [String: Any], at keyPath: String) -> Any? {
        let keys = keyPath.split(separator: ".").map(String.init)
        var current: Any = dict

        for key in keys {
            guard let currentDict = current as? [String: Any],
                let next = currentDict[key]
            else {
                return nil
            }
            current = next
        }

        return current
    }
}
