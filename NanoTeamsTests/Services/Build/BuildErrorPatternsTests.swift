import XCTest
@testable import NanoTeams

final class BuildErrorPatternsTests: XCTestCase {

    private var patterns: [BuildErrorPatterns.Pattern]!

    override func setUp() {
        super.setUp()
        patterns = BuildErrorPatterns.all()
    }

    override func tearDown() {
        patterns = nil
        super.tearDown()
    }

    // MARK: - Pattern count

    func testAllPatterns_returns7() {
        XCTAssertEqual(patterns.count, 7)
    }

    // MARK: - SwiftLint pattern (index 0)

    func testSwiftLintPattern_matchesSwiftLintError() {
        let line = "/path/File.swift:10:5: error: Trailing Whitespace Violation (trailing_whitespace)"
        let match = firstMatch(pattern: patterns[0], in: line)
        XCTAssertNotNil(match)
        XCTAssertEqual(extractGroup(match!, group: patterns[0].fileIndex, in: line), "/path/File.swift")
        XCTAssertEqual(extractGroup(match!, group: patterns[0].lineIndex, in: line), "10")
        XCTAssertEqual(extractGroup(match!, group: patterns[0].columnIndex, in: line), "5")
        XCTAssertEqual(extractGroup(match!, group: patterns[0].severityGroupIndex, in: line), "error")
        XCTAssertEqual(extractGroup(match!, group: patterns[0].messageIndex, in: line), "Trailing Whitespace Violation")
        XCTAssertEqual(extractGroup(match!, group: patterns[0].ruleIndex, in: line), "trailing_whitespace")
    }

    func testSwiftLintPattern_matchesWarning() {
        let line = "/src/App.swift:42:1: warning: Line Length Violation (line_length)"
        let match = firstMatch(pattern: patterns[0], in: line)
        XCTAssertNotNil(match)
        XCTAssertEqual(extractGroup(match!, group: patterns[0].severityGroupIndex, in: line), "warning")
    }

    // MARK: - Compiler error pattern (index 1)

    func testCompilerErrorPattern_matchesSwiftCompilerError() {
        let line = "/src/main.swift:25:13: error: cannot find 'foo' in scope"
        let match = firstMatch(pattern: patterns[1], in: line)
        XCTAssertNotNil(match)
        XCTAssertEqual(extractGroup(match!, group: patterns[1].fileIndex, in: line), "/src/main.swift")
        XCTAssertEqual(extractGroup(match!, group: patterns[1].lineIndex, in: line), "25")
        XCTAssertEqual(extractGroup(match!, group: patterns[1].columnIndex, in: line), "13")
        XCTAssertEqual(extractGroup(match!, group: patterns[1].messageIndex, in: line), "cannot find 'foo' in scope")
    }

    func testCompilerErrorPattern_matchesWarning() {
        let line = "/src/file.swift:5:8: warning: unused variable 'x'"
        let match = firstMatch(pattern: patterns[1], in: line)
        XCTAssertNotNil(match)
        XCTAssertEqual(extractGroup(match!, group: patterns[1].severityGroupIndex, in: line), "warning")
    }

    // MARK: - No-column pattern (index 2)

    func testNoColumnPattern_matchesErrorWithoutColumn() {
        let line = "/path/file.swift:100: error: missing return in function"
        let match = firstMatch(pattern: patterns[2], in: line)
        XCTAssertNotNil(match)
        XCTAssertEqual(extractGroup(match!, group: patterns[2].fileIndex, in: line), "/path/file.swift")
        XCTAssertEqual(extractGroup(match!, group: patterns[2].lineIndex, in: line), "100")
        XCTAssertEqual(patterns[2].columnIndex, -1)
        XCTAssertEqual(extractGroup(match!, group: patterns[2].messageIndex, in: line), "missing return in function")
    }

    // MARK: - Swift error with (at:) format (index 3)

    func testSwiftAtPattern_matchesErrorWithAtSuffix() {
        let line = "error: type 'Foo' does not conform to protocol 'Bar' (at: Sources/Foo.swift:15:3)"
        let match = firstMatch(pattern: patterns[3], in: line)
        XCTAssertNotNil(match)
        XCTAssertEqual(extractGroup(match!, group: patterns[3].severityGroupIndex, in: line), "error")
        XCTAssertEqual(extractGroup(match!, group: patterns[3].fileIndex, in: line), "Sources/Foo.swift")
        XCTAssertEqual(extractGroup(match!, group: patterns[3].lineIndex, in: line), "15")
        XCTAssertEqual(extractGroup(match!, group: patterns[3].columnIndex, in: line), "3")
    }

    // MARK: - Linker error (index 4)

    func testLinkerPattern_matchesLdError() {
        let line = "ld: error: undefined symbol: _main"
        let match = firstMatch(pattern: patterns[4], in: line)
        XCTAssertNotNil(match)
        XCTAssertEqual(extractGroup(match!, group: patterns[4].severityGroupIndex, in: line), "error")
        XCTAssertEqual(extractGroup(match!, group: patterns[4].messageIndex, in: line), "undefined symbol: _main")
        XCTAssertEqual(patterns[4].fileIndex, -1)
        XCTAssertEqual(patterns[4].lineIndex, -1)
    }

    func testLinkerPattern_matchesLdWarning() {
        let line = "ld: warning: dylib was built for newer OS version"
        let match = firstMatch(pattern: patterns[4], in: line)
        XCTAssertNotNil(match)
        XCTAssertEqual(extractGroup(match!, group: patterns[4].severityGroupIndex, in: line), "warning")
    }

    // MARK: - xcodebuild error (index 5)

    func testXcodebuildPattern_matchesXcodebuildError() {
        let line = "xcodebuild: error: Could not find scheme 'MyApp'"
        let match = firstMatch(pattern: patterns[5], in: line)
        XCTAssertNotNil(match)
        XCTAssertEqual(extractGroup(match!, group: patterns[5].severityGroupIndex, in: line), "error")
        XCTAssertEqual(extractGroup(match!, group: patterns[5].messageIndex, in: line), "Could not find scheme 'MyApp'")
        XCTAssertEqual(patterns[5].toolHint, "xcodebuild")
    }

    // MARK: - Fatal error (index 6)

    func testFatalErrorPattern_matchesFatalError() {
        let line = "fatal error: module 'Foundation' was not compiled with library evolution support"
        let match = firstMatch(pattern: patterns[6], in: line)
        XCTAssertNotNil(match)
        XCTAssertEqual(extractGroup(match!, group: patterns[6].messageIndex, in: line), "module 'Foundation' was not compiled with library evolution support")
        XCTAssertEqual(patterns[6].toolHint, "swiftc")
    }

    // MARK: - Tool hints

    func testToolHints_correctValues() {
        XCTAssertEqual(patterns[0].toolHint, "swiftlint")
        XCTAssertNil(patterns[1].toolHint)
        XCTAssertNil(patterns[2].toolHint)
        XCTAssertEqual(patterns[3].toolHint, "swiftc")
        XCTAssertEqual(patterns[4].toolHint, "ld")
        XCTAssertEqual(patterns[5].toolHint, "xcodebuild")
        XCTAssertEqual(patterns[6].toolHint, "swiftc")
    }

    // MARK: - Negative cases

    func testNormalLine_noMatch() {
        let line = "Compiling Swift source files"
        for pattern in patterns {
            XCTAssertNil(firstMatch(pattern: pattern, in: line),
                         "Pattern \(pattern.toolHint ?? "unnamed") should not match normal line")
        }
    }

    func testBuildSucceeded_noMatch() {
        let line = "BUILD SUCCEEDED"
        for pattern in patterns {
            XCTAssertNil(firstMatch(pattern: pattern, in: line))
        }
    }

    // MARK: - Helpers

    private func firstMatch(pattern: BuildErrorPatterns.Pattern, in line: String) -> NSTextCheckingResult? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return pattern.regex.firstMatch(in: line, range: range)
    }

    private func extractGroup(_ match: NSTextCheckingResult, group: Int, in line: String) -> String? {
        guard group >= 0, group < match.numberOfRanges else { return nil }
        let nsRange = match.range(at: group)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: line) else { return nil }
        return String(line[range])
    }
}
