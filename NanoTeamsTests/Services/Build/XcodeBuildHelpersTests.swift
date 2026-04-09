import XCTest

@testable import NanoTeams

final class XcodeBuildHelpersTests: XCTestCase {

    // MARK: - isFeatureBranchName Tests

    func testIsFeatureBranchName_validBasicName() {
        XCTAssertTrue(XcodeBuildHelpers.isFeatureBranchName("feature/add-login"))
        XCTAssertTrue(XcodeBuildHelpers.isFeatureBranchName("feature/fix-bug"))
        XCTAssertTrue(XcodeBuildHelpers.isFeatureBranchName("feature/update123"))
    }

    func testIsFeatureBranchName_validWithNumbers() {
        XCTAssertTrue(XcodeBuildHelpers.isFeatureBranchName("feature/123"))
        XCTAssertTrue(XcodeBuildHelpers.isFeatureBranchName("feature/v2"))
        XCTAssertTrue(XcodeBuildHelpers.isFeatureBranchName("feature/abc123def"))
    }

    func testIsFeatureBranchName_validWithSpecialCharacters() {
        XCTAssertTrue(XcodeBuildHelpers.isFeatureBranchName("feature/add-new-feature"))
        XCTAssertTrue(XcodeBuildHelpers.isFeatureBranchName("feature/add_new_feature"))
        XCTAssertTrue(XcodeBuildHelpers.isFeatureBranchName("feature/add.new.feature"))
        XCTAssertTrue(XcodeBuildHelpers.isFeatureBranchName("feature/add-new_feature.v2"))
    }

    func testIsFeatureBranchName_invalidPatterns() {
        // Missing feature/ prefix
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("main"))
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("develop"))
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("release/1.0"))

        // Wrong prefix
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("bugfix/fix-something"))
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("hotfix/urgent"))
    }

    func testIsFeatureBranchName_invalidStartingCharacter() {
        // Must start with lowercase letter or number after feature/
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("feature/-invalid"))
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("feature/_invalid"))
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("feature/.invalid"))
    }

    func testIsFeatureBranchName_invalidWithUppercase() {
        // Pattern requires lowercase
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("feature/AddFeature"))
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("feature/ADD-FEATURE"))
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("Feature/add-feature"))
    }

    func testIsFeatureBranchName_emptyOrWhitespace() {
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName(""))
        XCTAssertFalse(XcodeBuildHelpers.isFeatureBranchName("feature/"))
    }

    // MARK: - toolFailureMessage Tests

    func testToolFailureMessage_extractsFromMessage() {
        let result = ToolExecutionResult(
            toolName: "write_file",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":false,"message":"File not found"}"#,
            isError: true,
        )

        let message = XcodeBuildHelpers.toolFailureMessage(for: result)

        XCTAssertTrue(message.contains("write_file"))
        XCTAssertTrue(message.contains("File not found"))
    }

    func testToolFailureMessage_extractsFromError() {
        let result = ToolExecutionResult(
            toolName: "read_file",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":false,"error":"Permission denied"}"#,
            isError: true,
        )

        let message = XcodeBuildHelpers.toolFailureMessage(for: result)

        XCTAssertTrue(message.contains("read_file"))
        XCTAssertTrue(message.contains("Permission denied"))
    }

    func testToolFailureMessage_fallsBackToBase() {
        let result = ToolExecutionResult(
            toolName: "unknown_tool",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":false}"#,
            isError: true,
        )

        let message = XcodeBuildHelpers.toolFailureMessage(for: result)

        XCTAssertTrue(message.contains("unknown_tool"))
        XCTAssertTrue(message.contains("Tool execution failed"))
    }

    func testToolFailureMessage_invalidJSON() {
        let result = ToolExecutionResult(
            toolName: "some_tool",
            argumentsJSON: "{}",
            outputJSON: "not valid json",
            isError: true,
        )

        let message = XcodeBuildHelpers.toolFailureMessage(for: result)

        XCTAssertTrue(message.contains("some_tool"))
    }

    func testToolFailureMessage_prefersMessageOverError() {
        let result = ToolExecutionResult(
            toolName: "tool",
            argumentsJSON: "{}",
            outputJSON: #"{"message":"Specific message","error":"Generic error"}"#,
            isError: true,
        )

        let message = XcodeBuildHelpers.toolFailureMessage(for: result)

        XCTAssertTrue(message.contains("Specific message"))
    }

    // MARK: - didMutateFiles Tests

    func testDidMutateFiles_writeFile_success() {
        let toolCall = StepToolCall(name: "write_file", argumentsJSON: "{}")
        let result = ToolExecutionResult(
            toolName: "write_file",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":true}"#,
            isError: false,
        )

        XCTAssertTrue(XcodeBuildHelpers.didMutateFiles(toolCall: toolCall, result: result))
    }

    func testDidMutateFiles_writeFile_failure() {
        let toolCall = StepToolCall(name: "write_file", argumentsJSON: "{}")
        let result = ToolExecutionResult(
            toolName: "write_file",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":false}"#,
            isError: true,
        )

        XCTAssertFalse(XcodeBuildHelpers.didMutateFiles(toolCall: toolCall, result: result))
    }

    func testDidMutateFiles_readOnlyTool() {
        let toolCall = StepToolCall(name: "read_file", argumentsJSON: "{}")
        let result = ToolExecutionResult(
            toolName: "read_file",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":true,"content":"file contents"}"#,
            isError: false,
        )

        XCTAssertFalse(XcodeBuildHelpers.didMutateFiles(toolCall: toolCall, result: result))
    }

    func testDidMutateFiles_caseInsensitive() {
        let toolCall = StepToolCall(name: "Write_File", argumentsJSON: "{}")
        let result = ToolExecutionResult(
            toolName: "write_file",
            argumentsJSON: "{}",
            outputJSON: #"{"ok":true}"#,
            isError: false,
        )

        XCTAssertTrue(XcodeBuildHelpers.didMutateFiles(toolCall: toolCall, result: result))
    }

    func testDidMutateFiles_invalidJSON() {
        let toolCall = StepToolCall(name: "write_file", argumentsJSON: "{}")
        let result = ToolExecutionResult(
            toolName: "write_file",
            argumentsJSON: "{}",
            outputJSON: "invalid",
            isError: false,
        )

        XCTAssertFalse(XcodeBuildHelpers.didMutateFiles(toolCall: toolCall, result: result))
    }

    // MARK: - hasWarnings Tests

    func testHasWarnings_withWarnings() {
        let output = #"{"ok":true,"meta":{"warnings":["Deprecated API used"]}}"#

        XCTAssertTrue(XcodeBuildHelpers.hasWarnings(in: output))
    }

    func testHasWarnings_emptyWarnings() {
        let output = #"{"ok":true,"meta":{"warnings":[]}}"#

        XCTAssertFalse(XcodeBuildHelpers.hasWarnings(in: output))
    }

    func testHasWarnings_noTelemetry() {
        let output = #"{"ok":true}"#

        XCTAssertFalse(XcodeBuildHelpers.hasWarnings(in: output))
    }

    func testHasWarnings_noWarningsKey() {
        let output = #"{"ok":true,"meta":{"errors":[]}}"#

        XCTAssertFalse(XcodeBuildHelpers.hasWarnings(in: output))
    }

    func testHasWarnings_invalidJSON() {
        let output = "not json"

        XCTAssertFalse(XcodeBuildHelpers.hasWarnings(in: output))
    }

    func testHasWarnings_multipleWarnings() {
        let output = #"{"ok":true,"meta":{"warnings":["Warning 1","Warning 2","Warning 3"]}}"#

        XCTAssertTrue(XcodeBuildHelpers.hasWarnings(in: output))
    }

    // MARK: - parseBuildCounts Tests

    func testParseBuildCounts_parsesCorrectly() {
        let output = #"{"ok":true,"errorCount":5,"warningCount":10}"#

        let (errors, warnings) = XcodeBuildHelpers.parseBuildCounts(from: output)

        XCTAssertEqual(errors, 5)
        XCTAssertEqual(warnings, 10)
    }

    func testParseBuildCounts_zerosWhenMissing() {
        let output = #"{"ok":true}"#

        let (errors, warnings) = XcodeBuildHelpers.parseBuildCounts(from: output)

        XCTAssertEqual(errors, 0)
        XCTAssertEqual(warnings, 0)
    }

    func testParseBuildCounts_onlyErrors() {
        let output = #"{"ok":false,"errorCount":3}"#

        let (errors, warnings) = XcodeBuildHelpers.parseBuildCounts(from: output)

        XCTAssertEqual(errors, 3)
        XCTAssertEqual(warnings, 0)
    }

    func testParseBuildCounts_onlyWarnings() {
        let output = #"{"ok":true,"warningCount":7}"#

        let (errors, warnings) = XcodeBuildHelpers.parseBuildCounts(from: output)

        XCTAssertEqual(errors, 0)
        XCTAssertEqual(warnings, 7)
    }

    func testParseBuildCounts_invalidJSON() {
        let output = "not json"

        let (errors, warnings) = XcodeBuildHelpers.parseBuildCounts(from: output)

        XCTAssertEqual(errors, 0)
        XCTAssertEqual(warnings, 0)
    }

    func testParseBuildCounts_largeNumbers() {
        let output = #"{"errorCount":1000,"warningCount":5000}"#

        let (errors, warnings) = XcodeBuildHelpers.parseBuildCounts(from: output)

        XCTAssertEqual(errors, 1000)
        XCTAssertEqual(warnings, 5000)
    }

    // MARK: - DetectedXcodeProject Tests

    func testDetectedXcodeProject_initialization() {
        let detected = XcodeBuildHelpers.DetectedXcodeProject(
            found: true,
            kind: "workspace",
            path: "MyApp.xcworkspace",
            schemes: ["MyApp", "MyAppTests"]
        )

        XCTAssertTrue(detected.found)
        XCTAssertEqual(detected.kind, "workspace")
        XCTAssertEqual(detected.path, "MyApp.xcworkspace")
        XCTAssertEqual(detected.schemes.count, 2)
    }

    func testDetectedXcodeProject_notFound() {
        let detected = XcodeBuildHelpers.DetectedXcodeProject(
            found: false,
            kind: nil,
            path: nil,
            schemes: []
        )

        XCTAssertFalse(detected.found)
        XCTAssertNil(detected.kind)
        XCTAssertNil(detected.path)
        XCTAssertTrue(detected.schemes.isEmpty)
    }

    // MARK: - GitStatusSnapshot Tests

    func testGitStatusSnapshot_clean() {
        let snapshot = XcodeBuildHelpers.GitStatusSnapshot(
            branch: "main",
            isClean: true
        )

        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertTrue(snapshot.isClean)
    }

    func testGitStatusSnapshot_dirty() {
        let snapshot = XcodeBuildHelpers.GitStatusSnapshot(
            branch: "feature/work-in-progress",
            isClean: false
        )

        XCTAssertEqual(snapshot.branch, "feature/work-in-progress")
        XCTAssertFalse(snapshot.isClean)
    }

    func testGitStatusSnapshot_detachedHead() {
        let snapshot = XcodeBuildHelpers.GitStatusSnapshot(
            branch: nil,
            isClean: true
        )

        XCTAssertNil(snapshot.branch)
        XCTAssertTrue(snapshot.isClean)
    }
}
