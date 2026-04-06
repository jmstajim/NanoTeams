import Foundation

// MARK: - Git Processing

extension MemoryTagStore {

    private typealias TN = ToolNames

    func processGitStatus(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard !result.isError else { return .passthrough }

        let content = result.outputJSON

        if let currentTag = currentGitTag(resource: TN.gitStatus),
           let entry = entries[currentTag],
           entry.content == content {
            return .reference(content: buildUnchangedReference(tag: currentTag))
        }

        if let prevTag = currentGitTag(resource: TN.gitStatus) {
            entries[prevTag]?.status = .outdated(reason: "new status")
        }

        let tag = nextTag(.git)
        entries[tag] = TagEntry(tag: tag, type: .git, resource: TN.gitStatus,
                                iteration: iteration, status: .current, content: content)
        let taggedContent = "{\"tag\":\"\(tag)\",\"content\":\(jsonEscape(content))}"
        return .tagged(content: taggedContent, tag: tag)
    }

    func processGitDiff(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        guard !result.isError else { return .passthrough }

        let diffContent = result.outputJSON

        if let currentTag = currentGitTag(resource: TN.gitDiff),
           let entry = entries[currentTag],
           entry.content == diffContent {
            return .reference(content: buildUnchangedReference(tag: currentTag))
        }

        if let prevTag = currentGitTag(resource: TN.gitDiff) {
            entries[prevTag]?.status = .outdated(reason: "new diff")
        }

        let tag = nextTag(.git)
        entries[tag] = TagEntry(tag: tag, type: .git, resource: TN.gitDiff,
                                iteration: iteration, status: .current, content: diffContent)
        let taggedContent = "{\"tag\":\"\(tag)\",\"content\":\(jsonEscape(diffContent))}"
        return .tagged(content: taggedContent, tag: tag)
    }
}
