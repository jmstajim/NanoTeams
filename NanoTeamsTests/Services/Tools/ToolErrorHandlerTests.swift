import XCTest

@testable import NanoTeams

final class ToolErrorHandlerTests: XCTestCase {

    // MARK: - Success Path Tests

    func testExecuteReturnsResultOnSuccess() {
        let args: [String: Any] = ["path": "test.txt"]

        let result = ToolErrorHandler.execute(toolName: "test_tool", args: args) {
            return makeSuccessResult(
                toolName: "test_tool",
                args: args,
                data: ["success": true]
            )
        }

        XCTAssertTrue(result.outputJSON.contains("success"))
        XCTAssertTrue(result.outputJSON.contains("true"))
    }

    func testExecutePassesArgsCorrectly() {
        let args: [String: Any] = ["path": "/some/path", "content": "data"]

        let result = ToolErrorHandler.execute(toolName: "write_file", args: args) {
            return makeSuccessResult(
                toolName: "write_file",
                args: args,
                data: ["written": true]
            )
        }

        XCTAssertTrue(result.outputJSON.contains("written"))
    }

    // MARK: - ToolArgumentError Tests

    func testExecuteCatchesToolArgumentError() {
        let args: [String: Any] = [:]

        let result = ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw ToolArgumentError.missingRequired("path")
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
        XCTAssertTrue(result.outputJSON.contains("invalidArgs") || result.outputJSON.contains("INVALID_ARGS"))
    }

    func testExecuteHandlesInvalidTypeError() {
        let args: [String: Any] = ["path": 123]

        let result = ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw ToolArgumentError.missingRequired("path")
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
    }

    // MARK: - SandboxPathError Tests

    func testExecuteCatchesSandboxPathError() {
        let args: [String: Any] = ["path": "../../../etc/passwd"]

        let result = ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw SandboxPathError.outsideSandbox("../../../etc/passwd")
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
        XCTAssertTrue(result.outputJSON.contains("permissionDenied") || result.outputJSON.contains("PERMISSION_DENIED"))
    }

    func testExecuteHandlesEmptyPathError() {
        let args: [String: Any] = ["path": ""]

        let result = ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw SandboxPathError.emptyPath
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
    }

    // MARK: - Generic Error Tests

    func testExecuteCatchesGenericError() {
        let args: [String: Any] = ["path": "test.txt"]

        struct CustomError: LocalizedError {
            var errorDescription: String? { "Custom error occurred" }
        }

        let result = ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw CustomError()
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
        XCTAssertTrue(result.outputJSON.contains("Custom error occurred"))
    }

    func testExecuteHandlesNSError() {
        let args: [String: Any] = ["path": "nonexistent.txt"]

        let result = ToolErrorHandler.execute(toolName: "read_file", args: args) {
            throw NSError(
                domain: "TestDomain",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "File not found"]
            )
        }

        XCTAssertTrue(result.outputJSON.contains("error"))
    }

    // MARK: - Error Code Mapping Tests

    func testToolArgumentErrorMapsToInvalidArgsCode() {
        let args: [String: Any] = [:]

        let result = ToolErrorHandler.execute(toolName: "test", args: args) {
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

    func testSandboxPathErrorMapsToPermissionDeniedCode() {
        let args: [String: Any] = ["path": "/etc/passwd"]

        let result = ToolErrorHandler.execute(toolName: "test", args: args) {
            throw SandboxPathError.outsideSandbox("/etc/passwd")
        }

        XCTAssertTrue(result.outputJSON.contains("PERMISSION_DENIED") || result.outputJSON.contains("permissionDenied"))
    }

    // MARK: - Multiple Tool Names Tests

    func testExecuteWorksWithDifferentToolNames() {
        let toolNames = ["read_file", "write_file", "list_files", "search", "edit_file"]

        for toolName in toolNames {
            let result = ToolErrorHandler.execute(toolName: toolName, args: [:]) {
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

    func testExecuteWithEmptyArgs() {
        let result = ToolErrorHandler.execute(toolName: "test", args: [:]) {
            return makeSuccessResult(
                toolName: "test",
                args: [:],
                data: ["empty": true]
            )
        }

        XCTAssertTrue(result.outputJSON.contains("empty"))
    }

    func testExecuteWithComplexArgs() {
        let args: [String: Any] = [
            "path": "/some/file.txt",
            "content": "Hello, World!",
            "options": ["recursive": true, "force": false],
            "count": 42
        ]

        let result = ToolErrorHandler.execute(toolName: "complex_tool", args: args) {
            return makeSuccessResult(
                toolName: "complex_tool",
                args: args,
                data: ["processed": true]
            )
        }

        XCTAssertTrue(result.outputJSON.contains("processed"))
    }

    func testExecutePreservesToolNameInError() {
        let args: [String: Any] = [:]

        let result = ToolErrorHandler.execute(toolName: "my_custom_tool", args: args) {
            throw ToolArgumentError.missingRequired("important_key")
        }

        XCTAssertTrue(result.toolName.contains("my_custom_tool"))
    }
}
