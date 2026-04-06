import Foundation

/// Shared JSON parsing utilities used by tool tracking classes.
/// Centralizes duplicated parsing logic from ToolCallCache and ToolCallContextualizer.
/// See also: ToolCallSummarizer (argument/result display summarization).
enum ToolCallDataUtils {

    // MARK: - JSON Parsing

    static func parseJSON(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    static func formatJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let formatted = String(data: pretty, encoding: .utf8)
        else {
            return json
        }
        return formatted
    }

    // MARK: - Path Extraction

    static func extractPath(from argumentsJSON: String) -> String? {
        guard let dict = parseJSON(argumentsJSON) else { return nil }
        return dict["path"] as? String
    }

    // MARK: - Error Classification

    static func classifyError(outputJSON: String) -> String {
        guard let dict = parseJSON(outputJSON) else { return "parse_error" }

        if let error = dict["error"] as? String {
            return error
        }

        if let message = (dict["message"] as? String)?.lowercased() {
            if message.contains("not found") { return "not_found" }
            if message.contains("timeout") { return "timeout" }
            if message.contains("permission") { return "permission_denied" }
        }

        if (dict["ok"] as? Bool) == false {
            return "execution_failed"
        }

        return "unknown"
    }
}
