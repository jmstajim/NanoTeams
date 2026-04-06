import XCTest
@testable import NanoTeams

/// Tests for BuildDiagnosticsPersisted and BuildIssuePersisted models
final class BuildDiagnosticsPersistedTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - BuildIssuePersisted Initialization Tests

    func testBuildIssuePersistedInit() {
        let issue = BuildIssuePersisted(
            severity: "error",
            message: "Cannot find type 'Foo' in scope",
            file: "MyFile.swift",
            line: 42,
            column: 10,
            toolchainHint: "swiftc",
            ruleId: "type_not_found",
            excerpt: "/path/MyFile.swift:42:10: error: Cannot find type 'Foo' in scope"
        )

        XCTAssertEqual(issue.severity, "error")
        XCTAssertEqual(issue.message, "Cannot find type 'Foo' in scope")
        XCTAssertEqual(issue.file, "MyFile.swift")
        XCTAssertEqual(issue.line, 42)
        XCTAssertEqual(issue.column, 10)
        XCTAssertEqual(issue.toolchainHint, "swiftc")
        XCTAssertEqual(issue.ruleId, "type_not_found")
    }

    func testBuildIssuePersistedMinimalInit() {
        let issue = BuildIssuePersisted(
            severity: "warning",
            message: "Some warning",
            excerpt: "warning line"
        )

        XCTAssertEqual(issue.severity, "warning")
        XCTAssertEqual(issue.message, "Some warning")
        XCTAssertNil(issue.file)
        XCTAssertNil(issue.line)
        XCTAssertNil(issue.column)
        XCTAssertNil(issue.toolchainHint)
        XCTAssertNil(issue.ruleId)
        XCTAssertEqual(issue.excerpt, "warning line")
    }

    func testBuildIssuePersistedHashable() {
        let issue1 = BuildIssuePersisted(severity: "error", message: "Error 1", excerpt: "e1")
        let issue2 = BuildIssuePersisted(severity: "error", message: "Error 1", excerpt: "e1")
        let issue3 = BuildIssuePersisted(severity: "error", message: "Error 2", excerpt: "e2")

        var issueSet = Set<BuildIssuePersisted>()
        issueSet.insert(issue1)
        issueSet.insert(issue2)
        issueSet.insert(issue3)

        // issue1 and issue2 are equal
        XCTAssertEqual(issueSet.count, 2)
    }

    // MARK: - BuildIssuePersisted Codable Tests

    func testBuildIssuePersistedEncodeDecode() throws {
        let original = BuildIssuePersisted(
            severity: "error",
            message: "Test error",
            file: "Test.swift",
            line: 10,
            column: 5,
            toolchainHint: "clang",
            ruleId: "E001",
            excerpt: "error excerpt"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(BuildIssuePersisted.self, from: data)

        XCTAssertEqual(decoded.severity, original.severity)
        XCTAssertEqual(decoded.message, original.message)
        XCTAssertEqual(decoded.file, original.file)
        XCTAssertEqual(decoded.line, original.line)
        XCTAssertEqual(decoded.column, original.column)
        XCTAssertEqual(decoded.toolchainHint, original.toolchainHint)
        XCTAssertEqual(decoded.ruleId, original.ruleId)
        XCTAssertEqual(decoded.excerpt, original.excerpt)
    }

    func testBuildIssuePersistedDecodeWithNilOptionals() throws {
        let json = """
        {
            "severity": "warning",
            "message": "Test warning",
            "excerpt": "warning excerpt"
        }
        """

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(BuildIssuePersisted.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(decoded.severity, "warning")
        XCTAssertEqual(decoded.message, "Test warning")
        XCTAssertNil(decoded.file)
        XCTAssertNil(decoded.line)
        XCTAssertNil(decoded.column)
        XCTAssertNil(decoded.toolchainHint)
        XCTAssertNil(decoded.ruleId)
    }

    // MARK: - BuildDiagnosticsPersisted Initialization Tests

    func testBuildDiagnosticsPersistedInit() {
        let issues = [
            BuildIssuePersisted(severity: "error", message: "Error 1", excerpt: "e1"),
            BuildIssuePersisted(severity: "error", message: "Error 2", excerpt: "e2"),
            BuildIssuePersisted(severity: "warning", message: "Warning 1", excerpt: "w1")
        ]

        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 2,
            warningCount: 1,
            issues: issues
        )

        XCTAssertEqual(diagnostics.schemaVersion, 1)
        XCTAssertEqual(diagnostics.errorCount, 2)
        XCTAssertEqual(diagnostics.warningCount, 1)
        XCTAssertEqual(diagnostics.issues.count, 3)
        XCTAssertNil(diagnostics.skipped)
        XCTAssertNil(diagnostics.skipReason)
        XCTAssertNil(diagnostics.excerptsRelativePath)
    }

    func testBuildDiagnosticsPersistedWithAllFields() {
        let customDate = Date(timeIntervalSince1970: 1000)
        let issues = [
            BuildIssuePersisted(severity: "error", message: "Error", excerpt: "e")
        ]

        let diagnostics = BuildDiagnosticsPersisted(
            schemaVersion: 2,
            createdAt: customDate,
            errorCount: 1,
            warningCount: 0,
            skipped: false,
            skipReason: nil,
            issues: issues,
            excerptsRelativePath: "runs/123/steps/456/excerpts.txt"
        )

        XCTAssertEqual(diagnostics.schemaVersion, 2)
        XCTAssertEqual(diagnostics.createdAt, customDate)
        XCTAssertEqual(diagnostics.errorCount, 1)
        XCTAssertEqual(diagnostics.warningCount, 0)
        XCTAssertEqual(diagnostics.skipped, false)
        XCTAssertEqual(diagnostics.excerptsRelativePath, "runs/123/steps/456/excerpts.txt")
    }

    func testBuildDiagnosticsPersistedSkipped() {
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 0,
            warningCount: 0,
            skipped: true,
            skipReason: "no_project",
            issues: []
        )

        XCTAssertTrue(diagnostics.skipped ?? false)
        XCTAssertEqual(diagnostics.skipReason, "no_project")
        XCTAssertTrue(diagnostics.issues.isEmpty)
    }

    func testBuildDiagnosticsPersistedHashable() {
        let diagnostics1 = BuildDiagnosticsPersisted(
            createdAt: Date(timeIntervalSince1970: 1000),
            errorCount: 1, warningCount: 0, issues: []
        )
        let diagnostics2 = BuildDiagnosticsPersisted(
            createdAt: Date(timeIntervalSince1970: 2000),
            errorCount: 1, warningCount: 0, issues: []
        )

        var diagnosticsSet = Set<BuildDiagnosticsPersisted>()
        diagnosticsSet.insert(diagnostics1)
        diagnosticsSet.insert(diagnostics2)

        // Different createdAt timestamps
        XCTAssertEqual(diagnosticsSet.count, 2)
    }

    // MARK: - BuildDiagnosticsPersisted Codable Tests

    func testBuildDiagnosticsPersistedEncodeDecode() throws {
        let issues = [
            BuildIssuePersisted(severity: "error", message: "Test", excerpt: "e")
        ]
        let original = BuildDiagnosticsPersisted(
            schemaVersion: 1,
            errorCount: 1,
            warningCount: 2,
            skipped: false,
            issues: issues,
            excerptsRelativePath: "path/to/excerpts"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BuildDiagnosticsPersisted.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, original.schemaVersion)
        XCTAssertEqual(decoded.errorCount, original.errorCount)
        XCTAssertEqual(decoded.warningCount, original.warningCount)
        XCTAssertEqual(decoded.skipped, original.skipped)
        XCTAssertEqual(decoded.issues.count, original.issues.count)
        XCTAssertEqual(decoded.excerptsRelativePath, original.excerptsRelativePath)
    }

    func testBuildDiagnosticsPersistedDecodeFromMinimalJSON() throws {
        let json = """
        {
            "schemaVersion": 1,
            "createdAt": "2024-01-01T00:00:00Z",
            "errorCount": 0,
            "warningCount": 0,
            "issues": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BuildDiagnosticsPersisted.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.errorCount, 0)
        XCTAssertEqual(decoded.warningCount, 0)
        XCTAssertTrue(decoded.issues.isEmpty)
        XCTAssertNil(decoded.skipped)
        XCTAssertNil(decoded.skipReason)
        XCTAssertNil(decoded.excerptsRelativePath)
    }

    // MARK: - Issues Filtering Tests

    func testFilterErrorIssues() {
        let issues = [
            BuildIssuePersisted(severity: "error", message: "Error 1", excerpt: "e1"),
            BuildIssuePersisted(severity: "warning", message: "Warning 1", excerpt: "w1"),
            BuildIssuePersisted(severity: "error", message: "Error 2", excerpt: "e2"),
            BuildIssuePersisted(severity: "warning", message: "Warning 2", excerpt: "w2")
        ]
        let diagnostics = BuildDiagnosticsPersisted(errorCount: 2, warningCount: 2, issues: issues)

        let errors = diagnostics.issues.filter { $0.severity == "error" }
        let warnings = diagnostics.issues.filter { $0.severity == "warning" }

        XCTAssertEqual(errors.count, 2)
        XCTAssertEqual(warnings.count, 2)
    }

    func testFilterIssuesByFile() {
        let issues = [
            BuildIssuePersisted(severity: "error", message: "Error 1", file: "A.swift", excerpt: "e1"),
            BuildIssuePersisted(severity: "error", message: "Error 2", file: "B.swift", excerpt: "e2"),
            BuildIssuePersisted(severity: "error", message: "Error 3", file: "A.swift", excerpt: "e3")
        ]
        let diagnostics = BuildDiagnosticsPersisted(errorCount: 3, warningCount: 0, issues: issues)

        let fileAIssues = diagnostics.issues.filter { $0.file == "A.swift" }

        XCTAssertEqual(fileAIssues.count, 2)
    }

    // MARK: - Timestamp Tests

    func testBuildDiagnosticsDefaultTimestamp() {
        let before = Date()
        let diagnostics = BuildDiagnosticsPersisted(errorCount: 0, warningCount: 0, issues: [])

        // MonotonicClock may return timestamps slightly ahead of system time
        XCTAssertGreaterThanOrEqual(diagnostics.createdAt, before)
        XCTAssertLessThan(diagnostics.createdAt.timeIntervalSince(before), 1.0)
    }

    // MARK: - Empty Diagnostics Tests

    func testEmptyDiagnostics() {
        let diagnostics = BuildDiagnosticsPersisted(errorCount: 0, warningCount: 0, issues: [])

        XCTAssertEqual(diagnostics.errorCount, 0)
        XCTAssertEqual(diagnostics.warningCount, 0)
        XCTAssertTrue(diagnostics.issues.isEmpty)
    }

    // MARK: - Schema Version Tests

    func testSchemaVersionDefault() {
        let diagnostics = BuildDiagnosticsPersisted(errorCount: 0, warningCount: 0, issues: [])
        XCTAssertEqual(diagnostics.schemaVersion, 1)
    }

    func testSchemaVersionCustom() {
        let diagnostics = BuildDiagnosticsPersisted(schemaVersion: 5, errorCount: 0, warningCount: 0, issues: [])
        XCTAssertEqual(diagnostics.schemaVersion, 5)
    }
}
