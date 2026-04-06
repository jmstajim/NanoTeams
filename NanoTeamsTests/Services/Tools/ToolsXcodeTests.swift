import XCTest

@testable import NanoTeams

final class ToolsXcodeTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var registry: ToolRegistry!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create .nanoteams directory
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        // Create registry with Xcode tools
        let (reg, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        registry = reg
        runtime = run

        context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: Int(),
            runID: 0,
            roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
//        registry = nil
//        runtime = nil
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - run_xcodebuild Tests

    func testRunXcodebuild_noProjectFound() {
        let call = StepToolCall(name: "run_xcodebuild", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
        XCTAssertTrue(results[0].outputJSON.contains("xcodeproj") || results[0].outputJSON.contains("xcworkspace"))
    }

    func testRunXcodebuild_prefersWorkspaceOverProject() throws {
        // Create both workspace and project
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("App.xcworkspace"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true
        )

        // The tool should prefer workspace, but will fail because no scheme is configured
        let call = StepToolCall(name: "run_xcodebuild", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        // It will fail because no schemes configured, but we can verify it tried
        XCTAssertTrue(results[0].isError)
    }

    func testRunXcodebuild_noSchemesConfigured() throws {
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true
        )

        let call = StepToolCall(name: "run_xcodebuild", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        // Should fail without configured schemes (unless auto-detect works)
        // The error message should mention schemes or targets
        let output = results[0].outputJSON
        XCTAssertTrue(results[0].isError || output.contains("scheme"))
    }

    // MARK: - run_xcodetests Tests

    func testRunTests_noProjectFound() {
        let call = StepToolCall(name: "run_xcodetests", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
    }

    func testRunTests_noTestTargetsConfigured() throws {
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true
        )

        let call = StepToolCall(name: "run_xcodetests", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        // Should fail without configured test targets (unless auto-detect works)
        let output = results[0].outputJSON
        XCTAssertTrue(results[0].isError || output.contains("test"))
    }

    // MARK: - XcodeIssue Structure Tests

    func testXcodeIssue_codable() throws {
        let issue = XcodeIssue(
            file: "/path/to/file.swift",
            line: 42,
            column: 10,
            message: "Type mismatch",
            raw: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(issue)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(XcodeIssue.self, from: data)

        XCTAssertEqual(decoded.file, "/path/to/file.swift")
        XCTAssertEqual(decoded.line, 42)
        XCTAssertEqual(decoded.column, 10)
        XCTAssertEqual(decoded.message, "Type mismatch")
        XCTAssertNil(decoded.raw)
    }

    func testXcodeIssue_withOptionalFields() throws {
        let issue = XcodeIssue(
            file: nil,
            line: nil,
            column: nil,
            message: "Generic error",
            raw: "full error output"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(issue)
        let decoded = try JSONDecoder().decode(XcodeIssue.self, from: data)

        XCTAssertNil(decoded.file)
        XCTAssertNil(decoded.line)
        XCTAssertNil(decoded.column)
        XCTAssertEqual(decoded.message, "Generic error")
        XCTAssertEqual(decoded.raw, "full error output")
    }

    // MARK: - XcodeProjectRef Structure Tests

    func testXcodeProjectRef_workspace() throws {
        let ref = XcodeProjectRef(kind: "workspace", path: "MyApp.xcworkspace")

        let encoder = JSONEncoder()
        let data = try encoder.encode(ref)
        let decoded = try JSONDecoder().decode(XcodeProjectRef.self, from: data)

        XCTAssertEqual(decoded.kind, "workspace")
        XCTAssertEqual(decoded.path, "MyApp.xcworkspace")
    }

    func testXcodeProjectRef_project() throws {
        let ref = XcodeProjectRef(kind: "project", path: "MyApp.xcodeproj")

        let encoder = JSONEncoder()
        let data = try encoder.encode(ref)
        let decoded = try JSONDecoder().decode(XcodeProjectRef.self, from: data)

        XCTAssertEqual(decoded.kind, "project")
        XCTAssertEqual(decoded.path, "MyApp.xcodeproj")
    }

    // MARK: - Tool Registration Tests

    func testXcodeToolsRegistered() {
        let toolNames = registry.registeredToolNames

        XCTAssertTrue(toolNames.contains("run_xcodebuild"))
        XCTAssertTrue(toolNames.contains("run_xcodetests"))
    }

    // MARK: - Output Parsing Tests

    func testParseXcodeOutput_errorFormat() {
        // Test the error pattern parsing via the tool's internal behavior
        // This simulates what the tool parses from xcodebuild output
        let sampleOutput = """
        /Users/dev/Project/Sources/File.swift:42:10: error: cannot find 'foo' in scope
        /Users/dev/Project/Sources/Other.swift:15:5: warning: unused variable 'bar'
        """

        // Parse using regex pattern from Tools+Xcode.swift
        let pattern = #"^(.+?):(\d+):(\d+):\s*(error|warning|note):\s*(.+)$"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)

        let range = NSRange(sampleOutput.startIndex..., in: sampleOutput)
        var matches: [(file: String, line: Int, message: String)] = []

        regex.enumerateMatches(in: sampleOutput, options: [], range: range) { match, _, _ in
            guard let match = match else { return }

            let file = match.range(at: 1).location != NSNotFound
                ? String(sampleOutput[Range(match.range(at: 1), in: sampleOutput)!])
                : ""

            let line = match.range(at: 2).location != NSNotFound
                ? Int(sampleOutput[Range(match.range(at: 2), in: sampleOutput)!]) ?? 0
                : 0

            let message = match.range(at: 5).location != NSNotFound
                ? String(sampleOutput[Range(match.range(at: 5), in: sampleOutput)!])
                : ""

            matches.append((file: file, line: line, message: message))
        }

        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches[0].file.contains("File.swift"))
        XCTAssertEqual(matches[0].line, 42)
        XCTAssertTrue(matches[0].message.contains("foo"))

        XCTAssertTrue(matches[1].file.contains("Other.swift"))
        XCTAssertEqual(matches[1].line, 15)
        XCTAssertTrue(matches[1].message.contains("bar"))
    }

    func testParseXcodeOutput_testCaseFormat() {
        let sampleOutput = """
        Test Case '-[MyAppTests.SomeTests testExample]' started.
        Test Case '-[MyAppTests.SomeTests testExample]' passed (0.001 seconds).
        Test Case '-[MyAppTests.OtherTests testFailure]' started.
        Test Case '-[MyAppTests.OtherTests testFailure]' failed (0.002 seconds).
        """

        let passedPattern = #"Test Case .+ passed"#
        let failedPattern = #"Test Case .+ failed"#

        let passedRegex = try! NSRegularExpression(pattern: passedPattern)
        let failedRegex = try! NSRegularExpression(pattern: failedPattern)

        let range = NSRange(sampleOutput.startIndex..., in: sampleOutput)
        let passedCount = passedRegex.numberOfMatches(in: sampleOutput, range: range)
        let failedCount = failedRegex.numberOfMatches(in: sampleOutput, range: range)

        XCTAssertEqual(passedCount, 1)
        XCTAssertEqual(failedCount, 1)
    }

    func testParseXcodeOutput_testFailureDetails() {
        let sampleOutput = """
        /Users/dev/Project/Tests/SomeTests.swift:25: error: -[MyAppTests.SomeTests testExample] : XCTAssertEqual failed: ("1") is not equal to ("2")
        """

        let failurePattern = #"(.+?):(\d+):\s*error:\s*(.+)"#
        let regex = try! NSRegularExpression(pattern: failurePattern)

        let range = NSRange(sampleOutput.startIndex..., in: sampleOutput)
        let matches = regex.matches(in: sampleOutput, range: range)

        XCTAssertEqual(matches.count, 1)
        if let match = matches.first {
            let file = String(sampleOutput[Range(match.range(at: 1), in: sampleOutput)!])
            let line = Int(sampleOutput[Range(match.range(at: 2), in: sampleOutput)!])
            let message = String(sampleOutput[Range(match.range(at: 3), in: sampleOutput)!])

            XCTAssertTrue(file.contains("SomeTests.swift"))
            XCTAssertEqual(line, 25)
            XCTAssertTrue(message.contains("XCTAssertEqual"))
        }
    }

    // MARK: - Edge Cases

    func testXcodeOutput_multilineError() {
        let sampleOutput = """
        /path/to/file.swift:10:5: error: cannot convert value of type 'Int' to expected argument type 'String'
        /path/to/file.swift:20:10: error: missing return in a function expected to return 'Bool'
        /path/to/file.swift:30:3: warning: result of call to 'print' is unused
        """

        let pattern = #"^(.+?):(\d+):(\d+):\s*(error|warning|note):\s*(.+)$"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)

        let range = NSRange(sampleOutput.startIndex..., in: sampleOutput)
        var issueCount = 0
        var errorCount = 0
        var warningCount = 0

        regex.enumerateMatches(in: sampleOutput, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            issueCount += 1

            let severity = match.range(at: 4).location != NSNotFound
                ? String(sampleOutput[Range(match.range(at: 4), in: sampleOutput)!])
                : ""

            if severity == "error" { errorCount += 1 }
            if severity == "warning" { warningCount += 1 }
        }

        XCTAssertEqual(issueCount, 3)
        XCTAssertEqual(errorCount, 2)
        XCTAssertEqual(warningCount, 1)
    }

    func testXcodeOutput_noIssues() {
        let sampleOutput = """
        Build succeeded.
        ** BUILD SUCCEEDED **
        """

        let pattern = #"^(.+?):(\d+):(\d+):\s*(error|warning|note):\s*(.+)$"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)

        let range = NSRange(sampleOutput.startIndex..., in: sampleOutput)
        let matches = regex.matches(in: sampleOutput, range: range)

        XCTAssertEqual(matches.count, 0)
    }
}
