import Foundation

// MARK: - File Read Processing

nonisolated extension MemoryTagStore {

    /// Both `read_file` and `read_lines` return a `{start_line, end_line, total_lines, content}`
    /// envelope. They share the same range-keyed baseline machinery so dedup, invalidation,
    /// and tag references are identical.
    func processReadFile(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        processRangedRead(result, iteration: iteration)
    }

    func processReadLines(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        processRangedRead(result, iteration: iteration)
    }

    private func processRangedRead(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard let path = extractPath(from: result.argumentsJSON),
              let content = extractDataString(from: result.outputJSON, key: "content"),
              !result.isError else {
            return .passthrough
        }

        let startLine = extractDataInt(from: result.outputJSON, key: "start_line") ?? 0
        let endLine = extractDataInt(from: result.outputJSON, key: "end_line") ?? 0
        let totalLines = extractDataInt(from: result.outputJSON, key: "total_lines") ?? 0
        let rangeKey = "\(path):\(startLine)-\(endLine)"

        let wasEdited = editedSinceLastRead[path] ?? false

        if let existingTag = currentReadTags[rangeKey],
           let entry = entries[existingTag],
           !wasEdited && entry.content == content {
            return .reference(content: buildUnchangedReference(tag: existingTag, extras: [("path", path), ("lines", "\(startLine)-\(endLine)")]))
        }

        let tag = registerEntry(type: .read, resource: rangeKey, iteration: iteration,
                                content: content, replacingIn: &currentReadTags)
        // Clear staleness ONLY when post-edit reads collectively cover the file.
        // A partial re-read (e.g. `read_lines 60-100` after `edit_file`) refreshes
        // the baseline for that range only — other ranges (e.g. 1-50) remain
        // stale, and clearing the per-path flag prematurely would let a subsequent
        // 1-50 read incorrectly short-circuit to its pre-edit tag. The per-call
        // cap means a single read_lines may no longer cover the file in one shot,
        // so paginated coverage is tracked in `readRangesSinceEdit`.
        if totalLines > 0 && startLine <= endLine {
            var covered = readRangesSinceEdit[path] ?? IndexSet()
            covered.insert(integersIn: startLine..<(endLine + 1))
            if covered.contains(integersIn: 1..<(totalLines + 1)) {
                editedSinceLastRead[path] = false
                readRangesSinceEdit.removeValue(forKey: path)
            } else {
                readRangesSinceEdit[path] = covered
            }
        }

        let taggedContent = "{\"tag\":\"\(tag)\",\"path\":\(jsonEscape(path)),\"lines\":\"\(startLine)-\(endLine)\",\"content\":\(jsonEscape(content))}"
        return .tagged(content: taggedContent, tag: tag)
    }
}

// MARK: - Edit / Write / Delete Processing

nonisolated extension MemoryTagStore {

    func processEdit(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard let path = extractPath(from: result.argumentsJSON),
              !result.isError else {
            return .passthrough
        }

        let tag = nextTag(.edit)
        entries[tag] = TagEntry(tag: tag, type: .edit, resource: path,
                                iteration: iteration, status: .current, content: "")

        editedSinceLastRead[path] = true
        readRangesSinceEdit.removeValue(forKey: path)

        // Mark base read tag as outdated
        if let baseTag = currentReadTags[path] {
            entries[baseTag]?.status = .outdated(reason: tag)
        }
        // Also invalidate any read_lines ranges for this path
        invalidateReadRanges(forPath: path, reason: tag)

        invalidateBuilds(reason: tag)
        invalidateGit(reason: tag)

        let base = currentReadTags[path] ?? "?"
        let taggedContent = "{\"tag\":\"\(tag)\",\"status\":\"success\",\"path\":\(jsonEscape(path)),\"base\":\"\(base)\"}"
        return .tagged(content: taggedContent, tag: tag)
    }

    func processWrite(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard let path = extractPath(from: result.argumentsJSON),
              !result.isError else {
            return .passthrough
        }

        // Content is in ARGUMENTS for write_file, not in the result
        let newContent = extractString(from: result.argumentsJSON, key: "content") ?? ""

        let tag = registerEntry(type: .write, resource: path, iteration: iteration,
                                content: newContent, replacingIn: &currentReadTags)
        editedSinceLastRead[path] = false  // write = new baseline
        readRangesSinceEdit.removeValue(forKey: path)

        // Also invalidate any read_lines ranges for this path
        invalidateReadRanges(forPath: path, reason: tag)

        invalidateBuilds(reason: tag)
        invalidateGit(reason: tag)

        let lines = newContent.components(separatedBy: "\n").count
        let taggedContent = "{\"tag\":\"\(tag)\",\"status\":\"success\",\"path\":\(jsonEscape(path)),\"lines\":\(lines)}"
        return .tagged(content: taggedContent, tag: tag)
    }

    func processDelete(_ result: ToolExecutionResult) -> TagProcessingResult {
        guard let path = extractPath(from: result.argumentsJSON),
              !result.isError else {
            return .passthrough
        }

        // Mark all tags for this path as OUTDATED
        if let oldTag = currentReadTags[path] {
            entries[oldTag]?.status = .outdated(reason: "deleted")
        }
        currentReadTags.removeValue(forKey: path)
        editedSinceLastRead.removeValue(forKey: path)
        readRangesSinceEdit.removeValue(forKey: path)

        // Also invalidate any read_lines ranges for this path
        let rangeKeys = currentReadTags.keys.filter { $0.hasPrefix(path + ":") }
        for key in rangeKeys {
            if let tag = currentReadTags[key] {
                entries[tag]?.status = .outdated(reason: "deleted")
            }
            currentReadTags.removeValue(forKey: key)
        }

        invalidateBuilds(reason: "deleted \(path)")
        invalidateGit(reason: "deleted \(path)")

        return .passthrough
    }
}
