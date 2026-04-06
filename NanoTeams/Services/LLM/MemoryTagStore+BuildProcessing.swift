import Foundation

// MARK: - Build / Test Processing

extension MemoryTagStore {

    func processBuild(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard !result.isError else { return .passthrough }

        let summary = extractBuildSummary(from: result.outputJSON)

        // Check if same result as current build
        if let currentTag = currentBuildTag(),
           let entry = entries[currentTag],
           entry.content == summary {
            return .reference(content: buildUnchangedReference(tag: currentTag))
        }

        // Check for delta from previous build
        if let prevTag = currentBuildTag(),
           let prevEntry = entries[prevTag] {
            let prevErrors = parseBuildErrorLines(from: prevEntry.content)
            let newErrors = parseBuildErrorLines(from: summary)
            let fixed = prevErrors.subtracting(newErrors)
            let added = newErrors.subtracting(prevErrors)

            entries[prevTag]?.status = .outdated(reason: "new build")

            let tag = nextTag(.build)
            entries[tag] = TagEntry(tag: tag, type: .build, resource: "build",
                                    iteration: iteration, status: .current, content: summary)

            if !fixed.isEmpty || !added.isEmpty {
                let isSuccess = newErrors.isEmpty
                var parts: [String] = ["{\"tag\":\"\(tag)\",\"status\":\"\(isSuccess ? "SUCCESS" : "FAILED")\",\"prev\":\"\(prevTag)\""]
                if !fixed.isEmpty {
                    let fixedArr = fixed.prefix(5).map { jsonEscape($0) }.joined(separator: ",")
                    parts.append(",\"fixed\":[\(fixedArr)]")
                }
                if !added.isEmpty {
                    let addedArr = added.prefix(5).map { jsonEscape($0) }.joined(separator: ",")
                    parts.append(",\"new\":[\(addedArr)]")
                }
                parts.append(",\"_hint\":\"Delta from \(prevTag). Fixed \(fixed.count), new \(added.count).\"}")
                return .tagged(content: parts.joined(), tag: tag)
            }
        }

        // First build or no meaningful delta — full summary
        if let prevTag = currentBuildTag() {
            entries[prevTag]?.status = .outdated(reason: "new build")
        }
        let tag = nextTag(.build)
        entries[tag] = TagEntry(tag: tag, type: .build, resource: "build",
                                iteration: iteration, status: .current, content: summary)
        let taggedContent = "{\"tag\":\"\(tag)\",\"summary\":\(jsonEscape(summary))}"
        return .tagged(content: taggedContent, tag: tag)
    }

    func processTests(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard !result.isError else { return .passthrough }

        let summary = extractTestSummary(from: result.outputJSON)

        if let currentTag = currentTestTag(),
           let entry = entries[currentTag],
           entry.content == summary {
            return .reference(content: buildUnchangedReference(tag: currentTag))
        }

        if let prevTag = currentTestTag() {
            entries[prevTag]?.status = .outdated(reason: "new test run")
        }

        let tag = nextTag(.build)  // same B tag type
        entries[tag] = TagEntry(tag: tag, type: .build, resource: "tests",
                                iteration: iteration, status: .current, content: summary)
        return .tagged(content: "{\"tag\":\"\(tag)\",\"summary\":\(jsonEscape(summary))}", tag: tag)
    }
}
