import Foundation

/// Minimal, dependency-free metadata extraction for agent skill / command files.
///
/// NOT a YAML or TOML parser — it only reads top-level single-line scalars from a
/// leading `---` frontmatter block (Claude / Codex / Cursor / Copilot / Windsurf)
/// or a top-level `description` key (Gemini `.toml`). Nested structures, block
/// scalars, and multi-line values are ignored by design: the repo has zero
/// dependencies, and a hand-rolled full parser would corrupt escapes. The picker
/// only needs a name + one-line description; the injected content is always the
/// raw full file.
nonisolated enum SkillMetadataExtractor {

    /// Extracts the requested top-level keys from a leading `---`-delimited YAML
    /// frontmatter block (must start at the first non-BOM line and be closed by a
    /// second `---`). Values are single-line scalars with surrounding quotes
    /// stripped; block scalars (`|` / `>`) and empty values are skipped.
    static func frontmatterFields(_ keys: Set<String>, in text: String) -> [String: String] {
        let lines = normalizedLines(text)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var result: [String: String] = [:]
        var closed = false
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { closed = true; break }
            // Top-level keys only: no indentation, not a comment.
            if !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
               let colon = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                if keys.contains(key) {
                    let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    // Skip block scalars / empty (value lives on indented lines we don't parse).
                    if !rawValue.isEmpty, !["|", ">", "|-", ">-", "|+", ">+"].contains(rawValue) {
                        let value = stripQuotes(rawValue)
                        if !value.isEmpty { result[key] = value }
                    }
                }
            }
            i += 1
        }
        // An unterminated block isn't valid frontmatter.
        return closed ? result : [:]
    }

    /// Extracts a top-level (pre-table) `description = "..."` value from a TOML
    /// file. Handles `"..."`, `'...'`, and the first line of a `"""..."""` block.
    /// Commented lines and keys inside `[tables]` are ignored.
    static func tomlDescription(in text: String) -> String? {
        for raw in normalizedLines(text) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[") { break }  // entered a table — top-level scan done
            guard let eq = trimmed.range(of: "="),
                  trimmed[trimmed.startIndex..<eq.lowerBound].trimmingCharacters(in: .whitespaces) == "description"
            else { continue }

            let value = String(trimmed[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"\"\"") {
                let afterOpen = String(value.dropFirst(3))
                if let close = afterOpen.range(of: "\"\"\"") {
                    let inner = String(afterOpen[afterOpen.startIndex..<close.lowerBound])
                    return inner.isEmpty ? nil : inner
                }
                return afterOpen.isEmpty ? nil : afterOpen  // first line of the block
            }
            let unquoted = stripQuotes(value)
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

    // MARK: - Helpers

    private static func normalizedLines(_ text: String) -> [String] {
        var content = text
        if content.hasPrefix("\u{FEFF}") { content = String(content.dropFirst()) }  // strip BOM
        return content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
