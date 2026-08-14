import Foundation

// MARK: - File Read Processing

nonisolated extension MemoryTagStore {

    /// Both `read_file` and `read_lines` return a `{start_line, end_line, total_lines, content}`
    /// envelope; both are rendered identically. Every read gets a fresh tag —
    /// there is deliberately no "unchanged" detection.
    func processRangedRead(_ result: ToolExecutionResult) -> TagProcessingResult {
        // One parse of the (potentially large) envelope; all three keys read off it.
        guard !result.isError,
              let path = extractPath(from: result.argumentsJSON),
              let data = dataObject(from: result.outputJSON),
              let content = data["content"] as? String else {
            return .passthrough
        }

        let startLine = data["start_line"] as? Int ?? 0
        let endLine = data["end_line"] as? Int ?? 0

        let tag = nextTag(.read)
        let taggedContent = "{\"tag\":\"\(tag)\",\"path\":\(jsonEscape(path)),\"lines\":\"\(startLine)-\(endLine)\",\"content\":\(jsonEscape(content))}"
        return .tagged(content: taggedContent, tag: tag)
    }
}

// MARK: - Edit / Write Processing

nonisolated extension MemoryTagStore {

    /// The tagged envelope is BUILT, not filtered — which is why it has to carry the
    /// handler's disclosures forward explicitly. Two were being dropped:
    ///
    /// - `replacements_made`: with `replace_all` the model cannot otherwise tell whether
    ///   it changed one line or forty.
    /// - `matched_ignoring_trailing_whitespace`: `EditFileTool` emits this ONLY when the
    ///   fuzzy fallback fired, precisely "so the model knows the file's bytes differed
    ///   from its anchor". Discarding it presents a fuzzy match as a clean success — the
    ///   one outcome the handler went out of its way to disclose.
    func processEdit(_ result: ToolExecutionResult) -> TagProcessingResult {
        guard let path = extractPath(from: result.argumentsJSON),
              !result.isError else {
            return .passthrough
        }

        let tag = nextTag(.edit)
        let data = parseJSON(result.outputJSON)?["data"] as? [String: Any]
        var taggedContent =
            "{\"tag\":\"\(tag)\",\"status\":\"success\",\"path\":\(jsonEscape(path))"
        if let replacements = data?["replacements_made"] as? Int {
            taggedContent += ",\"replacements_made\":\(replacements)"
        }
        if data?["matched_ignoring_trailing_whitespace"] as? Bool == true {
            taggedContent += ",\"matched_ignoring_trailing_whitespace\":true"
        }
        taggedContent += "}"
        return .tagged(content: taggedContent, tag: tag)
    }

    func processWrite(_ result: ToolExecutionResult) -> TagProcessingResult {
        // For write_file the ARGUMENTS carry the entire file body — parse them
        // once and read both keys, instead of one parse per key.
        guard !result.isError,
              let args = parseJSON(result.argumentsJSON),
              let rawPath = args["path"] as? String else {
            return .passthrough
        }

        let path = canonicalizePath(rawPath)
        let newContent = args["content"] as? String ?? ""
        // Byte scan, not components(separatedBy:) — a split allocates one String
        // per line just to produce this integer.
        var lines = 1
        for byte in newContent.utf8 where byte == 0x0A { lines += 1 }

        let tag = nextTag(.write)
        let taggedContent = "{\"tag\":\"\(tag)\",\"status\":\"success\",\"path\":\(jsonEscape(path)),\"lines\":\(lines)}"
        return .tagged(content: taggedContent, tag: tag)
    }
}
