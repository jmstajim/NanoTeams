import XCTest
@testable import NanoTeams

final class ToolCallDataUtilsTests: XCTestCase {

    // MARK: - parseJSON

    func testParseJSON_validJSON_returnsDictionary() {
        let json = """
        {"name": "test", "count": 42}
        """
        let result = ToolCallDataUtils.parseJSON(json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["name"] as? String, "test")
        XCTAssertEqual(result?["count"] as? Int, 42)
    }

    func testParseJSON_invalidJSON_returnsNil() {
        XCTAssertNil(ToolCallDataUtils.parseJSON("{broken"))
        XCTAssertNil(ToolCallDataUtils.parseJSON(""))
        XCTAssertNil(ToolCallDataUtils.parseJSON("not json"))
    }

    func testParseJSON_emptyObject_returnsDictionary() {
        let result = ToolCallDataUtils.parseJSON("{}")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.isEmpty)
    }

    func testParseJSON_arrayJSON_returnsNil() {
        // Top-level arrays are not [String: Any]
        XCTAssertNil(ToolCallDataUtils.parseJSON("[1, 2, 3]"))
    }

    // MARK: - formatJSON

    func testFormatJSON_validJSON_returnsPrettyPrinted() {
        let json = """
        {"b": 2, "a": 1}
        """
        let formatted = ToolCallDataUtils.formatJSON(json)
        // sortedKeys → "a" before "b"
        let aIndex = formatted.range(of: "\"a\"")!.lowerBound
        let bIndex = formatted.range(of: "\"b\"")!.lowerBound
        XCTAssertLessThan(aIndex, bIndex)
        XCTAssertTrue(formatted.contains("\n"))
    }

    func testFormatJSON_invalidJSON_returnsOriginal() {
        let original = "{broken json"
        XCTAssertEqual(ToolCallDataUtils.formatJSON(original), original)
    }

    // MARK: - extractPath

    func testExtractPath_withPathKey_returnsPath() {
        let json = """
        {"path": "/Users/test/file.swift"}
        """
        XCTAssertEqual(ToolCallDataUtils.extractPath(from: json), "/Users/test/file.swift")
    }

    func testExtractPath_noPathKey_returnsNil() {
        XCTAssertNil(ToolCallDataUtils.extractPath(from: """
        {"file": "/Users/test/file.swift"}
        """))
    }

    func testExtractPath_invalidJSON_returnsNil() {
        XCTAssertNil(ToolCallDataUtils.extractPath(from: "broken"))
    }

    // MARK: - classifyError

    func testClassifyError_withErrorField_returnsErrorValue() {
        let json = """
        {"error": "custom_error_code"}
        """
        XCTAssertEqual(ToolCallDataUtils.classifyError(outputJSON: json), "custom_error_code")
    }

    func testClassifyError_notFound() {
        let json = """
        {"message": "File not found at path"}
        """
        XCTAssertEqual(ToolCallDataUtils.classifyError(outputJSON: json), "not_found")
    }

    func testClassifyError_timeout() {
        let json = """
        {"message": "Request timeout exceeded"}
        """
        XCTAssertEqual(ToolCallDataUtils.classifyError(outputJSON: json), "timeout")
    }

    func testClassifyError_permissionDenied() {
        let json = """
        {"message": "Permission denied for path"}
        """
        XCTAssertEqual(ToolCallDataUtils.classifyError(outputJSON: json), "permission_denied")
    }

    func testClassifyError_executionFailed() {
        let json = """
        {"ok": false}
        """
        XCTAssertEqual(ToolCallDataUtils.classifyError(outputJSON: json), "execution_failed")
    }

    func testClassifyError_unknown() {
        let json = """
        {"something": "else"}
        """
        XCTAssertEqual(ToolCallDataUtils.classifyError(outputJSON: json), "unknown")
    }

    func testClassifyError_invalidJSON_returnsParseError() {
        XCTAssertEqual(ToolCallDataUtils.classifyError(outputJSON: "broken"), "parse_error")
    }

    func testClassifyError_errorFieldTakesPrecedence() {
        // error field should be returned even if message also matches
        let json = """
        {"error": "specific_error", "message": "File not found"}
        """
        XCTAssertEqual(ToolCallDataUtils.classifyError(outputJSON: json), "specific_error")
    }
}
