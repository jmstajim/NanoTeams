import XCTest
@testable import NanoTeams

final class XcodeBuildLogParserTests: XCTestCase {
    private let parser = XcodeBuildLogParser()

    private func fixtureURL(_ name: String) -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        return testFile
            .deletingLastPathComponent()  // removes XcodeBuildLogParserTests.swift -> Build/
            .deletingLastPathComponent()  // removes Build/ -> Services/
            .deletingLastPathComponent()  // removes Services/ -> NanoTeamsTests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("XcodebuildLogs")
            .appendingPathComponent(name)
    }

    private func loadFixture(_ name: String) throws -> String {
        let url = fixtureURL(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesClangStyleErrorAndWarning() throws {
        let stdout = try loadFixture("clang_mixed.log")
        let issues = parser.parse(stdout: stdout, stderr: "")

        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertEqual(issues.first?.file?.hasSuffix("main.swift"), true)
        XCTAssertEqual(issues.first?.line, 12)
        XCTAssertEqual(issues.first?.column, 34)
        XCTAssertEqual(issues.last?.severity, .warning)
    }

    func testParsesSwiftErrorAtLocation() throws {
        let stdout = try loadFixture("swift_error_at.log")
        let issues = parser.parse(stdout: stdout, stderr: "")

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertEqual(issues.first?.file?.hasSuffix("main.swift"), true)
        XCTAssertEqual(issues.first?.line, 7)
        XCTAssertEqual(issues.first?.column, 9)
        XCTAssertEqual(issues.first?.toolchainHint, "swiftc")
    }

    func testParsesLinkerDuplicateSymbol() throws {
        let stderr = try loadFixture("linker_duplicate_symbol.log")
        let issues = parser.parse(stdout: "", stderr: stderr)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertEqual(issues.first?.toolchainHint, "ld")
        XCTAssertTrue(issues.first?.message.contains("duplicate symbol") == true)
    }

    func testParsesSwiftLintRuleId() throws {
        let stdout = try loadFixture("swiftlint_warning.log")
        let issues = parser.parse(stdout: stdout, stderr: "")

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .warning)
        XCTAssertEqual(issues.first?.ruleId, "syntactic_sugar")
        XCTAssertEqual(issues.first?.toolchainHint, "swiftlint")
    }

    func testParsesSwiftPMStyleWarning() throws {
        let stdout = try loadFixture("swiftpm_warning.log")
        let issues = parser.parse(stdout: stdout, stderr: "")

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .warning)
        XCTAssertEqual(issues.first?.file?.contains(".build/checkouts"), true)
    }

    func testParsesXcodebuildErrors() throws {
        let stderr = try loadFixture("xcodebuild_error.log")
        let issues = parser.parse(stdout: "", stderr: stderr)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertEqual(issues.first?.toolchainHint, "xcodebuild")
    }

    func testFiltersNoiseLines() throws {
        let stdout = try loadFixture("noise.log")
        let issues = parser.parse(stdout: stdout, stderr: "")
        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - Truncation Tests (Issue #34)

    func testTruncatesLongMessageAtParseTime() {
        // Create an issue with a very long message
        let longMessage = String(repeating: "x", count: 1000)
        let stdout = "/path/to/file.swift:10:5: error: \(longMessage)"
        let issues = parser.parse(stdout: stdout, stderr: "")

        XCTAssertEqual(issues.count, 1)
        XCTAssertLessThanOrEqual(issues.first?.message.count ?? 0, BuildConstants.maxIssueMessageLength)
        XCTAssertTrue(issues.first?.message.count ?? 0 > 0)  // Not empty, just truncated
    }

    func testTruncatesExcerptAtParseTime() {
        // Create a very long error line
        let longLine = "/path/to/file.swift:10:5: error: " + String(repeating: "x", count: 1000)
        let issues = parser.parse(stdout: longLine, stderr: "")

        XCTAssertEqual(issues.count, 1)
        XCTAssertLessThanOrEqual(issues.first?.excerpt.count ?? 0, BuildConstants.maxIssueExcerptLength)
    }

    // MARK: - Deduplication Tests (Issue #34)

    func testDeduplicatesIdenticalIssues() {
        // Parse the same error twice
        let stdout = """
        /path/to/File.swift:10:5: error: Variable 'x' not found
        some noise
        /path/to/File.swift:10:5: error: Variable 'x' not found
        """
        let issues = parser.parse(stdout: stdout, stderr: "")

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.message, "Variable 'x' not found")
    }

    func testDeduplicatesKeepsFirstOccurrence() {
        let stdout = """
        /path/to/FileA.swift:10:5: error: Same message
        /path/to/FileB.swift:20:10: error: Same message
        /path/to/FileA.swift:10:5: error: Same message
        """
        let issues = parser.parse(stdout: stdout, stderr: "")

        XCTAssertEqual(issues.count, 2)  // Two unique (file, line) combinations
        XCTAssertEqual(issues[0].file, "/path/to/FileA.swift")
        XCTAssertEqual(issues[1].file, "/path/to/FileB.swift")
    }

    func testDeduplicatesDifferentSeveritiesSeparately() {
        let stdout = """
        /path/to/File.swift:10:5: error: Same message text
        /path/to/File.swift:10:5: warning: Same message text
        """
        let issues = parser.parse(stdout: stdout, stderr: "")

        XCTAssertEqual(issues.count, 2)  // Different severity = different issues
        XCTAssertEqual(issues[0].severity, .error)
        XCTAssertEqual(issues[1].severity, .warning)
    }

    func testCapsIssuesAtMaxTotal() {
        var lines: [String] = []
        for i in 0..<(BuildConstants.maxTotalIssuesStored + 10) {
            lines.append("/path/to/File.swift:\(10 + i):5: error: Error \(i)")
        }
        let stdout = lines.joined(separator: "\n")
        let issues = parser.parse(stdout: stdout, stderr: "")

        XCTAssertLessThanOrEqual(issues.count, BuildConstants.maxTotalIssuesStored)
        XCTAssertEqual(issues.count, BuildConstants.maxTotalIssuesStored)
    }
}
