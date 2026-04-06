import Foundation

/// Stateless generator of LLM-readable summaries from tool call history.
/// Operates on a snapshot of calls from ToolCallCache.
enum ToolCallContextualizer {

    private typealias TN = ToolNames

    // MARK: - Summary

    /// Generates a compact summary of all tool calls made in this step.
    static func generateSummary(from calls: [ToolCallCache.TrackedCall]) -> String? {
        guard !calls.isEmpty else { return nil }

        var lines: [String] = ["Summary of tool calls made so far in this step:"]

        var byTool: [String: [ToolCallCache.TrackedCall]] = [:]
        for call in calls { byTool[call.toolName, default: []].append(call) }

        for (toolName, toolCalls) in byTool.sorted(by: { $0.key < $1.key }) {
            if toolCalls.count == 1 {
                let call = toolCalls[0]
                let status = call.wasSuccessful ? "✓" : "✗"
                lines.append("- \(toolName)(\(call.argumentsSummary)) \(status): \(call.resultSummary)")
            } else {
                let successful = toolCalls.filter { $0.wasSuccessful }.count
                let failed = toolCalls.count - successful
                var statusPart = "\(successful) successful"
                if failed > 0 { statusPart += ", \(failed) failed" }
                lines.append("- \(toolName): \(toolCalls.count) calls (\(statusPart))")
                if let lastSuccess = toolCalls.last(where: { $0.wasSuccessful }), isInfoTool(toolName) {
                    lines.append("  Last result: \(lastSuccess.resultSummary)")
                }
            }
        }

        lines.append("")
        lines.append("⚠️ Avoid re-calling tools with the same arguments if the data hasn't changed.")
        return lines.joined(separator: "\n")
    }

    // MARK: - State Context

    /// Generates a compact state summary (git branch, files modified, build status, etc.)
    /// to help the LLM understand where it is in the workflow.
    static func generateStateContext(
        from calls: [ToolCallCache.TrackedCall],
        scratchpadSummary: String? = nil
    ) -> String? {
        var gitBranch: String?
        var gitStatus: String?
        var lastBuild: String?
        var changesMade: [String] = []
        var filesModified: Set<String> = []
        var filesRead: Set<String> = []
        var stagedFiles: Set<String> = []
        var lastCommitMessage: String?

        for call in calls where call.wasSuccessful {
            switch call.toolName {
            case TN.gitStatus:
                gitBranch = extractBranch(from: call.resultSummary)
                gitStatus = call.resultSummary
            case TN.gitBranchList:
                if let data = ToolCallDataUtils.parseJSON(call.resultJSON)?["data"] as? [String: Any],
                   let current = data["current"] as? String {
                    gitBranch = current
                }
            case TN.runXcodebuild:
                lastBuild = call.resultSummary
            case TN.gitCommit:
                lastCommitMessage = call.argumentsSummary
                stagedFiles.removeAll()
            case TN.gitCheckout:
                changesMade.append("Switched to branch: \(call.argumentsSummary)")
            case TN.gitBranch:
                if let data = ToolCallDataUtils.parseJSON(call.resultJSON)?["data"] as? [String: Any],
                   let action = data["action"] as? String {
                    if action == "create" { changesMade.append("Created branch: \(call.argumentsSummary)") }
                    else if action == "delete" { changesMade.append("Deleted branch: \(call.argumentsSummary)") }
                }
            case TN.editFile, TN.writeFile:
                filesModified.insert(call.argumentsSummary)
            case TN.deleteFile:
                changesMade.append("Deleted: \(call.argumentsSummary)")
            case TN.gitAdd:
                stagedFiles.insert(call.argumentsSummary)
            case TN.readFile, TN.readLines:
                filesRead.insert(call.argumentsSummary)
            default:
                break
            }
        }

        if let msg = lastCommitMessage { changesMade.append("Committed: \(msg)") }
        for file in stagedFiles.sorted() { changesMade.append("Staged: \(file)") }

        guard gitBranch != nil || gitStatus != nil || !changesMade.isEmpty
            || !filesModified.isEmpty || !filesRead.isEmpty || lastBuild != nil
            || scratchpadSummary != nil
        else { return nil }

        var lines: [String] = ["Current state:"]

        if let branch = gitBranch {
            var line = "Git branch: \(branch)"
            if let status = gitStatus {
                line += status.contains("clean") ? " (clean)" : " (uncommitted changes)"
            }
            lines.append("- \(line)")
        }

        if !filesRead.isEmpty && filesModified.isEmpty {
            let list = filesRead.sorted().prefix(5)
            let suffix = filesRead.count > 5 ? " (+\(filesRead.count - 5) more)" : ""
            lines.append("- Files read: \(list.joined(separator: ", "))\(suffix)")
            lines.append("- No changes made yet")
        }

        if !filesModified.isEmpty {
            let list = filesModified.sorted().prefix(5)
            let suffix = filesModified.count > 5 ? " (+\(filesModified.count - 5) more)" : ""
            lines.append("- Files modified: \(list.joined(separator: ", "))\(suffix)")
        }

        for change in changesMade.suffix(3) { lines.append("- \(change)") }
        if let build = lastBuild { lines.append("- Last build: \(build)") }
        if let plan = scratchpadSummary { lines.append("- Plan: \(plan)") }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private static func isInfoTool(_ name: String) -> Bool {
        [TN.gitStatus, TN.gitBranchList].contains(name)
    }

    private static func extractBranch(from summary: String) -> String {
        if summary.contains("on "),
           let range = summary.range(of: "on ") {
            let after = summary[range.upperBound...]
            let branch = after.split(separator: ",").first ?? after.split(separator: " ").first ?? Substring(after)
            return String(branch).trimmingCharacters(in: .whitespaces)
        }
        if summary.contains("branch: "),
           let range = summary.range(of: "branch: ") {
            let after = summary[range.upperBound...]
            let branch = after.split(separator: ",").first ?? Substring(after)
            return String(branch).trimmingCharacters(in: .whitespaces)
        }
        return summary
    }
}
