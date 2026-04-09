import Foundation

/// Build error regex pattern definitions (configuration data).
/// Extracted from XcodeBuildLogParser for SRP — patterns are configuration, not parsing logic.
enum BuildErrorPatterns {

    struct Pattern {
        let regex: NSRegularExpression
        /// Which capture group contains the literal text "error" or "warning".
        let severityGroupIndex: Int
        /// Indexes for capture groups; -1 means not captured.
        let fileIndex: Int
        let lineIndex: Int
        let columnIndex: Int
        let messageIndex: Int
        let ruleIndex: Int
        let toolHint: String?
    }

    static func all() -> [Pattern] {
        // 1) SwiftLint-style: file:line:col: warning|error: message (rule_id)
        let p5 = makePattern(
            pattern: "^(.*?):(\\d+):(\\d+):\\s*(warning|error):\\s*(.*?)\\s*\\(([^)]+)\\)$",
            severityFromGroup: 4,
            fileIndex: 1,
            lineIndex: 2,
            columnIndex: 3,
            messageIndex: 5,
            ruleIndex: 6,
            toolHint: "swiftlint"
        )

        // 2) file:line:column: error|warning: message
        let p1 = makePattern(
            pattern: "^(.*?):(\\d+):(\\d+):\\s*(error|warning):\\s*(.*)$",
            severityFromGroup: 4,
            fileIndex: 1,
            lineIndex: 2,
            columnIndex: 3,
            messageIndex: 5,
            ruleIndex: -1,
            toolHint: nil
        )

        // 3) file:line: error|warning: message (no column)
        let p2 = makePattern(
            pattern: "^(.*?):(\\d+):\\s*(error|warning):\\s*(.*)$",
            severityFromGroup: 3,
            fileIndex: 1,
            lineIndex: 2,
            columnIndex: -1,
            messageIndex: 4,
            ruleIndex: -1,
            toolHint: nil
        )

        // 4) Swift errors like: error: <message> (at: file.swift:line:column)
        let p3 = makePattern(
            pattern: "^(error|warning):\\s*(.*)\\s*\\(at:\\s*(.*?):(\\d+):(\\d+)\\)$",
            severityFromGroup: 1,
            fileIndex: 3,
            lineIndex: 4,
            columnIndex: 5,
            messageIndex: 2,
            ruleIndex: -1,
            toolHint: "swiftc"
        )

        // 5) Linker errors: ld: error: <message>
        let p4 = makePattern(
            pattern: "^ld:\\s*(error|warning):\\s*(.*)$",
            severityFromGroup: 1,
            fileIndex: -1,
            lineIndex: -1,
            columnIndex: -1,
            messageIndex: 2,
            ruleIndex: -1,
            toolHint: "ld"
        )

        // 6) xcodebuild launcher messages: xcodebuild: error: <message>
        let p6 = makePattern(
            pattern: "^xcodebuild:\\s*(error|warning):\\s*(.*)$",
            severityFromGroup: 1,
            fileIndex: -1,
            lineIndex: -1,
            columnIndex: -1,
            messageIndex: 2,
            ruleIndex: -1,
            toolHint: "xcodebuild"
        )

        // 7) fatal error: <message>
        let p7 = makePattern(
            pattern: "^fatal\\s+error:\\s*(.*)$",
            severityFromGroup: 0, // not used; force error
            fileIndex: -1,
            lineIndex: -1,
            columnIndex: -1,
            messageIndex: 1,
            ruleIndex: -1,
            toolHint: "swiftc"
        )

        return [p5, p1, p2, p3, p4, p6, p7]
    }

    private static func makePattern(
        pattern: String, severityFromGroup: Int, fileIndex: Int,
        lineIndex: Int, columnIndex: Int, messageIndex: Int,
        ruleIndex: Int, toolHint: String?
    ) -> Pattern {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            fatalError("BuildErrorPatterns: invalid regex pattern: \(pattern)")
        }
        return Pattern(
            regex: regex,
            severityGroupIndex: severityFromGroup,
            fileIndex: fileIndex,
            lineIndex: lineIndex,
            columnIndex: columnIndex,
            messageIndex: messageIndex,
            ruleIndex: ruleIndex,
            toolHint: toolHint
        )
    }
}
