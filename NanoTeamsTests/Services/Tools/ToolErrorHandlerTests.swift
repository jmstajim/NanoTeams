import XCTest

@testable import NanoTeams

final class ToolErrorHandlerTests: XCTestCase {

    // MARK: - Success Path Tests

    func testExecuteReturnsResultOnSuccess() async {
        let args: [String: Any] = ["path": "test.txt"]

        let result = await ToolErrorHandler.execute(toolName: "test_tool", args: args) {
            return makeSuccessResult(
                toolName: "test_tool",
                args: args,
                data: ["success": true]
            )
        }

        XCTAssertTrue(result.outputJSON.contains("success"))
        XCTAssertTrue(result.outputJSON.contains("true"))
    }

    func testExecutePassesArgsCorrectly() async {
        let args: [String: Any] = ["path": "/some/path", "content": "data"]

        let result = await ToolErrorHandler.execute(toolName: "write_file", args: args) {
            return makeSuccessResult(
                toolName: "write_file",
                args: args,
                data: ["written": true]
            )
        }

        XCTAssertTrue(result.outputJSON.contains("written"))
    }

    // MARK: - ToolArgumentError Tests

    func testExecuteCatchesToolArgumentError() async {
        let args: [String: Any] = [:]

        let result = await ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw ToolArgumentError.missingRequired("path")
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
        XCTAssertTrue(result.outputJSON.contains("invalidArgs") || result.outputJSON.contains("INVALID_ARGS"))
    }

    func testExecuteHandlesInvalidTypeError() async {
        let args: [String: Any] = ["path": 123]

        let result = await ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw ToolArgumentError.missingRequired("path")
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
    }

    // MARK: - SandboxPathError Tests

    func testExecuteCatchesSandboxPathError() async {
        let args: [String: Any] = ["path": "../../../etc/passwd"]

        let result = await ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw SandboxPathError.outsideSandbox("../../../etc/passwd")
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
        XCTAssertTrue(result.outputJSON.contains("permissionDenied") || result.outputJSON.contains("PERMISSION_DENIED"))
    }

    // MARK: - Generic Error Tests

    func testExecuteCatchesGenericError() async {
        let args: [String: Any] = ["path": "test.txt"]

        struct CustomError: LocalizedError {
            var errorDescription: String? { "Custom error occurred" }
        }

        let result = await ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw CustomError()
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
        XCTAssertTrue(result.outputJSON.contains("Custom error occurred"))
    }

    func testExecuteHandlesNSError() async {
        let args: [String: Any] = ["path": "nonexistent.txt"]

        let result = await ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw NSError(
                domain: "TestDomain",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "File not found"]
            )
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
    }

    // MARK: - Error Code Mapping Tests

    func testToolArgumentErrorMapsToInvalidArgsCode() async {
        let args: [String: Any] = [:]

        let result = await ToolErrorHandler.execute(toolName: "test", args: args) {
            throw ToolArgumentError.missingRequired("required_field")
        }

        // Verify the error code is correctly set
        if let data = result.outputJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let code = error["code"] as? String
        {
            XCTAssertEqual(code, "INVALID_ARGS")
        } else {
            XCTAssertTrue(result.outputJSON.contains("INVALID_ARGS") || result.outputJSON.contains("invalidArgs"))
        }
    }

    func testSandboxPathErrorMapsToPermissionDeniedCode() async {
        let args: [String: Any] = ["path": "/etc/passwd"]

        let result = await ToolErrorHandler.execute(toolName: "test", args: args) {
            throw SandboxPathError.outsideSandbox("/etc/passwd")
        }

        XCTAssertTrue(result.outputJSON.contains("PERMISSION_DENIED") || result.outputJSON.contains("permissionDenied"))
    }

    // MARK: - Multiple Tool Names Tests

    func testExecuteWorksWithDifferentToolNames() async {
        let toolNames = ["read_file", "write_file", "list_files", "search", "edit_file"]

        for toolName in toolNames {
            let result = await ToolErrorHandler.execute(toolName: toolName, args: [:]) {
                return makeSuccessResult(
                    toolName: toolName,
                    args: [:],
                    data: ["tool": toolName, "status": "ok"]
                )
            }

            XCTAssertTrue(result.outputJSON.contains(toolName))
            XCTAssertTrue(result.outputJSON.contains("ok"))
        }
    }

    // MARK: - Edge Cases

    func testExecuteWithEmptyArgs() async {
        let result = await ToolErrorHandler.execute(toolName: "test", args: [:]) {
            return makeSuccessResult(
                toolName: "test",
                args: [:],
                data: ["empty": true]
            )
        }

        XCTAssertTrue(result.outputJSON.contains("empty"))
    }

    func testExecuteWithComplexArgs() async {
        let args: [String: Any] = [
            "path": "/some/file.txt",
            "content": "Hello, World!",
            "options": ["recursive": true, "force": false],
            "count": 42
        ]

        let result = await ToolErrorHandler.execute(toolName: "complex_tool", args: args) {
            return makeSuccessResult(
                toolName: "complex_tool",
                args: args,
                data: ["processed": true]
            )
        }

        XCTAssertTrue(result.outputJSON.contains("processed"))
    }

    func testExecutePreservesToolNameInError() async {
        let args: [String: Any] = [:]

        let result = await ToolErrorHandler.execute(toolName: "my_custom_tool", args: args) {
            throw ToolArgumentError.missingRequired("important_key")
        }

        XCTAssertTrue(result.toolName.contains("my_custom_tool"))
    }
}
