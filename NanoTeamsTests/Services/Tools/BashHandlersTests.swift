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

    private func context(isPlanningPhase: Bool = false) -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: workDir, taskID: 1, runID: 0, roleID: "r",
                             isPlanningPhase: isPlanningPhase)
    }

    private func errorEnvelope(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func meta(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["meta"] as? [String: Any]
    }

    private func successData(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true
        else { return nil }
        return obj["data"] as? [String: Any]
    }

    // MARK: - Foreground

    func testEcho_success() async {
        let r = await makeTool().handle(context: context(), args: ["command": "echo hello"])
        XCTAssertFalse(r.isError)
        let data = successData(r.outputJSON)
        XCTAssertEqual(data?["exit_code"] as? Int, 0)
        XCTAssertTrue((data?["stdout"] as? String ?? "").contains("hello"))
        XCTAssertEqual(data?["sandboxed"] as? Bool, false)
    }

    func testNonZeroExit_isNotToolError() async {
        let r = await makeTool().handle(context: context(), args: ["command": "exit 3"])
        XCTAssertFalse(r.isError, "a non-zero exit is normal output, not a tool error")
        XCTAssertEqual(successData(r.outputJSON)?["exit_code"] as? Int, 3)
    }

    func testStderrCaptured() async {
        let r = await makeTool().handle(context: context(), args: ["command": "echo oops 1>&2"])
        XCTAssertTrue((successData(r.outputJSON)?["stderr"] as? String ?? "").contains("oops"))
    }

    func testPipesAndGlobs() async {
        let r = await makeTool().handle(context: context(), args: ["command": "printf 'a\\nb\\nc\\n' | grep b"])
        XCTAssertEqual(successData(r.outputJSON)?["exit_code"] as? Int, 0)
        XCTAssertTrue((successData(r.outputJSON)?["stdout"] as? String ?? "").contains("b"))
    }

    func testWorkingDirectory() async throws {
        let sub = workDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let r = await makeTool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "sub"])
        XCTAssertTrue((successData(r.outputJSON)?["stdout"] as? String ?? "").contains("sub"))
    }

    func testWorkingDirectory_missing_isNotADirectory() async {
        let r = await makeTool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "does-not-exist"])
        XCTAssertTrue(r.isError)
    }

    func testMissingCommand_isError() async {
        let r = await makeTool().handle(context: context(), args: [:])
        XCTAssertTrue(r.isError)
    }

    func testAlternativeKeyCommand_runs() async {
        // The handler resolves the command via the shared resolver, so a command
        // under `text` (no `command` key) still runs — and the gate sees the same.
        let r = await makeTool().handle(context: context(), args: ["text": "echo viaText"])
        XCTAssertFalse(r.isError)
        XCTAssertTrue((successData(r.outputJSON)?["stdout"] as? String ?? "").contains("viaText"))
    }

    // MARK: - Timeout

    func testNegativeTimeout_isInvalidArgs() async {
        let r = await makeTool().handle(context: context(), args: ["command": "echo x", "timeout": -5000])
        XCTAssertTrue(r.isError, "a negative timeout must be rejected, not silently clamped to 1s")
    }

    func testZeroTimeout_isInvalidArgs() async {
        let r = await makeTool().handle(context: context(), args: ["command": "echo x", "timeout": 0])
        XCTAssertTrue(r.isError)
    }

    func testTimeout_returnsPartialOutput() async {
        // Prints a marker immediately, then sleeps past the (floored) 1s timeout.
        let r = await makeTool().handle(
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

    func testBackground_returnsCommandIDAndReadsOutput() async throws {
        let start = await makeTool().handle(
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
            let read = await outputTool.handle(context: context(), args: ["command_id": commandID])
            let data = successData(read.outputJSON)
            let out = (data?["output"] as? String ?? "")
            if out.contains("bgline") { sawOutput = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(sawOutput, "bash_output should eventually return the background command's output")
    }

    func testBashOutput_unknownID_isError() async {
        let r = await BashOutputTool().handle(context: context(), args: ["command_id": "bg_does_not_exist"])
        XCTAssertTrue(r.isError)
    }

    func testBashOutput_stopAction_marksNotRunning() async throws {
        let start = await makeTool().handle(
            context: context(), args: ["command": "sleep 5", "run_in_background": true])
        guard let commandID = successData(start.outputJSON)?["command_id"] as? String else {
            return XCTFail("expected a command_id")
        }
        let stop = await BashOutputTool().handle(
            context: context(), args: ["command_id": commandID, "action": "stop"])
        XCTAssertFalse(stop.isError)
        let data = successData(stop.outputJSON)
        XCTAssertEqual(data?["running"] as? Bool, false)
        XCTAssertEqual(data?["status"] as? String, "stopped")
    }

    func testBashOutput_missingCommandID_isError() async {
        let r = await BashOutputTool().handle(context: context(), args: [:])
        XCTAssertTrue(r.isError, "bash_output without a command_id must error")
    }

    // MARK: - Working directory / command validation

    func testWorkingDirectory_absoluteOutsideWorkFolder_isError() async {
        let r = await makeTool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "/etc"])
        XCTAssertTrue(r.isError, "an absolute working_directory outside the work folder must be rejected")
    }

    func testWorkingDirectory_parentTraversal_isError() async {
        let r = await makeTool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "../.."])
        XCTAssertTrue(r.isError, "a parent-traversal working_directory must be rejected")
    }

    func testWorkingDirectory_whitespaceOnly_runsInWorkFolderRoot() async {
        // The resolver (`SandboxPathResolver.resolveFileURL`) trims whitespace, so a
        // whitespace-only working_directory is treated as "none" — the command runs in
        // the work folder root rather than erroring.
        let r = await makeTool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "   "])
        XCTAssertFalse(r.isError, "a whitespace-only working_directory is trimmed to the work folder root")
        let out = successData(r.outputJSON)?["stdout"] as? String ?? ""
        XCTAssertTrue(out.contains(workDir.lastPathComponent), "runs in the work folder root")
    }

    func testNonStringCommand_isMissingCommandError() async {
        // A numeric command resolves to nil via the shared resolver → missing command.
        let r = await makeTool().handle(context: context(), args: ["command": 123])
        XCTAssertTrue(r.isError, "a non-string command resolves to nil → missing command error")
    }

    func testRunInBackground_ambiguousValue_runsForeground() async {
        // Coercion honors only unambiguous boolean spellings; anything else
        // keeps the default (false → foreground, so an exit_code comes back
        // rather than a background command_id).
        let r = await makeTool().handle(
            context: context(), args: ["command": "echo fg", "run_in_background": "later"])
        XCTAssertFalse(r.isError)
        let data = successData(r.outputJSON)
        XCTAssertEqual(data?["exit_code"] as? Int, 0, "an ambiguous run_in_background must default to foreground")
        XCTAssertNil(data?["command_id"], "a foreground result must not carry a background command_id")
        XCTAssertTrue((data?["stdout"] as? String ?? "").contains("fg"))
    }

    func testRunInBackground_stringEncodedTrue_runsInBackground() async {
        // `"yes"` / `"true"` are the quoting habit, not a different intent —
        // silently running in the foreground would strand a model that expects
        // a command_id to poll.
        let r = await makeTool().handle(
            context: context(), args: ["command": "echo bg", "run_in_background": "yes"])
        XCTAssertFalse(r.isError)
        let data = successData(r.outputJSON)
        XCTAssertNotNil(data?["command_id"], "string-encoded true must run in background. Got: \(r.outputJSON)")
    }

    // MARK: - Planning phase

    /// A detached process keeps the profile it was LAUNCHED with for its whole life, so one
    /// started during the phase would carry the write block across the boundary and past it,
    /// with no way to re-profile it. Refused rather than handed back crippled.
    ///
    /// `plan_required`, not INVALID_ARGS: the argument is well-formed and the identical call
    /// works next turn — only that error code reaches `ToolErrorNotePolicy.direction`'s retry arm.
    ///
    /// RED: delete the `context.isPlanningPhase, runInBackground` guard → the envelope becomes a
    /// success carrying a `command_id` and all three assertions fail.
    func testRunInBackground_duringPlanning_isRefusedWithPlanRequired() async {
        let r = await makeTool().handle(
            context: context(isPlanningPhase: true),
            args: ["command": "sleep 5", "run_in_background": true])

        XCTAssertTrue(r.isError)
        XCTAssertEqual(errorEnvelope(r.outputJSON)?["error"] as? String, "plan_required")
        XCTAssertEqual(errorEnvelope(r.outputJSON)?["tool"] as? String, ToolNames.bash)
        XCTAssertNil(successData(r.outputJSON)?["command_id"],
                     "no process may be started — the refusal must precede the launch")
    }

    /// Control: the refusal is scoped to the phase, not a permanent regression.
    ///
    /// RED: make the guard unconditional → the background start is refused outside the phase too.
    func testRunInBackground_outsidePlanning_stillStarts() async {
        let r = await makeTool().handle(
            context: context(), args: ["command": "echo bg", "run_in_background": true])
        XCTAssertFalse(r.isError)
        XCTAssertNotNil(successData(r.outputJSON)?["command_id"])
    }

    /// The envelope states the confinement structurally, so the model can tell a
    /// sandbox refusal from a filesystem one without parsing stderr.
    ///
    /// RED: pass `nil` instead of `true` in the planning arm → `writes_blocked` is absent.
    func testForegroundEnvelope_duringPlanning_carriesWritesBlocked() async {
        let r = await makeTool().handle(
            context: context(isPlanningPhase: true), args: ["command": "echo hi"])
        XCTAssertEqual(successData(r.outputJSON)?["writes_blocked"] as? Bool, true)
    }

    /// ABSENT, not `false`: `writes_blocked` is only ever interesting when true, and a key on
    /// every ordinary bash result is schema noise on a wire whose only speed lever is byte
    /// stability.
    ///
    /// RED: make `BashResult.writes_blocked` non-optional `Bool` → the key appears and the
    /// absence assertion fails.
    func testForegroundEnvelope_outsidePlanning_omitsWritesBlocked() async {
        let r = await makeTool().handle(context: context(), args: ["command": "echo hi"])
        let data = successData(r.outputJSON)
        XCTAssertNotNil(data, "precondition: the call succeeded")
        XCTAssertNil(data?["writes_blocked"])
    }

    /// A write the SANDBOX refused arrives as an ordinary non-zero exit with `isError == false`,
    /// which `ToolErrorNotePolicy.direction` structurally never sees. So the retry contract is taught
    /// in the envelope — otherwise the model reads `Operation not permitted` and concludes the
    /// file is protected, or that it needs `sudo`.
    ///
    /// RED: delete the `meta:` argument from the `.completed` success result → no warning reaches
    /// the envelope.
    func testPlanningWriteDenial_teachesTheRetryContract() async {
        let r = await makeTool().handle(
            context: context(isPlanningPhase: true),
            args: ["command": "echo 'x: Operation not permitted' >&2; exit 1"])
        let warnings = meta(r.outputJSON)?["warnings"] as? [String] ?? []
        XCTAssertTrue(warnings.contains { $0.contains("update_scratchpad") },
                      "got: \(r.outputJSON)")
    }

    /// The same failure outside the phase must NOT claim a planning-phase sandbox refused it —
    /// there, `Operation not permitted` really is the filesystem talking.
    ///
    /// RED: drop the `isPlanningPhase` term from `planningWriteDenialMeta`'s guard → the warning
    /// fires outside the phase and the emptiness assertion fails.
    func testWriteDenialWarning_neverFiresOutsidePlanning() async {
        let r = await makeTool().handle(
            context: context(),
            args: ["command": "echo 'x: Operation not permitted' >&2; exit 1"])
        XCTAssertTrue((meta(r.outputJSON)?["warnings"] as? [String] ?? []).isEmpty)
    }
}
