import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - bash

/// Runs a shell command through the user's login shell, confined by a macOS
/// Seatbelt sandbox (writes limited to the work folder + temp). Whether a given
/// command is *allowed* to reach this handler is decided upstream by the command
/// permission gate (`LLMExecutionService+CommandGate`) — this handler only
/// executes commands the gate already cleared.
nonisolated struct BashTool: ToolHandler {
    static let name = TN.bash
    static let schema = ToolSchema(
        name: TN.bash,
        description: """
        Run a shell command in the project work folder via your login shell \
        (supports pipes, &&, globs, redirection). A non-zero exit code is normal output, \
        not a tool error — read `exit_code`/`stderr`. Output is returned verbatim (text); \
        redirect binary output to a file. Commands run inside a sandbox that confines writes \
        to the work folder and temp directories.
        """,
        parameters: JS.object(
            properties: [
                "command": JS.string("The shell command to run."),
                "timeout": JS.integer("Timeout in milliseconds (max 600000)."),
                "working_directory": JS.string(
                    "Directory to run in, relative to the work folder. Defaults to the work folder root."),
                "run_in_background": JS.boolean(
                    "Run detached and return a command_id immediately — for servers, watchers, other long-running processes."),
            ],
            required: ["command"]
        )
    )
    static let category: ToolCategory = .shell
    // Usable with no work folder open: in default-storage mode the sandbox root is the
    // Application Support dir (a real, bootstrapped directory), and write scope is governed
    // by the existing Settings → Bash sandbox permissions — no work folder is required.
    static let blockedInDefaultStorage = false
    static let excludedInMeetings = true

    let workFolderRoot: URL
    let resolver: SandboxPathResolver
    let fileManager: FileManager
    let sandboxEnabled: Bool
    let sandboxPermissions: BashSandboxPermissions
    let allowUnsandboxedFallback: Bool

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(
            workFolderRoot: dependencies.workFolderRoot,
            resolver: dependencies.resolver,
            fileManager: dependencies.fileManager,
            sandboxEnabled: dependencies.bashSandboxEnabled,
            sandboxPermissions: dependencies.bashSandboxPermissions,
            allowUnsandboxedFallback: dependencies.bashAllowUnsandboxedFallback
        )
    }

    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // Resolve the command through the SHARED resolver so the handler runs
            // exactly the string the permission gate evaluated (no alternative-key
            // or `content`-decoy bypass).
            guard let command = BashArguments.command(from: args) else {
                throw ToolArgumentError.missingRequired("command")
            }

            // Resolve and validate the working directory (stays inside the sandbox).
            let cwd = try resolver.resolveFileURL(relativePath: optionalString(args, "working_directory"))
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
                return makeErrorResult(
                    toolName: Self.name, args: args, code: .notADirectory,
                    message: "working_directory does not exist or is not a directory.")
            }

            // Reject a non-positive timeout (a sign typo) instead of silently
            // clamping it to 1s; clamp the upper bound to the ceiling.
            guard let timeoutSec = BashArguments.resolveTimeoutSeconds(milliseconds: optionalInt(args, "timeout")) else {
                return makeErrorResult(
                    toolName: Self.name, args: args, code: .invalidArgs,
                    message: "timeout must be a positive number of milliseconds.")
            }
            let runInBackground = optionalBool(args, "run_in_background", default: false)

            // A detached process keeps the profile it was LAUNCHED with for its whole life, and
            // during the planning phase that profile blocks every write. It would carry the block
            // across the boundary and past it, unfixable — so refuse rather than hand back a
            // permanently crippled server. `plan_required`, not INVALID_ARGS: the argument is
            // well-formed, the PHASE is the blocker, and the identical call works next turn.
            if context.isPlanningPhase, runInBackground {
                return makePlanRequiredResult(
                    toolName: Self.name, args: args,
                    message: "Background commands are unavailable until your plan is recorded — a "
                        + "detached process would keep this phase's write-blocked sandbox for its "
                        + "whole life. Run it in the foreground, or start it after calling "
                        + "update_scratchpad.")
            }

            // Per-call narrowing: during the planning phase the command may read anything the
            // user's own grants allow and write nothing. It CANNOT ride the handler's stored
            // fields — those are baked once per step by `ToolHandlerRegistry.buildHandlers`, and
            // the phase flips mid-step, so `context` is the only channel that carries it.
            //
            // The fallback goes off with it: `allowUnsandboxedFallback` re-runs the command with
            // NO confinement, which would silently retract the very guarantee that admits `bash`
            // to the phase.
            let effectivePermissions = context.isPlanningPhase
                ? sandboxPermissions.withWritesDisabled()
                : sandboxPermissions
            let effectiveFallback = context.isPlanningPhase ? false : allowUnsandboxedFallback

            let sandboxProfile = sandboxEnabled
                ? SeatbeltSandbox.profile(
                    workFolderRoot: workFolderRoot,
                    permissions: effectivePermissions)
                : nil

            // MARK: Background
            if runInBackground {
                do {
                    let id = try BackgroundBashRegistry.shared.start(
                        command: command, directory: cwd, sandboxProfile: sandboxProfile,
                        taskID: context.taskID)
                    return makeSuccessResult(
                        toolName: Self.name, args: args,
                        data: BashBackgroundData(
                            command_id: id, status: "running",
                            message: "Command started in the background. Use bash_output with this command_id to read its output or stop it."),
                        next: NextHint(
                            suggested_cmd: TN.bashOutput,
                            suggested_args: ["command_id": id],
                            reason: "Read background command output"))
                } catch {
                    return makeErrorResult(
                        toolName: Self.name, args: args, code: .commandFailed,
                        message: "Failed to start background command: \(error.localizedDescription)")
                }
            }

            // MARK: Foreground
            // ProcessRunnerError.cancelled propagates to ToolErrorHandler → makeCancelledResult.
            let outcome = try runForeground(
                command: command, cwd: cwd, timeout: timeoutSec, sandboxProfile: sandboxProfile,
                fallbackAllowed: effectiveFallback)

            switch outcome {
            case .timedOut(let stdout, let stderr, let ranSandboxed):
                // Surface whatever the command printed before the deadline.
                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: BashResult(
                        exit_code: nil, stdout: stdout, stderr: stderr, timed_out: true,
                        sandboxed: ranSandboxed,
                        writes_blocked: context.isPlanningPhase ? true : nil))

            case .completed(let result, let ranSandboxed):
                // Sandbox failed to launch and no fallback was allowed. `ranSandboxed` keeps this
                // branch off the post-fallback path, where the command demonstrably DID run.
                if ranSandboxed, let sandboxProfile, sandboxProfile != "",
                   SeatbeltSandbox.isSandboxDenialFailure(exitCode: result.exitCode, stderr: result.stderr),
                   !effectiveFallback {
                    return makeErrorResult(
                        toolName: Self.name, args: args, code: .bashDenied,
                        message: "The macOS sandbox failed to initialize for this command, and running unsandboxed is not permitted. The command was not run — this is an environment failure, not an argument problem.")
                }

                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: BashResult(
                        exit_code: Int(result.exitCode),
                        stdout: result.stdout,
                        stderr: result.stderr,
                        timed_out: false,
                        sandboxed: ranSandboxed,
                        writes_blocked: context.isPlanningPhase ? true : nil),
                    meta: Self.planningWriteDenialMeta(
                        isPlanningPhase: context.isPlanningPhase,
                        exitCode: result.exitCode, stderr: result.stderr))
            }
        }
    }

    /// What a foreground run actually did, including whether a sandbox was in effect.
    ///
    /// `ProcessRunner.Result` carries only exit code / stdout / stderr, so returning it alone
    /// discarded the one fact the caller could not recover: after an unsandboxed retry the caller's
    /// `sandboxProfile` local is still non-nil, and the envelope rebuilt `sandboxed` from it —
    /// reporting `true` for a command that ran with no confinement at all. The timeout arm needs
    /// the same fact, and a `throw` cannot carry it, so the timeout is returned as data here rather
    /// than thrown past the boundary. Cancellation still propagates: it is not an outcome.
    private enum ForegroundOutcome {
        case completed(ProcessRunner.Result, ranSandboxed: Bool)
        case timedOut(stdout: String, stderr: String, ranSandboxed: Bool)
    }

    /// Runs the command sandboxed; if the sandbox WRAPPER itself fails to launch and the policy
    /// allows it, retries unsandboxed. A timeout is never a wrapper failure, so it never retries.
    ///
    /// The retry deliberately gets the full `timeout` again: a wrapper failure is decided before
    /// the child starts, so the first attempt costs milliseconds, and shortening the second would
    /// silently give the model less time than it asked for.
    /// A write the SANDBOX refused reaches the model as an ORDINARY non-zero exit: the schema
    /// says outright that a non-zero exit is normal output, `isError` stays false, and
    /// `ToolErrorNotePolicy.direction` runs only for `result.isError`. So the retry contract cannot be
    /// taught there — it is taught here, in the envelope, and only here. Without it the model
    /// reads `Operation not permitted` and concludes the file is protected, or that it needs
    /// `sudo`, neither of which is true.
    ///
    /// A `meta.warnings` line rather than an error envelope, on purpose: the command RAN, part
    /// of its stdout may be perfectly valid, and flipping `isError` would contradict the schema
    /// AND drop the result out of `MemoryTagStore.processBash`, which passes errors through
    /// untagged.
    ///
    /// The stderr substring is a heuristic and is allowed to be one: it only ever ADDS a
    /// sentence, and the structural fact (`writes_blocked` on the envelope) is reported whether
    /// or not it matches.
    private static func planningWriteDenialMeta(
        isPlanningPhase: Bool, exitCode: Int32, stderr: String
    ) -> ToolResultMeta {
        guard isPlanningPhase, exitCode != 0,
              stderr.lowercased().contains("operation not permitted")
        else { return ToolResultMeta() }
        return ToolResultMeta(warnings: [
            "This write was refused by the planning-phase sandbox, not by the shell or the "
                + "filesystem. Record your findings and numbered plan with update_scratchpad; "
                + "writes unlock on the next turn.",
        ])
    }

    /// `fallbackAllowed` is passed IN rather than read off `self.allowUnsandboxedFallback`: the
    /// planning phase forces it off per call, and a parameter that shadowed the stored property
    /// would silently hand the stored value to any future use added inside this function.
    private func runForeground(
        command: String, cwd: URL, timeout: TimeInterval, sandboxProfile: String?,
        fallbackAllowed: Bool
    ) throws -> ForegroundOutcome {
        func run(profile: String?) throws -> ForegroundOutcome {
            do {
                let result = try ProcessRunner.runShell(
                    command, in: cwd, timeout: timeout, sandboxProfile: profile)
                return .completed(result, ranSandboxed: profile != nil)
            } catch let ProcessRunnerError.timeout(_, stdout, stderr) {
                return .timedOut(stdout: stdout, stderr: stderr, ranSandboxed: profile != nil)
            }
        }

        let first = try run(profile: sandboxProfile)
        guard case .completed(let result, _) = first,
              sandboxProfile != nil,
              SeatbeltSandbox.isSandboxDenialFailure(exitCode: result.exitCode, stderr: result.stderr),
              fallbackAllowed
        else { return first }
        return try run(profile: nil)
    }
}

// MARK: - bash_output

/// Reads incremental output from — or stops — a background command started by
/// `bash` with `run_in_background: true`.
nonisolated struct BashOutputTool: ToolHandler {
    static let name = TN.bashOutput
    static let schema = ToolSchema(
        name: TN.bashOutput,
        description: """
        Read new output from a background command started by `bash` (run_in_background), \
        or stop it. Returns output produced since your last read, whether it is still \
        running, and its exit code once finished.
        """,
        parameters: JS.object(
            properties: [
                "command_id": JS.string("Id of the background command."),
                "action": JS.string("read fetches new output; stop terminates the command.",
                                    enumValues: ["read", "stop"]),
            ],
            required: ["command_id"]
        )
    )
    static let category: ToolCategory = .shell
    // Usable with no work folder open (mirrors `bash`) — reads the background command
    // registry, needs no folder.
    static let blockedInDefaultStorage = false
    static let excludedInMeetings = true

    static func makeInstance(dependencies _: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let commandID = try requiredString(args, "command_id")
            let action = (optionalString(args, "action") ?? "read").lowercased()

            if action == "stop" {
                let stopped = BackgroundBashRegistry.shared.stop(commandID: commandID)
                guard stopped else {
                    return makeErrorResult(
                        toolName: Self.name, args: args, code: .invalidArgs,
                        message: "Unknown command_id '\(commandID)'.")
                }
                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: BashOutputData(
                        command_id: commandID, command: nil, output: nil,
                        running: false, exit_code: nil, status: "stopped"))
            }

            guard let read = BackgroundBashRegistry.shared.read(commandID: commandID) else {
                return makeErrorResult(
                    toolName: Self.name, args: args, code: .invalidArgs,
                    message: "Unknown command_id '\(commandID)'.")
            }
            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: BashOutputData(
                    command_id: commandID,
                    command: read.command,
                    output: read.newOutput,
                    running: read.running,
                    exit_code: read.exitCode.map(Int.init),
                    status: read.running ? "running" : "finished"))
        }
    }
}

// MARK: - Result payloads

private nonisolated struct BashResult: Encodable {
    let exit_code: Int?
    let stdout: String
    let stderr: String
    let timed_out: Bool
    let sandboxed: Bool
    /// `true` while the step is in its planning phase, where the Seatbelt profile is rebuilt
    /// with every write scope off. Optional so the synthesized `Encodable` OMITS the key
    /// outside the phase — a `false` on every ordinary bash call would be schema noise on the
    /// wire for a fact that is only ever interesting when it is true.
    let writes_blocked: Bool?
}

private nonisolated struct BashBackgroundData: Encodable {
    let command_id: String
    let status: String
    let message: String
}

private nonisolated struct BashOutputData: Encodable {
    let command_id: String
    let command: String?
    let output: String?
    let running: Bool
    let exit_code: Int?
    let status: String
}
