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

            let sandboxProfile = sandboxEnabled
                ? SeatbeltSandbox.profile(
                    workFolderRoot: workFolderRoot,
                    permissions: sandboxPermissions,
                    fileManager: fileManager)
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
            let result: ProcessRunner.Result
            do {
                result = try runForeground(
                    command: command, cwd: cwd, timeout: timeoutSec, sandboxProfile: sandboxProfile)
            } catch let ProcessRunnerError.timeout(_, stdout, stderr) {
                // Surface whatever the command printed before the deadline.
                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: BashResult(
                        exit_code: nil, stdout: stdout, stderr: stderr, timed_out: true,
                        sandboxed: sandboxProfile != nil))
            }
            // ProcessRunnerError.cancelled propagates to ToolErrorHandler → makeCancelledResult.

            // Sandbox failed to launch and no fallback was allowed.
            if let sandboxProfile, sandboxProfile != "",
               SeatbeltSandbox.isSandboxDenialFailure(exitCode: result.exitCode, stderr: result.stderr),
               !allowUnsandboxedFallback {
                return makeErrorResult(
                    toolName: Self.name, args: args, code: .bashDenied,
                    message: "The macOS sandbox failed to initialize for this command, and the unsandboxed fallback is disabled in Settings. Command was not run.")
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: BashResult(
                    exit_code: Int(result.exitCode),
                    stdout: result.stdout,
                    stderr: result.stderr,
                    timed_out: false,
                    sandboxed: sandboxProfile != nil))
        }
    }

    /// Runs the command sandboxed; if the sandbox wrapper itself fails to launch
    /// and the policy allows it, retries unsandboxed.
    private func runForeground(
        command: String, cwd: URL, timeout: TimeInterval, sandboxProfile: String?
    ) throws -> ProcessRunner.Result {
        let result = try ProcessRunner.runShell(
            command, in: cwd, timeout: timeout, sandboxProfile: sandboxProfile)
        if sandboxProfile != nil,
           SeatbeltSandbox.isSandboxDenialFailure(exitCode: result.exitCode, stderr: result.stderr),
           allowUnsandboxedFallback {
            return try ProcessRunner.runShell(command, in: cwd, timeout: timeout, sandboxProfile: nil)
        }
        return result
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
