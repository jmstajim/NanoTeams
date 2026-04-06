import XCTest

@testable import NanoTeams

final class ToolsEnvelopeTests: XCTestCase {

    // MARK: - ToolErrorCode Tests

    func testToolErrorCodeCodableRoundTrip() throws {
        let codes: [ToolErrorCode] = [
            .invalidArgs, .fileNotFound, .notAFile, .notADirectory,
            .permissionDenied, .rangeOutOfBounds, .anchorNotFound,
            .patchApplyFailed, .conflict, .commandFailed
        ]

        for code in codes {
            let encoded = try JSONEncoder().encode(code)
            let decoded = try JSONDecoder().decode(ToolErrorCode.self, from: encoded)
            XCTAssertEqual(decoded, code)
        }
    }

    func testToolErrorCodeRawValues() {
        XCTAssertEqual(ToolErrorCode.invalidArgs.rawValue, "INVALID_ARGS")
        XCTAssertEqual(ToolErrorCode.fileNotFound.rawValue, "FILE_NOT_FOUND")
        XCTAssertEqual(ToolErrorCode.notAFile.rawValue, "NOT_A_FILE")
        XCTAssertEqual(ToolErrorCode.notADirectory.rawValue, "NOT_A_DIRECTORY")
        XCTAssertEqual(ToolErrorCode.permissionDenied.rawValue, "PERMISSION_DENIED")
        XCTAssertEqual(ToolErrorCode.rangeOutOfBounds.rawValue, "RANGE_OUT_OF_BOUNDS")
        XCTAssertEqual(ToolErrorCode.anchorNotFound.rawValue, "ANCHOR_NOT_FOUND")
        XCTAssertEqual(ToolErrorCode.patchApplyFailed.rawValue, "PATCH_APPLY_FAILED")
        XCTAssertEqual(ToolErrorCode.conflict.rawValue, "CONFLICT")
        XCTAssertEqual(ToolErrorCode.commandFailed.rawValue, "COMMAND_FAILED")
    }

    // MARK: - ToolError Tests

    func testToolErrorCodableRoundTrip() throws {
        let error = ToolError(
            code: "FILE_NOT_FOUND",
            message: "The file does not exist",
            details: ["path": "/missing/file.txt"]
        )

        let encoded = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(ToolError.self, from: encoded)

        XCTAssertEqual(decoded.code, error.code)
        XCTAssertEqual(decoded.message, error.message)
        XCTAssertEqual(decoded.details?["path"], "/missing/file.txt")
    }

    func testToolErrorWithoutDetails() throws {
        let error = ToolError(code: "INVALID_ARGS", message: "Missing required field", details: nil)

        let encoded = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(ToolError.self, from: encoded)

        XCTAssertEqual(decoded.code, "INVALID_ARGS")
        XCTAssertEqual(decoded.message, "Missing required field")
        XCTAssertNil(decoded.details)
    }

    // MARK: - NextHint Tests

    func testNextHintCodableRoundTrip() throws {
        let hint = NextHint(
            suggested_cmd: "read_file",
            suggested_args: ["path": "config.json"],
            reason: "Check the configuration file"
        )

        let encoded = try JSONEncoder().encode(hint)
        let decoded = try JSONDecoder().decode(NextHint.self, from: encoded)

        XCTAssertEqual(decoded.suggested_cmd, "read_file")
        XCTAssertEqual(decoded.suggested_args?["path"], "config.json")
        XCTAssertEqual(decoded.reason, "Check the configuration file")
    }

    func testNextHintWithNilFields() throws {
        let hint = NextHint(suggested_cmd: nil, suggested_args: nil, reason: nil)

        let encoded = try JSONEncoder().encode(hint)
        let decoded = try JSONDecoder().decode(NextHint.self, from: encoded)

        XCTAssertNil(decoded.suggested_cmd)
        XCTAssertNil(decoded.suggested_args)
        XCTAssertNil(decoded.reason)
    }

    // MARK: - Telemetry Tests

    func testTelemetryDefaultInit() {
        let telemetry = Telemetry()

        XCTAssertFalse(telemetry.truncated)
        XCTAssertTrue(telemetry.warnings.isEmpty)
    }

    func testTelemetryCustomInit() {
        let telemetry = Telemetry(truncated: true, warnings: ["Output was truncated", "Large file detected"])

        XCTAssertTrue(telemetry.truncated)
        XCTAssertEqual(telemetry.warnings.count, 2)
        XCTAssertEqual(telemetry.warnings[0], "Output was truncated")
    }

    func testTelemetryCodableRoundTrip() throws {
        let telemetry = Telemetry(truncated: true, warnings: ["Warning 1", "Warning 2"])

        let encoded = try JSONEncoder().encode(telemetry)
        let decoded = try JSONDecoder().decode(Telemetry.self, from: encoded)

        XCTAssertEqual(decoded.truncated, telemetry.truncated)
        XCTAssertEqual(decoded.warnings, telemetry.warnings)
    }

    // MARK: - Entry Tests

    func testEntryCodableRoundTrip() throws {
        let entry = Entry(path: "/project/src", name: "src", type: "dir")

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(Entry.self, from: encoded)

        XCTAssertEqual(decoded.path, "/project/src")
        XCTAssertEqual(decoded.name, "src")
        XCTAssertEqual(decoded.type, "dir")
    }

    func testEntryFileType() throws {
        let entry = Entry(path: "/project/main.swift", name: "main.swift", type: "file")

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(Entry.self, from: encoded)

        XCTAssertEqual(decoded.type, "file")
    }

    // MARK: - LineRef Tests

    func testLineRefCodableRoundTrip() throws {
        let lineRef = LineRef(line: 42, text: "let x = 10")

        let encoded = try JSONEncoder().encode(lineRef)
        let decoded = try JSONDecoder().decode(LineRef.self, from: encoded)

        XCTAssertEqual(decoded.line, 42)
        XCTAssertEqual(decoded.text, "let x = 10")
    }

    // MARK: - SearchMatch Tests

    func testSearchMatchCodableRoundTrip() throws {
        let match = SearchMatch(
            path: "/project/main.swift",
            line: 10,
            text: "func main() {",
            context_before: [LineRef(line: 9, text: "import Foundation")],
            context_after: [LineRef(line: 11, text: "    print(\"Hello\")")]
        )

        let encoded = try JSONEncoder().encode(match)
        let decoded = try JSONDecoder().decode(SearchMatch.self, from: encoded)

        XCTAssertEqual(decoded.path, "/project/main.swift")
        XCTAssertEqual(decoded.line, 10)
        XCTAssertEqual(decoded.text, "func main() {")
        XCTAssertEqual(decoded.context_before?.count, 1)
        XCTAssertEqual(decoded.context_after?.count, 1)
    }

    func testSearchMatchWithoutContext() throws {
        let match = SearchMatch(
            path: "/project/file.swift",
            line: 5,
            text: "// TODO: implement",
            context_before: nil,
            context_after: nil
        )

        let encoded = try JSONEncoder().encode(match)
        let decoded = try JSONDecoder().decode(SearchMatch.self, from: encoded)

        XCTAssertNil(decoded.context_before)
        XCTAssertNil(decoded.context_after)
    }

    // MARK: - GitPathStatus Tests

    func testGitPathStatusCodableRoundTrip() throws {
        let status = GitPathStatus(path: "README.md", status: "M")

        let encoded = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(GitPathStatus.self, from: encoded)

        XCTAssertEqual(decoded.path, "README.md")
        XCTAssertEqual(decoded.status, "M")
    }

    // MARK: - Commit Tests

    func testCommitCodableRoundTrip() throws {
        let commit = Commit(
            hash: "abc123def456",
            message: "Initial commit",
            author: "Developer",
            date: "2024-01-15"
        )

        let encoded = try JSONEncoder().encode(commit)
        let decoded = try JSONDecoder().decode(Commit.self, from: encoded)

        XCTAssertEqual(decoded.hash, "abc123def456")
        XCTAssertEqual(decoded.message, "Initial commit")
        XCTAssertEqual(decoded.author, "Developer")
        XCTAssertEqual(decoded.date, "2024-01-15")
    }

    func testCommitWithOptionalFieldsNil() throws {
        let commit = Commit(hash: "abc123", message: "Fix bug", author: nil, date: nil)

        let encoded = try JSONEncoder().encode(commit)
        let decoded = try JSONDecoder().decode(Commit.self, from: encoded)

        XCTAssertEqual(decoded.hash, "abc123")
        XCTAssertEqual(decoded.message, "Fix bug")
        XCTAssertNil(decoded.author)
        XCTAssertNil(decoded.date)
    }

    // MARK: - BranchInfo Tests

    func testBranchInfoCodableRoundTrip() throws {
        let branch = BranchInfo(
            name: "main",
            current: true,
            upstream: "origin/main",
            is_remote: false
        )

        let encoded = try JSONEncoder().encode(branch)
        let decoded = try JSONDecoder().decode(BranchInfo.self, from: encoded)

        XCTAssertEqual(decoded.name, "main")
        XCTAssertTrue(decoded.current)
        XCTAssertEqual(decoded.upstream, "origin/main")
        XCTAssertEqual(decoded.is_remote, false)
    }

    func testBranchInfoWithOptionalFieldsNil() throws {
        let branch = BranchInfo(name: "feature", current: false, upstream: nil, is_remote: nil)

        let encoded = try JSONEncoder().encode(branch)
        let decoded = try JSONDecoder().decode(BranchInfo.self, from: encoded)

        XCTAssertEqual(decoded.name, "feature")
        XCTAssertFalse(decoded.current)
        XCTAssertNil(decoded.upstream)
        XCTAssertNil(decoded.is_remote)
    }

    // MARK: - XcodeIssue Tests

    func testXcodeIssueCodableRoundTrip() throws {
        let issue = XcodeIssue(
            file: "/project/main.swift",
            line: 25,
            column: 10,
            message: "Use of unresolved identifier 'foo'",
            raw: "error: use of unresolved identifier 'foo'"
        )

        let encoded = try JSONEncoder().encode(issue)
        let decoded = try JSONDecoder().decode(XcodeIssue.self, from: encoded)

        XCTAssertEqual(decoded.file, "/project/main.swift")
        XCTAssertEqual(decoded.line, 25)
        XCTAssertEqual(decoded.column, 10)
        XCTAssertEqual(decoded.message, "Use of unresolved identifier 'foo'")
        XCTAssertEqual(decoded.raw, "error: use of unresolved identifier 'foo'")
    }

    func testXcodeIssueWithOptionalFieldsNil() throws {
        let issue = XcodeIssue(
            file: nil,
            line: nil,
            column: nil,
            message: "Build failed",
            raw: nil
        )

        let encoded = try JSONEncoder().encode(issue)
        let decoded = try JSONDecoder().decode(XcodeIssue.self, from: encoded)

        XCTAssertNil(decoded.file)
        XCTAssertNil(decoded.line)
        XCTAssertNil(decoded.column)
        XCTAssertEqual(decoded.message, "Build failed")
        XCTAssertNil(decoded.raw)
    }

    // MARK: - XcodeProjectRef Tests

    func testXcodeProjectRefCodableRoundTrip() throws {
        let ref = XcodeProjectRef(kind: "workspace", path: "/project/App.xcworkspace")

        let encoded = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(XcodeProjectRef.self, from: encoded)

        XCTAssertEqual(decoded.kind, "workspace")
        XCTAssertEqual(decoded.path, "/project/App.xcworkspace")
    }

    func testXcodeProjectRefProject() throws {
        let ref = XcodeProjectRef(kind: "project", path: "/project/App.xcodeproj")

        let encoded = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(XcodeProjectRef.self, from: encoded)

        XCTAssertEqual(decoded.kind, "project")
    }

    // MARK: - AskSupervisorData Tests

    func testAskSupervisorDataCodableRoundTrip() throws {
        let data = AskSupervisorData(
            question: "Should we proceed with this approach?",
            status: "pending"
        )

        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(AskSupervisorData.self, from: encoded)

        XCTAssertEqual(decoded.question, "Should we proceed with this approach?")
        XCTAssertEqual(decoded.status, "pending")
    }

    // MARK: - ToolArgumentError Tests

    func testToolArgumentErrorDescription() {
        let error = ToolArgumentError.missingRequired("path")

        XCTAssertEqual(error.errorDescription, "Missing required argument: path")
    }

    func testToolArgumentErrorIsLocalizedError() {
        let error: LocalizedError = ToolArgumentError.missingRequired("content")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("content"))
    }

    // MARK: - makeSuccessEnvelope Tests

    func testMakeSuccessEnvelopeBasic() {
        let json = makeSuccessEnvelope(data: ["result": "success"])

        XCTAssertTrue(json.contains("\"ok\":true"))
        XCTAssertTrue(json.contains("\"result\""))
        XCTAssertTrue(json.contains("\"success\""))
    }

    func testMakeSuccessEnvelopeWithNextHint() {
        let hint = NextHint(suggested_cmd: "write_file", suggested_args: nil, reason: "Save the result")
        let json = makeSuccessEnvelope(data: ["done": true], next: hint)

        XCTAssertTrue(json.contains("\"ok\":true"))
        XCTAssertTrue(json.contains("\"suggested_cmd\""))
        XCTAssertTrue(json.contains("write_file"))
    }

    func testMakeSuccessEnvelopeWithTelemetry() {
        let telemetry = Telemetry(truncated: true, warnings: ["Output truncated"])
        let json = makeSuccessEnvelope(data: ["items": [1, 2, 3]], telemetry: telemetry)

        XCTAssertTrue(json.contains("\"truncated\":true"))
        XCTAssertTrue(json.contains("Output truncated"))
    }

    func testMakeSuccessEnvelopeContainsTelemetry() {
        let json = makeSuccessEnvelope(data: "test")

        XCTAssertTrue(json.contains("telemetry"))
    }

    // MARK: - makeErrorEnvelope Tests

    func testMakeErrorEnvelopeBasic() {
        let json = makeErrorEnvelope(code: .fileNotFound, message: "File not found: test.txt")

        XCTAssertTrue(json.contains("\"ok\":false"))
        XCTAssertTrue(json.contains("FILE_NOT_FOUND"))
        XCTAssertTrue(json.contains("File not found: test.txt"))
    }

    func testMakeErrorEnvelopeWithDetails() {
        let json = makeErrorEnvelope(
            code: .invalidArgs,
            message: "Invalid argument",
            details: ["argument": "path", "expected": "string"]
        )

        XCTAssertTrue(json.contains("\"ok\":false"))
        XCTAssertTrue(json.contains("INVALID_ARGS"))
        XCTAssertTrue(json.contains("\"argument\""))
        XCTAssertTrue(json.contains("\"path\""))
    }

    func testMakeErrorEnvelopeWithNextHint() {
        let hint = NextHint(suggested_cmd: "list_files", suggested_args: nil, reason: "Check available files")
        let json = makeErrorEnvelope(code: .fileNotFound, message: "Missing file", next: hint)

        XCTAssertTrue(json.contains("list_files"))
        XCTAssertTrue(json.contains("Check available files"))
    }

    func testMakeErrorEnvelopeAllErrorCodes() {
        let codes: [ToolErrorCode] = [
            .invalidArgs, .fileNotFound, .notAFile, .notADirectory,
            .permissionDenied, .rangeOutOfBounds, .anchorNotFound,
            .patchApplyFailed, .conflict, .commandFailed
        ]

        for code in codes {
            let json = makeErrorEnvelope(code: code, message: "Test error")
            XCTAssertTrue(json.contains(code.rawValue), "Expected \(code.rawValue) in JSON")
            XCTAssertTrue(json.contains("\"ok\":false"))
        }
    }

    // MARK: - makeSuccessResult Tests

    func testMakeSuccessResultStructure() {
        let result = makeSuccessResult(
            toolName: "read_file",
            args: ["path": "/test.txt"],
            data: ["content": "Hello, World!"]
        )

        XCTAssertEqual(result.toolName, "read_file")
        XCTAssertFalse(result.isError)
        XCTAssertNil(result.signal)
        XCTAssertTrue(result.outputJSON.contains("\"ok\":true"))
        XCTAssertTrue(result.argumentsJSON.contains("path"))
    }

    func testMakeSuccessResultWithAllParameters() {
        let hint = NextHint(suggested_cmd: "parse_file", suggested_args: nil, reason: "Process content")
        let telemetry = Telemetry(truncated: false, warnings: [])

        let result = makeSuccessResult(
            toolName: "download",
            args: ["url": "https://example.com"],
            data: ["downloaded": true],
            next: hint,
            telemetry: telemetry
        )

        XCTAssertEqual(result.toolName, "download")
        XCTAssertTrue(result.outputJSON.contains("parse_file"))
    }

    // MARK: - makeErrorResult Tests

    func testMakeErrorResultStructure() {
        let result = makeErrorResult(
            toolName: "write_file",
            args: ["path": "/readonly.txt"],
            code: .permissionDenied,
            message: "Cannot write to read-only file"
        )

        XCTAssertEqual(result.toolName, "write_file")
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.signal)
        XCTAssertTrue(result.outputJSON.contains("\"ok\":false"))
        XCTAssertTrue(result.outputJSON.contains("PERMISSION_DENIED"))
    }

    func testMakeErrorResultWithDetails() {
        let result = makeErrorResult(
            toolName: "edit_file",
            args: ["path": "missing.swift"],
            code: .patchApplyFailed,
            message: "Edit failed",
            details: ["line": "5", "expected": "foo", "actual": "bar"]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("\"line\""))
        XCTAssertTrue(result.outputJSON.contains("\"expected\""))
    }

    // MARK: - makeSupervisorQuestionResult Tests

    func testMakeSupervisorQuestionResult() {
        let result = makeSupervisorQuestionResult(
            toolName: "ask_supervisor",
            args: ["question": "Approve deployment?"],
            question: "Approve deployment?"
        )

        XCTAssertEqual(result.toolName, "ask_supervisor")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.signal, .supervisorQuestion("Approve deployment?"))
        XCTAssertTrue(result.outputJSON.contains("\"ok\":true"))
        XCTAssertTrue(result.outputJSON.contains("pending"))
    }

    // MARK: - resolveContentString Tests

    func testResolveContentString_exactMatch() {
        let args: [String: Any] = ["content": "hello", "path": "test.txt"]
        XCTAssertEqual(resolveContentString(args), "hello")
    }

    func testResolveContentString_textFallback() {
        let args: [String: Any] = ["text": "hello world", "path": "test.txt"]
        XCTAssertEqual(resolveContentString(args), "hello world")
    }

    func testResolveContentString_bodyFallback() {
        let args: [String: Any] = ["body": "some body"]
        XCTAssertEqual(resolveContentString(args), "some body")
    }

    func testResolveContentString_planFallback() {
        let args: [String: Any] = ["plan": "Step 1: Do something"]
        XCTAssertEqual(resolveContentString(args), "Step 1: Do something")
    }

    func testResolveContentString_singleUnknownStringFallback() {
        let args: [String: Any] = ["weird_name": "the content", "path": "test.txt"]
        XCTAssertEqual(resolveContentString(args), "the content")
    }

    func testResolveContentString_multipleUnknownStringsReturnsNil() {
        let args: [String: Any] = ["name1": "value1", "name2": "value2"]
        XCTAssertNil(resolveContentString(args))
    }

    func testResolveContentString_emptyArgsReturnsNil() {
        let args: [String: Any] = [:]
        XCTAssertNil(resolveContentString(args))
    }

    func testResolveContentString_onlyNonContentKeysReturnsNil() {
        let args: [String: Any] = ["path": "test.txt", "create_dirs": true]
        XCTAssertNil(resolveContentString(args))
    }

    func testResolveContentString_contentTakesPriority() {
        let args: [String: Any] = ["content": "primary", "text": "secondary"]
        XCTAssertEqual(resolveContentString(args), "primary")
    }

    func testResolveContentString_emptyContentIsValid() {
        let args: [String: Any] = ["content": ""]
        XCTAssertEqual(resolveContentString(args), "")
    }

    func testResolveContentString_excludeKeysRespected() {
        let args: [String: Any] = ["custom_key": "value"]
        XCTAssertNil(resolveContentString(args, excludeKeys: ["custom_key"]))
    }

    // MARK: - encodeArgsToJSON Tests

    func testEncodeArgsToJSONBasic() {
        let args: [String: Any] = ["path": "/test.txt", "content": "Hello"]
        let json = encodeArgsToJSON(args)

        XCTAssertTrue(json.contains("path"))
        XCTAssertTrue(json.contains("/test.txt"))
        XCTAssertTrue(json.contains("content"))
        XCTAssertTrue(json.contains("Hello"))
    }

    func testEncodeArgsToJSONWithNumber() {
        let args: [String: Any] = ["count": 42, "enabled": true]
        let json = encodeArgsToJSON(args)

        XCTAssertTrue(json.contains("42"))
        XCTAssertTrue(json.contains("true"))
    }

    func testEncodeArgsToJSONEmptyArgs() {
        let args: [String: Any] = [:]
        let json = encodeArgsToJSON(args)

        XCTAssertEqual(json, "{}")
    }

    func testEncodeArgsToJSONSortedKeys() {
        let args: [String: Any] = ["z": 1, "a": 2, "m": 3]
        let json = encodeArgsToJSON(args)

        // Keys should be sorted
        let aIndex = json.range(of: "\"a\"")!.lowerBound
        let mIndex = json.range(of: "\"m\"")!.lowerBound
        let zIndex = json.range(of: "\"z\"")!.lowerBound

        XCTAssertLessThan(aIndex, mIndex)
        XCTAssertLessThan(mIndex, zIndex)
    }

    // MARK: - Argument Extraction Helper Tests

    func testRequiredStringSuccess() throws {
        let args: [String: Any] = ["path": "/test.txt"]
        let value = try requiredString(args, "path")
        XCTAssertEqual(value, "/test.txt")
    }

    func testRequiredStringMissing() {
        let args: [String: Any] = [:]

        XCTAssertThrowsError(try requiredString(args, "path")) { error in
            XCTAssertTrue(error is ToolArgumentError)
            if case ToolArgumentError.missingRequired(let key) = error {
                XCTAssertEqual(key, "path")
            }
        }
    }

    func testRequiredStringWrongType() {
        let args: [String: Any] = ["path": 123]

        XCTAssertThrowsError(try requiredString(args, "path"))
    }

    func testOptionalStringPresent() {
        let args: [String: Any] = ["name": "test"]
        let value = optionalString(args, "name")
        XCTAssertEqual(value, "test")
    }

    func testOptionalStringMissing() {
        let args: [String: Any] = [:]
        let value = optionalString(args, "name")
        XCTAssertNil(value)
    }

    func testOptionalStringWrongType() {
        let args: [String: Any] = ["name": 42]
        let value = optionalString(args, "name")
        XCTAssertNil(value)
    }

    func testOptionalIntFromInt() {
        let args: [String: Any] = ["count": 42]
        let value = optionalInt(args, "count")
        XCTAssertEqual(value, 42)
    }

    func testOptionalIntFromDouble() {
        let args: [String: Any] = ["count": 42.0]
        let value = optionalInt(args, "count")
        XCTAssertEqual(value, 42)
    }

    func testOptionalIntMissing() {
        let args: [String: Any] = [:]
        let value = optionalInt(args, "count")
        XCTAssertNil(value)
    }

    func testRequiredIntFromInt() throws {
        let args: [String: Any] = ["line": 10]
        let value = try requiredInt(args, "line")
        XCTAssertEqual(value, 10)
    }

    func testRequiredIntFromDouble() throws {
        let args: [String: Any] = ["line": 10.5]
        let value = try requiredInt(args, "line")
        XCTAssertEqual(value, 10)
    }

    func testRequiredIntMissing() {
        let args: [String: Any] = [:]

        XCTAssertThrowsError(try requiredInt(args, "line")) { error in
            XCTAssertTrue(error is ToolArgumentError)
        }
    }

    func testOptionalBoolTrue() {
        let args: [String: Any] = ["enabled": true]
        let value = optionalBool(args, "enabled")
        XCTAssertTrue(value)
    }

    func testOptionalBoolFalse() {
        let args: [String: Any] = ["enabled": false]
        let value = optionalBool(args, "enabled")
        XCTAssertFalse(value)
    }

    func testOptionalBoolMissingUsesDefault() {
        let args: [String: Any] = [:]
        let value = optionalBool(args, "enabled", default: true)
        XCTAssertTrue(value)
    }

    func testOptionalBoolMissingDefaultFalse() {
        let args: [String: Any] = [:]
        let value = optionalBool(args, "enabled")
        XCTAssertFalse(value)
    }

    func testOptionalStringArrayPresent() {
        let args: [String: Any] = ["files": ["a.txt", "b.txt"]]
        let value = optionalStringArray(args, "files")
        XCTAssertEqual(value, ["a.txt", "b.txt"])
    }

    func testOptionalStringArrayMissing() {
        let args: [String: Any] = [:]
        let value = optionalStringArray(args, "files")
        XCTAssertNil(value)
    }

    func testRequiredStringArraySuccess() throws {
        let args: [String: Any] = ["paths": ["/a", "/b", "/c"]]
        let value = try requiredStringArray(args, "paths")
        XCTAssertEqual(value, ["/a", "/b", "/c"])
    }

    func testRequiredStringArrayMissing() {
        let args: [String: Any] = [:]

        XCTAssertThrowsError(try requiredStringArray(args, "paths")) { error in
            XCTAssertTrue(error is ToolArgumentError)
        }
    }

    func testRequiredStringArrayWrongType() {
        let args: [String: Any] = ["paths": "not an array"]

        XCTAssertThrowsError(try requiredStringArray(args, "paths"))
    }

    // MARK: - Edge Cases

    func testEmptyStringInArgs() throws {
        let args: [String: Any] = ["path": ""]
        let value = try requiredString(args, "path")
        XCTAssertEqual(value, "")
    }

    func testUnicodeInArgs() throws {
        let args: [String: Any] = ["message": "Hello 👋 World 🌍"]
        let value = try requiredString(args, "message")
        XCTAssertEqual(value, "Hello 👋 World 🌍")
    }

    func testSpecialCharactersInJSON() {
        let args: [String: Any] = ["content": "Line1\nLine2\tTabbed"]
        let json = encodeArgsToJSON(args)

        XCTAssertTrue(json.contains("\\n") || json.contains("Line1"))
    }

    func testLargeNumberInArgs() throws {
        let args: [String: Any] = ["bigNumber": Int.max]
        let value = try requiredInt(args, "bigNumber")
        XCTAssertEqual(value, Int.max)
    }

    // MARK: - __raw_input__ JSON Extraction

    func testRequiredStringExtractsFromRawInputJSON() throws {
        let args: [String: Any] = ["__raw_input__": "{\"question\":\"What color?\"}"]
        let value = try requiredString(args, "question")
        XCTAssertEqual(value, "What color?")
    }

    func testRequiredStringRawInputFallsBackToRawWhenKeyMissing() throws {
        let args: [String: Any] = ["__raw_input__": "{\"other\":\"value\"}"]
        let value = try requiredString(args, "other")
        XCTAssertEqual(value, "value")
    }

    func testRequiredStringRawInputFallsBackForNonJSON() throws {
        let args: [String: Any] = ["__raw_input__": "plain text question"]
        let value = try requiredString(args, "question")
        XCTAssertEqual(value, "plain text question")
    }

    func testRequiredStringRawInputExtractsNestedJSON() throws {
        let args: [String: Any] = ["__raw_input__": "{\"question\":\"Hello world\",\"extra\":123}"]
        let value = try requiredString(args, "question")
        XCTAssertEqual(value, "Hello world")
    }
}
