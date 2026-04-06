import Foundation

// MARK: - JSON Parsing Helpers

extension MemoryTagStore {

    /// Extract "path" from arguments JSON: {"path": "..."}
    func extractPath(from argsJSON: String) -> String? {
        extractString(from: argsJSON, key: "path")
    }

    /// Extract a string value from the "data" object of an envelope JSON:
    /// {"ok": true, "data": {"content": "...", ...}, ...}
    func extractDataString(from outputJSON: String, key: String) -> String? {
        guard let parsed = parseJSON(outputJSON),
              let data = parsed["data"] as? [String: Any],
              let value = data[key] as? String else {
            return nil
        }
        return value
    }

    /// Extract an int value from the "data" object of an envelope JSON.
    func extractDataInt(from outputJSON: String, key: String) -> Int? {
        guard let parsed = parseJSON(outputJSON),
              let data = parsed["data"] as? [String: Any],
              let value = data[key] as? Int else {
            return nil
        }
        return value
    }

    /// Extract a string value from a flat JSON object.
    func extractString(from json: String, key: String) -> String? {
        guard let parsed = parseJSON(json),
              let value = parsed[key] as? String else {
            return nil
        }
        return value
    }

    func parseJSON(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// JSON-escape a string for embedding in JSON output.
    func jsonEscape(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: string, options: .fragmentsAllowed
        ) else {
            return "\"\(string)\""
        }
        return String(data: data, encoding: .utf8) ?? "\"\(string)\""
    }

    // MARK: - Unchanged Reference

    /// Builds a compact JSON reference for an unchanged resource.
    /// `extras` are additional key-value pairs inserted before the ref/hint fields.
    func buildUnchangedReference(tag: String, extras: [(String, String)] = []) -> String {
        var parts = ["{\"status\":\"unchanged\""]
        for (key, value) in extras {
            parts.append(",\"\(key)\":\(jsonEscape(value))")
        }
        parts.append(",\"ref\":\"\(tag)\",\"_hint\":\"Do NOT re-read. See \(tag) above.\"}")
        return parts.joined()
    }
}
