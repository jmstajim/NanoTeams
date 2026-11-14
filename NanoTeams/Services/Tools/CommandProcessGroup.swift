import Foundation

/// The process group a role's shell command runs in — what NanoTeams signals to stop the command
/// AND everything it started.
///
/// `Process` makes the child the leader of a group of its own: measured 2026-11-08, the child's
/// pgid is its pid and never the app's. So the group id is the child's pid, and a group is
/// recorded only when that holds — a signal meant for a command can never reach the app's own
/// group, nor the broadcast `kill(-1, …)` sends. POSIX keeps a pid from being reused while a group
/// with that id still has members, so the group can be signalled after its leader exited: that is
/// how what a command left running (`server &`, `nohup … &`) is stopped with it.
///
/// A group signal alone is not the whole stop — see `stop(_:group:process:)`. A process the role
/// took out of the group itself (`setsid`, a shell with job control) is out of every group
/// NanoTeams knows and has no pid it holds, which stays in DEBTS.md D-M16.
nonisolated struct CommandProcessGroup: Sendable, Equatable {

    /// The group's id, which is also the pid of the process leading it — the two are the same
    /// number by construction, since a group's id IS its leader's pid.
    let id: pid_t

    /// The group `process` leads, read right after `run()`. A child that already exited is still
    /// recorded — it was made the leader at spawn, so its pid is the group's id — and nothing is
    /// recorded for a child in any other group, the app's included.
    init?(leading process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return nil }
        let group = getpgid(pid)
        guard group == pid || (group == -1 && errno == ESRCH) else { return nil }
        self.init(id: pid)
    }

    /// `nil` for no group, for the app's own, and for 1 — `kill(-1, …)` is not a group signal at
    /// all but a broadcast to every process the user can signal. The one home of that rule: both
    /// inits come through here and `id` is a `let`, so `signal` and `hasMembers` trust it.
    init?(id: pid_t) {
        guard id > 1, id != getpgrp() else { return nil }
        self.id = id
    }

    /// Sends `signal` to every process in the group; `false` when none received it — the group
    /// is gone, or was never there. The leader is in it only while it has not moved itself out,
    /// so a stop goes through `stop(_:group:process:)` instead; this is for the leftovers of a
    /// command whose leader has just exited, which is the one moment they are certainly here.
    @discardableResult
    func signal(_ signal: Int32) -> Bool {
        Darwin.kill(-id, signal) == 0
    }
}

extension CommandProcessGroup {

    /// Sends `signal` to everything a RUNNING command is: its process group, and its leader.
    /// `false` when nothing received it — the command had already ended on its own.
    ///
    /// The leader is signalled by its own pid because a group signal does not reach it once it
    /// has moved itself into another group. Unconfined, the leader IS the role's own command
    /// (`ProcessRunner.runShell` with no profile launches the login shell directly), so a command
    /// that `exec`s a process manager can leave the group recorded at its spawn: measured
    /// 2026-11-08 — the group signal then answers ESRCH and the command runs on, which is how a
    /// command started with the sandbox off could survive the stop that switching the sandbox on
    /// makes (`BackgroundBashRegistry.stopUnconfinedCommands`). Confined, the leader is
    /// `sandbox-exec`, which a role cannot move: it is the role's ancestor, not its child.
    ///
    /// Both targets are safe because the leader is still unreaped, which this checks: the kernel
    /// holds its pid while NanoTeams holds it, and a group whose leader is alive is this command's
    /// group. A command that has ALREADY FINISHED is not signalled at all — its leftovers went
    /// down as it exited (the registry's termination handler, `ProcessRunner`'s post-wait group
    /// signal), and by any later moment its pid, and an empty group's id, are free to belong to
    /// something else. Until 2026-11-08 the late stops signalled a finished command's group
    /// anyway, and `stop` reported success for a command that outlived its group.
    @discardableResult
    nonisolated static func stop(
        _ signal: Int32, group: CommandProcessGroup?, process: Process
    ) -> Bool {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return false }
        // Both, not one or the other: the group carries what the command started, the pid carries
        // the leader wherever it went. Ordered group-first so a leader still leading its own group
        // does not outlive its children by a syscall.
        let reachedGroup = group?.signal(signal) ?? false
        let reachedLeader = Darwin.kill(pid, signal) == 0
        return reachedGroup || reachedLeader
    }

    /// Whether any process is in the group right now — `kill(-id, 0)` answers ESRCH for an empty
    /// one. A group that outlived its leader keeps its id until its last member is reaped.
    nonisolated var hasMembers: Bool {
        Darwin.kill(-id, 0) == 0 || errno == EPERM
    }

    /// Waits until each command is gone — its leader reaped AND its group empty — `timeout` for
    /// all of them together. Both, because the socket on a guarded port may be held by a member
    /// other than the leader (`sh -c 'server &'`), and until that member is reaped the External
    /// Agents listener's bind still fails on it. A SIGKILLed member runs no code, so what is
    /// awaited here is the port, never a leak. Until 2026-11-08 only the leader was awaited.
    nonisolated static func awaitExit(
        of commands: [(process: Process, group: CommandProcessGroup?)], timeout: TimeInterval = 1
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        for command in commands {
            while command.process.isRunning || command.group?.hasMembers == true, Date() < deadline {
                usleep(5_000)
            }
        }
    }

    /// `awaitExit(of:timeout:)` for processes whose group is not known — the leader alone.
    nonisolated static func awaitExit(of processes: [Process], timeout: TimeInterval = 1) {
        awaitExit(of: processes.map { (process: $0, group: nil) }, timeout: timeout)
    }

    /// `SIGKILL` to the command — its group and its leader (`stop(_:group:process:)`). `false`
    /// when nothing received it: the command had already ended on its own.
    @discardableResult
    nonisolated static func kill(_ group: CommandProcessGroup?, process: Process) -> Bool {
        stop(SIGKILL, group: group, process: process)
    }
}
