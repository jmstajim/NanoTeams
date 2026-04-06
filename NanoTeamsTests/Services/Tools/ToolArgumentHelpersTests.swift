import XCTest
@testable import NanoTeams

final class ToolArgumentHelpersTests: XCTestCase {

    // MARK: - requiredString

    func testRequiredString_keyPresent_returnsValue() throws {
        let args: [String: Any] = ["name": "hello"]
        XCTAssertEqual(try requiredString(args, "name"), "hello")
    }

    func testRequiredString_keyMissing_throws() {
        let args: [String: Any] = ["other": "value"]
        XCTAssertThrowsError(try requiredString(args, "name")) { error in
            XCTAssertTrue(error is ToolArgumentError)
        }
    }

    func testRequiredString_rawInputFallback_plainString() throws {
        let args: [String: Any] = ["__raw_input__": "plain text content"]
        XCTAssertEqual(try requiredString(args, "content"), "plain text content")
    }

    func testRequiredString_rawInputFallback_jsonString() throws {
        let args: [String: Any] = ["__raw_input__": "{\"path\": \"/src/file.swift\"}"]
        XCTAssertEqual(try requiredString(args, "path"), "/src/file.swift")
    }

    func testRequiredString_rawInputFallback_jsonKeyNotFound_returnsRaw() throws {
        let args: [String: Any] = ["__raw_input__": "{\"other\": \"value\"}"]
        // Key "path" not in JSON, falls back to raw string
        XCTAssertEqual(try requiredString(args, "path"), "{\"other\": \"value\"}")
    }

    // MARK: - optionalString

    func testOptionalString_keyPresent_returnsValue() {
        let args: [String: Any] = ["key": "value"]
        XCTAssertEqual(optionalString(args, "key"), "value")
    }

    func testOptionalString_keyMissing_returnsNil() {
        let args: [String: Any] = [:]
        XCTAssertNil(optionalString(args, "key"))
    }

    // MARK: - optionalInt

    func testOptionalInt_intValue() {
        let args: [String: Any] = ["count": 42]
        XCTAssertEqual(optionalInt(args, "count"), 42)
    }

    func testOptionalInt_doubleCoercion() {
        let args: [String: Any] = ["count": 42.7]
        XCTAssertEqual(optionalInt(args, "count"), 42)
    }

    func testOptionalInt_missing_returnsNil() {
        let args: [String: Any] = [:]
        XCTAssertNil(optionalInt(args, "count"))
    }

    func testOptionalInt_wrongType_returnsNil() {
        let args: [String: Any] = ["count": "not a number"]
        XCTAssertNil(optionalInt(args, "count"))
    }

    // MARK: - requiredInt

    func testRequiredInt_intValue() throws {
        let args: [String: Any] = ["line": 10]
        XCTAssertEqual(try requiredInt(args, "line"), 10)
    }

    func testRequiredInt_doubleCoercion() throws {
        let args: [String: Any] = ["line": 10.5]
        XCTAssertEqual(try requiredInt(args, "line"), 10)
    }

    func testRequiredInt_missing_throws() {
        let args: [String: Any] = [:]
        XCTAssertThrowsError(try requiredInt(args, "line"))
    }

    // MARK: - optionalBool

    func testOptionalBool_true() {
        let args: [String: Any] = ["flag": true]
        XCTAssertTrue(optionalBool(args, "flag"))
    }

    func testOptionalBool_false() {
        let args: [String: Any] = ["flag": false]
        XCTAssertFalse(optionalBool(args, "flag"))
    }

    func testOptionalBool_missing_usesDefault() {
        let args: [String: Any] = [:]
        XCTAssertFalse(optionalBool(args, "flag"))
        XCTAssertTrue(optionalBool(args, "flag", default: true))
    }

    // MARK: - optionalStringArray

    func testOptionalStringArray_present() {
        let args: [String: Any] = ["paths": ["a.swift", "b.swift"]]
        XCTAssertEqual(optionalStringArray(args, "paths"), ["a.swift", "b.swift"])
    }

    func testOptionalStringArray_missing_returnsNil() {
        let args: [String: Any] = [:]
        XCTAssertNil(optionalStringArray(args, "paths"))
    }

    // MARK: - requiredStringArray

    func testRequiredStringArray_present() throws {
        let args: [String: Any] = ["paths": ["x", "y"]]
        XCTAssertEqual(try requiredStringArray(args, "paths"), ["x", "y"])
    }

    func testRequiredStringArray_missing_throws() {
        let args: [String: Any] = [:]
        XCTAssertThrowsError(try requiredStringArray(args, "paths"))
    }

    // MARK: - resolveContentString

    func testResolveContentString_exactContentKey() {
        let args: [String: Any] = ["content": "hello world"]
        XCTAssertEqual(resolveContentString(args), "hello world")
    }

    func testResolveContentString_alternativeText() {
        let args: [String: Any] = ["text": "hello text"]
        XCTAssertEqual(resolveContentString(args), "hello text")
    }

    func testResolveContentString_alternativeBody() {
        let args: [String: Any] = ["body": "hello body"]
        XCTAssertEqual(resolveContentString(args), "hello body")
    }

    func testResolveContentString_alternativeFileContent() {
        let args: [String: Any] = ["file_content": "file data"]
        XCTAssertEqual(resolveContentString(args), "file data")
    }

    func testResolveContentString_singleRemainingStringFallback() {
        let args: [String: Any] = ["my_custom_key": "fallback value"]
        XCTAssertEqual(resolveContentString(args), "fallback value")
    }

    func testResolveContentString_multipleRemainingStrings_returnsNil() {
        let args: [String: Any] = ["key1": "val1", "key2": "val2"]
        XCTAssertNil(resolveContentString(args))
    }

    func testResolveContentString_nonContentKeysExcluded() {
        // "path" is in nonContentKeys, should not be treated as content
        let args: [String: Any] = ["path": "/src/file.swift"]
        XCTAssertNil(resolveContentString(args))
    }

    func testResolveContentString_excludeKeysRespected() {
        let args: [String: Any] = ["custom": "value"]
        XCTAssertNil(resolveContentString(args, excludeKeys: ["custom"]))
    }

    func testResolveContentString_contentKeyTakesPrecedence() {
        let args: [String: Any] = ["content": "primary", "text": "secondary"]
        XCTAssertEqual(resolveContentString(args), "primary")
    }

    func testResolveContentString_emptyArgs_returnsNil() {
        XCTAssertNil(resolveContentString([:]))
    }
}
