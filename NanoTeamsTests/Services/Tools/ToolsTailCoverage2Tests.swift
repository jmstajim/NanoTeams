import XCTest

@testable import NanoTeams

// MARK: - Process launch / drain

/// The subprocess arms of `ProcessRunner` + `BackgroundBashRegistry` + `BashTool`
/// that no existing suite reaches, and the defect one of them was hiding.
///
/// **Defect found here (fixed in this pass).** Both spawn sites answered EVERY
/// `Process.run()` failure with `ProcessRunnerError.executableNotFound(executable)`.
/// `Process.run()` throws for reasons that have nothing to do with the executable
/// — measured 2026-08-08 against Foundation:
///
/// * a `currentDirectoryURL` that does not exist → `NSCocoaErrorDomain 4`
/// * a `currentDirectoryURL` the caller cannot search (mode `0o000`) → `NSPOSIXErrorDomain 13`
///
/// Both surfaced to the model as **"Executable not found: /bin/zsh"** — a false
/// statement about the one component that is definitely fine, pointing the reader
/// at a missing login shell instead of at `working_directory`. The second case is
/// reachable straight through the `bash` tool: the handler checks `fileExists`
/// before spawning, and an unsearchable directory passes that check.
///
/// Real subprocesses throughout; every fixture lives under `NSTemporaryDirectory()`.
final class FToolsProcessLaunchTests: XCTestCase {

    private var workDir: URL!
    private var lockedDir: URL!
    /// Unique per instance so `terminate(taskID:)` in tearDown can never reap a
    /// background command belonging to another suite sharing the singleton.
    private var taskID: Int!

    override func setUpWithError() throws {
        try super.setUpWithError()
        taskID = Int.random(in: 900_000...999_999)
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ftools-launch-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let taskID { BackgroundBashRegistry.shared.terminate(taskID: taskID) }
        // A 0o000 directory cannot be removed until it is searchable again;
        // skipping this leaves the whole fixture tree behind.
        if let lockedDir {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        }
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        lockedDir = nil
        workDir = nil
        taskID = nil
        try super.tearDownWithError()
    }

    /// Creates a directory that `fileExists(atPath:isDirectory:)` reports as a real
    /// directory but that no process can `chdir` into.
    private func makeLockedDirectory() throws -> URL {
        let dir = workDir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: dir.path)
        lockedDir = dir
        return dir
    }

    private func makeTool(
        sandboxEnabled: Bool = false,
        permissions: BashSandboxPermissions = BashSandboxPermissions()
    ) -> BashTool {
        BashTool(
            workFolderRoot: workDir,
            resolver: SandboxPathResolver(workFolderRoot: workDir),
            fileManager: .default,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: permissions,
            allowUnsandboxedFallback: false)
    }

    private func context() -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: workDir, taskID: taskID, runID: 0, roleID: "r")
    }

    // MARK: - The misreported spawn failure

    /// DEFECT (fixed): the directory is unsearchable, not the shell missing.
    ///
    /// RED: revert `ProcessRunner.run`'s catch to
    /// `throw ProcessRunnerError.executableNotFound(executable)` -> the
    /// `case .launchFailed` unwrap fails ("expected .launchFailed").
    func testRun_unsearchableWorkingDirectory_isNotReportedAsAMissingExecutable() async throws {
        try XCTSkipIf(getuid() == 0, "running as root bypasses directory permissions")
        let locked = try makeLockedDirectory()
        let shell = ProcessRunner.loginShell()

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell),
                      "precondition: the login shell must really be runnable")

        var captured: Error?
        XCTAssertThrowsError(
            try ProcessRunner.run(
                executable: shell, arguments: ["-lc", "echo hi"], currentDirectory: locked)
        ) { captured = $0 }

        guard let runnerError = captured as? ProcessRunnerError else {
            return XCTFail("expected a ProcessRunnerError, got \(String(describing: captured))")
        }
        guard case let .launchFailed(executable, reason) = runnerError else {
            return XCTFail("expected .launchFailed, got \(runnerError)")
        }
        XCTAssertEqual(executable, shell)
        XCTAssertFalse(reason.isEmpty, "the underlying reason must be preserved, not discarded")

        let rendered = try XCTUnwrap(runnerError.errorDescription)
        XCTAssertFalse(
            rendered.contains("Executable not found"),
            "the shell exists — claiming otherwise sends the reader to the wrong place: \(rendered)")
        XCTAssertTrue(rendered.contains("working directory"),
                      "the message must name the real suspect: \(rendered)")
    }

    /// The classifier must NOT over-correct: a genuinely absent executable keeps
    /// the accurate `executableNotFound`, and so does a DIRECTORY passed as the
    /// executable (`isExecutableFile` answers `true` for directories on macOS —
    /// the `x` bit means "searchable" — so an `isExecutableFile`-only gate would
    /// have re-labelled that case).
    ///
    /// RED: drop the `!isDir.boolValue` term from `ProcessRunner.launchError` ->
    /// the directory case reports `.launchFailed` and the second unwrap fails.
    func testLaunchError_keepsExecutableNotFoundForAMissingBinaryAndForADirectory() async throws {
        let missing = ProcessRunner.launchError(
            executable: workDir.appendingPathComponent("nope").path,
            underlying: CocoaError(.fileNoSuchFile))
        guard case ProcessRunnerError.executableNotFound = missing else {
            return XCTFail("a missing binary must stay executableNotFound, got \(missing)")
        }

        let directory = ProcessRunner.launchError(
            executable: workDir.path, underlying: CocoaError(.fileNoSuchFile))
        guard case ProcessRunnerError.executableNotFound = directory else {
            return XCTFail("a directory-as-executable must stay executableNotFound, got \(directory)")
        }
    }

    /// End-to-end through the tool the model actually calls. `bash` validates that
    /// `working_directory` exists (it does) and then hands it to the spawn (which
    /// cannot chdir into it), so this is a live production path, not a synthetic one.
    ///
    /// RED: revert either spawn-site catch -> `Executable not found` reappears in
    /// the envelope and the `XCTAssertFalse(... contains ...)` fires.
    func testBashForeground_unsearchableWorkingDirectory_envelopeBlamesTheDirectory() async throws {
        try XCTSkipIf(getuid() == 0, "running as root bypasses directory permissions")
        _ = try makeLockedDirectory()

        let result = makeTool().handle(
            context: context(), args: ["command": "echo hi", "working_directory": "locked"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertFalse(
            result.outputJSON.contains("Executable not found"),
            "the login shell is present; the envelope must not say otherwise: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("working directory"),
                      "got: \(result.outputJSON)")
    }

    /// Same failure through the BACKGROUND branch, which has its own spawn-site
    /// catch and its own envelope (`BashHandlers` "Failed to start background
    /// command: …"). Both had the identical misreport.
    ///
    /// RED: revert `BackgroundBashRegistry.start`'s catch -> the envelope reads
    /// "Failed to start background command: Executable not found: /bin/zsh".
    func testBashBackground_unsearchableWorkingDirectory_reportsTheRealReason() async throws {
        try XCTSkipIf(getuid() == 0, "running as root bypasses directory permissions")
        _ = try makeLockedDirectory()

        let result = makeTool().handle(
            context: context(),
            args: ["command": "echo hi", "working_directory": "locked", "run_in_background": true])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("Failed to start background command"),
                      "must come from the background arm: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("Executable not found"),
                       "got: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("command_id"),
                       "a failed start must not hand back an id to poll: \(result.outputJSON)")
    }

    /// The failed start must leave nothing behind: the log file it pre-created is
    /// deleted and no entry is retained (a `command_id` that never ran would make
    /// `bash_output` report a phantom running command).
    ///
    /// RED: delete `try? fm.removeItem(at: outputURL)` from the catch -> an orphan
    /// `bg_N.log` survives the failed start and the subtraction is non-empty.
    func testBackgroundStart_spawnFailure_leavesNoLogFileBehind() async throws {
        try XCTSkipIf(getuid() == 0, "running as root bypasses directory permissions")
        let locked = try makeLockedDirectory()
        let logDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nanoteams-bg", isDirectory: true)
        func logNames() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: logDir.path)) ?? [])
        }
        let before = logNames()

        XCTAssertThrowsError(
            try BackgroundBashRegistry.shared.start(
                command: "echo hi", directory: locked, sandboxProfile: nil, taskID: taskID)
        )

        // Set subtraction, not a count: the log dir is process-wide, so an unrelated
        // stale file disappearing between the two reads must not fail this.
        XCTAssertTrue(
            logNames().subtracting(before).isEmpty,
            "the pre-created log file must be cleaned up on a failed start")
    }

    // MARK: - Sandboxed background command

    /// `BackgroundBashRegistry.start`'s `sandboxProfile` branch — the only arm that
    /// routes a detached command through `SeatbeltSandbox.wrap`.
    ///
    /// The discriminator is a READ that the default profile denies
    /// (`credentialRead: false` denies `~/Library/Keychains`) and that succeeds
    /// unwrapped. Chosen over a write probe because it touches nothing: measured
    /// 2026-08-08, sandboxed prints NOREAD, unsandboxed prints READ.
    ///
    /// RED: make the `if let profile` branch fall through to the unwrapped
    /// `(shell, ["-lc", command])` -> the log reads READ and the assertion fires.
    func testBackgroundStart_withSandboxProfile_actuallyConfinesTheCommand() async throws {
        let keychains = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Keychains", isDirectory: true)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: keychains.path),
            "discriminator requires ~/Library/Keychains to exist")
        try XCTSkipIf(getuid() == 0, "root is not confined by the read deny")

        let profile = SeatbeltSandbox.profile(workFolderRoot: workDir)
        let command = "ls \"$HOME/Library/Keychains\" >/dev/null 2>&1 && echo READ || echo NOREAD"

        let id = try BackgroundBashRegistry.shared.start(
            command: command, directory: workDir, sandboxProfile: profile, taskID: taskID)

        let output = try await drain(commandID: id)
        XCTAssertTrue(output.contains("NOREAD"),
                      "a sandboxed background command must be confined; got: \(output.debugDescription)")
    }

    /// Polls `read(commandID:)` until the command finishes, accumulating the
    /// incremental output. Fails rather than hanging if it never terminates.
    private func drain(commandID: String, timeout: TimeInterval = 20) async throws -> String {
        var accumulated = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = try XCTUnwrap(
                BackgroundBashRegistry.shared.read(commandID: commandID),
                "registry forgot \(commandID)")
            accumulated += snapshot.newOutput
            if !snapshot.running {
                // One last read: the termination handler can fire before the final
                // bytes are flushed to the log.
                try await Task.sleep(for: .milliseconds(100))
                accumulated += BackgroundBashRegistry.shared.read(commandID: commandID)?.newOutput ?? ""
                return accumulated
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("background command \(commandID) never finished")
        return accumulated
    }

    // MARK: - Bounded pipe drain

    /// `ProcessRunner.run`'s bounded drain. The child exits immediately but
    /// backgrounds a `sleep` that INHERITS the stdout pipe, so `readDataToEndOfFile`
    /// (which waits for the LAST writer) would otherwise block for the grandchild's
    /// whole lifetime and hang the cooperative pool on every cancelled run.
    ///
    /// Two things are asserted because the arm has two halves: it must give up
    /// (bounded), and it must still hand back the bytes that were already flushed
    /// (forced close, not abandonment). Measured 2026-08-08: the drain gives up at
    /// ~5.0 s and the closes unwind the blocked readers cleanly.
    ///
    /// RED (bound): replace the timed `pipeGroup.wait(timeout:)` with a plain
    /// `pipeGroup.wait()` -> elapsed grows to the grandchild's 25 s and the
    /// `elapsed < 15` assertion fires.
    /// RED (partial output): delete the two `close()` calls -> the readers never
    /// unwind, the boxes are still empty when read, and `stdout` is "".
    func testRun_grandchildHoldsThePipe_drainIsBoundedAndKeepsWhatWasFlushed() async throws {
        let shell = ProcessRunner.loginShell()
        let started = Date()
        let result = try ProcessRunner.run(
            executable: shell,
            arguments: ["-lc", "echo FLUSHED-BEFORE-EXIT; sleep 25 & exit 0"],
            currentDirectory: workDir,
            timeout: 120)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, 15,
            "the drain must be bounded — the grandchild holds the pipe for 25 s")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.stdout.contains("FLUSHED-BEFORE-EXIT"),
            "output flushed before the forced close must survive it: \(result.stdout.debugDescription)")
    }

    // MARK: - SystemXcodebuildRunner

    /// The production `XcodebuildRunning` adapter. Its own doc comment calls it
    /// unreachable from a test "because covering it means spawning a build" — but
    /// `-version` is not a build (measured: 0.04 s), so the forwarding CAN be
    /// checked, and forwarding is the only thing the adapter does.
    ///
    /// Differential rather than absolute: comparing the adapter's output against
    /// `ProcessRunner.runXcodebuild`'s own output pins "this runs xcodebuild"
    /// without depending on whether a developer directory is selected (both sides
    /// then carry the same xcode-select error).
    ///
    /// RED: point the adapter at `ProcessRunner.runGit` -> the outputs diverge
    /// ("git version …" vs xcodebuild's) and the equality assertion fires.
    func testSystemXcodebuildRunner_forwardsToXcodebuild() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/xcodebuild"),
            "xcodebuild is not installed on this machine")

        let direct = try ProcessRunner.runXcodebuild(["-version"], in: workDir, timeout: 60)
        let viaAdapter = try SystemXcodebuildRunner().run(["-version"], in: workDir, timeout: 60)

        try XCTSkipIf(
            direct.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "xcodebuild produced no output here — nothing to compare")
        XCTAssertEqual(viaAdapter.combinedOutput, direct.combinedOutput,
                       "the adapter must run the same binary with the same arguments")
        XCTAssertEqual(viaAdapter.exitCode, direct.exitCode)
    }
}

// MARK: - Git handler failure arms

/// The `git_commit` / `git_pull` / `git_diff` arms `ToolsGitTests`,
/// `ToolsGitPullMergeTests` and `GitHandlerTailTests` do not reach. Real temp
/// repos driven through `ToolRuntime`; no network (nothing here needs a remote).
///
/// Every git behaviour asserted was measured against the installed git before the
/// assertion was written.
final class FToolsGitTailTests: XCTestCase {

    private var repoDir: URL!
    private var plainDir: URL!
    private var runtime: ToolRuntime!
    private var plainRuntime: ToolRuntime!
    private var repoContext: ToolExecutionContext!
    private var plainContext: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        repoDir = try makeDir(prefix: "ftools-git-repo")
        plainDir = try makeDir(prefix: "ftools-git-plain")

        try initRepo(at: repoDir)
        (runtime, repoContext) = try makeRuntime(for: repoDir)
        (plainRuntime, plainContext) = try makeRuntime(for: plainDir)
    }

    override func tearDownWithError() throws {
        if let repoDir { try? FileManager.default.removeItem(at: repoDir) }
        if let plainDir { try? FileManager.default.removeItem(at: plainDir) }
        repoDir = nil
        plainDir = nil
        runtime = nil
        plainRuntime = nil
        repoContext = nil
        plainContext = nil
        try super.tearDownWithError()
    }

    // MARK: - git_commit

    /// `git_commit` in a folder with no repository. Every other git tool routes
    /// this to the "skip git for this run" guidance; the commit arm must too, or a
    /// model in a non-git folder keeps retrying a commit that can never work.
    ///
    /// RED: replace the `isNotARepository` branch with the generic
    /// `makeErrorResult(... message: errorMsg)` -> git's raw "not a git repository
    /// (or any of the parent directories)" ships and the guidance assertion fires.
    func testGitCommit_inANonRepository_returnsTheSkipGitGuidance() async throws {
        let result = try call(
            ToolNames.gitCommit, ["message": "x"],
            runtime: plainRuntime, context: plainContext)

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("Skip all git_* tools"),
                      "must be the actionable guidance, not git's raw fatal: \(result.outputJSON)")
        // Anchored on a phrase ONLY git's raw message carries: "not a git
        // repository" appears in the correct envelope too, so asserting that alone
        // would pass for the generic passthrough this branch exists to replace.
        XCTAssertFalse(result.outputJSON.contains("or any of the parent directories"),
                       "git's raw fatal must not be what ships: \(result.outputJSON)")
    }

    /// The third `git_commit` failure class: neither "not a repository" nor
    /// "nothing to commit". `git commit --amend` on a repo with no commits exits
    /// non-zero with "fatal: You have nothing to amend." (measured). That reason is
    /// the ONLY thing that tells the model what went wrong, so it must be passed
    /// through rather than collapsed into a bare "commit failed".
    ///
    /// RED: replace `message: errorMsg` with a fixed string -> the
    /// "nothing to amend" assertion fires.
    func testGitCommit_amendWithNoCommits_passesGitsOwnReasonThrough() async throws {
        let result = try call(ToolNames.gitCommit, ["message": "x", "amend": true])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("COMMAND_FAILED"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("nothing to amend"),
                      "git's reason must survive: \(result.outputJSON)")
        // Anti-miscoding: this is NOT the "nothing to commit" class, which carries
        // CONFLICT and a different remedy.
        XCTAssertFalse(result.outputJSON.contains("Nothing to commit"), result.outputJSON)
    }

    // MARK: - git_pull

    /// `git_pull`'s classifier branch. A pull in a non-repository is the one pull
    /// failure `GitErrorClassifier.classify` recognises, and it must produce the
    /// same skip-git guidance as every other git tool rather than the generic
    /// COMMAND_FAILED passthrough one line below it.
    ///
    /// RED: make `classify` return nil (or drop the `if let classified` branch) ->
    /// the envelope carries git's raw fatal and the guidance assertion fires.
    func testGitPull_inANonRepository_usesTheClassifierNotTheGenericArm() async throws {
        let result = try call(
            ToolNames.gitPull, ["remote": "origin"],
            runtime: plainRuntime, context: plainContext)

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("Skip all git_* tools"),
                      "the classified branch must win: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("or any of the parent directories"),
                       "the generic passthrough arm must not be what ships: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("\"success\""),
                       "a failed pull must not emit the success-shaped payload: \(result.outputJSON)")
    }

    // MARK: - git_diff

    /// `git_diff`'s non-not-a-repo failure arm. An invalid pathspec magic exits 128
    /// with "fatal: Invalid pathspec magic 'zzz'" (measured), and `:`-prefixed
    /// pathspecs are deliberately passed through `relativizePathspec` unchanged, so
    /// this reaches git verbatim.
    ///
    /// RED: replace `message: result.stderr` with a fixed string -> the
    /// "Invalid pathspec magic" assertion fires.
    func testGitDiff_invalidPathspecMagic_reportsGitsReasonAndNoDiff() async throws {
        let result = try call(ToolNames.gitDiff, ["paths": [":(zzz)x"]])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("COMMAND_FAILED"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("Invalid pathspec magic"),
                      "git's reason must survive: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("files_changed"),
                       "a failed diff must not emit a diff payload: \(result.outputJSON)")
    }

    /// `git_diff`'s untracked-files probe failing while the diff itself succeeds.
    /// Pointing `core.excludesFile` at a DIRECTORY makes `git ls-files --others
    /// --exclude-standard` die with "fatal: cannot use … as an exclude file" while
    /// `git diff` is unaffected (measured) — the exact asymmetry the warning arm
    /// exists for.
    ///
    /// The honest behaviour has two halves and both are asserted: the probe's
    /// failure is SURFACED (not swallowed), and `untracked_files` stays empty
    /// rather than claiming "there are none". The control run first proves the
    /// probe would otherwise have found the file, so the empty list is genuinely
    /// "could not tell" and this test is not vacuous.
    ///
    /// RED: drop the `warnings.append(...)` in the `else` -> the warning assertion
    /// fires and the envelope silently reports zero untracked files.
    func testGitDiff_untrackedProbeFailure_isWarnedNotSilentlyReportedAsNone() async throws {
        try seedCommit(named: "base.txt", contents: "base\n", message: "base")
        try Data("u\n".utf8).write(to: repoDir.appendingPathComponent("untracked.txt"))

        // Control: the probe works and DOES see the file.
        let healthy = try dataOf(ToolNames.gitDiff, [:])
        let seen = try XCTUnwrap(healthy["untracked_files"] as? [String])
        XCTAssertTrue(seen.contains("untracked.txt"),
                      "control run must see the untracked file, got: \(seen)")

        // Break only the probe.
        let excludeDir = repoDir.appendingPathComponent("excl-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: excludeDir, withIntermediateDirectories: true)
        try git(["config", "core.excludesFile", excludeDir.path], in: repoDir)

        let result = try call(ToolNames.gitDiff, [:])
        XCTAssertFalse(result.isError, "the diff itself still succeeded: \(result.outputJSON)")

        let envelope = try envelopeOf(result)
        let meta = try XCTUnwrap(envelope["meta"] as? [String: Any], result.outputJSON)
        let warnings = try XCTUnwrap(meta["warnings"] as? [String], result.outputJSON)
        XCTAssertTrue(
            warnings.contains { $0.contains("untracked_files probe failed") },
            "the probe's failure must be surfaced: \(warnings)")

        let data = try XCTUnwrap(envelope["data"] as? [String: Any], result.outputJSON)
        let untracked = try XCTUnwrap(data["untracked_files"] as? [String], result.outputJSON)
        XCTAssertTrue(untracked.isEmpty,
                      "a failed probe must not invent an answer: \(untracked)")
    }

    // MARK: - Harness

    private func makeDir(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRuntime(for dir: URL) throws -> (ToolRuntime, ToolExecutionContext) {
        let paths = NTMSPaths(workFolderRoot: dir)
        try FileManager.default.createDirectory(
            at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: dir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0))
        return (run, ToolExecutionContext(
            workFolderRoot: dir, taskID: 0, runID: 0, roleID: "ftools_role"))
    }

    private func initRepo(at directory: URL) throws {
        try git(["init", "-b", "main"], in: directory)
        try git(["config", "user.email", "ftools@example.com"], in: directory)
        try git(["config", "user.name", "FTools"], in: directory)
        // Never inherit the developer's global config: a signing key fails every
        // commit and an unset pull.rebase makes git refuse a divergent pull.
        try git(["config", "commit.gpgsign", "false"], in: directory)
        try git(["config", "pull.rebase", "false"], in: directory)
    }

    private func seedCommit(named name: String, contents: String, message: String) throws {
        try Data(contents.utf8).write(to: repoDir.appendingPathComponent(name))
        try git(["add", name], in: repoDir)
        try git(["commit", "-m", message], in: repoDir)
    }

    private func call(
        _ tool: String,
        _ args: [String: Any],
        runtime overrideRuntime: ToolRuntime? = nil,
        context overrideContext: ToolExecutionContext? = nil
    ) throws -> ToolExecutionResult {
        let payload = try JSONSerialization.data(withJSONObject: args)
        let json = try XCTUnwrap(String(data: payload, encoding: .utf8))
        let calls = [StepToolCall(name: tool, argumentsJSON: json)]
        let results = (overrideRuntime ?? runtime!)
            .executeAll(context: overrideContext ?? repoContext!, toolCalls: calls)
        return try XCTUnwrap(results.first, "runtime returned no result for \(tool)")
    }

    private func envelopeOf(_ result: ToolExecutionResult) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
        return try XCTUnwrap(object as? [String: Any], "not an object: \(result.outputJSON)")
    }

    private func dataOf(_ tool: String, _ args: [String: Any]) throws -> [String: Any] {
        let result = try call(tool, args)
        XCTAssertFalse(result.isError, "expected success, got \(result.outputJSON)")
        let envelope = try envelopeOf(result)
        return try XCTUnwrap(envelope["data"] as? [String: Any], result.outputJSON)
    }

    @discardableResult
    private func git(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            XCTFail("fixture `git \(args.joined(separator: " "))` failed "
                + "(exit \(process.terminationStatus)): \(output)")
        }
        return output
    }
}

// MARK: - ToolRuntime argument normalization

/// `ToolRuntime.parseAndNormalizeArguments`' two unreached arms: a top-level JSON
/// value that parses but is not an object, and a key that needs trimming.
final class FToolsToolRuntimeArgumentTests: XCTestCase {

    private var workDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ftools-runtime-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: workDir)
        try FileManager.default.createDirectory(
            at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: workDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0))
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: workDir, taskID: 0, runID: 0, roleID: "ftools_role")
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        runtime = nil
        context = nil
        try super.tearDownWithError()
    }

    private func run(_ tool: String, rawArgs: String) throws -> ToolExecutionResult {
        let results = runtime.executeAll(
            context: context, toolCalls: [StepToolCall(name: tool, argumentsJSON: rawArgs)])
        return try XCTUnwrap(results.first)
    }

    /// A JSON ARRAY is valid JSON, so it never reaches the `__raw_input__` wrapper
    /// (which only catches un-parseable text) — it lands on the not-an-object
    /// guard. The model must be told the expected SHAPE; a bare "failed" leaves it
    /// re-emitting the same array.
    ///
    /// RED: change the guard to `argsAny as? [String: Any] ?? [:]` -> the tool runs
    /// with empty args, reports a missing `path`, and the "must be a JSON object"
    /// assertion fires.
    func testExecute_jsonArrayArguments_rejectedWithTheExpectedShape() async throws {
        let result = try run(ToolNames.readFile, rawArgs: "[1,2,3]")

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("must be a JSON object"),
                      "the model needs the shape, not just a failure: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("execution_failed"), result.outputJSON)
    }

    /// Keys arrive from models with stray whitespace/newlines. The trim is a
    /// silent auto-fix, so the only observable is that the tool BEHAVES as if the
    /// key were clean — asserted on the file content, not on the args dictionary.
    ///
    /// RED: delete the `if key != trimmedKey` rewrite -> `path` is missing and the
    /// call fails with INVALID_ARGS instead of returning the file.
    func testExecute_whitespacePaddedKey_isTrimmedAndTheToolSeesIt() async throws {
        let file = workDir.appendingPathComponent("padded.txt")
        try Data("PADDED-KEY-CONTENT\n".utf8).write(to: file)

        let result = try run(
            ToolNames.readFile, rawArgs: #"{" \npath\t ": "padded.txt"}"#)

        XCTAssertFalse(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("PADDED-KEY-CONTENT"), result.outputJSON)
    }
}

// MARK: - Pure helpers

/// Pure arms: the Seatbelt narrow-read credential grant, the quoted-program
/// extraction the deny layer depends on, the total-by-contract envelope encoder,
/// and `forward_to_team`'s missing-argument guard.
final class FToolsPureTailTests: XCTestCase {

    // MARK: - SeatbeltSandbox: narrow read + credential grant

    /// The narrow-read branch (`everythingElseRead: false`) with credential reads
    /// ENABLED. This is the only path that puts the credential paths into an ALLOW
    /// clause; every other combination either denies them or leaves them to the
    /// broad allow.
    ///
    /// The assertion is scoped rather than a bare `contains(".ssh")`: `.ssh`
    /// appears in the deny clause of the sibling configuration too, so a substring
    /// test would pass for the wrong profile.
    ///
    /// RED: delete the `if permissions.credentialRead { readSubpaths.append(...) }`
    /// block -> `.ssh` disappears from the read-allow clause and the first
    /// assertion fires.
    func testProfile_narrowRead_withCredentialReadOn_grantsTheCredentialPaths() async throws {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ftools-seatbelt", isDirectory: true)
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath().standardizedFileURL.path
        let ssh = "\(home)/.ssh"
        let netrc = "\(home)/.netrc"

        let granted = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(
                credentialRead: true, homeRead: false, everythingElseRead: false))

        let readAllow = try XCTUnwrap(
            Self.clause(startingWith: "(allow file-read*", in: granted),
            "narrow read must still emit a read-allow clause: \(granted)")
        XCTAssertTrue(readAllow.contains("(subpath \"\(ssh)\")"),
                      "credential subpaths must be granted: \(readAllow)")
        XCTAssertTrue(readAllow.contains("(literal \"\(netrc)\")"),
                      "credential literals must be granted too: \(readAllow)")
        XCTAssertNil(Self.clause(startingWith: "(deny file-read*", in: granted),
                     "nothing left to deny once credentials are granted: \(granted)")

        // The sibling configuration is what makes the assertions above meaningful:
        // with the grant off, the same paths must NOT appear in a read-allow.
        let withheld = SeatbeltSandbox.profile(
            workFolderRoot: work,
            permissions: BashSandboxPermissions(
                credentialRead: false, homeRead: false, everythingElseRead: false))
        let withheldAllow = Self.clause(startingWith: "(allow file-read*", in: withheld) ?? ""
        XCTAssertFalse(withheldAllow.contains(ssh),
                       "credentials must not be readable when the toggle is off: \(withheldAllow)")
    }

    /// Returns the SBPL clause beginning with `prefix` (clauses are joined by "\n"
    /// and each begins at column 0, so the next column-0 "(" ends it).
    private static func clause(startingWith prefix: String, in profile: String) -> String? {
        guard let start = profile.range(of: prefix) else { return nil }
        let rest = String(profile[start.lowerBound...])
        var lines: [String] = []
        for (index, line) in rest.components(separatedBy: "\n").enumerated() {
            if index > 0 && line.hasPrefix("(") { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - BashPermissionService: quoted program extraction

    /// `stripQuotes`' strip arm. `tokenize` already removes the OUTER quote pair,
    /// so a token still wrapped in quotes only arises from nesting — `"'rm'"` —
    /// which is exactly the shape a deny rule must not be fooled by.
    ///
    /// Asserted through `evaluate` because the security consequence is the point:
    /// without the strip the program reads as `'rm'`, matches no bare-program deny
    /// rule, and the command downgrades from DENY to a review.
    ///
    /// RED: make `stripQuotes` return `s` unchanged -> `leadingProgram` yields
    /// `'rm'`, `evaluate` returns `.ask`, and both assertions fire.
    func testEvaluate_nestedQuotedProgram_stillMatchesTheBareProgramDenyRule() async throws {
        XCTAssertEqual(BashPermissionService.leadingProgram(of: "\"'rm'\" -rf x"), "rm")

        let policy = BashPolicy(
            mode: .auto, restrictionLevel: .standard, denyRules: ["rm"])
        let decision = BashPermissionService.evaluate(command: "\"'rm'\" -rf x", policy: policy)

        guard case .deny = decision else {
            return XCTFail("quoting must not launder a denied program, got \(decision)")
        }
    }

    /// The strip must be exactly one MATCHING pair — a token that merely starts or
    /// ends with a quote keeps it, or `leadingProgram` would corrupt real names.
    ///
    /// RED: weaken the pairing to `first == "\"" || last == "\""` -> `"rm` is
    /// stripped to `r` and the first assertion fires.
    func testLeadingProgram_unbalancedQuoteIsNotStripped() async throws {
        // `\"` survives tokenize as a literal quote character (escape processing
        // emits it), so the token really does start with a quote and not end with one.
        XCTAssertEqual(BashPermissionService.leadingProgram(of: #"\"rm -rf x"#), "\"rm")
        XCTAssertEqual(BashPermissionService.leadingProgram(of: "a"), "a")
    }

    // MARK: - Envelope encoder is total

    /// `encodeToJSON`'s failure arm. Every caller treats the result as a JSON
    /// string it can hand to the model unconditionally, so a throwing payload must
    /// still yield parseable JSON rather than an empty string or a crash.
    ///
    /// RED: change the `else` to `return ""` -> the JSON parse below fails.
    func testMakeSuccessEnvelope_unencodablePayload_stillReturnsParseableJSON() async throws {
        let json = makeSuccessEnvelope(data: FToolsUnencodablePayload())

        XCTAssertEqual(json, "{}")
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertNotNil(parsed as? [String: Any], "callers hand this straight to the model: \(json)")
        // Honest about the consequence: with no `ok` key this reads as
        // `EnvelopeStatus.indeterminate`, never as a success.
        XCTAssertFalse(json.contains("\"ok\""), json)
    }

    /// `JSONEncoder` throws on a non-conforming float by default, which is the only
    /// way an `Encodable` payload can fail this encoder.
    private struct FToolsUnencodablePayload: Encodable {
        let value: Double = .infinity
    }

    // MARK: - forward_to_team

    /// `forward_to_team`'s missing-`child_task_id` guard. The id comes from the
    /// paused-delegation envelope, so a model that forgets it must be told WHICH
    /// argument is missing and must not have its message routed anywhere.
    ///
    /// RED: default the missing id (e.g. `?? 0`) -> a `.forwardToTeam` signal is
    /// emitted and the `XCTAssertNil(result.signal)` assertion fires.
    func testForwardToTeam_missingChildTaskID_isRejectedAndEmitsNoSignal() async throws {
        let context = ToolExecutionContext(
            workFolderRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            taskID: 1, runID: 0, roleID: "r")

        let result = ForwardToTeamTool().handle(
            context: context, args: ["message": "use library X"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("INVALID_ARGS"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("child_task_id"),
                      "must name the missing argument: \(result.outputJSON)")
        XCTAssertNil(result.signal, "a rejected call must not reach the delegation plane")
    }
}

// MARK: - Document package failure arms

/// The OOXML/ODF extractors' "the package is not what we expected" arms. Fixtures
/// are real ZIPs built by `ZIPArchiveWriter`; a deliberately wrong CRC-32 is what
/// makes `ZIPReader.readEntry` THROW for an entry `listEntries` still reports.
final class FToolsDocumentPackageTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftools-doc-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func zip(_ name: String, _ entries: [ZIPArchiveWriter.EntrySpec]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try ZIPArchiveWriter.write(to: url, entries: entries)
        return url
    }

    /// A valid ZIP that simply is not a DOCX. The reason must name the missing
    /// part — "could not extract text" alone is indistinguishable from a parse
    /// failure, and the two have different remedies.
    ///
    /// RED: change the `guard let docXML` reason to a generic string -> the
    /// "word/document.xml" assertion fires.
    func testDOCX_packageWithoutDocumentXML_namesTheMissingPart() async throws {
        let url = try zip("a.docx", [.init(name: "docProps/app.xml", data: Data("<x/>".utf8))])

        let out = DOCXDocumentExtractor().extract(from: url)

        XCTAssertTrue(DocumentExtractionFailure.isFailure(out), out)
        XCTAssertTrue(out.contains("word/document.xml"), out)
    }

    /// ODT sibling of the DOCX case.
    ///
    /// RED: change the `guard let contentXML` reason -> the "content.xml"
    /// assertion fires.
    func testODT_packageWithoutContentXML_namesTheMissingPart() async throws {
        // `mimetype` is STORED in a real ODT package; keep the fixture faithful.
        let url = try zip("a.odt", [
            .init(name: "mimetype", data: Data("application/vnd.oasis.opendocument.text".utf8),
                  method: .stored)
        ])

        let out = ODTDocumentExtractor().extract(from: url)

        XCTAssertTrue(DocumentExtractionFailure.isFailure(out), out)
        XCTAssertTrue(out.contains("content.xml"), out)
    }

    /// A PPTX-shaped package with no slides at all.
    ///
    /// RED: replace the `guard !slideEntries.isEmpty` reason -> the "no slide
    /// content" assertion fires.
    func testPPTX_noSlideEntries_reportsNoSlideContent() async throws {
        let url = try zip("a.pptx", [.init(name: "ppt/presentation.xml", data: Data("<p/>".utf8))])

        let out = PPTXDocumentExtractor().extract(from: url)

        XCTAssertTrue(DocumentExtractionFailure.isFailure(out), out)
        XCTAssertTrue(out.contains("no slide content"), out)
    }

    /// A slide that is listed in the archive but whose bytes fail CRC-32
    /// verification. `readEntry` throws, the loop captures the reason and keeps
    /// going, and — because that was the only slide — the captured reason becomes
    /// the failure message. Reporting the generic "no text content in slides"
    /// instead would tell the reader the deck is empty when it is CORRUPT.
    ///
    /// RED: drop `capturedError = String(describing: error)` -> the message falls
    /// back to "no text content in slides" and the crc assertion fires.
    func testPPTX_corruptSlideEntry_reportsTheCorruptionNotEmptiness() async throws {
        let url = try zip("b.pptx", [
            .init(name: "ppt/slides/slide1.xml", data: Data("<a:t>hi</a:t>".utf8),
                  method: .stored, overrideCRC: 0xDEAD_BEEF)
        ])

        let out = PPTXDocumentExtractor().extract(from: url)

        XCTAssertTrue(DocumentExtractionFailure.isFailure(out), out)
        XCTAssertTrue(out.lowercased().contains("crc"),
                      "the corruption must be named, not reported as emptiness: \(out)")
        XCTAssertFalse(out.contains("no text content in slides"), out)
    }

    /// An XLSX-shaped package with no worksheets and nothing else wrong.
    ///
    /// RED: swap the `errors.isEmpty` ternary arms -> the reason becomes an empty
    /// joined list and the "no worksheet data" assertion fires.
    func testXLSX_noWorksheets_reportsNoWorksheetData() async throws {
        let url = try zip("a.xlsx", [.init(name: "xl/workbook.xml", data: Data("<w/>".utf8))])

        let out = XLSXDocumentExtractor().extract(from: url)

        XCTAssertTrue(DocumentExtractionFailure.isFailure(out), out)
        XCTAssertTrue(out.contains("no worksheet data"), out)
    }

    /// Same "no worksheets" shape, but the shared-string table ALSO failed to read.
    /// The collected error must win over the generic phrase — a package whose
    /// shared strings are corrupt is a different problem from one that simply has
    /// no sheets, and the reader can only tell from this reason.
    ///
    /// RED: replace the `errors.isEmpty ? … : errors.joined(…)` with the bare
    /// generic reason -> the "shared strings" assertion fires.
    func testXLSX_noWorksheetsAndBrokenSharedStrings_reportsTheCollectedError() async throws {
        let url = try zip("b.xlsx", [
            .init(name: "xl/sharedStrings.xml", data: Data("<sst/>".utf8),
                  method: .stored, overrideCRC: 0x0BAD_0BAD)
        ])

        let out = XLSXDocumentExtractor().extract(from: url)

        XCTAssertTrue(DocumentExtractionFailure.isFailure(out), out)
        XCTAssertTrue(out.contains("shared strings"),
                      "the collected reason must win over the generic one: \(out)")
        XCTAssertFalse(out.contains("no worksheet data"), out)
    }

    /// A worksheet that parses cleanly and yields zero rows. Every sheet is
    /// skipped, so no section is produced and the package reads as empty — which
    /// is the truth here, and must not be reported as a read failure.
    ///
    /// RED: replace the `sections.isEmpty` reason with the sheet-listing one ->
    /// the "empty spreadsheet" assertion fires.
    func testXLSX_worksheetWithNoRows_reportsAnEmptySpreadsheet() async throws {
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData/>
        </worksheet>
        """
        let url = try zip("c.xlsx", [
            .init(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8))
        ])

        let out = XLSXDocumentExtractor().extract(from: url)

        XCTAssertTrue(DocumentExtractionFailure.isFailure(out), out)
        XCTAssertTrue(out.contains("empty spreadsheet"), out)
    }
}
