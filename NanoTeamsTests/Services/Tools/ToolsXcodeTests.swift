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

    /// Writes `settings.json` with a configured scheme, so a test can get past scheme
    /// resolution without going near auto-detection.
    private func writeSelectedScheme(_ scheme: String) throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        try #"{"selectedScheme":"\#(scheme)"}"#
            .write(to: paths.settingsJSON, atomically: true, encoding: .utf8)
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

    /// A workspace that references the project would report a SUBSET of the schemes the
    /// user actually builds, so the workspace has to win.
    ///
    /// Asserted on the argv now. This test used to claim to verify the preference while
    /// asserting only `isError` — which was true for either choice, and true for a dozen
    /// unrelated reasons. It also reached a real `xcodebuild -list` through the registry,
    /// so its outcome depended on what the installed Xcode printed for a fake `.xcodeproj`.
    ///
    /// RED: swap the two `first(where:)` clauses in `findProject` → the argv carries
    /// `-project`.
    func testRunXcodebuild_prefersWorkspaceOverProject() throws {
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("App.xcworkspace"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true
        )
        try writeSelectedScheme("App")
        let runner = RecordingXcodebuildRunner(responses: [.ok("** BUILD SUCCEEDED **")])

        _ = RunXcodebuildTool(workFolderRoot: tempDir, runner: runner)
            .handle(context: context, args: [:])

        let argv = try XCTUnwrap(runner.calls.first?.arguments)
        XCTAssertEqual(Array(argv.prefix(2)), ["-workspace", "App.xcworkspace"])
        XCTAssertFalse(argv.contains("-project"))
    }

    /// No scheme configured AND none detectable is an ERROR with actionable text, not a
    /// build that silently does nothing.
    ///
    /// The assertion used to be `isError || output.contains("scheme")` — a disjunction that
    /// holds in both worlds, so it could not distinguish "reported the problem" from
    /// "auto-detected something and built it". Which one happened depended on a real
    /// subprocess.
    func testRunXcodebuild_noSchemesConfigured() throws {
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true
        )
        let runner = RecordingXcodebuildRunner(responses: [.failed(66)])

        let result = RunXcodebuildTool(workFolderRoot: tempDir, runner: runner)
            .handle(context: context, args: [:])

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(
            result.outputJSON.contains("No scheme configured in project settings."),
            result.outputJSON)
        XCTAssertEqual(runner.callCount, 1, "only the -list probe; nothing was built")
        XCTAssertTrue(try XCTUnwrap(runner.calls.first?.arguments).contains("-list"))
    }

    // MARK: - run_xcodetests Tests

    func testRunTests_noProjectFound() {
        let call = StepToolCall(name: "run_xcodetests", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
    }

    /// Same as the build side, with the tool-specific phrasing that tells the user which
    /// action they were trying to run. Also previously a pass-either-way disjunction over a
    /// real subprocess.
    func testRunTests_noTestTargetsConfigured() throws {
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true
        )
        let runner = RecordingXcodebuildRunner(responses: [.failed(66)])

        let result = RunXcodetestsTool(workFolderRoot: tempDir, runner: runner)
            .handle(context: context, args: [:])

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(
            result.outputJSON.contains("before running tests"),
            "the message must name the action the user was attempting: " + result.outputJSON)
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
    //
    // These five used to re-implement the production regexes INLINE and assert against
    // their own copies, so they held whatever production did — including when production
    // was wrong. `testParseXcodeOutput_testCaseFormat` was the expensive case: it pinned
    // `#"Test Case .+ passed"#` with no `.caseInsensitive`, which is exactly the pattern
    // that reported `passed: 0, failed: 0` for every run on Xcode 26's lowercase
    // `Test case` output. A test whose fixture and expectation are both derived from the
    // defect cannot see the defect. They now call the production parsers.

    func testParseIssues_errorAndWarningFormat() {
        let issues = XcodeBuildRunner.parseIssues(
            from: """
            /Users/dev/Project/Sources/File.swift:42:10: error: cannot find 'foo' in scope
            /Users/dev/Project/Sources/Other.swift:15:5: warning: unused variable 'bar'
            """,
            workFolderRoot: URL(fileURLWithPath: "/Users/dev/Project"))

        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues[0].file, "Sources/File.swift")
        XCTAssertEqual(issues[0].line, 42)
        XCTAssertEqual(issues[0].column, 10)
        XCTAssertEqual(issues[0].severity, "error")
        XCTAssertTrue(issues[0].message.contains("foo"))

        XCTAssertEqual(issues[1].file, "Sources/Other.swift")
        XCTAssertEqual(issues[1].severity, "warning")
    }

    /// BOTH result-line spellings must count. Xcode 26 prints `Test case '…' passed on
    /// '…'`; the older shape is `Test Case '-[…]' passed`. Production matches
    /// case-insensitively for exactly this reason, and the modern spelling is the one the
    /// old inline copy of the pattern could not see.
    ///
    /// RED: drop `.caseInsensitive` from `parseTestOutcome` → the lowercase half stops
    /// counting and `passed` falls to 1.
    func testParseTestOutcome_countsBothResultLineSpellings() {
        let outcome = XcodeBuildRunner.parseTestOutcome(
            output: """
            Test Case '-[MyAppTests.SomeTests testLegacy]' started.
            Test Case '-[MyAppTests.SomeTests testLegacy]' passed (0.001 seconds).
            Test case 'SomeTests.testModern()' passed on 'My Mac - NanoTeams (123)'
            Test case 'OtherTests.testFailure()' failed on 'My Mac - NanoTeams (123)'
            """,
            scheme: "App",
            workFolderRoot: URL(fileURLWithPath: "/Users/dev/Project"))

        XCTAssertEqual(outcome.passed, 2, "one legacy spelling and one modern")
        XCTAssertEqual(outcome.failed, 1)
    }

    func testParseTestOutcome_failureDetailsCarryFileLineAndMessage() {
        let outcome = XcodeBuildRunner.parseTestOutcome(
            output: """
            /Users/dev/Project/Tests/SomeTests.swift:25: error: -[MyAppTests.SomeTests testExample] : XCTAssertEqual failed: ("1") is not equal to ("2")
            """,
            scheme: "App",
            workFolderRoot: URL(fileURLWithPath: "/Users/dev/Project"))

        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failures[0]["file"], "Tests/SomeTests.swift")
        XCTAssertEqual(outcome.failures[0]["line"], "25")
        XCTAssertEqual(outcome.failures[0]["scheme"], "App")
        XCTAssertTrue(outcome.failures[0]["message"]?.contains("XCTAssertEqual") == true)
    }

    // MARK: - Edge Cases

    func testParseIssues_countsSeveritiesAcrossManyLines() {
        let issues = XcodeBuildRunner.parseIssues(
            from: """
            /path/to/file.swift:10:5: error: cannot convert value of type 'Int' to expected argument type 'String'
            /path/to/file.swift:20:10: error: missing return in a function expected to return 'Bool'
            /path/to/file.swift:30:3: warning: result of call to 'print' is unused
            """,
            workFolderRoot: tempDir)

        XCTAssertEqual(issues.count, 3)
        XCTAssertEqual(issues.filter { $0.severity == "error" }.count, 2)
        XCTAssertEqual(issues.filter { $0.severity == "warning" }.count, 1)
    }

    func testParseIssues_cleanBuildOutput_reportsNoIssues() {
        XCTAssertTrue(
            XcodeBuildRunner.parseIssues(
                from: "Build succeeded.\n** BUILD SUCCEEDED **",
                workFolderRoot: tempDir
            ).isEmpty)
    }
}
