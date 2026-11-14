import Foundation

/// The loopback ports NanoTeams has dialled or bound with a credential or a prompt on them in this
/// process — and what that does to the commands a role's `bash` is running.
///
/// A role's command is confined by the Seatbelt profile it was launched with, for its whole life
/// (`SeatbeltSandbox.profile`): no process can be given another one. A port that joined the list
/// after a command started is therefore one that command may hold — listen on it beside the real
/// server, or before it — and would receive what NanoTeams is about to send there. So
/// `reserve(_:)` runs right before such a dial or bind and stops, at once, every confined command
/// whose profile lacks the port: background commands (`BackgroundBashRegistry`) and the
/// foreground ones running right now (`trackForeground`). Every later profile gets the port too
/// (`ports`), including those built by a batch that read its list before the reservation.
///
/// Thread-safe (`NSLock`), not `@MainActor`: the MCP manager reserves on the main actor, LLM
/// clients on whatever thread builds the request, `bash` on the tool batch's. No lock is held
/// while another type's lock is taken.
nonisolated final class LoopbackPortReservations: @unchecked Sendable {

    static let shared = LoopbackPortReservations(registry: .shared)

    /// A confined FOREGROUND command — announced before its spawn (`beginForeground`), attached
    /// to its process the moment it has one (`attach`), tracked until it returns
    /// (`untrackForeground`) — so a reservation stops it as it stops a background command, and its
    /// `bash` result can say why. `guardedPorts` never changes; the rest is written under the
    /// reservations' lock.
    final class ForegroundRun: @unchecked Sendable {
        let guardedPorts: Set<UInt16>
        fileprivate var process: Process?
        fileprivate var group: CommandProcessGroup?
        fileprivate var stopReason: String?

        fileprivate init(guardedPorts: Set<UInt16>) {
            self.guardedPorts = guardedPorts
        }
    }

    private let registry: BackgroundBashRegistry
    private let lock = NSLock()
    private var reserved: Set<UInt16> = []
    private var foreground: [ObjectIdentifier: ForegroundRun] = [:]

    init(registry: BackgroundBashRegistry) {
        self.registry = registry
    }

    /// Every port reserved in this process so far. Only grows: a port NanoTeams stopped dialling
    /// stays closed to roles until the app quits, which costs a role one port and leaves no window.
    var ports: Set<UInt16> { lock.withLock { reserved } }

    // MARK: - Reserving

    /// Records `ports` as reserved and stops every running confined command whose profile lacks
    /// one of them — `SIGKILL` to its whole process group (`CommandProcessGroup`): a command that is
    /// not trusted to hold the port is not trusted to honour a request to stop, and once the signal
    /// is delivered it runs no more code, so nothing it accepted is ever read. Returns the ids of
    /// the background commands it stopped. Port 0 names no port.
    ///
    /// What a command took out of its group itself (`setsid`, a shell with job control) is out of
    /// every group NanoTeams knows, and what outlived an app that crashed is unknown to the next
    /// one — DEBTS.md D-M16 records both.
    @discardableResult
    func reserve(_ ports: Set<UInt16>) -> [String] {
        let ports = ports.subtracting([0])
        guard !ports.isEmpty else { return [] }
        let staleRuns: [ForegroundRun] = lock.withLock {
            reserved.formUnion(ports)
            return foreground.values.filter { run in
                guard run.stopReason == nil else { return false }
                let missing = ports.subtracting(run.guardedPorts)
                guard !missing.isEmpty else { return false }
                run.stopReason = Self.stopReason(forReserved: missing)
                return true
            }
        }
        var stopping: [(process: Process, group: CommandProcessGroup?)] = []
        for run in staleRuns {
            if let attached = lock.withLock({ run.process.map { (process: $0, group: run.group) } }) {
                // Tracked with its pid: this reservation stops it.
                if CommandProcessGroup.kill(attached.group, process: attached.process) {
                    stopping.append(attached)
                } else {
                    lock.withLock { run.stopReason = nil }
                }
            } else if let attached = awaitAttachment(of: run) {
                // Being spawned right now: `attach` finds the reason set above and stops it the
                // moment the pid is known; what is awaited below is that stop. Until 2026-11-08 a
                // run was tracked only once it had a pid, and a reservation landing in between
                // returned past a child it never saw, while the child came up under the old
                // profile.
                stopping.append(attached)
            }
        }
        let stopped = registry.stopConfinedCommands(lacking: ports, reason: Self.stopReason(forReserved:))
        // The caller binds or dials next. A killed process runs no more code, but until it is
        // gone its socket still holds the port — the External Agents listener's bind on `::1` would
        // fail on it — so wait for each to be reaped, leader and group, a second at most.
        CommandProcessGroup.awaitExit(of: stopping + registry.commands(of: stopped))
        return stopped
    }

    /// The process of a run announced but not yet attached, waiting up to a second for the spawn
    /// in progress (one takes milliseconds). `nil` when none came: the spawn failed, and
    /// `untrackForeground` drops the run.
    private func awaitAttachment(of run: ForegroundRun) -> (process: Process, group: CommandProcessGroup?)? {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if let attached = lock.withLock({ run.process.map { (process: $0, group: run.group) } }) {
                return attached
            }
            usleep(5_000)
        } while Date() < deadline
        return nil
    }

    /// The port an outgoing request to `url` uses when it lands on this machine, reserved
    /// (`reserve(_:)`) — what every request to an LLM server calls before its first byte goes out
    /// (`URLRequest.applyLMStudioBearer`). A remote URL reserves nothing.
    func reserve(forRequestTo url: URL?) {
        guard let url, let port = SeatbeltSandbox.loopbackPort(of: url) else { return }
        reserve([port])
    }

    /// A background command just started under a profile reserving `guardedPorts`: one reserved
    /// since that profile was built is a port it lacks, and it is stopped at once. Paired with the
    /// scan in `reserve(_:)` — whichever of the two runs second sees the other's write.
    func enforce(onBackgroundCommand commandID: String, guardedPorts: Set<UInt16>) {
        let lacking = ports.subtracting(guardedPorts)
        guard !lacking.isEmpty else { return }
        registry.stopConfinedCommand(commandID, reason: Self.stopReason(forReserved: lacking))
    }

    // MARK: - Foreground commands

    /// Announces a confined foreground command about to be spawned under `guardedPorts`. It is
    /// tracked from this moment, before it has a pid: a reservation landing while it is being
    /// spawned finds it, marks it stale and waits for `attach` to stop it — instead of returning
    /// past a child it never saw and dialling while that child comes up under the old profile.
    func beginForeground(guardedPorts: Set<UInt16>) -> ForegroundRun {
        let run = ForegroundRun(guardedPorts: guardedPorts)
        lock.withLock { foreground[ObjectIdentifier(run)] = run }
        return run
    }

    /// Attaches the spawned process to its announced run — `ProcessRunner.runShell`'s `onLaunch`,
    /// right after the spawn. A port reserved since the run's profile was built, before the
    /// announcement or after it, stops the command at once; a reservation that marked the run
    /// while it was pending is waiting for exactly this stop (`reserve`).
    func attach(_ process: Process, group: CommandProcessGroup?, to run: ForegroundRun) {
        let stale: Bool = lock.withLock {
            run.process = process
            run.group = group
            if run.stopReason == nil {
                let lacking = reserved.subtracting(run.guardedPorts)
                if !lacking.isEmpty { run.stopReason = Self.stopReason(forReserved: lacking) }
            }
            return run.stopReason != nil
        }
        if stale, !CommandProcessGroup.kill(group, process: process) {
            lock.withLock { run.stopReason = nil }
        }
    }

    /// `beginForeground` and `attach` in one call, for a process that already runs.
    func trackForeground(
        _ process: Process, group: CommandProcessGroup?, guardedPorts: Set<UInt16>
    ) -> ForegroundRun {
        let run = beginForeground(guardedPorts: guardedPorts)
        attach(process, group: group, to: run)
        return run
    }

    /// Forgets a foreground command once it returned, and says why NanoTeams stopped it, if it did.
    func untrackForeground(_ run: ForegroundRun) -> String? {
        lock.withLock {
            foreground[ObjectIdentifier(run)] = nil
            return run.stopReason
        }
    }

    // MARK: - What the role is told

    /// What the role reads about a command a reservation stopped — in `bash_output` for a
    /// background command, in the `bash` result's warnings for a foreground one.
    static func stopReason(forReserved ports: Set<UInt16>) -> String {
        let list = ports.sorted().map(String.init).joined(separator: ", ")
        let noun = ports.count == 1 ? "port" : "ports"
        return "NanoTeams stopped this command: local \(noun) \(list) became reserved after it "
            + "started, and a running command keeps the sandbox it started with. Start it again if "
            + "you still need it — on another port if it listened on \(list)."
    }

    #if DEBUG
    /// Forgets the reserved ports — for a test that asserts on them in a process other suites share.
    func _testForget() {
        lock.withLock { reserved.removeAll() }
    }

    /// How many foreground commands are tracked right now — for a test that must reserve while one runs.
    var _testTrackedForegroundCount: Int { lock.withLock { foreground.count } }
    #endif
}
