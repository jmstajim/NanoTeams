import Foundation

// MARK: - Git Processing

nonisolated extension MemoryTagStore {

    /// `git_status` and `git_diff` share one rendering: the full envelope with a
    /// fresh `G` tag stamped on it.
    func processGit(_ result: ToolExecutionResult) -> TagProcessingResult {
        guard !result.isError else { return .passthrough }

        let tag = nextTag(.git)
        return .tagged(content: taggedEnvelope(tag: tag, wrapping: result.outputJSON), tag: tag)
    }
}
