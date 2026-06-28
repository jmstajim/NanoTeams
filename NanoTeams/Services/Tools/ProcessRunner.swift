import Foundation

nonisolated enum ProcessRunnerError: LocalizedError {
    /// Carries the output captured BEFORE the deadline so a timed-out command
    /// (e.g. a build that printed 100 KB then hung) can still surface its partial
    /// stdout/stderr instead of returning empty.
    case timeout(TimeInterval, stdout: String, stderr: String)
    case executableNotFound(String)
    /// The enclosing Swift `Task` was cancelled while the subprocess was running.
    /// `ProcessRunner.run` SIGTERMs (and SIGKILLs after a grace period) the child
    /// process before throwing this so a paused step doesn't leave a runaway
    /// `xcodebuild` / `git` consuming CPU/disk for minutes.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .timeout(let seconds, _, _):
            "Process timed out after \(Int(seconds)) seconds"
        case .executableNotFound(let path):
            "Executable not found: \(path)"
        case .cancelled:
            "Process cancelled (run paused or interrupted)."
        }
    }
}

nonisolated struct ProcessRunner {
    struct Result {
        var exitCode: Int32
        var stdout: String
        var stderr: String

        var success: Bool { exitCode == 0 }
        var combinedOutput: String { stdout + stderr }
    }

    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let dir = currentDirectory {
            process.currentDirectoryURL = dir
        }

        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // `terminationHandler` MUST be set before `process.run()` — Apple's docs
        // guarantee delivery only if it was set before the process exited. A
        // short-lived child (e.g. `git rev-parse HEAD`) can race the post-run
        // handler installation.
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.executableNotFound(executable)
        }

        // Read pipes concurrently BEFORE the wait loop to prevent deadlock.
        // If the child process fills the pipe buffer (~64KB), it blocks on write.
        // Waiting before draining the pipes would deadlock.
        // Use a class wrapper instead of `var Data` so Swift 6's strict checker
        // can prove the assignment is safe inside the dispatch closure — the
        // happens-before edge is `dispatch.async { box.data = … }` → `pipeGroup.wait()`,
        // which the compiler can't see; `@unchecked Sendable` documents the
        // invariant we enforce by `pipeGroup.wait()`.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let pipeGroup = DispatchGroup()

        pipeGroup.enter()
        DispatchQueue.global().async {
            stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            pipeGroup.leave()
        }
        pipeGroup.enter()
        DispatchQueue.global().async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            pipeGroup.leave()
        }

        // Polling wait so a single semaphore covers BOTH timeout and
        // `Task.isCancelled` — a blocking `process.waitUntilExit()` would
        // ignore Swift task cancellation and leave a paused run unable to
        // stop a long subprocess.
        let deadline = DispatchTime.now() + .nanoseconds(Int(timeout * 1_000_000_000))
        var didTimeOut = false
        var didCancel = false
        waitLoop: while true {
            // 100 ms tick: cancellation observed within one frame, poll adds
            // < 1 % CPU.
            let now = DispatchTime.now()
            let nextTick = min(now + .milliseconds(100), deadline)
            switch exitSemaphore.wait(timeout: nextTick) {
            case .success:
                break waitLoop
            case .timedOut:
                if DispatchTime.now() >= deadline {
                    didTimeOut = true
                    if process.isRunning { process.terminate() }
                    exitSemaphore.wait()
                    break waitLoop
                }
                if Task.isCancelled {
                    didCancel = true
                    if process.isRunning { process.terminate() }
                    // Grace period: give the child up to 2 s to flush+exit on
                    // SIGTERM; if it ignores that, SIGKILL. `kill(pid, SIGKILL)`
                    // works for any descendant pid we own.
                    if exitSemaphore.wait(timeout: .now() + .seconds(2)) == .timedOut {
                        let pid = process.processIdentifier
                        if pid > 0 { kill(pid, SIGKILL) }
                        exitSemaphore.wait()
                    }
                    break waitLoop
                }
            }
        }

        // Bounded pipe drain. `readDataToEndOfFile()` blocks until the LAST
        // writer closes the pipe — and a SIGKILLed parent (e.g. `xcodebuild`)
        // can leave grandchildren (compilers, linkers) holding the writer FD
        // open. Without the timeout, a cancelled run can hang the cooperative
        // thread pool waiting for them to clean up.
        if pipeGroup.wait(timeout: .now() + .seconds(5)) == .timedOut {
            // Force the readers to unwind by closing the pipes ourselves.
            // The dispatch closures will resume with whatever bytes already
            // flushed; `stdoutBox.data` / `stderrBox.data` may be truncated.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            _ = pipeGroup.wait(timeout: .now() + .seconds(1))
        }

        // Decode the drained pipes BEFORE the throws so a timeout can carry the
        // partial output captured before the deadline.
        let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""

        if didCancel {
            throw ProcessRunnerError.cancelled
        }
        if didTimeOut {
            throw ProcessRunnerError.timeout(timeout, stdout: stdout, stderr: stderr)
        }

        return Result(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    /// Run git command in specified directory
    static func runGit(
        _ arguments: [String],
        in directory: URL,
        timeout: TimeInterval = 60
    ) throws -> Result {
        try run(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: directory,
            timeout: timeout
        )
    }

    /// Run xcodebuild command in specified directory
    static func runXcodebuild(
        _ arguments: [String],
        in directory: URL,
        timeout: TimeInterval = 600
    ) throws -> Result {
        try run(
            executable: "/usr/bin/xcodebuild",
            arguments: arguments,
            currentDirectory: directory,
            timeout: timeout
        )
    }

    /// Resolves the user's login shell. Prefers `$SHELL` when it points at an
    /// executable (so the user's real PATH from `~/.zshrc` is available), else
    /// falls back to `/bin/zsh`. `/bin/bash` on macOS is the frozen 3.2 build
    /// that reads `~/.bash_profile`, which most users don't maintain — using the
    /// login shell from `$SHELL` mirrors Claude Code's Bash tool.
    static func loginShell(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        if let shell = environment["SHELL"],
           !shell.trimmingCharacters(in: .whitespaces).isEmpty,
           fileManager.isExecutableFile(atPath: shell) {
            return shell
        }
        return BashConstants.fallbackShell
    }

    /// Runs a shell command string through the login shell (`<shell> -lc "<cmd>"`),
    /// optionally confined by a Seatbelt profile. A non-zero exit is returned in
    /// the `Result` (NOT thrown) — the caller decides whether that's a failure.
    /// Timeout / cancellation still throw `ProcessRunnerError`.
    static func runShell(
        _ command: String,
        in directory: URL,
        timeout: TimeInterval,
        sandboxProfile: String?
    ) throws -> Result {
        let shell = loginShell()
        let executable: String
        let arguments: [String]
        if let profile = sandboxProfile {
            (executable, arguments) = SeatbeltSandbox.wrap(
                profile: profile, shell: shell, command: command)
        } else {
            executable = shell
            arguments = ["-lc", command]
        }
        return try run(
            executable: executable,
            arguments: arguments,
            currentDirectory: directory,
            timeout: timeout
        )
    }
}

/// Mutable `Data` container used to receive pipe-read output from a background
/// dispatch closure. Safety relies on the `DispatchGroup.wait()` happens-before
/// edge in `ProcessRunner.run`; the box is read only after `group.wait()`.
/// `nonisolated` is required so the `data` property can be both written from
/// the dispatch closure and read back inline (otherwise the property inherits
/// the app target's default `@MainActor` isolation).
nonisolated private final class DataBox: @unchecked Sendable {
    var data = Data()
}
