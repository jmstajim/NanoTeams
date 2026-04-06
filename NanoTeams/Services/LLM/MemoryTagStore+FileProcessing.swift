import Foundation

// MARK: - File Read Processing

extension MemoryTagStore {

    func processReadFile(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard let path = extractPath(from: result.argumentsJSON),
              let fileContent = extractDataString(from: result.outputJSON, key: "content"),
              !result.isError else {
            return .passthrough
        }

        if let existingTag = currentReadTags[path],
           let entry = entries[existingTag] {
            let wasEdited = editedSinceLastRead[path] ?? false

            if !wasEdited && entry.content == fileContent {
                // Unchanged, no edits — reference only
                return .reference(content: buildUnchangedReference(tag: existingTag, extras: [("path", path)]))
            }

            // Changed (by edits or externally) — new baseline with full content
            return createNewReadBaseline(path: path, content: fileContent, iteration: iteration)
        }

        // First read — create baseline
        return createNewReadBaseline(path: path, content: fileContent, iteration: iteration)
    }

    func processReadLines(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard let path = extractPath(from: result.argumentsJSON),
              let content = extractDataString(from: result.outputJSON, key: "content"),
              !result.isError else {
            return .passthrough
        }

        let startLine = extractDataInt(from: result.outputJSON, key: "start_line") ?? 0
        let endLine = extractDataInt(from: result.outputJSON, key: "end_line") ?? 0
        let rangeKey = "\(path):\(startLine)-\(endLine)"

        let wasEdited = editedSinceLastRead[path] ?? false

        if let existingTag = currentReadTags[rangeKey],
           let entry = entries[existingTag],
           !wasEdited && entry.content == content {
            return .reference(content: buildUnchangedReference(tag: existingTag, extras: [("path", path), ("lines", "\(startLine)-\(endLine)")]))
        }

        // First read or changed — new baseline for this range
        let tag = registerEntry(type: .read, resource: rangeKey, iteration: iteration,
                                content: content, replacingIn: &currentReadTags)

        let taggedContent = "{\"tag\":\"\(tag)\",\"path\":\(jsonEscape(path)),\"lines\":\"\(startLine)-\(endLine)\",\"content\":\(jsonEscape(content))}"
        return .tagged(content: taggedContent, tag: tag)
    }

    func createNewReadBaseline(path: String, content: String, iteration: Int) -> TagProcessingResult {
        let tag = registerEntry(type: .read, resource: path, iteration: iteration,
                                content: content, replacingIn: &currentReadTags)
        editedSinceLastRead[path] = false

        let lines = content.components(separatedBy: "\n").count
        let taggedContent = "{\"tag\":\"\(tag)\",\"path\":\(jsonEscape(path)),\"lines\":\(lines),\"content\":\(jsonEscape(content))}"
        return .tagged(content: taggedContent, tag: tag)
    }
}

// MARK: - Edit / Write / Delete Processing

extension MemoryTagStore {

    func processEdit(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard let path = extractPath(from: result.argumentsJSON),
              !result.isError else {
            return .passthrough
        }

        let tag = nextTag(.edit)
        entries[tag] = TagEntry(tag: tag, type: .edit, resource: path,
                                iteration: iteration, status: .current, content: "")

        editedSinceLastRead[path] = true

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
