import Foundation

/// A compact, migration-safe record of a single build issue suitable for persistence.
nonisolated struct BuildIssuePersisted: Codable, Hashable {
    /// "error" or "warning"
    var severity: String
    var message: String
    var file: String?
    var line: Int?
    var column: Int?
    var toolchainHint: String?
    var ruleId: String?
    /// Minimal excerpt (typically the matching line from the log)
    var excerpt: String

    init(
        severity: String,
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

/// The top-level JSON persisted to .nanoteams/runs/<runId>/steps/<stepId>/build_diagnostics.json
nonisolated struct BuildDiagnosticsPersisted: Codable, Hashable {
    var schemaVersion: Int
    var createdAt: Date
    var errorCount: Int
    var warningCount: Int
    /// True when a build was intentionally skipped (e.g. no Xcode project found).
    var skipped: Bool?
    /// When skipped==true, a short reason code (e.g. "no_project").
    var skipReason: String?
    var issues: [BuildIssuePersisted]
    /// Optional path to curated excerpts (relative to .nanoteams/)
    var excerptsRelativePath: String?

    init(
        schemaVersion: Int = 1,
        createdAt: Date = MonotonicClock.shared.now(),
        errorCount: Int,
        warningCount: Int,
        skipped: Bool? = nil,
        skipReason: String? = nil,
        issues: [BuildIssuePersisted],
        excerptsRelativePath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.skipped = skipped
        self.skipReason = skipReason
        self.issues = issues
        self.excerptsRelativePath = excerptsRelativePath
    }
}
