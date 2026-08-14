import Foundation

// MARK: - Bash Processing

nonisolated extension MemoryTagStore {

    /// Tags `bash` command output. Skips errors (denied commands).
    /// Held-for-approval commands never reach here — the gate awaits the human
    /// in-loop and only the REAL command output is processed.
    func processBash(_ result: ToolExecutionResult) -> TagProcessingResult {
        guard !result.isError else { return .passthrough }

        let tag = nextTag(.shell)
        return .tagged(content: taggedEnvelope(tag: tag, wrapping: result.outputJSON), tag: tag)
    }
}
