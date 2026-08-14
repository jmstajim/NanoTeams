import Foundation

// MARK: - Build / Test Processing

nonisolated extension MemoryTagStore {

    func processBuild(_ result: ToolExecutionResult) -> TagProcessingResult {
        guard !result.isError else { return .passthrough }

        let summary = extractBuildSummary(from: result.outputJSON)
        let tag = nextTag(.build)
        let taggedContent = "{\"tag\":\"\(tag)\",\"summary\":\(jsonEscape(summary))}"
        return .tagged(content: taggedContent, tag: tag)
    }

    func processTests(_ result: ToolExecutionResult) -> TagProcessingResult {
        guard !result.isError else { return .passthrough }

        let summary = extractTestSummary(from: result.outputJSON)
        let tag = nextTag(.build)  // same B tag type
        return .tagged(content: "{\"tag\":\"\(tag)\",\"summary\":\(jsonEscape(summary))}", tag: tag)
    }
}
