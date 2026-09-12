import Foundation
@testable import NanoTeams

/// Reads a run's `tool_calls.jsonl` back into `ToolCallLogRecord`s.
///
/// The counterpart of `FirstPromptFromLogsExtractor`, which does the same for `network_log`.
/// It exists so a measurement can be derived from a run's own artifacts rather than from the
/// live object graph: the trainer reads the run it has just produced through exactly the same
/// door a human reads a run from the field through, so the same classifier answers both and a
/// field run recorded weeks ago can be re-scored without re-running anything.
///
/// JSONL only — `tool_calls.jsonl` has never had an array form (the 2026-08-21 split that left
/// `network_log.json` behind was the wire log's alone), so there is no legacy arm to carry.
nonisolated enum ToolCallLogReader {

    /// Records in the order they were appended, i.e. the order the calls were made.
    ///
    /// A line that will not decode is DROPPED rather than throwing the file away: the log is
    /// appended to by parallel roles (CLAUDE.md #45) and a truncated final line at the moment
    /// a process dies would otherwise cost the whole run's evidence.
    static func records(at url: URL) throws -> [ToolCallLogRecord] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let decoder = JSONCoderFactory.makeDateDecoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(ToolCallLogRecord.self, from: Data($0.utf8))
        }
    }

    /// The log of one run in a work folder, addressed the way the app addresses it.
    static func records(workFolderRoot: URL, taskID: Int, runID: Int) throws -> [ToolCallLogRecord] {
        try records(at: NTMSPaths(workFolderRoot: workFolderRoot)
            .toolCallsJSONL(taskID: taskID, runID: runID))
    }
}
