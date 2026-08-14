import XCTest

@testable import NanoTeams

/// What `run_xcodebuild` and `run_xcodetests` actually hand the model.
///
/// Both handlers' entire bodies were uncovered — every assertion here is about behaviour
/// that had never executed in a test process, including the two things a model most depends
/// on: that a FAILED build ships its log and a SUCCEEDED one does not, and that a test run's
/// pass/fail counts are real rather than zero.
///
/// The handlers are constructed directly rather than through `ToolRegistry.defaultRegistry`.
/// The registry builds its handlers from `ToolHandlerDependencies`, which is a bag of user
/// preferences and paths; putting a subprocess runner in it would change what that type is
/// for, and `makeInstance` naming `SystemXcodebuildRunner()` keeps production's single
/// construction site explicit (the CLAUDE.md §49 shape).
final class XcodeHandlerEnvelopeCoverageTests: XCTestCase {

    private var root: URL!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt_xchandler_\(UUID().uuidString.prefix(8))", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: root)
        try FileManager.default.createDirectory(
            at: paths.internalDir, withIntermediateDirectories: true)
        try #"{"selectedScheme":"App"}"#
            .write(to: paths.settingsJSON, atomically: true, encoding: .utf8)

        context = ToolExecutionContext(
            workFolderRoot: root, taskID: 1, runID: 0, roleID: "role")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        context = nil
        try super.tearDownWithError()
    }

    private func decodedData(_ result: ToolExecutionResult) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: Data(result.outputJSON.utf8)) as? [String: Any]
        return (object?["data"] as? [String: Any]) ?? [:]
    }

    // MARK: - run_xcodebuild

    /// A green build ships NO log. The log exists to carry a diagnostic; on success there is
    /// none, and shipping thousands of lines of compile chatter would displace real context.
    ///
    /// RED: change `log: success ? "" : log` to always `log` → the emptiness assertion fails.
    func testBuild_success_reportsSuccessAndShipsNoLog() throws {
        let runner = RecordingXcodebuildRunner(responses: [.ok("""
            Building App
            ** BUILD SUCCEEDED **
            """)])
        let tool = RunXcodebuildTool(workFolderRoot: root, runner: runner)

        let result = tool.handle(context: context, args: [:])
        let data = try decodedData(result)

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(data["success"] as? Bool, true)
        XCTAssertEqual(data["exit_code"] as? Int, 0)
        XCTAssertEqual(data["error_count"] as? Int, 0)
        XCTAssertEqual(data["log"] as? String, "", "a successful build has no diagnostic to ship")
        XCTAssertEqual(runner.calls.first?.timeout, XcodeBuildRunner.buildTimeout)
    }

    /// A red build ships the log, the exit code, and the parsed issues — with paths made
    /// relative to the work folder so the model can feed them straight back into `read_file`.
    ///
    /// RED: drop the `parseIssues` call from `aggregateBuild` → `error_count` becomes 0 while
    /// the build is reported failed, i.e. "it broke and I can't tell you where".
    func testBuild_failure_shipsLogExitCodeAndRelativizedIssues() throws {
        let sourcePath = root.appendingPathComponent("Sources/Counter.swift").path
        let runner = RecordingXcodebuildRunner(responses: [.failed(65, stdout: """
            \(sourcePath):12:5: error: cannot find 'foo' in scope
            \(sourcePath):20:1: warning: unused variable 'bar'
            ** BUILD FAILED **
            """)])
        let tool = RunXcodebuildTool(workFolderRoot: root, runner: runner)

        let result = tool.handle(context: context, args: [:])
        let data = try decodedData(result)

        XCTAssertFalse(result.isError, "a failed build is a successful tool call")
        XCTAssertEqual(data["success"] as? Bool, false)
        XCTAssertEqual(data["exit_code"] as? Int, 65)
        XCTAssertEqual(data["error_count"] as? Int, 1)
        XCTAssertEqual(data["warning_count"] as? Int, 1)

        let log = try XCTUnwrap(data["log"] as? String)
        XCTAssertTrue(log.contains("--- Scheme: App ---"), log)
        XCTAssertTrue(log.contains("BUILD FAILED"), log)

        let issues = try XCTUnwrap(data["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.first?["file"] as? String, "Sources/Counter.swift",
                       "relative to the work folder, so read_file resolves it")
        XCTAssertEqual(issues.first?["line"] as? Int, 12)
    }

    /// The line cap reaches `meta.truncated`, which is the only signal the model gets that
    /// what it is reading is a tail rather than the whole log.
    func testBuild_longFailureLog_reportsTruncation() throws {
        let flood = (1...(XcodeBuildRunner.defaultMaxLogLines + 20))
            .map { "line \($0)" }.joined(separator: "\n")
        let runner = RecordingXcodebuildRunner(responses: [.failed(65, stdout: flood)])
        let tool = RunXcodebuildTool(workFolderRoot: root, runner: runner)

        let result = tool.handle(context: context, args: [:])
        let data = try decodedData(result)

        XCTAssertTrue(result.outputJSON.contains("\"truncated\":true"), result.outputJSON)
        let log = try XCTUnwrap(data["log"] as? String)
        XCTAssertTrue(log.contains("line \(XcodeBuildRunner.defaultMaxLogLines + 20)"),
                      "truncation keeps the TAIL — the newest output is the diagnostic")
        XCTAssertFalse(log.contains("line 1\n"), "the head is what gets dropped")
    }

    /// A thrown `ProcessRunnerError` (timeout / cancellation / missing executable) becomes an
    /// error envelope, not a build that "failed".
    func testBuild_processThrows_becomesAnErrorEnvelope() throws {
        let runner = RecordingXcodebuildRunner(
            thrown: ProcessRunnerError.timeout(600, stdout: "", stderr: ""))
        let tool = RunXcodebuildTool(workFolderRoot: root, runner: runner)

        let result = tool.handle(context: context, args: [:])

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("timed out"), result.outputJSON)
    }

    func testBuild_noProject_reportsFileNotFoundWithTheRecoveryHint() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("App.xcodeproj"))
        let runner = ForbiddenXcodebuildRunner()
        let tool = RunXcodebuildTool(workFolderRoot: root, runner: runner)

        let result = tool.handle(context: context, args: [:])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("FILE_NOT_FOUND"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains(ToolNames.listFiles), result.outputJSON)
        XCTAssertFalse(runner.reached)
    }

    // MARK: - run_xcodetests

    /// The counts must be REAL. `parseTestOutcome`'s result-line pattern was
    /// case-sensitive against Xcode 26's lowercase `Test case`, so `run_xcodetests` reported
    /// `passed: 0, failed: 0` for every run — a green suite and a red one produced identical
    /// numbers. Nothing could catch that from a handler test, because no handler test existed.
    ///
    /// RED: drop `.caseInsensitive` from `parseTestOutcome`'s `count(_:)` → `passed` becomes 0.
    func testTests_success_reportsTheParsedPassCountAndNoLog() throws {
        let runner = RecordingXcodebuildRunner(responses: [.ok("""
            Test case 'AlphaTests.testOne()' passed on 'My Mac - NanoTeams (123)'
            Test case 'AlphaTests.testTwo()' passed on 'My Mac - NanoTeams (123)'
            ** TEST SUCCEEDED **
            """)])
        let tool = RunXcodetestsTool(workFolderRoot: root, runner: runner)

        let result = tool.handle(context: context, args: [:])
        let data = try decodedData(result)

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(data["success"] as? Bool, true)
        XCTAssertEqual(data["passed"] as? Int, 2)
        XCTAssertEqual(data["failed"] as? Int, 0)
        XCTAssertEqual(data["log"] as? String, "")
        XCTAssertEqual(runner.calls.first?.timeout, XcodeBuildRunner.testTimeout,
                       "a test run builds first, so it gets the longer budget")
    }

    /// A failing test ships its failures with relativized paths, and `success` is false even
    /// though a failing suite still exits non-zero for a *different* reason than a build
    /// error would.
    func testTests_failure_shipsFailureRecordsWithRelativePaths() throws {
        let testPath = root.appendingPathComponent("Tests/AlphaTests.swift").path
        let runner = RecordingXcodebuildRunner(responses: [.failed(65, stdout: """
            Test case 'AlphaTests.testOne()' passed on 'My Mac - NanoTeams (123)'
            Test case 'AlphaTests.testTwo()' failed on 'My Mac - NanoTeams (123)'
            \(testPath):25: error: XCTAssertEqual failed: ("1") is not equal to ("2")
            ** TEST FAILED **
            """)])
        let tool = RunXcodetestsTool(workFolderRoot: root, runner: runner)

        let result = tool.handle(context: context, args: [:])
        let data = try decodedData(result)

        XCTAssertEqual(data["success"] as? Bool, false)
        XCTAssertEqual(data["passed"] as? Int, 1)
        XCTAssertEqual(data["failed"] as? Int, 1)
        XCTAssertEqual(data["exit_code"] as? Int, 65)

        let failures = try XCTUnwrap(data["failures"] as? [[String: String]])
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?["scheme"], "App")
        XCTAssertEqual(failures.first?["file"], "Tests/AlphaTests.swift")
        XCTAssertEqual(failures.first?["line"], "25")
        XCTAssertTrue(failures.first?["message"]?.contains("XCTAssertEqual") == true)
        XCTAssertFalse((data["log"] as? String ?? "").isEmpty, "a red run ships its log")
    }

    /// A clean exit with parsed failures is a contradiction, and `success` must take the
    /// pessimistic side: reporting green while handing over failure records would be a lie
    /// the model has no way to check.
    ///
    /// RED: change `exitedCleanly && failed == 0` to just `exitedCleanly` → this fails.
    func testTests_zeroExitButParsedFailures_isNotReportedAsSuccess() throws {
        let runner = RecordingXcodebuildRunner(responses: [.ok("""
            Test case 'AlphaTests.testTwo()' failed on 'My Mac - NanoTeams (123)'
            /elsewhere/AlphaTests.swift:9: error: boom
            """)])
        let tool = RunXcodetestsTool(workFolderRoot: root, runner: runner)

        let data = try decodedData(tool.handle(context: context, args: [:]))

        XCTAssertEqual(data["success"] as? Bool, false)
        XCTAssertEqual(data["failed"] as? Int, 1)
        XCTAssertEqual(data["exit_code"] as? Int, 0, "the process really did exit 0")
    }

    /// A path outside the work folder stays ABSOLUTE rather than being truncated into a
    /// plausible-but-nonexistent relative one — the failure mode `relativizeIssuePath`
    /// documents, where a model chased a `read_file` that could never resolve.
    func testTests_failureOutsideTheWorkFolder_keepsTheAbsolutePath() throws {
        let runner = RecordingXcodebuildRunner(responses: [.failed(65, stdout: """
            Test case 'X.testY()' failed on 'My Mac'
            /somewhere/else/Other.swift:3: error: nope
            """)])
        let tool = RunXcodetestsTool(workFolderRoot: root, runner: runner)

        let data = try decodedData(tool.handle(context: context, args: [:]))
        let failures = try XCTUnwrap(data["failures"] as? [[String: String]])

        XCTAssertEqual(failures.first?["file"], "/somewhere/else/Other.swift")
    }

    func testTests_noProject_reportsFileNotFoundWithTheRecoveryHint() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("App.xcodeproj"))
        let runner = ForbiddenXcodebuildRunner()
        let tool = RunXcodetestsTool(workFolderRoot: root, runner: runner)

        let result = tool.handle(context: context, args: [:])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("FILE_NOT_FOUND"), result.outputJSON)
        XCTAssertTrue(
            result.outputJSON.contains(ToolNames.listFiles),
            "run_xcodetests used to omit the recovery hint that run_xcodebuild carried: "
                + result.outputJSON)
    }

    // MARK: - Production wiring

    /// `makeInstance` must name the LIVE runner. The seam's whole point is that a forgotten
    /// injection cannot compile — but `makeInstance` is the one site that supplies it, so if
    /// it named an inert one instead, `run_xcodebuild` would report a fabricated result to
    /// every user and no other test would notice.
    func testMakeInstance_wiresTheSystemRunner() {
        let dependencies = ToolHandlerDependencies(
            workFolderRoot: root,
            resolver: SandboxPathResolver(workFolderRoot: root),
            fileManager: .default,
            internalDir: NTMSPaths(workFolderRoot: root).internalDir,
            searchExploratoryByDefault: false,
            readFileMaxLines: 500,
            searchMaxResults: 100,
            searchContextBefore: 0,
            searchContextAfter: 0)

        XCTAssertTrue(
            RunXcodebuildTool.makeInstance(dependencies: dependencies).runner
                is SystemXcodebuildRunner)
        XCTAssertTrue(
            RunXcodetestsTool.makeInstance(dependencies: dependencies).runner
                is SystemXcodebuildRunner)
    }
}
