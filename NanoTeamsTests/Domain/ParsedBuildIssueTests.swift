import XCTest
@testable import NanoTeams

final class ParsedBuildIssueTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit_MinimalParameters() {
        let issue = ParsedBuildIssue(
            severity: .error,
            message: "Undefined symbol",
            excerpt: "/path/to/file.swift:10: error: Undefined symbol"
        )

        XCTAssertEqual(issue.severity, .error)
        XCTAssertEqual(issue.message, "Undefined symbol")
        XCTAssertNil(issue.file)
        XCTAssertNil(issue.line)
        XCTAssertNil(issue.column)
        XCTAssertNil(issue.toolchainHint)
        XCTAssertNil(issue.ruleId)
        XCTAssertEqual(issue.excerpt, "/path/to/file.swift:10: error: Undefined symbol")
    }

    func testInit_AllParameters() {
        let issue = ParsedBuildIssue(
            severity: .warning,
            message: "Unused variable 'x'",
            file: "/Users/dev/Project/Source.swift",
            line: 42,
            column: 15,
            toolchainHint: "swift-5.9",
            ruleId: "unused_variable",
            excerpt: "Source.swift:42:15: warning: Unused variable 'x'"
        )

        XCTAssertEqual(issue.severity, .warning)
        XCTAssertEqual(issue.message, "Unused variable 'x'")
        XCTAssertEqual(issue.file, "/Users/dev/Project/Source.swift")
        XCTAssertEqual(issue.line, 42)
        XCTAssertEqual(issue.column, 15)
        XCTAssertEqual(issue.toolchainHint, "swift-5.9")
        XCTAssertEqual(issue.ruleId, "unused_variable")
        XCTAssertEqual(issue.excerpt, "Source.swift:42:15: warning: Unused variable 'x'")
    }

    // MARK: - Severity Tests

    func testSeverity_Error() {
        XCTAssertEqual(ParsedBuildIssue.Severity.error.rawValue, "error")
    }

    func testSeverity_Warning() {
        XCTAssertEqual(ParsedBuildIssue.Severity.warning.rawValue, "warning")
    }

    func testSeverity_Codable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let errorData = try encoder.encode(ParsedBuildIssue.Severity.error)
        let decodedError = try decoder.decode(ParsedBuildIssue.Severity.self, from: errorData)
        XCTAssertEqual(decodedError, .error)

        let warningData = try encoder.encode(ParsedBuildIssue.Severity.warning)
        let decodedWarning = try decoder.decode(ParsedBuildIssue.Severity.self, from: warningData)
        XCTAssertEqual(decodedWarning, .warning)
    }

    // MARK: - Codable Tests

    func testCodable_FullIssue() throws {
        let issue = ParsedBuildIssue(
            severity: .error,
            message: "Type 'Foo' has no member 'bar'",
            file: "/path/to/file.swift",
            line: 100,
            column: 20,
            toolchainHint: "Xcode 15.0",
            ruleId: "missing_member",
            excerpt: "file.swift:100:20: error: Type 'Foo' has no member 'bar'"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(issue)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ParsedBuildIssue.self, from: data)

        XCTAssertEqual(decoded.severity, issue.severity)
        XCTAssertEqual(decoded.message, issue.message)
        XCTAssertEqual(decoded.file, issue.file)
        XCTAssertEqual(decoded.line, issue.line)
        XCTAssertEqual(decoded.column, issue.column)
        XCTAssertEqual(decoded.toolchainHint, issue.toolchainHint)
        XCTAssertEqual(decoded.ruleId, issue.ruleId)
        XCTAssertEqual(decoded.excerpt, issue.excerpt)
    }

    func testCodable_MinimalIssue() throws {
        let issue = ParsedBuildIssue(
            severity: .warning,
            message: "Deprecated API usage",
            excerpt: "DeprecatedAPI.swift: warning: Deprecated API usage"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(issue)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ParsedBuildIssue.self, from: data)

        XCTAssertEqual(decoded.severity, .warning)
        XCTAssertEqual(decoded.message, "Deprecated API usage")
        XCTAssertNil(decoded.file)
        XCTAssertNil(decoded.line)
        XCTAssertNil(decoded.column)
        XCTAssertNil(decoded.toolchainHint)
        XCTAssertNil(decoded.ruleId)
    }

    func testCodable_JSONFormat() throws {
        let issue = ParsedBuildIssue(
            severity: .error,
            message: "Test message",
            file: "/test.swift",
            line: 10,
            column: 5,
            excerpt: "excerpt"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(issue)
        let jsonString = String(data: data, encoding: .utf8)!

        XCTAssertTrue(jsonString.contains("\"severity\":\"error\""))
        XCTAssertTrue(jsonString.contains("\"message\":\"Test message\""))
        // JSON encoder escapes forward slashes as \/
        XCTAssertTrue(jsonString.contains("\"file\":\"\\/test.swift\""))
        XCTAssertTrue(jsonString.contains("\"line\":10"))
        XCTAssertTrue(jsonString.contains("\"column\":5"))
    }

    // MARK: - Hashable Tests

    func testHashable_Equal() {
        let issue1 = ParsedBuildIssue(
            severity: .error,
            message: "Same message",
            file: "/path/file.swift",
            line: 10,
            column: 5,
            excerpt: "excerpt"
        )

        let issue2 = ParsedBuildIssue(
            severity: .error,
            message: "Same message",
            file: "/path/file.swift",
            line: 10,
            column: 5,
            excerpt: "excerpt"
        )

        XCTAssertEqual(issue1, issue2)
        XCTAssertEqual(issue1.hashValue, issue2.hashValue)
    }

    func testHashable_NotEqual_DifferentSeverity() {
        let error = ParsedBuildIssue(
            severity: .error,
            message: "Message",
            excerpt: "excerpt"
        )

        let warning = ParsedBuildIssue(
            severity: .warning,
            message: "Message",
            excerpt: "excerpt"
        )

        XCTAssertNotEqual(error, warning)
    }

    func testHashable_NotEqual_DifferentMessage() {
        let issue1 = ParsedBuildIssue(
            severity: .error,
            message: "Message 1",
            excerpt: "excerpt"
        )

        let issue2 = ParsedBuildIssue(
            severity: .error,
            message: "Message 2",
            excerpt: "excerpt"
        )

        XCTAssertNotEqual(issue1, issue2)
    }

    func testHashable_NotEqual_DifferentFile() {
        let issue1 = ParsedBuildIssue(
            severity: .error,
            message: "Message",
            file: "/path1/file.swift",
            excerpt: "excerpt"
        )

        let issue2 = ParsedBuildIssue(
            severity: .error,
            message: "Message",
            file: "/path2/file.swift",
            excerpt: "excerpt"
        )

        XCTAssertNotEqual(issue1, issue2)
    }

    func testHashable_Set() {
        let issues: Set<ParsedBuildIssue> = [
            ParsedBuildIssue(severity: .error, message: "Error 1", excerpt: "e1"),
            ParsedBuildIssue(severity: .error, message: "Error 2", excerpt: "e2"),
            ParsedBuildIssue(severity: .warning, message: "Warning 1", excerpt: "w1"),
            // Duplicate of first
            ParsedBuildIssue(severity: .error, message: "Error 1", excerpt: "e1")
        ]

        XCTAssertEqual(issues.count, 3)
    }

    // MARK: - Sendable Tests

    func testSendable_CanBeSentAcrossBoundaries() async {
        let issue = ParsedBuildIssue(
            severity: .error,
            message: "Test",
            excerpt: "Test excerpt"
        )

        // This compiles because ParsedBuildIssue is Sendable
        let result = await Task { issue }.value

        XCTAssertEqual(result.message, "Test")
    }

    // MARK: - Real-World Scenarios

    func testRealWorld_SwiftCompilerError() {
        let issue = ParsedBuildIssue(
            severity: .error,
            message: "Cannot convert value of type 'Int' to expected argument type 'String'",
            file: "/Users/dev/MyApp/Sources/ViewModel.swift",
            line: 45,
            column: 23,
            toolchainHint: "Apple Swift version 5.9",
            excerpt: "ViewModel.swift:45:23: error: Cannot convert value of type 'Int' to expected argument type 'String'"
        )

        XCTAssertEqual(issue.severity, .error)
        XCTAssertNotNil(issue.file)
        XCTAssertNotNil(issue.line)
        XCTAssertNotNil(issue.column)
    }

    func testRealWorld_LinkerError() {
        let issue = ParsedBuildIssue(
            severity: .error,
            message: "Undefined symbols for architecture arm64: '_OBJC_CLASS_$_SomeFramework'",
            excerpt: "ld: Undefined symbols for architecture arm64"
        )

        XCTAssertEqual(issue.severity, .error)
        XCTAssertNil(issue.file)
        XCTAssertNil(issue.line)
    }

    func testRealWorld_DeprecationWarning() {
        let issue = ParsedBuildIssue(
            severity: .warning,
            message: "'UIWebView' is deprecated: first deprecated in iOS 12.0",
            file: "/Users/dev/MyApp/Sources/WebViewController.swift",
            line: 15,
            ruleId: "deprecation",
            excerpt: "WebViewController.swift:15: warning: 'UIWebView' is deprecated"
        )

        XCTAssertEqual(issue.severity, .warning)
        XCTAssertEqual(issue.ruleId, "deprecation")
    }

    func testRealWorld_BuildSettingWarning() {
        let issue = ParsedBuildIssue(
            severity: .warning,
            message: "The iOS Simulator deployment target 'IPHONEOS_DEPLOYMENT_TARGET' is set to 11.0",
            excerpt: "warning: The iOS Simulator deployment target is set to 11.0"
        )

        XCTAssertEqual(issue.severity, .warning)
        XCTAssertNil(issue.file)
    }

    // MARK: - Edge Cases

    func testEdgeCase_EmptyMessage() {
        let issue = ParsedBuildIssue(
            severity: .error,
            message: "",
            excerpt: "excerpt"
        )

        XCTAssertEqual(issue.message, "")
    }

    func testEdgeCase_VeryLongMessage() {
        let longMessage = String(repeating: "a", count: 10000)
        let issue = ParsedBuildIssue(
            severity: .error,
            message: longMessage,
            excerpt: "excerpt"
        )

        XCTAssertEqual(issue.message.count, 10000)
    }

    func testEdgeCase_SpecialCharactersInMessage() {
        let issue = ParsedBuildIssue(
            severity: .error,
            message: "Error with 'quotes' and \"double quotes\" and <brackets>",
            excerpt: "excerpt"
        )

        XCTAssertTrue(issue.message.contains("'quotes'"))
        XCTAssertTrue(issue.message.contains("\"double quotes\""))
        XCTAssertTrue(issue.message.contains("<brackets>"))
    }

    func testEdgeCase_UnicodeInMessage() {
        let issue = ParsedBuildIssue(
            severity: .warning,
            message: "Variable '変数' is unused",
            file: "/path/日本語.swift",
            excerpt: "日本語.swift: warning: Variable '変数' is unused"
        )

        XCTAssertTrue(issue.message.contains("変数"))
        XCTAssertTrue(issue.file!.contains("日本語"))
    }

    func testEdgeCase_ZeroLineAndColumn() {
        let issue = ParsedBuildIssue(
            severity: .error,
            message: "Error at start",
            line: 0,
            column: 0,
            excerpt: "excerpt"
        )

        XCTAssertEqual(issue.line, 0)
        XCTAssertEqual(issue.column, 0)
    }

    func testEdgeCase_NegativeLineNumber() {
        // While unusual, the type allows it
        let issue = ParsedBuildIssue(
            severity: .error,
            message: "Unusual error",
            line: -1,
            excerpt: "excerpt"
        )

        XCTAssertEqual(issue.line, -1)
    }
}
