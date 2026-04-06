import Foundation

// MARK: - Argument Extraction Helpers

func requiredString(_ args: [String: Any], _ key: String) throws -> String {
    if let value = args[key] as? String { return value }
    // Fallback: LLM passed a plain string instead of a JSON object
    if let raw = args["__raw_input__"] as? String {
        // Try to parse as JSON and extract the requested key
        if let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = parsed[key] as? String {
            return value
        }
        return raw
    }
    throw ToolArgumentError.missingRequired(key)
}

func optionalString(_ args: [String: Any], _ key: String) -> String? {
    args[key] as? String
}

func optionalInt(_ args: [String: Any], _ key: String) -> Int? {
    if let intVal = args[key] as? Int {
        return intVal
    }
    if let doubleVal = args[key] as? Double {
        return Int(doubleVal)
    }
    return nil
}

func requiredInt(_ args: [String: Any], _ key: String) throws -> Int {
    if let intVal = args[key] as? Int {
        return intVal
    }
    if let doubleVal = args[key] as? Double {
        return Int(doubleVal)
    }
    throw ToolArgumentError.missingRequired(key)
}

func optionalBool(_ args: [String: Any], _ key: String, default defaultValue: Bool = false) -> Bool
{
    (args[key] as? Bool) ?? defaultValue
}

func optionalStringArray(_ args: [String: Any], _ key: String) -> [String]? {
    args[key] as? [String]
}

func requiredStringArray(_ args: [String: Any], _ key: String) throws -> [String] {
    guard let value = args[key] as? [String] else {
        throw ToolArgumentError.missingRequired(key)
    }
    return value
}

// MARK: - Resilient Content Resolution

/// Known non-content keys that should never be treated as content fallbacks.
private let nonContentKeys: Set<String> = [
    "path", "create_dirs", "encoding", "max_bytes",
    "must_exist", "mode", "file_glob", "patch",
    "start_line", "end_line", "include_line_numbers",
    "new_text", "anchors", "replace_range", "occurrence",
    "match_strategy", "sort", "depth", "include_files",
    "include_dirs", "paths", "max_results", "context_before",
    "context_after", "max_match_lines", "query"
]

/// Common alternative argument names LLMs use instead of "content".
private let contentAlternativeNames: [String] = [
    "text", "body", "file_content", "data", "value",
    "plan", "notes", "output", "message", "code", "source"
]

/// Resolves the "content" argument from a tool's args dictionary,
/// with fallback for common LLM argument naming mistakes.
///
/// Resolution order:
/// 1. `args["content"]` (exact match)
/// 2. Known alternative names: "text", "body", "file_content", etc.
/// 3. If exactly one non-excluded string value remains, use it.
func resolveContentString(_ args: [String: Any], excludeKeys: Set<String> = []) -> String? {
    // 1. Exact match
    if let content = args["content"] as? String {
        return content
    }

    // 2. Known alternative names
    for alt in contentAlternativeNames {
        if let content = args[alt] as? String {
            return content
        }
    }

    // 3. Single remaining string value fallback
    let allExcluded = nonContentKeys.union(excludeKeys)
    let candidateEntries = args.filter { key, value in
        !allExcluded.contains(key) && value is String
    }
    if candidateEntries.count == 1, let content = candidateEntries.first?.value as? String {
        return content
    }

    return nil
}
