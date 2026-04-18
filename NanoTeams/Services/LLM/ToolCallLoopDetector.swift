import Foundation

/// Represents a detected loop pattern in tool calls.
enum LoopDetection {
    case readOnlyLoop(message: String)
    case repetitiveTool(tool: String, count: Int, message: String)

    var message: String {
        switch self {
        case .readOnlyLoop(let msg), .repetitiveTool(_, _, let msg):
            return msg
        }
    }
}

/// Stateless loop detection for tool call sequences.
/// Operates on a snapshot of recent calls from ToolCallCache.
enum ToolCallLoopDetector {

    private typealias TN = ToolNames

    private static var readOnlyTools: Set<String> {
        ToolHandlerRegistry.fileReadTools.union(ToolHandlerRegistry.gitReadTools)
    }

    /// Detects if recent calls form a loop pattern.
    /// - Parameter recentCalls: The last N tracked calls (typically limit: 6).
    static func detectLoopPattern(in recentCalls: [ToolCallCache.TrackedCall]) -> LoopDetection? {
        guard recentCalls.count >= 6 else { return nil }

        if recentCalls.allSatisfy({ readOnlyTools.contains($0.toolName) }) {
            return .readOnlyLoop(
                message: "Last 6 tool calls were all read-only. You're not making changes. Consider making a code change or committing your work."
            )
        }

        // Detect TRUE repetition: same tool + same arguments. Calls to the same tool with
        // DIFFERENT arguments are normal (e.g. write_file across many files during scaffolding,
        // read_lines across many lines of a large file). The previous heuristic counted only
        // by tool name and falsely flagged legitimate scaffolding streaks; SWE saw the warning
        // and gave up before completing the UI in run EA190834.
        let implementationCalls = recentCalls.filter { $0.toolName != TN.updateScratchpad && $0.wasSuccessful }
        let identityCounts = Dictionary(grouping: implementationCalls, by: { "\($0.toolName)\u{1F}\($0.argumentsSummary)" })
        if let (key, dupCalls) = identityCounts.max(by: { $0.value.count < $1.value.count }),
           dupCalls.count >= 3 {
            let tool = String(key.split(separator: "\u{1F}").first ?? "")
            return .repetitiveTool(
                tool: tool,
                count: dupCalls.count,
                message: "You've called '\(tool)' with identical arguments \(dupCalls.count) times. The state isn't changing — try different arguments or move on to the next step."
            )
        }

        return nil
    }
}
