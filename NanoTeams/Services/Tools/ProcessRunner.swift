import Foundation

nonisolated enum ProcessRunnerError: LocalizedError {
    /// Carries the output captured BEFORE the deadline so a timed-out command
    /// (e.g. a build that printed 100 KB then hung) can still surface its partial
    /// stdout/stderr instead of returning empty.
    case timeout(TimeInterval, stdout: String, stderr: String)
    case executableNotFound(String)
    /// `Process.run()` refused to spawn even though the executable IS a present,
    /// runnable regular file — so the blame lies elsewhere. The overwhelmingly
    /// common cause is the working directory: a `currentDirectoryURL` that does
    /// not exist raises `NSCocoaErrorDomain 4`, and one the user cannot search
    /// (mode `0o000`) raises `NSPOSIXErrorDomain 13`. Measured 2026-08-08.
    ///
    /// Before this case existed both of those were reported as
    /// `executableNotFound(<login shell>)` — "Executable not found: /bin/zsh" —
    /// which is not merely vague but FALSE, and sends the model (and the user)
    /// hunting for a missing shell instead of looking at `working_directory`.
    case launchFailed(executable: String, reason: String)
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
        case .launchFailed(let executable, let reason):
            // ONE expression: this `switch` is a switch-EXPRESSION (implicit
            // returns), so an arm cannot be split into statements.
            "Could not start \(executable): \(reason). The executable itself is present and runnable — check that the working directory exists and is accessible."
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

    /// `reapsProcessGroup`: the command's process group dies with it — whatever it left running
    /// (`server &`) is killed once the command returns, times out or is cancelled, and the SIGKILL
    /// a stop escalates to reaches the whole group (`CommandProcessGroup`). `Process.terminate()`
    /// signals the group too, but only while the leader runs, and `kill(pid, SIGKILL)` reaches the
    /// leader alone (measured 2026-11-08). A role's
    /// `bash` asks for it (`runShell`); git and xcodebuild do not — a build service that outlives
    /// one build is how the next one is fast. `onLaunch` sees the process and its group right
    /// after the spawn, before anything is waited for — what lets a running command be found and
    /// stopped (`BackgroundBashRegistry.trackForeground`).
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60,
        reapsProcessGroup: Bool = false,
        onLaunch: ((Process, CommandProcessGroup?) -> Void)? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let dir = currentDirectory {
            process.currentDirectoryURL = dir
        }

        var processEnv = HostedMCPEnvironment.scrubbingHostedMCPVariables(
            from: ProcessInfo.processInfo.environment
        )
        if let env = environment {
            for (key, value) in env {
                processEnv[key] = value
            }
            processEnv = HostedMCPEnvironment.scrubbingHostedMCPVariables(from: processEnv)
        }
        process.environment = processEnv

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
            throw Self.launchError(executable: executable, underlying: error)
        }
        let group = reapsProcessGroup ? CommandProcessGroup(leading: process) : nil
        onLaunch?(process, group)

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
        // SIGTERM, then — after a 2 s grace to flush and exit — SIGKILL; to the whole group AND
        // the leader when the caller asked for a group (`CommandProcessGroup.stop`), since an
        // unconfined leader can leave the group recorded at its spawn. Until 2026-11-08 a TIMEOUT
        // sent SIGTERM and then waited with no bound, so a child that ignored SIGTERM hung the
        // call; only cancellation escalated. The final wait is bounded too: a SIGKILL nothing
        // received (the child was reaped meanwhile) must not hold the caller for ever — the
        // process is gone either way, and `isRunning` says which.
        func stopChild() {
            if group != nil {
                CommandProcessGroup.stop(SIGTERM, group: group, process: process)
            } else if process.isRunning {
                process.terminate()
            }
            if exitSemaphore.wait(timeout: .now() + .seconds(2)) == .timedOut {
                if group != nil {
                    CommandProcessGroup.stop(SIGKILL, group: group, process: process)
                } else {
                    let pid = process.processIdentifier
                    if pid > 0, process.isRunning { kill(pid, SIGKILL) }
                }
                _ = exitSemaphore.wait(timeout: .now() + .seconds(2))
            }
        }
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
                    stopChild()
                    break waitLoop
                }
                if Task.isCancelled {
                    didCancel = true
                    stopChild()
                    break waitLoop
                }
            }
        }
        // What the command left running dies with it — before the pipes are drained, since a
        // backgrounded child still holds them open. The leader is gone by now, so this is the
        // group alone, at the one moment its leftovers are certainly still in it.
        group?.signal(SIGKILL)

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

    /// Classifies a `Process.run()` spawn failure. Shared by `run` and
    /// `BackgroundBashRegistry.start`, which both used to report EVERY spawn
    /// failure as `executableNotFound(executable)`.
    ///
    /// The check is deliberately three-part rather than a bare
    /// `isExecutableFile`: that returns `true` for a DIRECTORY on macOS (the `x`
    /// bit means "searchable"), and a directory passed as the executable really
    /// is the not-found case. Only a present, non-directory, executable file is
    /// exonerated — anything else keeps the original, accurate diagnosis.
    static func launchError(executable: String, underlying: Error) -> ProcessRunnerError {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: executable, isDirectory: &isDir)
        guard exists, !isDir.boolValue, fm.isExecutableFile(atPath: executable) else {
            return .executableNotFound(executable)
        }
        // The OS's spawn reason, classified rather than localized: `Process.run()` throws
        // Cocoa file errors for a missing or unreadable working directory, and their
        // `localizedDescription` is the user's system language plus an absolute path —
        // both of which then ride the model's prompt prefix (playbook R1.8.2).
        return .launchFailed(executable: executable, reason: ToolErrorHandler.classify(underlying).message)
    }

    /// Run git command in specified directory
    static func runGit(
        _ arguments: [String],
        in directory: URL,
        timeout: TimeInterval = 60
    ) throws -> Result {
        try runGit(arguments, in: directory, environment: nil, timeout: timeout)
    }

    /// Run git command in specified directory with custom environment
    static func runGit(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String]?,
        timeout: TimeInterval = 60
    ) throws -> Result {
        try run(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: directory,
            environment: environment,
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

    struct RawResult: Sendable {
        var exitCode: Int32
        var stdoutData: Data
        var stderrData: Data

        var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
        var stderr: String { String(decoding: stderrData, as: UTF8.self) }
        var success: Bool { exitCode == 0 }

        init(exitCode: Int32, stdoutData: Data, stderrData: Data) {
            self.exitCode = exitCode
            self.stdoutData = stdoutData
            self.stderrData = stderrData
        }
    }

    /// `inheritsEnvironment: false` starts the child with `environment` and NOTHING else — no
    /// variable of the app's own environment reaches it. The snapshot store's git runs this way
    /// (S10, F6 2026-11-12): an inherited `GIT_WORK_TREE`, `GIT_DIR` or `GIT_CONFIG_PARAMETERS`
    /// changes what git reads and where it writes, and blanking each to "" is not the same as
    /// leaving it out (`GIT_WORK_TREE=""` alone makes `git init --bare` refuse).
    static func runAsync(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]? = nil,
        inheritsEnvironment: Bool = true,
        timeout: TimeInterval = 60,
        reapsProcessGroup: Bool = false,
        onLaunch: ((Process, CommandProcessGroup?) -> Void)? = nil
    ) async throws -> RawResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let dir = currentDirectory {
            process.currentDirectoryURL = dir
        }

        var processEnv = HostedMCPEnvironment.scrubbingHostedMCPVariables(
            from: inheritsEnvironment ? ProcessInfo.processInfo.environment : [:]
        )
        if let env = environment {
            for (key, value) in env {
                processEnv[key] = value
            }
            processEnv = HostedMCPEnvironment.scrubbingHostedMCPVariables(from: processEnv)
        }
        process.environment = processEnv

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = AsyncProcessState(process: process, timeout: timeout)
        // Before `run()`, as `run` does: delivery is guaranteed only for a handler set before the
        // child exits, and a short git call can exit before the line after `run()`.
        process.terminationHandler = { [weak state] proc in
            state?.handleTermination(status: proc.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            // Nothing reads the pipes yet, and their write ends are still the parent's: closed
            // here, so no reader is left waiting for an EOF no child will send (N6, F6
            // 2026-11-12 — the readers used to start before `run()` and hung the throw).
            process.terminationHandler = nil
            Self.closePipes(stdoutPipe, stderrPipe)
            throw Self.launchError(executable: executable, underlying: error)
        }

        // The readers start once there is a child to read from, on GCD threads — never a
        // cooperative one — and right away, so a child that fills a pipe's buffer is not blocked.
        let drain = PipeDrain(stdout: stdoutPipe, stderr: stderrPipe)

        let processGroup = reapsProcessGroup ? CommandProcessGroup(leading: process) : nil
        state.setGroup(processGroup)
        onLaunch?(process, processGroup)

        state.armTimeout()

        let exitStatus: Int32
        var caughtError: Error?
        do {
            exitStatus = try await withTaskCancellationHandler {
                try await state.waitForExit()
            } onCancel: {
                state.cancel()
            }
        } catch {
            caughtError = error
            exitStatus = -1
        }

        // What the command left running dies with it, as in `run`.
        processGroup?.signal(SIGKILL)
        let (stdoutData, stderrData) = await drain.collect()

        if let caughtError {
            if case ProcessRunnerError.timeout = caughtError {
                let outStr = String(decoding: stdoutData, as: UTF8.self)
                let errStr = String(decoding: stderrData, as: UTF8.self)
                throw ProcessRunnerError.timeout(timeout, stdout: outStr, stderr: errStr)
            }
            throw caughtError
        }

        return RawResult(
            exitCode: exitStatus,
            stdoutData: stdoutData,
            stderrData: stderrData
        )
    }

    /// Closes both ends of each pipe — what a failed spawn leaves the parent holding.
    fileprivate static func closePipes(_ pipes: Pipe...) {
        for pipe in pipes {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
    }

    static func runGitAsync(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String]? = nil,
        inheritsEnvironment: Bool = true,
        timeout: TimeInterval = 60
    ) async throws -> RawResult {
        try await runAsync(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: directory,
            environment: environment,
            inheritsEnvironment: inheritsEnvironment,
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
    ///
    /// The command's process group dies with it (`reapsProcessGroup`): a role keeps a process
    /// alive past its command through `run_in_background`, never through `&`.
    static func runShell(
        _ command: String,
        in directory: URL,
        timeout: TimeInterval,
        sandboxProfile: String?,
        onLaunch: ((Process, CommandProcessGroup?) -> Void)? = nil
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
            timeout: timeout,
            reapsProcessGroup: true,
            onLaunch: onLaunch
        )
    }

    /// Asks the WRAPPER why a sandboxed run failed, by re-launching the identical
    /// invocation with a shell no-op. The command under judgement does not participate,
    /// so there is nothing for it to forge.
    ///
    /// Measured on macOS 26 / arm64 — the three states separate deterministically:
    ///
    ///     healthy profile                          exit 0    → .childRan
    ///     bad profile                              exit 65   `sandbox-exec: syntax error…`
    ///     `(deny default)` (execvp refused)        exit 71   `sandbox-exec: execvp() of…`
    ///     `(deny default)(allow process*)`         exit 134  empty stderr → .confinedBeforeStart
    ///
    /// Cost: 30–40 ms, paid only on the failure path of a sandboxed foreground command.
    /// That is why this beats the two alternatives considered. An inherited extra file
    /// descriptor would mean abandoning `Process` (Darwin spawns with
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`, so fd 3 is closed without explicit `posix_spawn`
    /// file actions) and re-implementing `run`'s timeout loop, cancellation, SIGTERM/SIGKILL
    /// grace and bounded pipe drain — the most safety-critical loop here — to buy a fact this
    /// already yields. A stdout nonce is worse than the defect it fixes: `run` decodes with
    /// `String(data:encoding:.utf8) ?? ""`, so ONE invalid UTF-8 byte anywhere in the stream
    /// erases the nonce, the run reads as "the child never started", and with the fallback on
    /// it is re-executed unconfined — reachable by accident, not only by malice.
    ///
    /// Honest weakness, stated rather than buried: this answers "would the child start",
    /// which is a re-derivation, not an observation of the run that failed. It is
    /// deterministic because the profile is an inline `-p` string (no file to change
    /// underneath) and `sandbox-exec`'s failures are a function of that string plus the shell
    /// path. A transient `execvp` failure (ENOMEM) would probe clean and be reported as the
    /// command's own exit — the conservative direction, and the same one the classifier's
    /// doc comment already chose.
    ///
    /// A probe that itself throws yields `.childRan`: no unconfined retry, no false
    /// "did not run".
    static func probeSandboxLaunch(
        profile: String,
        in directory: URL,
        timeout: TimeInterval = 20
    ) -> SeatbeltSandbox.LaunchVerdict {
        // The SAME shell `runShell` used. Probing a different one would be blind to an
        // `execvp` failure of the real one.
        let (executable, arguments) = SeatbeltSandbox.probeInvocation(
            profile: profile, shell: loginShell())
        guard let result = try? run(
            executable: executable,
            arguments: arguments,
            currentDirectory: directory,
            timeout: timeout
        ) else {
            return .childRan
        }

        if result.exitCode == 0 { return .childRan }
        return SeatbeltSandbox.isWrapperDiagnostic(exitCode: result.exitCode, stderr: result.stderr)
            ? .wrapperRejected
            : .confinedBeforeStart
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

/// The two readers of an async run's pipes, and their BOUNDED collection: once the child has
/// exited, the readers get `drainBound` to reach EOF, then their read ends are closed and they
/// get one more second — the same bound as `run`'s. A grandchild that inherited a pipe (a
/// `repack` that outlived the `gc` it served, a command's own `&`) keeps it open for as long as
/// it lives, and until 2026-11-12 the async path waited for it with no bound, holding the
/// snapshot store's folder lock all that time (N6 of the F6 acceptance).
nonisolated private final class PipeDrain: @unchecked Sendable {
    static let drainBound: DispatchTimeInterval = .seconds(5)

    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stdoutBox = DataBox()
    private let stderrBox = DataBox()
    private let group = DispatchGroup()

    init(stdout: Pipe, stderr: Pipe) {
        stdoutPipe = stdout
        stderrPipe = stderr
        start(stdout, into: stdoutBox)
        start(stderr, into: stderrBox)
    }

    private func start(_ pipe: Pipe, into box: DataBox) {
        group.enter()
        DispatchQueue.global().async { [group] in
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
    }

    /// Both streams as far as they were read — whole, unless a grandchild held a pipe past the
    /// bound. The wait blocks a GCD thread, never a cooperative one.
    func collect() async -> (Data, Data) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                if group.wait(timeout: .now() + Self.drainBound) == .timedOut {
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                    _ = group.wait(timeout: .now() + .seconds(1))
                }
                continuation.resume(returning: (stdoutBox.data, stderrBox.data))
            }
        }
    }
}

nonisolated private final class AsyncProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let timeout: TimeInterval
    private var group: CommandProcessGroup?
    private var continuation: CheckedContinuation<Int32, any Error>?
    private var isTerminated = false
    private var didCancel = false
    private var didTimeout = false
    private var timeoutTask: Task<Void, Never>?

    init(process: Process, timeout: TimeInterval) {
        self.process = process
        self.timeout = timeout
    }

    func setGroup(_ group: CommandProcessGroup?) {
        lock.lock()
        self.group = group
        lock.unlock()
    }

    /// Under the lock, as `handleTermination` reads it — the two used to race (N6).
    func armTimeout() {
        guard timeout > 0 && timeout < .infinity else { return }
        let seconds = timeout
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleTimeout()
        }
        lock.lock()
        if isTerminated {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    func waitForExit() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isTerminated {
                let cancelled = didCancel
                let timedOut = didTimeout
                let status = process.terminationStatus
                lock.unlock()
                if cancelled {
                    continuation.resume(throwing: ProcessRunnerError.cancelled)
                } else if timedOut {
                    continuation.resume(throwing: ProcessRunnerError.timeout(timeout, stdout: "", stderr: ""))
                } else {
                    continuation.resume(returning: status)
                }
                return
            }
            if Task.isCancelled {
                didCancel = true
                lock.unlock()
                stopChild()
                continuation.resume(throwing: ProcessRunnerError.cancelled)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func handleTermination(status: Int32) {
        lock.lock()
        timeoutTask?.cancel()
        timeoutTask = nil
        isTerminated = true
        let c = continuation
        continuation = nil
        let cancelled = didCancel
        let timedOut = didTimeout
        lock.unlock()

        if cancelled {
            c?.resume(throwing: ProcessRunnerError.cancelled)
        } else if timedOut {
            c?.resume(throwing: ProcessRunnerError.timeout(timeout, stdout: "", stderr: ""))
        } else {
            c?.resume(returning: status)
        }
    }

    func cancel() {
        lock.lock()
        if isTerminated || didCancel {
            lock.unlock()
            return
        }
        didCancel = true
        lock.unlock()
        stopChild()
    }

    func handleTimeout() {
        lock.lock()
        if isTerminated || didTimeout || didCancel {
            lock.unlock()
            return
        }
        didTimeout = true
        lock.unlock()
        stopChild()
    }

    private func stopChild() {
        lock.lock()
        let grp = group
        let proc = process
        lock.unlock()

        if grp != nil {
            CommandProcessGroup.stop(SIGTERM, group: grp, process: proc)
        } else if proc.isRunning {
            proc.terminate()
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = self.process.isRunning
            let grp = self.group
            let proc = self.process
            self.lock.unlock()

            if stillRunning {
                if grp != nil {
                    CommandProcessGroup.stop(SIGKILL, group: grp, process: proc)
                } else {
                    let pid = proc.processIdentifier
                    if pid > 0, proc.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
    }
}
