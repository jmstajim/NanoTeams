import XCTest

@testable import NanoTeams

final class ProcessRunnerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Basic Execution Tests

    func testRunEchoCommand() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/echo",
            arguments: ["Hello, World!"],
            currentDirectory: tempDir
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "Hello, World!")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testRunWithMultipleArguments() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/echo",
            arguments: ["-n", "no", "newline"],
            currentDirectory: tempDir
        )

        XCTAssertTrue(result.success)
        // -n flag suppresses newline, output should be "no newline"
        XCTAssertTrue(result.stdout.contains("no") && result.stdout.contains("newline"))
    }

    func testRunCommandWithExitCode() throws {
        // /bin/false always returns exit code 1
        let result = try ProcessRunner.run(
            executable: "/usr/bin/false",
            arguments: [],
            currentDirectory: tempDir
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.exitCode, 1)
    }

    func testRunCommandWithStderr() throws {
        // ls on non-existent path writes to stderr
        let result = try ProcessRunner.run(
            executable: "/bin/ls",
            arguments: ["/nonexistent/path/that/does/not/exist"],
            currentDirectory: tempDir
        )

        XCTAssertFalse(result.success)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.stderr.isEmpty)
    }

    // MARK: - Current Directory Tests

    func testRunInSpecificDirectory() throws {
        // Create a file in temp directory
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "content".write(to: testFile, atomically: true, encoding: .utf8)

        let result = try ProcessRunner.run(
            executable: "/bin/ls",
            arguments: [],
            currentDirectory: tempDir
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.stdout.contains("test.txt"))
    }

    func testRunWithNilDirectory() throws {
        // When currentDirectory is nil, should use current working directory
        let result = try ProcessRunner.run(
            executable: "/bin/pwd",
            arguments: [],
            currentDirectory: nil
        )

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.stdout.isEmpty)
    }

    // MARK: - Environment Tests

    func testRunWithCustomEnvironment() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo $CUSTOM_VAR"],
            currentDirectory: tempDir,
            environment: ["CUSTOM_VAR": "custom_value"]
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "custom_value"
        )
    }

    func testRunPreservesSystemEnvironment() throws {
        // HOME should be available even with custom environment
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo $HOME"],
            currentDirectory: tempDir,
            environment: ["CUSTOM_VAR": "value"]
        )

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testRunWithNilEnvironment() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo $HOME"],
            currentDirectory: tempDir,
            environment: nil
        )

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.stdout.isEmpty)
    }

    // MARK: - Timeout Tests

    func testRunWithinTimeout() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/echo",
            arguments: ["quick"],
            currentDirectory: tempDir,
            timeout: 5
        )

        XCTAssertTrue(result.success)
    }

    func testRunExceedsTimeout() throws {
        // sleep for 2 seconds with 0.5 second timeout should timeout
        XCTAssertThrowsError(
            try ProcessRunner.run(
                executable: "/bin/sleep",
                arguments: ["2"],
                currentDirectory: tempDir,
                timeout: 0.5
            )
        ) { error in
            if case ProcessRunnerError.timeout(let seconds, _, _) = error {
                XCTAssertEqual(seconds, 0.5)
            } else {
                XCTFail("Expected timeout error, got: \(error)")
            }
        }
    }

    // MARK: - Error Tests

    func testRunNonExistentExecutable() throws {
        XCTAssertThrowsError(
            try ProcessRunner.run(
                executable: "/nonexistent/binary",
                arguments: [],
                currentDirectory: tempDir
            )
        ) { error in
            if case ProcessRunnerError.executableNotFound(let path) = error {
                XCTAssertEqual(path, "/nonexistent/binary")
            } else {
                XCTFail("Expected executableNotFound error, got: \(error)")
            }
        }
    }

    func testProcessRunnerErrorDescriptions() {
        let timeoutError = ProcessRunnerError.timeout(30, stdout: "", stderr: "")
        XCTAssertEqual(timeoutError.errorDescription, "Process timed out after 30 seconds")

        let notFoundError = ProcessRunnerError.executableNotFound("/path/to/bin")
        XCTAssertEqual(notFoundError.errorDescription, "Executable not found: /path/to/bin")
    }

    // MARK: - Result Properties Tests

    func testResultCombinedOutput() throws {
        // Use a command that writes to both stdout and stderr
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo stdout; echo stderr >&2"],
            currentDirectory: tempDir
        )

        XCTAssertTrue(result.stdout.contains("stdout"))
        XCTAssertTrue(result.stderr.contains("stderr"))
        XCTAssertTrue(result.combinedOutput.contains("stdout"))
        XCTAssertTrue(result.combinedOutput.contains("stderr"))
    }

    func testResultSuccessProperty() {
        let successResult = ProcessRunner.Result(exitCode: 0, stdout: "", stderr: "")
        XCTAssertTrue(successResult.success)

        let failureResult = ProcessRunner.Result(exitCode: 1, stdout: "", stderr: "")
        XCTAssertFalse(failureResult.success)

        let otherFailure = ProcessRunner.Result(exitCode: 127, stdout: "", stderr: "")
        XCTAssertFalse(otherFailure.success)
    }

    // MARK: - Git Convenience Tests

    func testRunGitInit() throws {
        let result = try ProcessRunner.runGit(["init"], in: tempDir)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.stdout.contains("Initialized") || result.stderr.contains("Initialized"))

        // Verify .git directory was created
        let gitDir = tempDir.appendingPathComponent(".git")
        XCTAssertTrue(fileManager.fileExists(atPath: gitDir.path))
    }

    func testRunGitStatus() throws {
        // First init a git repo
        _ = try ProcessRunner.runGit(["init"], in: tempDir)

        let result = try ProcessRunner.runGit(["status"], in: tempDir)

        XCTAssertTrue(result.success)
        // Should contain typical git status output
        XCTAssertTrue(
            result.stdout.contains("On branch") ||
                result.stdout.contains("No commits yet") ||
                result.stdout.contains("nothing to commit")
        )
    }

    func testRunGitWithCustomTimeout() throws {
        _ = try ProcessRunner.runGit(["init"], in: tempDir, timeout: 30)
        let result = try ProcessRunner.runGit(["status"], in: tempDir, timeout: 30)
        XCTAssertTrue(result.success)
    }

    // MARK: - Xcodebuild Convenience Tests

    func testRunXcodebuildVersion() throws {
        // This test might fail if xcodebuild is not installed
        // Skip if not available
        guard fileManager.fileExists(atPath: "/usr/bin/xcodebuild") else {
            throw XCTSkip("xcodebuild not available")
        }

        let result = try ProcessRunner.runXcodebuild(["-version"], in: tempDir)

        // xcodebuild -version should work without a project
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.stdout.contains("Xcode"))
    }

    func testRunXcodebuildWithLongerTimeout() throws {
        guard fileManager.fileExists(atPath: "/usr/bin/xcodebuild") else {
            throw XCTSkip("xcodebuild not available")
        }

        // Default timeout for xcodebuild is 600 seconds
        let result = try ProcessRunner.runXcodebuild(["-version"], in: tempDir, timeout: 60)
        XCTAssertTrue(result.success)
    }

    // MARK: - Large Output Tests

    func testRunCommandWithLargeOutput() throws {
        // Generate output with many lines
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 1000); do echo Line $i; done"],
            currentDirectory: tempDir
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.stdout.contains("Line 1"))
        XCTAssertTrue(result.stdout.contains("Line 1000"))
    }

    // MARK: - Special Characters Tests

    func testRunWithSpecialCharactersInArguments() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/echo",
            arguments: ["Hello", "World!", "Special: $HOME 'quoted' \"double\""],
            currentDirectory: tempDir
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.stdout.contains("Special:"))
    }

    // MARK: - Pipe Deadlock Prevention (Round 4 regression)

    func testRunLargeOutput_DoesNotDeadlock() throws {
        // Generate >64KB of output (pipe buffer size) to verify no deadlock
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes | head -100000"],
            currentDirectory: tempDir,
            timeout: 10
        )

        XCTAssertTrue(result.success, "Large output command should succeed without deadlock")
        XCTAssertGreaterThan(result.stdout.count, 64_000,
                             "Should capture >64KB of stdout without pipe deadlock")
    }

    func testRunWithSpacesInPath() throws {
        // Create a directory with spaces
        let spacedDir = tempDir.appendingPathComponent("dir with spaces")
        try fileManager.createDirectory(at: spacedDir, withIntermediateDirectories: true)

        let testFile = spacedDir.appendingPathComponent("test.txt")
        try "content".write(to: testFile, atomically: true, encoding: .utf8)

        let result = try ProcessRunner.run(
            executable: "/bin/ls",
            arguments: [],
            currentDirectory: spacedDir
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.stdout.contains("test.txt"))
    }

    // MARK: - Cancellation

    /// On `Task` cancellation mid-subprocess, `ProcessRunner.run` MUST:
    ///   1. SIGTERM (then SIGKILL after 2 s grace) the child so the run stops
    ///      within seconds rather than the configured timeout.
    ///   2. Throw `ProcessRunnerError.cancelled`.
    func testRunCancellation_terminatesSubprocessAndThrowsCancelled() async throws {
        let started = Date()
        let task = Task.detached { () throws -> ProcessRunner.Result in
            // `/bin/sleep 30` exists on every macOS, is cheap, and gives a
            // wide cancellation window without depending on tool flags.
            return try ProcessRunner.run(
                executable: "/bin/sleep",
                arguments: ["30"],
                currentDirectory: nil,
                timeout: 60  // longer than 30 — must NOT be the path that fires
            )
        }

        // Let the subprocess actually start before signaling cancel; a cancel
        // delivered before `process.run()` returns would just abort cleanly
        // without exercising the SIGTERM path.
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to throw, got normal completion")
        } catch let err as ProcessRunnerError {
            guard case .cancelled = err else {
                XCTFail("Expected ProcessRunnerError.cancelled, got \(err)")
                return
            }
        } catch {
            XCTFail("Expected ProcessRunnerError.cancelled, got \(error)")
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        // The cooperative wait polls every 100 ms and grants a 2 s grace
        // period for SIGTERM before SIGKILL. Even with very slow CI hosts,
        // a 5 s upper bound proves we did NOT just wait the full 30 s
        // (which would mean the cancellation path silently no-op'd).
        XCTAssertLessThan(
            elapsed, 5.0,
            "Cancellation must abort within seconds, not wait the full sleep duration. Took \(elapsed)s."
        )
    }

    /// SIGTERM-ignoring child must still be killed within the 2 s grace
    /// window. Pins the SIGKILL escalation path that the simpler `/bin/sleep`
    /// test doesn't exercise (sleep honors SIGTERM and exits immediately).
    /// A regression that drops the SIGKILL fallback would silently let a
    /// trap-handling subprocess outlive cancellation forever.
    func testRunCancellation_subprocessIgnoresSIGTERM_isSIGKILLedWithinGrace() async throws {
        // Skip if Python isn't available — this happens on the bare CI macOS
        // runners. The check is cheap: stat the path.
        let pythonPath = "/usr/bin/python3"
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            throw XCTSkip("python3 not present at \(pythonPath); cannot test SIGTERM-ignoring child.")
        }
        // Python program: trap SIGTERM (so SIGTERM alone won't kill us),
        // then sleep 60 s. Only SIGKILL gets through. Print to stdout after
        // setup so a hung start is distinguishable from a hung wait.
        let trapScript = """
        import signal, time, sys
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print("trapped", flush=True)
        time.sleep(60)
        """

        let started = Date()
        let task = Task.detached { () throws -> ProcessRunner.Result in
            return try ProcessRunner.run(
                executable: pythonPath,
                arguments: ["-c", trapScript],
                currentDirectory: nil,
                timeout: 120
            )
        }

        // Let the SIGTERM trap install and `time.sleep` start. Without this
        // delay, cancel could land before the trap is in place; the test
        // would pass for the wrong reason.
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation, got normal completion")
        } catch let err as ProcessRunnerError {
            guard case .cancelled = err else {
                XCTFail("Expected ProcessRunnerError.cancelled, got \(err)")
                return
            }
        } catch {
            XCTFail("Expected ProcessRunnerError.cancelled, got \(error)")
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        // Sub-4 s upper bound: 400 ms setup + 100 ms poll + 2 s SIGTERM grace
        // + SIGKILL wait. Loose enough for slow CI but tight enough that a
        // missing SIGKILL escalation (which would wait the full 60 s sleep)
        // is unambiguous.
        XCTAssertLessThan(
            elapsed, 4.0,
            "SIGTERM-ignoring child must be SIGKILLed within 2 s grace; took \(elapsed)s. "
                + "A SIGKILL regression would wait the full 60 s sleep."
        )
    }

    /// A non-cancelled subprocess must still return normally — pins that the
    /// new cooperative wait loop doesn't accidentally throw `.cancelled` on
    /// the happy path.
    func testRunCancellation_uncancelled_completesNormally() async throws {
        let task = Task.detached { () throws -> ProcessRunner.Result in
            return try ProcessRunner.run(
                executable: "/bin/echo",
                arguments: ["normal-completion-marker"],
                currentDirectory: nil
            )
        }
        let result = try await task.value
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.stdout.contains("normal-completion-marker"))
    }
}
