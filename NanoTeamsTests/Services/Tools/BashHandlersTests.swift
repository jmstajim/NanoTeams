import XCTest

@testable import NanoTeams

/// Exercises `BashTool` / `BashOutputTool` against real subprocesses. Runs
/// UNSANDBOXED (`sandboxEnabled: false`) so the tests don't depend on
/// `sandbox-exec`. The permission gate is upstream and not involved here.
final class BashHandlersTests: XCTestCase {

    var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-bashtest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Kill any background commands this suite started so they (and their log
        // files) don't leak into later runs / suites sharing the singleton.
        BackgroundBashRegistry.shared.terminateAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        super.tearDown()
    }

    private func makeTool() -> BashTool {
        BashTool(
            workFolderRoot: workDir,
            resolver: SandboxPathResolver(workFolderRoot: workDir),
            fileManager: .default,
            sandboxEnabled: false,
            sandboxPermissions: BashSandboxPermissions(),
            allowUnsandboxedFallback: false)
    }

    private func context() -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: workDir, taskID: 1, runID: 0, roleID: "r")
    }

    private func successData(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true
        else { return nil }
        return obj["data"] as? [String: Any]
    }

    // MARK: - Foreground

    func testEcho_success() {
        let r = makeTool().handle(context: context(), args: ["command": "echo hello"])
        XCTAssertFalse(r.isError)
        let data = successData(r.outputJSON)
        XCTAssertEqual(data?["exit_code"] as? Int, 0)
        XCTAssertTrue((data?["stdout"] as? String ?? "").contains("hello"))
        XCTAssertEqual(data?["sandboxed"] as? Bool, false)
    }

    func testNonZeroExit_isNotToolError() {
        let r = makeTool().handle(context: context(), args: ["command": "exit 3"])
        XCTAssertFalse(r.isError, "a non-zero exit is normal output, not a tool error")
        XCTAssertEqual(successData(r.outputJSON)?["exit_code"] as? Int, 3)
    }

    func testStderrCaptured() {
        let r = makeTool().handle(context: context(), args: ["command": "echo oops 1>&2"])
        XCTAssertTrue((successData(r.outputJSON)?["stderr"] as? String ?? "").contains("oops"))
    }

    func testPipesAndGlobs() {
        let r = makeTool().handle(context: context(), args: ["command": "printf 'a\\nb\\nc\\n' | grep b"])
        XCTAssertEqual(successData(r.outputJSON)?["exit_code"] as? Int, 0)
        XCTAssertTrue((successData(r.outputJSON)?["stdout"] as? String ?? "").contains("b"))
    }

    func testWorkingDirectory() throws {
        let sub = workDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let r = makeTool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "sub"])
        XCTAssertTrue((successData(r.outputJSON)?["stdout"] as? String ?? "").contains("sub"))
    }

    func testWorkingDirectory_missing_isNotADirectory() {
        let r = makeTool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "does-not-exist"])
        XCTAssertTrue(r.isError)
    }

    func testMissingCommand_isError() {
        let r = makeTool().handle(context: context(), args: [:])
        XCTAssertTrue(r.isError)
    }

    func testAlternativeKeyCommand_runs() {
        // The handler resolves the command via the shared resolver, so a command
        // under `text` (no `command` key) still runs — and the gate sees the same.
        let r = makeTool().handle(context: context(), args: ["text": "echo viaText"])
        XCTAssertFalse(r.isError)
        XCTAssertTrue((successData(r.outputJSON)?["stdout"] as? String ?? "").contains("viaText"))
    }

    // MARK: - Timeout

    func testNegativeTimeout_isInvalidArgs() {
        let r = makeTool().handle(context: context(), args: ["command": "echo x", "timeout": -5000])
        XCTAssertTrue(r.isError, "a negative timeout must be rejected, not silently clamped to 1s")
    }

    func testZeroTimeout_isInvalidArgs() {
        let r = makeTool().handle(context: context(), args: ["command": "echo x", "timeout": 0])
        XCTAssertTrue(r.isError)
    }

    func testTimeout_returnsPartialOutput() {
        // Prints a marker immediately, then sleeps past the (floored) 1s timeout.
        let r = makeTool().handle(
            context: context(),
            args: ["command": "echo PARTIAL_MARKER; sleep 5", "timeout": 500])
        XCTAssertFalse(r.isError, "a timeout is a success envelope with timed_out:true")
        let data = successData(r.outputJSON)
        XCTAssertEqual(data?["timed_out"] as? Bool, true)
        XCTAssertTrue(
            (data?["stdout"] as? String ?? "").contains("PARTIAL_MARKER"),
            "output produced before the deadline must be preserved")
    }

    // MARK: - Background

    func testBackground_returnsCommandIDAndReadsOutput() throws {
        let start = makeTool().handle(
            context: context(),
            args: ["command": "echo bgline", "run_in_background": true])
        XCTAssertFalse(start.isError)
        guard let commandID = successData(start.outputJSON)?["command_id"] as? String else {
            return XCTFail("expected a command_id")
        }

        let outputTool = BashOutputTool()
        // Poll up to ~3s for the background process to flush and exit.
        var sawOutput = false
        for _ in 0..<30 {
            let read = outputTool.handle(context: context(), args: ["command_id": commandID])
            let data = successData(read.outputJSON)
            let out = (data?["output"] as? String ?? "")
            if out.contains("bgline") { sawOutput = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawOutput, "bash_output should eventually return the background command's output")
    }

    func testBashOutput_unknownID_isError() {
        let r = BashOutputTool().handle(context: context(), args: ["command_id": "bg_does_not_exist"])
        XCTAssertTrue(r.isError)
    }

    func testBashOutput_stopAction_marksNotRunning() throws {
        let start = makeTool().handle(
            context: context(), args: ["command": "sleep 5", "run_in_background": true])
        guard let commandID = successData(start.outputJSON)?["command_id"] as? String else {
            return XCTFail("expected a command_id")
        }
        let stop = BashOutputTool().handle(
            context: context(), args: ["command_id": commandID, "action": "stop"])
        XCTAssertFalse(stop.isError)
        let data = successData(stop.outputJSON)
        XCTAssertEqual(data?["running"] as? Bool, false)
        XCTAssertEqual(data?["status"] as? String, "stopped")
    }

    func testBashOutput_missingCommandID_isError() {
        let r = BashOutputTool().handle(context: context(), args: [:])
        XCTAssertTrue(r.isError, "bash_output without a command_id must error")
    }

    // MARK: - Working directory / command validation

    func testWorkingDirectory_absoluteOutsideWorkFolder_isError() {
        let r = makeTool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "/etc"])
        XCTAssertTrue(r.isError, "an absolute working_directory outside the work folder must be rejected")
    }

    func testWorkingDirectory_parentTraversal_isError() {
        let r = makeTool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "../.."])
        XCTAssertTrue(r.isError, "a parent-traversal working_directory must be rejected")
    }

    func testWorkingDirectory_whitespaceOnly_runsInWorkFolderRoot() {
        // The resolver (`SandboxPathResolver.resolveFileURL`) trims whitespace, so a
        // whitespace-only working_directory is treated as "none" — the command runs in
        // the work folder root rather than erroring.
        let r = makeTool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "   "])
        XCTAssertFalse(r.isError, "a whitespace-only working_directory is trimmed to the work folder root")
        let out = successData(r.outputJSON)?["stdout"] as? String ?? ""
        XCTAssertTrue(out.contains(workDir.lastPathComponent), "runs in the work folder root")
    }

    func testNonStringCommand_isMissingCommandError() {
        // A numeric command resolves to nil via the shared resolver → missing command.
        let r = makeTool().handle(context: context(), args: ["command": 123])
        XCTAssertTrue(r.isError, "a non-string command resolves to nil → missing command error")
    }

    func testRunInBackground_ambiguousValue_runsForeground() {
        // Coercion honors only unambiguous boolean spellings; anything else
        // keeps the default (false → foreground, so an exit_code comes back
        // rather than a background command_id).
        let r = makeTool().handle(
            context: context(), args: ["command": "echo fg", "run_in_background": "later"])
        XCTAssertFalse(r.isError)
        let data = successData(r.outputJSON)
        XCTAssertEqual(data?["exit_code"] as? Int, 0, "an ambiguous run_in_background must default to foreground")
        XCTAssertNil(data?["command_id"], "a foreground result must not carry a background command_id")
        XCTAssertTrue((data?["stdout"] as? String ?? "").contains("fg"))
    }

    func testRunInBackground_stringEncodedTrue_runsInBackground() {
        // `"yes"` / `"true"` are the quoting habit, not a different intent —
        // silently running in the foreground would strand a model that expects
        // a command_id to poll.
        let r = makeTool().handle(
            context: context(), args: ["command": "echo bg", "run_in_background": "yes"])
        XCTAssertFalse(r.isError)
        let data = successData(r.outputJSON)
        XCTAssertNotNil(data?["command_id"], "string-encoded true must run in background. Got: \(r.outputJSON)")
    }
}
