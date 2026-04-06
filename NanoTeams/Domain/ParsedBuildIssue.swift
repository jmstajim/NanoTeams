import Foundation

struct ParsedBuildIssue: Codable, Hashable, Sendable {
    enum Severity: String, Codable, Sendable {
        case error
        case warning
    }

    var severity: Severity
    var message: String
    var file: String?
    var line: Int?
    var column: Int?
    var toolchainHint: String?
    var ruleId: String?
    /// Minimal excerpt — typically the single matching line from the log.
    var excerpt: String

    init(
        severity: Severity,
        message: String,
        file: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        toolchainHint: String? = nil,
        ruleId: String? = nil,
        excerpt: String
    ) {
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.column = column
        self.toolchainHint = toolchainHint
        self.ruleId = ruleId
        self.excerpt = excerpt
    }
}
