import XCTest

@testable import NanoTeams

/// Pins that `bash` reports whether it WAS sandboxed, not whether it MEANT to be — and that a
/// command's own output can never arm the unsandboxed retry.
///
/// Two defects met here. `SeatbeltSandbox.isSandboxDenialFailure` was a case-insensitive
/// `contains` over stderr, but `sandbox-exec` and the child it launches write to the SAME pipe, so
/// any failing command whose stderr merely mentioned the wrapper looked like a wrapper failure.
/// And the envelope rebuilt its `sandboxed` flag from the caller's untouched `sandboxProfile`
/// local, so the fact of a fallback was discarded at `runForeground`'s return boundary.
///
/// Measured on macOS 26 — every wrapper failure writes a stderr that BEGINS `sandbox-exec: `:
///   bad profile             → exit 65, `sandbox-exec: undefined sharp expression`
///   missing profile file    → exit 65, `sandbox-exec: …: No such file or directory`
///   unreadable profile file → exit 65, `sandbox-exec: …: Permission denied`
///   execvp failure          → exit 71, `sandbox-exec: execvp() of '…' failed: …`
/// while a confined child that fails on its own does not:
///   `cat /usr/bin/sandbox-exec/nope` → exit 1, `cat: …: Not a directory`
///   `set -x; grep -rn "sandbox-exec" …` → exit 2, `+zsh:1> grep -rn sandbox-exec …`
/// A profile that compiles but denies the system reads the shell needs is exit 134 with EMPTY
/// stderr — a genuinely confined failure, and NOT a wrapper fault, so no retry is the right
/// answer there and the prefix rule gives it.
final class BashSandboxHonestyCoverageTests: XCTestCase {

    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-bashhonesty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        BackgroundBashRegistry.shared.terminateAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        super.tearDown()
    }

    private func makeTool(sandboxed: Bool, fallback: Bool) -> BashTool {
        BashTool(
            workFolderRoot: workDir,
            resolver: SandboxPathResolver(workFolderRoot: workDir),
            fileManager: .default,
            sandboxEnabled: sandboxed,
            sandboxPermissions: BashSandboxPermissions(),
            allowUnsandboxedFallback: fallback)
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

    // MARK: - The discriminator

    /// RED: restore the `contains("sandbox-exec")` test → every one of these child failures is
    /// classified as a wrapper denial, which (with the fallback on) re-runs the command outside
    /// the sandbox and (with it off, the default) tells the model "Command was not run" about a
    /// command that ran.
    func testChildStderrMentioningTheWrapper_isNotAWrapperFailure() {
        let childFailures: [(String, Int32)] = [
            ("cat: /usr/bin/sandbox-exec/nope: Not a directory", 1),
            ("+zsh:1> grep -rn sandbox-exec /nonexistent-dir\ngrep: /nonexistent-dir: No such file or directory", 2),
            ("error: could not find sandbox_apply symbol in the binary", 1),
            ("build failed: profile compilation step skipped", 2),
            ("", 134),
        ]
        for (stderr, code) in childFailures {
            XCTAssertFalse(
                SeatbeltSandbox.isSandboxDenialFailure(exitCode: code, stderr: stderr),
                "child stderr must not read as a wrapper failure: \(stderr)")
        }
    }

    /// The four measured wrapper shapes must still classify — narrowing the rule must not make the
    /// legitimate fallback unreachable.
    ///
    /// RED: anchor on `hasPrefix("sandbox-exec:")` against the RAW string without trimming, then
    /// feed a leading-newline stderr → the real wrapper failure stops being recognised.
    func testWrapperDiagnostics_stillClassifyAsDenial() {
        let wrapperFailures: [(String, Int32)] = [
            ("sandbox-exec: undefined sharp expression\n\nBacktrace: \n/tmp/x.sb:2:2:", 65),
            ("sandbox-exec: /tmp/nope.sb: No such file or directory", 65),
            ("sandbox-exec: /tmp/x.sb: Permission denied", 65),
            ("sandbox-exec: execvp() of '/no/such/binary' failed: No such file or directory", 71),
            ("\n  sandbox-exec: syntax error: expecting ')'", 65),
        ]
        for (stderr, code) in wrapperFailures {
            XCTAssertTrue(
                SeatbeltSandbox.isSandboxDenialFailure(exitCode: code, stderr: stderr),
                "wrapper diagnostic must classify as a denial: \(stderr)")
        }
    }

    /// A zero exit code is never a denial regardless of what the text says.
    ///
    /// RED: drop the `exitCode != 0` guard → a successful command that prints the wrapper's name
    /// triggers a pointless second execution.
    func testSuccessfulCommand_isNeverADenial() {
        XCTAssertFalse(SeatbeltSandbox.isSandboxDenialFailure(
            exitCode: 0, stderr: "sandbox-exec: warning printed but we succeeded"))
    }

    // MARK: - The flag reports the fact

    /// RED: rebuild the envelope's flag from the caller's `sandboxProfile` local (the pre-fix
    /// `sandboxed: sandboxProfile != nil`) → an unsandboxed run reports `sandboxed: true`.
    func testUnsandboxedRun_reportsSandboxedFalse() {
        let r = makeTool(sandboxed: false, fallback: false)
            .handle(context: context(), args: ["command": "echo hi"])
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertEqual(successData(r.outputJSON)?["sandboxed"] as? Bool, false)
    }

    /// The ordinary confined command still reports `true` — the fix must not invert the flag.
    ///
    /// RED: hard-code `sandboxed: false` → this reds while the test above still passes, so the
    /// pair distinguishes "reports the fact" from "always says false".
    func testSandboxedRun_reportsSandboxedTrue() {
        let r = makeTool(sandboxed: true, fallback: false)
            .handle(context: context(), args: ["command": "echo hi"])
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertEqual(successData(r.outputJSON)?["sandboxed"] as? Bool, true)
    }

    /// The whole point, end to end: a command that fails while printing the wrapper's name runs
    /// ONCE, inside the sandbox — no silent second unconfined execution.
    ///
    /// The marker lives in `/private/tmp` rather than the work folder, and the reason is a
    /// correction worth keeping. This comment first claimed the work folder was structurally
    /// unwritable from the sandbox — "measured", and wrong about the cause. The real cause was a
    /// defect: `SeatbeltSandbox.canonical` used `URL.resolvingSymlinksInPath()`, which hands back
    /// the SHORT form for macOS's root-level symlinks, so a work folder under `$TMPDIR` was granted
    /// as `/var/folders/…` while the kernel asked about `/private/var/folders/…` and matched
    /// nothing. That is fixed (`realpath(3)`, pinned by `SeatbeltCanonicalPathCoverageTests`), and
    /// the work folder IS writable now.
    ///
    /// The observation the placement rests on survives intact: a marker whose sandboxed write is
    /// denied counts 0 for the confined run and 1 for the unsandboxed retry — total 1 — and so
    /// would have passed against the pre-fix `contains` heuristic for entirely the wrong reason. It
    /// did, until the count was measured. `/private/tmp` keeps this test independent of whether the
    /// work folder happens to be writable, which is a different subsystem's invariant.
    ///
    /// RED: restore the `contains("sandbox-exec")` test → the retry fires and the marker holds two
    /// lines.
    func testCommandWhoseStderrNamesTheWrapper_runsExactlyOnce() throws {
        let marker = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("nanoteams-w18-\(UUID().uuidString).marker")
        defer { try? FileManager.default.removeItem(at: marker) }

        let r = makeTool(sandboxed: true, fallback: true).handle(
            context: context(),
            args: ["command": "echo ran >> \(marker.path); echo 'cat: /usr/bin/sandbox-exec/x: Not a directory' >&2; exit 1"])

        XCTAssertFalse(r.isError, r.outputJSON)
        let contents = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        let runs = contents.split(separator: "\n").count
        XCTAssertEqual(runs, 1, "command executed \(runs) times — the unsandboxed retry fired")
    }

    /// The reporting half of a genuine fallback: an execution with no sandbox says so. Together
    /// with `testSandboxedRun_reportsSandboxedTrue` this pins that the flag tracks the fact rather
    /// than being pinned to either constant.
    ///
    /// RED: rebuild the flag from `sandboxProfile != nil` → reports `true` for a run that had no
    /// sandbox at all.
    func testUnconfinedExecution_reportsSandboxedFalse() {
        let r = makeTool(sandboxed: false, fallback: true)
            .handle(context: context(), args: ["command": "echo hi"])
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertEqual(successData(r.outputJSON)?["sandboxed"] as? Bool, false)
    }

    /// The default configuration's half of the same defect: with the fallback OFF, a command that
    /// merely mentions the wrapper while failing used to be reported as never having run, and its
    /// stdout was discarded.
    ///
    /// RED: restore the `contains` heuristic → this returns a `bashDenied` error envelope reading
    /// "Command was not run", and `hello` is nowhere in the result.
    func testCommandWhoseStderrNamesTheWrapper_isNotReportedAsNeverRun() {
        let r = makeTool(sandboxed: true, fallback: false).handle(
            context: context(),
            args: ["command": "echo hello; echo 'grep: sandbox-exec: no match' >&2; exit 1"])

        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertFalse(r.outputJSON.contains("Command was not run"), r.outputJSON)
        XCTAssertTrue((successData(r.outputJSON)?["stdout"] as? String ?? "").contains("hello"), r.outputJSON)
    }
}
