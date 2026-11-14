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
    /// The names a command is sent under. A NARROWING of what was accepted before 2026-11-09,
    /// on purpose: the old resolver took eleven body names and then any single remaining
    /// string, BEFORE the declared `command` — so `{"command":"ls","content":"…"}` ran the
    /// `content`. Now two spellings refuse the call, and a key outside this list is refused by
    /// name instead of run as a command. `description` is the agent-harness habit of saying
    /// what a command does; it is not part of what runs.
    static let undeclaredArguments: [String: UndeclaredArgument] = [
        "content": .alias(of: "command"), "text": .alias(of: "command"), "body": .alias(of: "command"),
        "code": .alias(of: "command"), "cmd": .alias(of: "command"), "script": .alias(of: "command"),
        "description": .ignored(reason: "a command's description is not part of what runs"),
    ]
    // Usable with no work folder open: in default-storage mode the sandbox root is the
    // Application Support dir (a real, bootstrapped directory), and write scope is governed
    // by the existing Settings → Bash sandbox permissions — no work folder is required.
    static let blockedInDefaultStorage = false
    static let excludedInMeetings = true

    let workFolderRoot: URL
    let resolver: SandboxPathResolver
    // `nonisolated(unsafe)`: see `ToolHandlerDependencies.fileManager`.
    nonisolated(unsafe) let fileManager: FileManager
    // No sandbox settings here: they ride each batch (`ToolExecutionContext.bashSandbox`).

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(
            workFolderRoot: dependencies.workFolderRoot,
            resolver: dependencies.resolver,
            fileManager: dependencies.fileManager
        )
    }

    func handle(context: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // Resolve the command through the SHARED resolver so the handler runs
            // exactly the string the permission gate evaluated (no alternative-key
            // or `content`-decoy bypass).
            guard let command = BashArguments.command(from: args) else {
                throw ToolArgumentError.missingRequired("command")
            }

            // Resolve and validate the working directory (stays inside the sandbox).
            // Resolved as written: `bash` runs INSIDE Seatbelt, which decides on the path the
            // kernel resolved, and a `cd` in the command reaches the same place anyway — so
            // real-path containment here only refused the monorepo and `npm link` layouts that
            // address a sibling checkout through a link (#376).
            let cwd = try resolver.resolveWorkingDirectoryURL(
                relativePath: optionalString(args, "working_directory"))
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
                return makeErrorResult(
                    toolName: Self.name, args: args, code: .notADirectory,
                    message: "working_directory does not exist or is not a directory — send a directory relative to the work folder, or omit working_directory to run at its root.",
                    next: NextHint(
                        suggested_cmd: ToolNames.listFiles,
                        suggested_args: ["path": "."],
                        reason: "See the directories under the work folder"
                    ))
            }

            // Reject a non-positive timeout (a sign typo) instead of silently
            // clamping it to 1s; clamp the upper bound to the ceiling.
            guard let timeoutSec = BashArguments.resolveTimeoutSeconds(milliseconds: optionalInt(args, "timeout")) else {
                throw ToolArgumentError.invalidValue(
                    key: "timeout", detail: "must be a positive number of milliseconds.")
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
            // user's own grants allow and write nothing. The sandbox settings themselves come
            // with the batch too (`ToolExecutionContext.bashSandbox`): the switch, the grants and
            // the fallback a person changes mid-step govern the next command, where a handler
            // field baked once per step by `ToolHandlerRegistry.buildHandlers` carried the old
            // setting to the task's close in chat mode (review 2026-11-08).
            //
            // The fallback goes off with the phase: `allowUnsandboxedFallback` re-runs the
            // command with NO confinement, which would silently retract the very guarantee that
            // admits `bash` to the phase.
            let sandbox = context.bashSandbox
            let effectivePermissions = context.isPlanningPhase
                ? sandbox.permissions.withWritesDisabled()
                : sandbox.permissions
            let effectiveFallback = context.isPlanningPhase ? false : sandbox.allowUnsandboxedFallback

            // The loopback ports NanoTeams's own servers and connections use — read per BATCH,
            // like the phase above, because a server configured mid-step is dialled at once
            // (`ToolExecutionContext.guardedLoopbackPorts`) — plus every port a dial has reserved
            // since, which a batch already in flight did not read (`LoopbackPortReservations`).
            let guardedPorts = SeatbeltSandbox.effectiveGuardedPorts(
                context.guardedLoopbackPorts + LoopbackPortReservations.shared.ports)
            let sandboxProfile = sandbox.enabled
                ? SeatbeltSandbox.profile(
                    workFolderRoot: workFolderRoot,
                    permissions: effectivePermissions,
                    guardedLoopbackPorts: guardedPorts)
                : nil

            // MARK: Background
            if runInBackground {
                do {
                    // The ports go with the entry: the process keeps this profile for its whole
                    // life, and one launched before a port was reserved is stopped before that
                    // port is dialled (`LoopbackPortReservations.reserve`) — or right now, when the
                    // reservation landed while this profile was being built (`enforce`).
                    let confinement = sandboxProfile.map {
                        BackgroundBashRegistry.Confinement(profile: $0, guardedPorts: Set(guardedPorts))
                    }
                    let id = try BackgroundBashRegistry.shared.start(
                        command: command, directory: cwd, confinement: confinement,
                        taskID: context.taskID)
                    if let confinement {
                        LoopbackPortReservations.shared.enforce(
                            onBackgroundCommand: id, guardedPorts: confinement.guardedPorts)
                    }
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
                    // Classified, not localized: `Process.run()` failures arrive as Cocoa
                    // errors, whose `localizedDescription` is in the USER's system language
                    // and names absolute paths. `classify` also picks the right code — a
                    // spawn refused because `working_directory` does not exist is an
                    // argument problem, not a command failure.
                    let (code, message) = ToolErrorHandler.classify(error)
                    return makeErrorResult(
                        toolName: Self.name, args: args, code: code,
                        message: "Failed to start background command: \(message) Check the command and its working_directory.")
                }
            }

            // MARK: Foreground
            // ProcessRunnerError.cancelled propagates to ToolErrorHandler → makeCancelledResult.
            let (outcome, reservationStop) = try runForeground(
                command: command, cwd: cwd, timeout: timeoutSec, sandboxProfile: sandboxProfile,
                guardedPorts: Set(guardedPorts), fallbackAllowed: effectiveFallback)
            // A reservation stopped it while it ran: its exit is NanoTeams's SIGKILL, not the
            // command's own failure — nor the clock's, when it was already timing out — and the
            // role is told so on either arm.
            let stopWarnings: [String] = reservationStop.map { [$0] } ?? []

            switch outcome {
            case .timedOut(let stdout, let stderr, let ranSandboxed):
                // Surface whatever the command printed before the deadline.
                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: BashResult(
                        exit_code: nil, stdout: stdout, stderr: stderr, timed_out: true,
                        sandboxed: ranSandboxed,
                        writes_blocked: context.isPlanningPhase ? true : nil),
                    meta: ToolResultMeta(warnings: stopWarnings))

            case .completed(let result, let ranSandboxed, let launch):
                // The wrapper refused and no fallback was allowed: nothing ran, and now that is
                // a fact the WRAPPER reported rather than one inferred from a stream the command
                // could write. The condition lives in `SeatbeltSandbox.response` — the retry
                // gate in `runForeground` asks about the same verdict and the same flag, and a
                // rule with two homes can disagree with itself (#51/#60).
                if SeatbeltSandbox.response(
                    ranSandboxed: ranSandboxed, launch: launch,
                    fallbackAllowed: effectiveFallback) == .reportNothingRan {
                    return makeErrorResult(
                        toolName: Self.name, args: args, code: .bashDenied,
                        message: "The macOS sandbox failed to initialize for this command, and running unsandboxed is not permitted. The command was not run — this is an environment failure, not an argument problem.")
                }

                // A profile that compiled but killed the shell before the command started: the
                // result IS honest (exit 134, empty output), but on its own it reads as the
                // command failing. Say what happened without flipping `isError` — same reasoning
                // as `planningWriteDenialMeta`: the envelope's structural fields stay true and a
                // warning adds the cause.
                var meta = Self.planningWriteDenialMeta(
                    isPlanningPhase: context.isPlanningPhase,
                    exitCode: result.exitCode, stderr: result.stderr)
                meta.warnings += Self.sandboxDenialWarnings(
                    ranSandboxed: ranSandboxed, isPlanningPhase: context.isPlanningPhase,
                    exitCode: result.exitCode, stderr: result.stderr, guardedPorts: guardedPorts)
                meta.warnings += stopWarnings
                if ranSandboxed, launch == .confinedBeforeStart {
                    meta.warnings += [
                        "The sandbox profile denied the reads the shell needs to start, so the command never ran. This is the confinement working, not an argument problem — narrow what the command touches, or ask the Supervisor to widen the bash sandbox scopes."
                    ]
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
                    meta: meta)
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
    /// `launch` answers "did the command actually run", and it is computed ONCE here and read
    /// by both consumers. Before, `runForeground` and `handle` each classified independently
    /// from `result.stderr` — two derivations of one fact, and under the probe design that
    /// would also mean two extra process launches per failing command.
    ///
    /// `.timedOut` needs no verdict: a wrapper failure exits in milliseconds, so a timeout is
    /// itself proof the child ran.
    private enum ForegroundOutcome {
        case completed(ProcessRunner.Result, ranSandboxed: Bool, launch: SeatbeltSandbox.LaunchVerdict)
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

    /// The same missing explanation outside the planning phase. A sandboxed command refused a
    /// write outside its scopes, a connection to or a listener on a port NanoTeams reserves, or a
    /// signal to a process it did not start, reads `Operation not permitted` — which a model takes
    /// for a file it lacks rights to, or a reason for `sudo` — and the reserved ports are nowhere
    /// else it could learn them: a dev server on `localhost:3000` breaks the moment a person
    /// configures an MCP server there (review 2026-11-08). One line naming the scopes, the ports
    /// and the signal rule, added only when the command ran sandboxed, failed, and said that; the
    /// planning phase has its own. Worded as the usual cause, not the certain one: TCC, SIP and
    /// file flags say the same words.
    /// The refusal every role meets first (D-M19 S8, 2026-11-12): the profile closes
    /// `.nanoteams/internal` — the node itself, so `stat`/`opendir` of it are refused too — and a
    /// recursive command from the work folder's root (`find .`, `grep -r`, `du`, `cp -R`) reports
    /// it and exits non-zero after doing everything else (`SeatbeltInternalDenyRecursionTests`).
    /// The generic warning sends a model hunting for a write scope or a permission it lacks; this
    /// one says the rest of the output stands and how to leave the directory out. The profile is
    /// not narrowed instead: a visible node with closed contents fails the same walks one level
    /// down, and the deny is what keeps `snapshots.git` and `teams.json` from a role.
    static let internalDenialWarning =
        "\(NTMSPaths.internalRelativePath) is NanoTeams' own and closed to commands, so a command "
        + "that walks into it reports it and exits non-zero after doing the rest — its other output "
        + "stands. Leave it out: grep -r --exclude-dir=.nanoteams, "
        + "find . -path ./.nanoteams -prune -o -print, or run on a subdirectory."

    static func sandboxDenialWarnings(
        ranSandboxed: Bool, isPlanningPhase: Bool, exitCode: Int32, stderr: String,
        guardedPorts: [UInt16]
    ) -> [String] {
        guard ranSandboxed, !isPlanningPhase, exitCode != 0 else { return [] }
        // Per refused line: one on `.nanoteams/internal` is the deny every recursive walk from the
        // root meets, and gets its own warning; any other keeps the generic one (D-M19 S8).
        let refused = stderr.split(whereSeparator: \.isNewline)
            .filter { $0.lowercased().contains("operation not permitted") }
        guard !refused.isEmpty else { return [] }
        var warnings: [String] = []
        if refused.contains(where: { $0.contains(NTMSPaths.internalRelativePath) }) {
            warnings.append(internalDenialWarning)
        }
        guard refused.contains(where: { !$0.contains(NTMSPaths.internalRelativePath) }) else { return warnings }
        let ports = guardedPorts.map(String.init).joined(separator: ", ")
        return warnings + [
            "Operation not permitted from a sandboxed command usually means the bash sandbox refused "
                + "it, not file permissions, and sudo does not lift it. Commands may write only where "
                + "the sandbox allows (the work folder and temporary directories by default), may "
                + "neither connect to nor listen on these reserved ports: \(ports), and may signal "
                + "only processes the same command started — stop a background command with "
                + "bash_output. Use another port or path.",
        ]
    }

    /// `fallbackAllowed` is passed IN rather than read off `self.allowUnsandboxedFallback`: the
    /// planning phase forces it off per call, and a parameter that shadowed the stored property
    /// would silently hand the stored value to any future use added inside this function.
    ///
    /// A sandboxed run is tracked while it runs (`LoopbackPortReservations.trackForeground`): a
    /// port reserved meanwhile stops it like a background command, and the second value says
    /// why. The command's whole process group dies when it returns (`ProcessRunner.runShell`).
    private func runForeground(
        command: String, cwd: URL, timeout: TimeInterval, sandboxProfile: String?,
        guardedPorts: Set<UInt16>, fallbackAllowed: Bool
    ) throws -> (ForegroundOutcome, reservationStop: String?) {
        let reservations = LoopbackPortReservations.shared
        func run(profile: String?) throws -> (ForegroundOutcome, reservationStop: String?) {
            let tracked = TrackedRun()
            // Announced BEFORE the spawn, so a reservation landing while the child comes up finds
            // it and waits for the stop (`LoopbackPortReservations.beginForeground`); an
            // unconfined run is not tracked — nothing is reserved for it.
            if profile != nil { tracked.handle = reservations.beginForeground(guardedPorts: guardedPorts) }
            // A launch failure or a cancellation leaves by `throw`: forget the run there too.
            defer { if let handle = tracked.handle { _ = reservations.untrackForeground(handle) } }
            do {
                let result = try ProcessRunner.runShell(
                    command, in: cwd, timeout: timeout, sandboxProfile: profile,
                    onLaunch: tracked.handle.map { run in
                        { process, group in reservations.attach(process, group: group, to: run) }
                    })
                // Ask the wrapper only when there IS one and something went wrong. On the
                // success path and on an unconfined run the answer is known without spending
                // 30–40 ms on a second process.
                let launch: SeatbeltSandbox.LaunchVerdict
                if let profile, result.exitCode != 0 {
                    launch = ProcessRunner.probeSandboxLaunch(profile: profile, in: cwd)
                } else {
                    launch = .childRan
                }
                let stop = tracked.handle.flatMap { reservations.untrackForeground($0) }
                tracked.handle = nil
                return (.completed(result, ranSandboxed: profile != nil, launch: launch), stop)
            } catch let ProcessRunnerError.timeout(_, stdout, stderr) {
                let stop = tracked.handle.flatMap { reservations.untrackForeground($0) }
                tracked.handle = nil
                return (.timedOut(stdout: stdout, stderr: stderr, ranSandboxed: profile != nil), stop)
            }
        }

        let first = try run(profile: sandboxProfile)
        // Only a wrapper REJECTION licenses an unconfined retry. `.confinedBeforeStart` is a
        // profile doing its job — retrying without it would defeat the confinement the user
        // asked for — and it is now refused by a case name instead of by a text rule declining
        // it for the right reason. Same owner as the envelope arm in `handle`.
        guard case .completed(_, let ranSandboxed, let launch) = first.0,
              SeatbeltSandbox.response(
                  ranSandboxed: ranSandboxed, launch: launch,
                  fallbackAllowed: fallbackAllowed) == .retryUnconfined
        else { return first }
        return try run(profile: nil)
    }
}

/// The foreground run `runForeground` announces before the spawn and attaches in `ProcessRunner`'s
/// launch hook — set and read on the calling thread, before and after the wait; never shared
/// across threads.
private nonisolated final class TrackedRun: @unchecked Sendable {
    var handle: LoopbackPortReservations.ForegroundRun?
}

// MARK: - bash_output

/// Reads incremental output from — or stops — a background command started by
/// `bash` with `run_in_background: true`.
nonisolated struct BashOutputTool: ToolHandler {
    /// `ToolErrorNotePolicy` appends "Fix the arguments and retry" plus the required list for
    /// every `INVALID_ARGS`; what it cannot know is WHERE a valid value comes from — the one
    /// fact this message adds (playbook R1.8.1). One string for both actions.
    static func unknownCommandIDMessage(_ commandID: String) -> String {
        "Unknown command_id '\(commandID)' — send the command_id returned by bash with run_in_background: true."
    }

    static let name = TN.bashOutput
    static let schema = ToolSchema(
        name: TN.bashOutput,
        description: """
        Read new output from a background command started by `bash` (run_in_background). \
        Returns output produced since your last read, whether it is still running, and its \
        exit code once finished.
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

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let commandID = try requiredString(args, "command_id")
            let action = (optionalString(args, "action") ?? "read").lowercased()

            if action == "stop" {
                let stopped = BackgroundBashRegistry.shared.stop(commandID: commandID)
                guard stopped else {
                    return makeErrorResult(
                        toolName: Self.name, args: args, code: .invalidArgs,
                        message: Self.unknownCommandIDMessage(commandID))
                }
                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: BashOutputData(
                        command_id: commandID, command: nil, output: nil,
                        running: false, exit_code: nil, status: "stopped", stop_reason: nil))
            }

            guard let read = BackgroundBashRegistry.shared.read(commandID: commandID) else {
                return makeErrorResult(
                    toolName: Self.name, args: args, code: .invalidArgs,
                    message: Self.unknownCommandIDMessage(commandID))
            }
            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: BashOutputData(
                    command_id: commandID,
                    command: read.command,
                    output: read.newOutput,
                    running: read.running,
                    exit_code: read.exitCode.map(Int.init),
                    status: read.running ? "running" : (read.stopReason == nil ? "finished" : "stopped"),
                    stop_reason: read.stopReason))
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
    /// Why NanoTeams stopped the command, when it did (`BackgroundBashRegistry`'s stop reason) —
    /// omitted otherwise, so an ordinary read carries no new key.
    let stop_reason: String?
}
