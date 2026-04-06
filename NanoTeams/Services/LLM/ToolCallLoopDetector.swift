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

        let implementationCalls = recentCalls.filter { $0.toolName != TN.updateScratchpad && $0.wasSuccessful }
        let toolCounts = Dictionary(grouping: implementationCalls, by: { $0.toolName })
        if let (tool, toolCalls) = toolCounts.max(by: { $0.value.count < $1.value.count }),
           toolCalls.count >= 4 {
            return .repetitiveTool(
                tool: tool,
                count: toolCalls.count,
                message: "You've called '\(tool)' \(toolCalls.count) times in the last 6 calls. Try a different approach."
            )
        }

        return nil
    }
}
