import XCTest

@testable import NanoTeams

/// Pins that `bash` reports whether it WAS sandboxed, not whether it MEANT to be — and that a
/// command's own output can never arm the unsandboxed retry.
///
/// Three defects met here, in two waves.
///
/// 2026-08: the classifier was a case-insensitive `contains` over stderr, but `sandbox-exec` and
/// the child it launches write to the SAME pipe, so any failing command whose stderr merely
/// MENTIONED the wrapper looked like a wrapper failure. And the envelope rebuilt its `sandboxed`
/// flag from the caller's untouched `sandboxProfile` local, so the fact of a fallback was
/// discarded at `runForeground`'s return boundary.
///
/// 2026-08-25: narrowing `contains` to `hasPrefix` fixed the ACCIDENTAL half and left the
/// deliberate one — the child still owns the first bytes when the wrapper does not fail, so
/// `echo "sandbox-exec: …" >&2; exit 1` was measured to classify as a wrapper denial. The
/// discriminator is now `ProcessRunner.probeSandboxLaunch`, which re-launches the same invocation
/// with a no-op command and reads a stream the judged command never touched.
/// `SeatbeltSandbox.isWrapperDiagnostic` (renamed) still holds the position rule and is applied to
/// THAT stderr.
///
/// Note which of the tests below actually caught the second defect:
/// `testCommandWhoseStderrNamesTheWrapper_runsExactlyOnce` did NOT — its fixture is a `contains`
/// case that `hasPrefix` already declined, so it looked like the end-to-end pin for this and was
/// green against it. `testCommandWhoseStderrOPENSWithTheWrapperName_*` are the ones that were red.
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

    private func makeTool(
        sandboxed: Bool,
        fallback: Bool,
        permissions: BashSandboxPermissions = BashSandboxPermissions()
    ) -> BashTool {
        BashTool(
            workFolderRoot: workDir,
            resolver: SandboxPathResolver(workFolderRoot: workDir),
            fileManager: .default,
            sandboxEnabled: sandboxed,
            sandboxPermissions: permissions,
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

    /// Re-aimed 2026-08-25. The SUT changed, the table did not.
    ///
    /// These five rows are CHILD output, and after the probe fix child output never reaches a
    /// classifier at all — so asserting `isWrapperDiagnostic(childStderr) == false` would pin a
    /// call production no longer makes. Deleting the test would restore exactly the blindness it
    /// exists to prevent (CLAUDE.md #104), so the rows are driven end-to-end through `BashTool`
    /// instead: each must come back as a real result carrying the command's own output.
    ///
    /// The last row (`"", 134`) is the shape that used to be indistinguishable from a wrapper
    /// fault by absence of evidence; it is now its own verdict.
    ///
    /// RED: classify from `result.stderr` instead of the probe → the rows whose text LEADS with
    /// the wrapper name come back as a `bashDenied` envelope and PAYLOAD is gone.
    func testChildStderrMentioningTheWrapper_neverArmsTheRetryOrTheDenial() async throws {
        let childFailures: [(String, Int32)] = [
            ("cat: /usr/bin/sandbox-exec/nope: Not a directory", 1),
            ("+zsh:1> grep -rn sandbox-exec /nonexistent-dir\ngrep: /nonexistent-dir: No such file or directory", 2),
            ("error: could not find sandbox_apply symbol in the binary", 1),
            ("build failed: profile compilation step skipped", 2),
            ("sandbox-exec: fake denial authored by the command itself", 1),
        ]
        let tool = makeTool(sandboxed: true, fallback: false)
        for (stderr, code) in childFailures {
            let escaped = stderr.replacingOccurrences(of: "'", with: "'\\''")
            let result = await tool.handle(context: context(), args: [
                "command": "printf '%s' '\(escaped)' >&2; echo PAYLOAD; exit \(code)"
            ])
            XCTAssertFalse(
                result.isError,
                "a child that merely mentions the wrapper must not produce an error envelope: \(stderr)")
            XCTAssertTrue(
                result.outputJSON.contains("PAYLOAD"),
                "the command's real stdout must survive: \(stderr) → \(result.outputJSON)")
            XCTAssertFalse(
                result.outputJSON.contains("command was not run"),
                "the envelope must not claim the command did not run: \(result.outputJSON)")
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
                SeatbeltSandbox.isWrapperDiagnostic(exitCode: code, stderr: stderr),
                "wrapper diagnostic must classify as a denial: \(stderr)")
        }
    }

    /// A zero exit code is never a denial regardless of what the text says.
    ///
    /// RED: drop the `exitCode != 0` guard → a successful command that prints the wrapper's name
    /// triggers a pointless second execution.
    func testSuccessfulCommand_isNeverADenial() {
        XCTAssertFalse(SeatbeltSandbox.isWrapperDiagnostic(
            exitCode: 0, stderr: "sandbox-exec: warning printed but we succeeded"))
    }

    // MARK: - The flag reports the fact

    /// RED: rebuild the envelope's flag from the caller's `sandboxProfile` local (the pre-fix
    /// `sandboxed: sandboxProfile != nil`) → an unsandboxed run reports `sandboxed: true`.
    func testUnsandboxedRun_reportsSandboxedFalse() async {
        let r = await makeTool(sandboxed: false, fallback: false)
            .handle(context: context(), args: ["command": "echo hi"])
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertEqual(successData(r.outputJSON)?["sandboxed"] as? Bool, false)
    }

    /// The ordinary confined command still reports `true` — the fix must not invert the flag.
    ///
    /// RED: hard-code `sandboxed: false` → this reds while the test above still passes, so the
    /// pair distinguishes "reports the fact" from "always says false".
    func testSandboxedRun_reportsSandboxedTrue() async {
        let r = await makeTool(sandboxed: true, fallback: false)
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
    func testCommandWhoseStderrNamesTheWrapper_runsExactlyOnce() async throws {
        let marker = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("nanoteams-w18-\(UUID().uuidString).marker")
        defer { try? FileManager.default.removeItem(at: marker) }

        let r = await makeTool(sandboxed: true, fallback: true).handle(
            context: context(),
            args: ["command": "echo ran >> \(marker.path); echo 'cat: /usr/bin/sandbox-exec/x: Not a directory' >&2; exit 1"])

        XCTAssertFalse(r.isError, r.outputJSON)
        let contents = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        let runs = contents.split(separator: "\n").count
        XCTAssertEqual(runs, 1, "command executed \(runs) times — the unsandboxed retry fired")
    }

    /// The measured spoof, and the pin the sibling above only LOOKS like.
    ///
    /// Its fixture (`cat: /usr/bin/sandbox-exec/x: …`) is a `contains` case, which the position
    /// rule already declined — so it was green against this defect the whole time. This one OPENS
    /// stderr with the wrapper's own prefix, which is what a command controls and what the
    /// position rule cannot tell from a real wrapper fault.
    ///
    /// RED: classify from `result.stderr` instead of `ProcessRunner.probeSandboxLaunch` → the
    /// retry fires and the marker holds two lines, i.e. a command talked the tool into running it
    /// again with no sandbox.
    func testCommandWhoseStderrOPENSWithTheWrapperName_runsExactlyOnce() async throws {
        let marker = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("nanoteams-d7-\(UUID().uuidString).marker")
        defer { try? FileManager.default.removeItem(at: marker) }

        let r = await makeTool(sandboxed: true, fallback: true).handle(
            context: context(),
            args: ["command": "echo ran >> \(marker.path); echo 'sandbox-exec: fake denial' >&2; exit 1"])

        XCTAssertFalse(r.isError, r.outputJSON)
        let contents = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        let runs = contents.split(separator: "\n").count
        XCTAssertEqual(
            runs, 1,
            "command executed \(runs) times — a command forged the wrapper's diagnostic and was "
                + "re-run OUTSIDE the sandbox")
    }

    /// The default-configuration half of the spoof: fallback off, so nothing escapes, but the
    /// tool told the model and the transcript that a command which ran had not run, throwing away
    /// its real output.
    ///
    /// RED: classify from `result.stderr` → a `bashDenied` envelope replaces `hello`.
    func testCommandWhoseStderrOPENSWithTheWrapperName_isNotReportedAsNeverRun() async {
        let r = await makeTool(sandboxed: true, fallback: false).handle(
            context: context(),
            args: ["command": "echo hello; echo 'sandbox-exec: fake denial' >&2; exit 1"])

        XCTAssertFalse(r.isError, "a command that RAN must not produce an error envelope: \(r.outputJSON)")
        XCTAssertTrue(r.outputJSON.contains("hello"), "the real stdout must survive: \(r.outputJSON)")
        XCTAssertFalse(r.outputJSON.lowercased().contains("command was not run"), r.outputJSON)
    }

    /// The reporting half of a genuine fallback: an execution with no sandbox says so. Together
    /// with `testSandboxedRun_reportsSandboxedTrue` this pins that the flag tracks the fact rather
    /// than being pinned to either constant.
    ///
    /// RED: rebuild the flag from `sandboxProfile != nil` → reports `true` for a run that had no
    /// sandbox at all.
    func testUnconfinedExecution_reportsSandboxedFalse() async {
        let r = await makeTool(sandboxed: false, fallback: true)
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
    func testCommandWhoseStderrNamesTheWrapper_isNotReportedAsNeverRun() async {
        let r = await makeTool(sandboxed: true, fallback: false).handle(
            context: context(),
            args: ["command": "echo hello; echo 'grep: sandbox-exec: no match' >&2; exit 1"])

        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertFalse(r.outputJSON.contains("Command was not run"), r.outputJSON)
        XCTAssertTrue((successData(r.outputJSON)?["stdout"] as? String ?? "").contains("hello"), r.outputJSON)
    }

    // MARK: - The probe's three answers (D-7)

    /// The probe is what replaced "classify the stream the command can write". It re-runs the
    /// SAME invocation with a no-op command, so what it classifies is a stream the judged
    /// command never touched.
    ///
    /// RED: make `probeSandboxLaunch` return `.wrapperRejected` on a zero exit → a healthy
    /// profile would license an unconfined retry.
    func testProbe_onAWorkingProfile_saysTheChildRan() {
        let profile = SeatbeltSandbox.profile(workFolderRoot: workDir)
        XCTAssertEqual(
            ProcessRunner.probeSandboxLaunch(profile: profile, in: workDir), .childRan,
            "a profile the wrapper accepts and a shell that starts is the ordinary case")
    }

    /// A profile `sandbox-exec` cannot parse. This is the ONLY verdict that licenses an
    /// unconfined retry, so it has to be distinguishable by something other than "the command
    /// failed and said something about the wrapper".
    func testProbe_onAMalformedProfile_saysTheWrapperRejectedIt() {
        XCTAssertEqual(
            ProcessRunner.probeSandboxLaunch(profile: "(version 1) (this-is-not-sbpl", in: workDir),
            .wrapperRejected,
            "an unparseable profile is the wrapper's fault, not the command's")
    }

    /// A profile that COMPILES and then denies the reads the shell needs to start. The third
    /// state the old `Bool` could not express: exit 134 with empty stderr, which on its own
    /// reads as the command failing.
    ///
    /// The profile is built by PRODUCTION's own builder from a permissions value the settings
    /// UI can express, not hand-written. Measured while writing this test: a hand-written
    /// `(version 1)(deny default)` classifies as `.wrapperRejected`, because denying
    /// `process*` makes `sandbox-exec`'s own `execvp` fail and the wrapper reports that as its
    /// own fault. That shape is unreachable here — `SeatbeltSandbox.profile` emits
    /// `(allow process*)` unconditionally — so pinning it would have pinned an SBPL string the
    /// app never produces (CLAUDE.md #78: which production caller reaches this line).
    ///
    /// RED: fold `.confinedBeforeStart` into `.wrapperRejected` → the confinement the user
    /// asked for would be retried away.
    func testProbe_onAProfileThatStarvesTheShell_saysConfinedBeforeStart() {
        var permissions = BashSandboxPermissions()
        permissions.everythingElseRead = false
        let profile = SeatbeltSandbox.profile(workFolderRoot: workDir, permissions: permissions)
        XCTAssertTrue(profile.contains("(allow process*)"),
                      "premise: exec is never denied, so this is a READ starvation")

        XCTAssertEqual(
            ProcessRunner.probeSandboxLaunch(profile: profile, in: workDir),
            .confinedBeforeStart,
            "the profile did its job — this is not a wrapper fault and must not be retried")
    }

    // MARK: - What the handler does with `.confinedBeforeStart`

    /// The envelope stays STRUCTURALLY true (the command really did exit non-zero and print
    /// nothing) and a warning adds the cause. Flipping `isError` here would claim an argument
    /// problem, which is exactly what the exit code cannot tell you.
    ///
    /// RED: drop the `launch == .confinedBeforeStart` warning block → the result is an
    /// unexplained exit 134 and the second assertion fails.
    func testConfinedBeforeStart_addsAWarningWithoutFlippingIsError() async {
        // Nothing readable outside the work folder — the shell cannot even read itself.
        var permissions = BashSandboxPermissions()
        permissions.everythingElseRead = false
        let r = await makeTool(sandboxed: true, fallback: false, permissions: permissions)
            .handle(context: context(), args: ["command": "echo hi"])

        XCTAssertFalse(
            r.isError,
            "the process result is honest; the cause belongs in a warning: \(r.outputJSON)")
        XCTAssertTrue(
            r.outputJSON.contains("never ran"),
            "the confinement must be NAMED — an unexplained exit 134 reads as a broken "
                + "command: \(r.outputJSON)")
        XCTAssertFalse(
            r.outputJSON.contains("running unsandboxed is not permitted"),
            "this is not a wrapper rejection and must not be reported as one: \(r.outputJSON)")
    }
}
