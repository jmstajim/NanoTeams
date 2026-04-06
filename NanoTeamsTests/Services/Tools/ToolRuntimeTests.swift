import XCTest
@testable import NanoTeams

@MainActor
final class ToolRuntimeTests: XCTestCase {
    private let fileManager = FileManager.default
    private var workFolderRoot: URL!
    private var runtime: ToolRuntime!
    private var logURL: URL!
    private var context: ToolExecutionContext!

    private func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func decodeJSONObject(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func makeTempProjectRoot() throws -> URL {
        let fileManager = FileManager.default
        let caches = try? fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let base = caches ?? fileManager.temporaryDirectory
        let testRoot = base.appendingPathComponent("NanoTeamsTests", isDirectory: true)
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        let tempDir = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func makeRegistryAndRuntime(workFolderRoot: URL) -> (ToolRuntime, URL) {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let logURL = paths.toolCallsJSONL(taskID: 0, runID: 0)
        let (_, runtime) = ToolRegistry.defaultRegistry(workFolderRoot: workFolderRoot, toolCallsLogURL: logURL)
        return (runtime, logURL)
    }

    private func makeContext(workFolderRoot: URL) -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: workFolderRoot, taskID: Int(), runID: 0, roleID: "test_role")
    }

    private func executeTool(runtime: ToolRuntime, context: ToolExecutionContext, name: String, args: [String: Any]) -> ToolExecutionResult {
        let call = StepToolCall(name: name, argumentsJSON: jsonString(args))
        return runtime.executeAll(context: context, toolCalls: [call]).first!
    }

    private func runGit(_ args: [String], in directory: URL) throws -> (Int, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (Int(process.terminationStatus), stdout, stderr)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        workFolderRoot = try makeTempProjectRoot()
        let (runtime, logURL) = makeRegistryAndRuntime(workFolderRoot: workFolderRoot)
        self.runtime = runtime
        self.logURL = logURL
        context = makeContext(workFolderRoot: workFolderRoot)
    }

    override func tearDownWithError() throws {
        if let workFolderRoot {
            try? fileManager.removeItem(at: workFolderRoot)
        }
        try super.tearDownWithError()
    }

    func testToolExecutionIsLogged() throws {
        let fileURL = workFolderRoot.appendingPathComponent("hello.txt", isDirectory: false)
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let args: [String: Any] = ["path": "."]
        let argsJSON = jsonString(args)
        let call = StepToolCall(name: "list_files", argumentsJSON: argsJSON)
        let result = runtime.executeAll(context: context, toolCalls: [call]).first!

        let logText = try String(contentsOf: logURL, encoding: .utf8)
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)

        let record = decodeJSONObject(String(lines[0]))
        XCTAssertEqual(record["toolName"] as? String, "list_files")
        XCTAssertEqual(record["argumentsJSON"] as? String, argsJSON)
        XCTAssertEqual(record["taskID"] as? Int, context.taskID)
        XCTAssertEqual(record["runID"] as? Int, context.runID)
        XCTAssertEqual(record["roleID"] as? String, context.roleID)
        XCTAssertEqual(record["resultJSON"] as? String, result.outputJSON)
        let errorValue = record["errorMessage"]
        XCTAssertTrue(errorValue == nil || errorValue is NSNull)
    }

    func testGitAddStagesFile() throws {
        _ = try runGit(["init"], in: workFolderRoot)

        let fileURL = workFolderRoot.appendingPathComponent("hello.txt", isDirectory: false)
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = executeTool(runtime: runtime, context: context, name: "git_add", args: ["paths": ["hello.txt"]])
        let payload = decodeJSONObject(result.outputJSON)
        XCTAssertEqual(payload["ok"] as? Bool, true)

        let (_, statusOut, _) = try runGit(["status", "--porcelain=v1"], in: workFolderRoot)
        XCTAssertTrue(statusOut.contains("A  hello.txt"))
    }

    // MARK: - Tool Arguments Validation Tests

    func testEmptyKeyInArgumentsIsStripped() {
        // Empty keys are silently stripped (LLMs like gpt-oss-20b emit {"":""} for no-param tools)
        let call = StepToolCall(name: "list_files", argumentsJSON: "{\"\": \"value\"}")
        let result = runtime.executeAll(context: context, toolCalls: [call]).first!

        // Should succeed — empty key stripped, treated as {}
        let payload = decodeJSONObject(result.outputJSON)
        let errorMessage = payload["error"] as? String ?? ""
        XCTAssertFalse(errorMessage.contains("empty key"))
    }

    func testWhitespaceOnlyKeyIsStripped() {
        // Whitespace-only keys are silently stripped after trimming
        let call = StepToolCall(name: "list_files", argumentsJSON: "{\"   \": \"value\"}")
        let result = runtime.executeAll(context: context, toolCalls: [call]).first!

        // Should succeed — whitespace-only key stripped, treated as {}
        let payload = decodeJSONObject(result.outputJSON)
        let errorMessage = payload["error"] as? String ?? ""
        XCTAssertFalse(errorMessage.contains("empty key"))
    }

    func testInvalidJSONRecoveredViaRawInput() {
        // Invalid JSON is recovered — raw string wrapped as __raw_input__ fallback
        let call = StepToolCall(name: "list_files", argumentsJSON: "{not valid json}")
        let result = runtime.executeAll(context: context, toolCalls: [call]).first!

        // Tool handler receives {"__raw_input__": "{not valid json}"} and proceeds
        // (ls doesn't require string args via requiredString, so it won't use __raw_input__,
        // but the point is it doesn't crash with a JSON parse error)
        XCTAssertFalse(result.outputJSON.contains("isn't in the correct format"))
    }

    func testEmptyJSONObjectIsValid() {
        // Empty JSON object {} should be valid
        let call = StepToolCall(name: "list_files", argumentsJSON: "{}")
        let result = runtime.executeAll(context: context, toolCalls: [call]).first!

        // Should not be an error (though the tool itself might fail for other reasons)
        // The validation should pass for empty object
        let payload = decodeJSONObject(result.outputJSON)
        let errorMessage = payload["error"] as? String ?? ""
        XCTAssertFalse(errorMessage.contains("empty key"))
    }

    func testValidJSONArgsWork() throws {
        // Create a file so ls has something to list
        let fileURL = workFolderRoot.appendingPathComponent("test.txt", isDirectory: false)
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(name: "list_files", argumentsJSON: "{\"path\": \".\"}")
        let result = runtime.executeAll(context: context, toolCalls: [call]).first!

        XCTAssertFalse(result.isError)
        let payload = decodeJSONObject(result.outputJSON)
        XCTAssertEqual(payload["ok"] as? Bool, true)
    }

    func testEmptyStringArgumentsIsValid() {
        // Empty string args should be treated as empty object
        let call = StepToolCall(name: "list_files", argumentsJSON: "")
        let result = runtime.executeAll(context: context, toolCalls: [call]).first!

        // Empty string should be converted to {} which is valid
        let payload = decodeJSONObject(result.outputJSON)
        let errorMessage = payload["error"] as? String ?? ""
        XCTAssertFalse(errorMessage.contains("empty key"))
    }

    func testWhitespaceOnlyArgumentsIsValid() {
        // Whitespace-only args should be treated as empty object
        let call = StepToolCall(name: "list_files", argumentsJSON: "   ")
        let result = runtime.executeAll(context: context, toolCalls: [call]).first!

        // Whitespace should be converted to {} which is valid
        let payload = decodeJSONObject(result.outputJSON)
        let errorMessage = payload["error"] as? String ?? ""
        XCTAssertFalse(errorMessage.contains("empty key"))
    }

    func testLiteralNewlinesInJSONArgsAreSanitized() throws {
        // LLMs stream markdown with literal newlines inside JSON string values.
        // ToolRuntime should sanitize these before JSON parsing so tools get correct args.
        let fileURL = workFolderRoot.appendingPathComponent("test.txt", isDirectory: false)
        try "existing content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Simulate LLM emitting JSON with literal newline inside a string value
        let argsWithLiteralNewline = "{\"path\":\"test.txt\",\"content\":\"line1\nline2\nline3\"}"
        let call = StepToolCall(name: "write_file", argumentsJSON: argsWithLiteralNewline)
        let result = runtime.executeAll(context: context, toolCalls: [call]).first!

        // Should succeed — sanitize fixes the JSON before parsing
        XCTAssertFalse(result.isError, "write_file should succeed after sanitizing literal newlines")

        // Verify the file was written with correct content (newlines preserved via round-trip)
        let written = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(written, "line1\nline2\nline3")
    }

    // MARK: - escapeJSON Control Characters (Round 5 regression)

    func testEscapeJSON_ControlCharacters_ProducesValidJSON() throws {
        let root = try makeTempProjectRoot()
        let (rt, _) = makeRegistryAndRuntime(workFolderRoot: root)
        let ctx = makeContext(workFolderRoot: root)

        // Create .nanoteams directory
        let paths = NTMSPaths(workFolderRoot: root)
        try FileManager.default.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        // Call a non-existent tool whose name contains ANSI escape and null chars
        let badName = "tool\u{1b}_test\u{0}_end\u{1f}"
        let call = StepToolCall(name: badName, argumentsJSON: "{}")
        let result = rt.executeAll(context: ctx, toolCalls: [call]).first!

        // The outputJSON must be valid JSON (parseable by JSONSerialization)
        let data = result.outputJSON.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data, options: [])
        XCTAssertNotNil(parsed, "outputJSON with control chars must be valid JSON")

        // Should indicate tool not found
        XCTAssertTrue(result.outputJSON.contains("tool_not_found") || result.outputJSON.contains("not_found"),
                       "Should contain tool_not_found error")
        XCTAssertTrue(result.isError)
    }
}
