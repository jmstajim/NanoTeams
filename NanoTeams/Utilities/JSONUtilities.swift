import Foundation

/// Centralized JSON parsing and serialization utilities.
enum JSONUtilities {

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

    /// Escapes literal control characters (0x00-0x1F) inside JSON string values.
    /// LLMs often stream content with literal newlines/tabs instead of \n/\t,
    /// which causes JSONSerialization to reject the JSON.
    /// Uses inString/escape tracking to only escape chars inside quoted strings.
    static func sanitizeJSONControlCharacters(_ jsonText: String) -> String {
        var result = ""
        result.reserveCapacity(jsonText.count + 64)
        var inString = false
        var escape = false

        for ch in jsonText {
            if inString {
                if escape {
                    escape = false
                    result.append(ch)
                } else if ch == "\\" {
                    escape = true
                    result.append(ch)
                } else if ch == "\"" {
                    inString = false
                    result.append(ch)
                } else if ch.asciiValue.map({ $0 < 0x20 }) == true {
                    switch ch {
                    case "\n": result.append("\\n")
                    case "\r": result.append("\\r")
                    case "\t": result.append("\\t")
                    default:
                        let code = ch.asciiValue ?? 0
                        result.append(String(format: "\\u%04x", code))
                    }
                } else {
                    result.append(ch)
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
