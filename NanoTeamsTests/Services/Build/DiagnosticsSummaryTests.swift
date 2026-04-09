import XCTest
@testable import NanoTeams

/// Tests for XcodeBuildLogParser.diagnosticsSummary() — including maxIssues
/// truncation behavior and edge cases.
final class DiagnosticsSummaryTests: XCTestCase {

    // MARK: - Basic Summary

    func testSummary_NoIssues_ShowsCountsOnly() {
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 0,
            warningCount: 0,
            issues: []
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics)

        XCTAssertTrue(summary.contains("0 error(s)"))
        XCTAssertTrue(summary.contains("0 warning(s)"))
        XCTAssertFalse(summary.contains("Top issues:"))
    }

    func testSummary_WithIssues_ShowsTopIssues() {
        let issues = [
            BuildIssuePersisted(
                severity: "error",
                message: "Cannot find 'foo' in scope",
                file: "main.swift",
                line: 42,
                excerpt: "main.swift:42:5: error: Cannot find 'foo' in scope"
            )
        ]
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 1,
            warningCount: 0,
            issues: issues
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics)

        XCTAssertTrue(summary.contains("1 error(s)"))
        XCTAssertTrue(summary.contains("Top issues:"))
        XCTAssertTrue(summary.contains("[E] Cannot find 'foo' in scope"))
        XCTAssertTrue(summary.contains("main.swift:42"))
    }

    func testSummary_WarningPrefix() {
        let issues = [
            BuildIssuePersisted(
                severity: "warning",
                message: "Unused variable 'x'",
                file: "test.swift",
                line: 10,
                excerpt: "test.swift:10:5: warning: Unused variable 'x'"
            )
        ]
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 0,
            warningCount: 1,
            issues: issues
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics)

        XCTAssertTrue(summary.contains("[W] Unused variable 'x'"))
    }

    func testSummary_FileWithoutLine() {
        let issues = [
            BuildIssuePersisted(
                severity: "error",
                message: "Linker error",
                file: "libFoo.a",
                excerpt: "ld: error: Linker error"
            )
        ]
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 1,
            warningCount: 0,
            issues: issues
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics)

        // Should show file without line number
        XCTAssertTrue(summary.contains("libFoo.a"))
        XCTAssertFalse(summary.contains("libFoo.a:"))
    }

    func testSummary_NoFile() {
        let issues = [
            BuildIssuePersisted(
                severity: "error",
                message: "Unknown build system error",
                excerpt: "error: Unknown build system error"
            )
        ]
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 1,
            warningCount: 0,
            issues: issues
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics)

        XCTAssertTrue(summary.contains("[E] Unknown build system error"))
        // No file/line location
        XCTAssertFalse(summary.contains(" — "))
    }

    // MARK: - maxIssues Truncation

    func testSummary_ExactlyMaxIssues_NoTruncationMessage() {
        let issues = (0..<10).map { i in
            BuildIssuePersisted(
                severity: "error",
                message: "Error \(i)",
                excerpt: "error: Error \(i)"
            )
        }
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 10,
            warningCount: 0,
            issues: issues
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics, maxIssues: 10)

        XCTAssertFalse(summary.contains("more."))
        // All 10 issues should be present
        for i in 0..<10 {
            XCTAssertTrue(summary.contains("Error \(i)"), "Missing Error \(i)")
        }
    }

    func testSummary_MoreThanMaxIssues_ShowsTruncationMessage() {
        let issues = (0..<15).map { i in
            BuildIssuePersisted(
                severity: "error",
                message: "Error \(i)",
                excerpt: "error: Error \(i)"
            )
        }
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 15,
            warningCount: 0,
            issues: issues
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics, maxIssues: 10)

        XCTAssertTrue(summary.contains("and 5 more."))
        // First 10 should be present
        for i in 0..<10 {
            XCTAssertTrue(summary.contains("Error \(i)"), "Missing Error \(i)")
        }
        // 11th and beyond should not
        XCTAssertFalse(summary.contains("Error 10"))
    }

    func testSummary_BoundaryAt12_MaxDiagnosticsIssues() {
        // Tests the actual maxDiagnosticsIssues constant behavior
        let issues = (0..<13).map { i in
            BuildIssuePersisted(
                severity: "error",
                message: "Error \(i)",
                excerpt: "error: Error \(i)"
            )
        }
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 13,
            warningCount: 0,
            issues: issues
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics, maxIssues: 12)

        XCTAssertTrue(summary.contains("and 1 more."))
        // First 12 should be present
        for i in 0..<12 {
            XCTAssertTrue(summary.contains("Error \(i)"), "Missing Error \(i)")
        }
        XCTAssertFalse(summary.contains("Error 12"))
    }

    func testSummary_MaxIssuesZero_ShowsNoIssues() {
        let issues = [
            BuildIssuePersisted(
                severity: "error",
                message: "Error 0",
                excerpt: "error: Error 0"
            )
        ]
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 1,
            warningCount: 0,
            issues: issues
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics, maxIssues: 0)

        XCTAssertTrue(summary.contains("1 error(s)"))
        XCTAssertFalse(summary.contains("[E] Error 0"))
        XCTAssertTrue(summary.contains("and 1 more."))
    }

    // MARK: - Build Skipped

    func testSummary_BuildSkipped_ShowsSkipReason() {
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 0,
            warningCount: 0,
            skipped: true,
            skipReason: "no_project",
            issues: []
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics)

        XCTAssertTrue(summary.contains("Build skipped"))
        XCTAssertTrue(summary.contains("no_project"))
        XCTAssertFalse(summary.contains("error(s)"))
    }

    func testSummary_BuildSkipped_NoReason() {
        let diagnostics = BuildDiagnosticsPersisted(
            errorCount: 0,
            warningCount: 0,
            skipped: true,
            issues: []
        )

        let summary = XcodeBuildLogParser.diagnosticsSummary(diagnostics)

        XCTAssertTrue(summary.contains("Build skipped"))
        XCTAssertTrue(summary.contains("unknown"))
    }
}
