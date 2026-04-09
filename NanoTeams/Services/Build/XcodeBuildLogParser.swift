import Foundation

struct XcodeBuildLogParser {
    init() {}

    func parse(stdout: String, stderr: String) -> [ParsedBuildIssue] {
        let combined = stdout + "\n" + stderr
        let lines = combined.split(whereSeparator: { $0.isNewline }).map(String.init)

        var issues: [ParsedBuildIssue] = []
        let patterns = BuildErrorPatterns.all()

        for line in lines {
            if let issue = matchAny(line: line, patterns: patterns) {
                issues.append(issue)
            }
        }

        // Deduplicate identical issues and cap total count
        let deduped = Self.deduplicate(issues)
        let capped = Array(deduped.prefix(BuildConstants.maxTotalIssuesStored))

        return capped
    }

    /// Create a compact, stable summary suitable for feeding back to an LLM.
    /// Includes counts and a capped list of top issues with short locations.
    static func diagnosticsSummary(
        _ diagnostics: BuildDiagnosticsPersisted,
        maxIssues: Int = 10
    ) -> String {
        if diagnostics.skipped == true {
            let reason = diagnostics.skipReason ?? "unknown"
            return "Build skipped (reason: \(reason))."
        }

        let e = diagnostics.errorCount
        let w = diagnostics.warningCount
        var lines: [String] = []
        lines.append("Build diagnostics: \(e) error(s), \(w) warning(s).")

        if diagnostics.issues.isEmpty {
            return lines.joined(separator: "\n")
        }

        lines.append("Top issues:")
        let limited = diagnostics.issues.prefix(max(0, maxIssues))
        for issue in limited {
            let sev = issue.severity.lowercased().hasPrefix("w") ? "[W]" : "[E]"
            var loc = ""
            if let file = issue.file, let line = issue.line {
                loc = " — \(file):\(line)"
            } else if let file = issue.file {
                loc = " — \(file)"
            }
            let msg = issue.message.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(sev) \(msg)\(loc)")
        }

        if diagnostics.issues.count > maxIssues {
            lines.append("…and \(diagnostics.issues.count - maxIssues) more.")
        }

        return lines.joined(separator: "\n")
    }


    private func matchAny(line: String, patterns: [BuildErrorPatterns.Pattern]) -> ParsedBuildIssue? {
        let nsline = line as NSString
        for p in patterns {
            let range = NSRange(location: 0, length: nsline.length)
            if let m = p.regex.firstMatch(in: line, options: [], range: range) {
                return buildIssue(from: line, match: m, pattern: p)
            }
        }
        return nil
    }

    private func buildIssue(from line: String, match: NSTextCheckingResult, pattern: BuildErrorPatterns.Pattern) -> ParsedBuildIssue? {
        func group(_ idx: Int) -> String? {
            guard idx >= 0 else { return nil }
            let nsline = line as NSString
            let r = match.range(at: idx)
            guard r.location != NSNotFound, r.length > 0 else { return nil }
            return nsline.substring(with: r)
        }

        let severityText = group(pattern.severityGroupIndex)?.lowercased()
        let severity: ParsedBuildIssue.Severity = (severityText == "warning") ? .warning : .error

        let file = group(pattern.fileIndex)
        let lineNum = group(pattern.lineIndex).flatMap { Int($0) }
        let colNum = group(pattern.columnIndex).flatMap { Int($0) }
        let messageRaw = group(pattern.messageIndex) ?? line
        let ruleId = group(pattern.ruleIndex)

        // Truncate message to prevent context explosion
        let messageTrimmed = messageRaw.trimmingCharacters(in: .whitespaces)
        let message = String(messageTrimmed.prefix(BuildConstants.maxIssueMessageLength))

        // Truncate excerpt (code line) to prevent context explosion
        let excerpt = String(line.prefix(BuildConstants.maxIssueExcerptLength))

        return ParsedBuildIssue(
            severity: severity,
            message: message,
            file: file,
            line: lineNum,
            column: colNum,
            toolchainHint: pattern.toolHint,
            ruleId: ruleId,
            excerpt: excerpt
        )
    }

    /// Deduplicate issues by (severity, file, line, message prefix).
    /// Removes duplicate errors from the same location with similar messages.
    private static func deduplicate(_ issues: [ParsedBuildIssue]) -> [ParsedBuildIssue] {
        var seen = Set<String>()
        var unique: [ParsedBuildIssue] = []

        for issue in issues {
            // Create a dedup key from severity, file, line, and first 100 chars of message
            let messageKey = String(issue.message.prefix(100))
            let key = "\(issue.severity)|\(issue.file ?? "")|\(issue.line ?? -1)|\(messageKey)"

            if !seen.contains(key) {
                seen.insert(key)
                unique.append(issue)
            }
        }

        return unique
    }
}
