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

    // MARK: - Wave F2: Async Execution & Raw Byte Handling (Feature 12 / §3.2)

    func testRunAsync_echoCommand_returnsRawBytesAndString() async throws {
        let result = try await ProcessRunner.runAsync(
            executable: "/bin/echo",
            arguments: ["Hello, Async World!"],
            currentDirectory: tempDir
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "Hello, Async World!")
        XCTAssertFalse(result.stdoutData.isEmpty)
        XCTAssertEqual(result.stdoutData, Data("Hello, Async World!\n".utf8))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testRunAsync_largeOutput_returnsEveryByteOfEachConcurrentRun() async throws {
        let count = 5
        try await withThrowingTaskGroup(of: ProcessRunner.RawResult.self) { group in
            for i in 0..<count {
                group.addTask {
                    try await ProcessRunner.runAsync(
                        executable: "/bin/sh",
                        arguments: ["-c", "for j in $(seq 1 1000); do echo \"line $j for task \(i)\"; done"],
                        currentDirectory: nil
                    )
                }
            }

            var finished = 0
            for try await res in group {
                XCTAssertTrue(res.success)
                XCTAssertGreaterThan(res.stdoutData.count, 10_000)
                finished += 1
            }
            XCTAssertEqual(finished, count)
        }
    }

    /// The child's lifetime is not a cooperative thread's: twice as many one-second children as
    /// the pool has threads finish together, and a task on the pool runs meanwhile. A runner
    /// that blocked a pool thread per child would take `⌈n / width⌉` seconds and starve the
    /// probe (N10 of the F6 acceptance — the test this replaces only counted results).
    func testRunAsync_concurrentChildren_holdNoCooperativeThread() async throws {
        let width = ProcessInfo.processInfo.activeProcessorCount
        let count = width * 2 + 2
        let clock = ContinuousClock()
        let started = clock.now
        let probe = Task.detached { () -> Duration in
            try? await Task.sleep(for: .milliseconds(200))
            let probeStart = clock.now
            await Task.yield()
            return clock.now - probeStart
        }
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try await ProcessRunner.runAsync(
                        executable: "/bin/sleep", arguments: ["1"], currentDirectory: nil
                    ).exitCode
                }
            }
            for try await status in group { XCTAssertEqual(status, 0) }
        }
        let elapsed = clock.now - started
        let probeLatency = await probe.value
        XCTAssertLessThan(elapsed, .milliseconds(2500), "\(count) one-second children took \(elapsed)")
        XCTAssertLessThan(probeLatency, .milliseconds(500), "a pool task waited \(probeLatency)")
    }

    /// A spawn that fails comes back as `.launchFailed` at once. Until 2026-11-12 the pipe
    /// readers started BEFORE `run()`, and when it threw nothing closed the pipes' write ends:
    /// the readers never saw EOF, the implicit await of the `async let` readers never returned,
    /// and the throw — and the snapshot store's folder lock above it — stayed held for good
    /// (N6 of the F6 acceptance).
    func testRunAsync_missingWorkingDirectory_throwsLaunchFailedPromptly() async throws {
        let missing = tempDir.appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)
        let returned = expectation(description: "runAsync returned")
        let outcome = OutcomeBox()
        Task.detached {
            do {
                _ = try await ProcessRunner.runAsync(
                    executable: "/bin/echo", arguments: ["x"], currentDirectory: missing, timeout: 30)
                outcome.set("succeeded")
            } catch let error as ProcessRunnerError {
                if case .launchFailed = error { outcome.set("launchFailed") } else { outcome.set("\(error)") }
            } catch {
                outcome.set("\(error)")
            }
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertEqual(outcome.value, "launchFailed")
    }

    /// The pipes are drained within a bound after the child exits, as the synchronous `run`
    /// drains them: a grandchild that inherited them — `repack` after `gc` was stopped, a
    /// command's own `&` — no longer holds the call until it exits (N6 of the F6 acceptance).
    func testRunAsync_grandchildHoldingThePipes_returnsWithinTheDrainBound() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await ProcessRunner.runAsync(
            executable: "/bin/sh",
            arguments: ["-c", "/bin/sleep 20 & echo started"],
            currentDirectory: tempDir,
            timeout: 60)
        let elapsed = clock.now - started
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("started"), result.stdout)
        XCTAssertLessThan(elapsed, .seconds(9), "the call waited \(elapsed) for a grandchild")
    }

    func testRunAsync_cancellation_escalatesSIGTERMtoSIGKILL() async throws {
        let pythonPath = "/usr/bin/python3"
        guard fileManager.isExecutableFile(atPath: pythonPath) else {
            throw XCTSkip("Python3 is not available at \(pythonPath)")
        }

        let trapScript = """
        import signal, sys, time
        def handler(sig, frame):
            sys.stdout.write("CAUGHT_SIGTERM\\n")
            sys.stdout.flush()
        signal.signal(signal.SIGTERM, handler)
        sys.stdout.write("READY\\n")
        sys.stdout.flush()
        time.sleep(60)
        """

        let started = Date()
        let task = Task.detached { () throws -> ProcessRunner.RawResult in
            return try await ProcessRunner.runAsync(
                executable: pythonPath,
                arguments: ["-c", trapScript],
                currentDirectory: nil,
                timeout: 120
            )
        }

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
        XCTAssertLessThan(
            elapsed, 4.0,
            "SIGTERM-ignoring child must be SIGKILLed within 2 s grace; took \(elapsed)s."
        )
    }

    /// `stdoutData` is the lossless channel — every byte as written; `stdout` is a convenience
    /// that decodes with U+FFFD and must only not come back EMPTY. A reader that needs the
    /// bytes (the `task_changes` page diff, N8) reads `stdoutData`.
    func testRunAsync_nonUTF8Bytes_stdoutDataKeepsEveryByte_stdoutIsNotEmptied() async throws {
        let pythonPath = "/usr/bin/python3"
        guard fileManager.isExecutableFile(atPath: pythonPath) else {
            throw XCTSkip("Python3 is not available at \(pythonPath)")
        }

        let binaryScript = """
        import sys
        sys.stdout.buffer.write(b"header\\xff\\xfe\\x00trailer\\n")
        sys.stdout.buffer.flush()
        """

        let res = try await ProcessRunner.runAsync(
            executable: pythonPath,
            arguments: ["-c", binaryScript],
            currentDirectory: nil
        )

        XCTAssertTrue(res.success)
        XCTAssertEqual(res.stdoutData, Data("header".utf8) + Data([0xFF, 0xFE, 0x00]) + Data("trailer\n".utf8))
        XCTAssertFalse(res.stdout.isEmpty, "RawResult.stdout must not be emptied by invalid UTF-8 bytes")
        XCTAssertTrue(res.stdout.contains("header"))
        XCTAssertTrue(res.stdout.contains("trailer"))
    }

    /// `inheritsEnvironment: false`: the child sees the given variables and nothing of the
    /// app's own (S10, F6 2026-11-12) — the snapshot store's git runs this way.
    func testRunAsync_withoutInheritance_childSeesOnlyTheGivenEnvironment() async throws {
        setenv("NANOTEAMS_PROCESS_RUNNER_PROBE", "inherited", 1)
        defer { unsetenv("NANOTEAMS_PROCESS_RUNNER_PROBE") }

        let exact = try await ProcessRunner.runAsync(
            executable: "/usr/bin/env", arguments: [], currentDirectory: tempDir,
            environment: ["ONLY": "this"], inheritsEnvironment: false)
        XCTAssertEqual(exact.stdout, "ONLY=this\n")

        let empty = try await ProcessRunner.runAsync(
            executable: "/usr/bin/env", arguments: [], currentDirectory: tempDir,
            environment: nil, inheritsEnvironment: false)
        XCTAssertEqual(empty.stdout, "")

        // The default still inherits — every other caller is unchanged.
        let inherited = try await ProcessRunner.runAsync(
            executable: "/usr/bin/env", arguments: [], currentDirectory: tempDir, environment: ["ONLY": "this"])
        XCTAssertTrue(inherited.stdout.contains("NANOTEAMS_PROCESS_RUNNER_PROBE=inherited"))
        XCTAssertTrue(inherited.stdout.contains("ONLY=this"))
    }

    func testRunGitAsync_executesSuccessfully() async throws {
        let result = try await ProcessRunner.runGitAsync(["version"], in: tempDir)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.stdout.contains("git version"))
    }

    // MARK: - Wave Final Coverage Hardening: Async Timeout & Escalation (M6.1)

    func testRunAsync_timeoutFires_throwsTimeoutErrorWithCapturedOutput() async throws {
        do {
            _ = try await ProcessRunner.runAsync(
                executable: "/bin/sh",
                arguments: ["-c", "echo 'starting'; sleep 2; echo 'finished'"],
                currentDirectory: tempDir,
                timeout: 0.2
            )
            XCTFail("Expected ProcessRunnerError.timeout")
        } catch let err as ProcessRunnerError {
            guard case let .timeout(limit, stdout, _) = err else {
                XCTFail("Expected ProcessRunnerError.timeout, got \(err)")
                return
            }
            XCTAssertEqual(limit, 0.2)
            XCTAssertTrue(stdout.contains("starting"))
        }
    }

    func testRunAsync_timeoutWithSIGTERMIgnoringChild_escalatesToSIGKILL() async throws {
        let pythonPath = "/usr/bin/python3"
        guard fileManager.isExecutableFile(atPath: pythonPath) else {
            throw XCTSkip("Python3 not available")
        }

        let trapScript = """
        import signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        sys.stdout.write("READY\\n")
        sys.stdout.flush()
        time.sleep(60)
        """

        let started = Date()
        do {
            _ = try await ProcessRunner.runAsync(
                executable: pythonPath,
                arguments: ["-c", trapScript],
                currentDirectory: tempDir,
                timeout: 0.3
            )
            XCTFail("Expected timeout")
        } catch let err as ProcessRunnerError {
            guard case .timeout = err else {
                XCTFail("Expected ProcessRunnerError.timeout, got \(err)")
                return
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 4.0,
            "SIGTERM-ignoring child must be SIGKILLed within 2 s grace period; took \(elapsed)s."
        )
    }

    func testProbeSandboxLaunch_nonExistentDirectory_returnsChildRan() {
        let invalidDir = URL(fileURLWithPath: "/nonexistent/invalid/dir/\(UUID().uuidString)")
        let verdict = ProcessRunner.probeSandboxLaunch(profile: "(version 1)", in: invalidDir, timeout: 5)
        XCTAssertEqual(verdict, .childRan)
    }

    func testRunAsync_earlyProcessTermination_resumesContinuationsCorrectly() async throws {
        // Child exits while onLaunch sleeps, so isTerminated is true when waitForExit is called
        let res = try await ProcessRunner.runAsync(
            executable: "/bin/echo",
            arguments: ["done"],
            currentDirectory: tempDir,
            timeout: 5.0,
            onLaunch: { _, _ in
                usleep(50000)
            }
        )
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.stdout.contains("done"))
    }

    func testRunAsync_cancelledPriorToExit_throwsCancelled() async throws {
        let runTask = Task {
            try await ProcessRunner.runAsync(
                executable: "/bin/sleep",
                arguments: ["10"],
                currentDirectory: nil,
                timeout: 10.0,
                onLaunch: { _, _ in
                    usleep(20000)
                }
            )
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        runTask.cancel()
        do {
            _ = try await runTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is ProcessRunnerError || error is CancellationError)
        }
    }

    func testRunAsync_timeoutWithProcessGroup_stopsProcessGroup() async throws {
        do {
            _ = try await ProcessRunner.runAsync(
                executable: "/bin/sleep",
                arguments: ["10"],
                currentDirectory: tempDir,
                timeout: 0.2,
                reapsProcessGroup: true
            )
            XCTFail("Expected ProcessRunnerError.timeout")
        } catch let err as ProcessRunnerError {
            guard case .timeout = err else {
                XCTFail("Expected ProcessRunnerError.timeout, got \(err)")
                return
            }
        }
    }

    func testRunAsync_timeoutWithSIGTERMIgnoringChildAndProcessGroup_escalatesToSIGKILL() async throws {
        let pythonPath = "/usr/bin/python3"
        guard fileManager.isExecutableFile(atPath: pythonPath) else {
            throw XCTSkip("Python3 not available")
        }

        let trapScript = """
        import signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        sys.stdout.write("READY\\n")
        sys.stdout.flush()
        time.sleep(60)
        """

        let started = Date()
        do {
            _ = try await ProcessRunner.runAsync(
                executable: pythonPath,
                arguments: ["-c", trapScript],
                currentDirectory: tempDir,
                timeout: 0.3,
                reapsProcessGroup: true
            )
            XCTFail("Expected timeout")
        } catch let err as ProcessRunnerError {
            guard case .timeout = err else {
                XCTFail("Expected ProcessRunnerError.timeout, got \(err)")
                return
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 4.0,
            "SIGTERM-ignoring child in process group must be SIGKILLed within grace period; took \(elapsed)s."
        )
    }

    func testRunAsync_timeoutFiresDuringLaunch_waitForExitHandlesAlreadyTimedOut() async throws {
        do {
            _ = try await ProcessRunner.runAsync(
                executable: "/bin/sleep",
                arguments: ["10"],
                currentDirectory: nil,
                timeout: 0.05,
                onLaunch: { @Sendable _, _ in
                    usleep(100_000)
                }
            )
            XCTFail("Expected timeout")
        } catch let err as ProcessRunnerError {
            guard case .timeout = err else {
                XCTFail("Expected timeout, got \(err)")
                return
            }
        }
    }

    func testRunAsync_cancelledDuringLaunchAfterTermination_waitForExitHandlesAlreadyCancelled() async throws {
        let runTask = Task {
            try await ProcessRunner.runAsync(
                executable: "/bin/echo",
                arguments: ["fast"],
                currentDirectory: nil,
                timeout: 10.0,
                onLaunch: { @Sendable proc, _ in
                    usleep(50_000)
                }
            )
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        runTask.cancel()
        do {
            _ = try await runTask.value
        } catch {
            XCTAssertTrue(error is ProcessRunnerError || error is CancellationError)
        }
    }

    func testRun_nonUTF8Output_replacesWithEmptyString() throws {
        let res = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '\\xff\\xfe\\xfd' >&2; printf '\\xff\\xfe\\xfd'"],
            currentDirectory: nil
        )
        XCTAssertEqual(res.stdout, "")
        XCTAssertEqual(res.stderr, "")
    }

    func testProbeSandboxLaunch_deniedProfile_returnsConfinedBeforeStartOrWrapperRejected() {
        let verdict = ProcessRunner.probeSandboxLaunch(profile: "(version 1) (deny default)", in: tempDir, timeout: 5)
        XCTAssertTrue(verdict == .confinedBeforeStart || verdict == .wrapperRejected)
    }

    func testProbeSandboxLaunch_nonexistentDirectory_returnsChildRan() {
        let nonexistent = URL(fileURLWithPath: "/nonexistent_sandbox_probe_path_\(UUID().uuidString)")
        let verdict = ProcessRunner.probeSandboxLaunch(profile: "(version 1)", in: nonexistent, timeout: 5)
        XCTAssertEqual(verdict, .childRan)
    }

    func testRunAsync_timeoutAfterProcessTerminated() async throws {
        let res = try await ProcessRunner.runAsync(
            executable: "/bin/echo",
            arguments: ["done"],
            currentDirectory: nil,
            timeout: 0.05,
            onLaunch: { _, _ in
                usleep(70_000)
            }
        )
        XCTAssertEqual(res.exitCode, 0)
    }
}

/// What a detached run reported, read after its expectation is fulfilled.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
}
