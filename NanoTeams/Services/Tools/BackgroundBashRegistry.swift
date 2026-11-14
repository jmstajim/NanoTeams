import Foundation

/// Process-wide registry of background shell commands started by `bash` with
/// `run_in_background: true`. Each command runs as a detached `Process` whose
/// stdout+stderr are redirected to a log file under the temp directory; `bash_output`
/// reads incremental output and can stop the process.
///
/// Thread-safe (`NSLock`), NOT `@MainActor` — `bash` handlers execute inside the
/// detached tool batch (`executeToolCalls`), off the main actor. `terminate(taskID:)` /
/// `terminateAll()` are called on task close / work-folder switch so a long-running background
/// process doesn't outlive its task.
///
/// A command is its PROCESS GROUP (`CommandProcessGroup`): every stop signals the group, so what
/// the command started stops with it, and when the command's shell exits whatever it left
/// running (`server &`) is killed — a process outlives its command only by leaving the group
/// itself (DEBTS.md D-M16). Which of its commands a reserved loopback port stops is
/// `LoopbackPortReservations`'s call (`stopConfinedCommands(lacking:reason:)`).
nonisolated final class BackgroundBashRegistry: @unchecked Sendable {

    static let shared = BackgroundBashRegistry()

    /// One running (or finished-but-unreaped) background command. Mutable fields
    /// (`running`, `exitCode`, `readOffset`) are only ever touched under the
    /// registry's lock or from the process termination handler, so the unchecked
    /// conformance is sound.
    private final class Entry: @unchecked Sendable {
        let id: String
        let command: String
        let outputURL: URL
        let process: Process
        let taskID: Int
        /// Monotonic creation order — used to evict the OLDEST finished entries
        /// when the retained-entry cap is exceeded.
        let seq: Int
        /// The loopback ports the command's profile reserves, for its whole life; `nil` when it
        /// runs unconfined (sandbox off), which no reservation is about.
        let guardedPorts: Set<UInt16>?
        var running: Bool = true
        var exitCode: Int32?
        var readOffset: UInt64 = 0
        /// Why NanoTeams stopped the command itself (`LoopbackPortReservations`,
        /// `stopUnconfinedCommands`), for `bash_output`.
        var stopReason: String?
        /// The command's process group, recorded right after the spawn — what every stop signals.
        var group: CommandProcessGroup?
        init(
            id: String, command: String, outputURL: URL, process: Process, taskID: Int, seq: Int,
            guardedPorts: Set<UInt16>?
        ) {
            self.id = id
            self.command = command
            self.outputURL = outputURL
            self.process = process
            self.taskID = taskID
            self.seq = seq
            self.guardedPorts = guardedPorts
        }
    }

    /// How a background command is confined: the Seatbelt profile it runs under for its whole
    /// life, and the loopback ports that profile reserves. One value, so no command can be
    /// launched under a profile whose ports the registry does not know.
    struct Confinement: Sendable, Equatable {
        let profile: String
        let guardedPorts: Set<UInt16>
    }

    struct ReadResult {
        let command: String
        let newOutput: String
        let running: Bool
        let exitCode: Int32?
        /// Set when NanoTeams stopped the command itself, saying why.
        let stopReason: String?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var counter = 0

    /// The app's registry is `shared`, for the life of the process. A test may hold one of its
    /// own — to drop it while a command still runs, say — and nothing else builds one.
    init() {}

    /// A background command is still running — a role's process, alive between its step's turns
    /// and after them. What the Add agent sheet asks before a token goes to the clipboard (#375).
    var hasRunningCommands: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.contains { $0.running }
    }

    /// Directory holding background command logs — one per PROCESS. A log is named by this
    /// registry's counter, which restarts at 1 in every process, while the temporary directory is
    /// the user's, shared by every process they run: two processes both writing `bg_1.log`
    /// replaced each other's file, and a command that printed and exited 0 read back as having
    /// printed nothing (parallel test processes, 2026-11-08).
    static var logDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nanoteams-bg", isDirectory: true)
            .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
    }

    // MARK: - Start

    /// Launches a background command. Returns the assigned `command_id`, or throws
    /// if the process can't be started.
    func start(
        command: String,
        directory: URL,
        confinement: Confinement?,
        taskID: Int
    ) throws -> String {
        let shell = ProcessRunner.loginShell()
        let executable: String
        let arguments: [String]
        if let confinement {
            (executable, arguments) = SeatbeltSandbox.wrap(
                profile: confinement.profile, shell: shell, command: command)
        } else {
            executable = shell
            arguments = ["-lc", command]
        }

        let seq = nextSeq()
        let id = "bg_\(seq)"
        let fm = FileManager.default
        try fm.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        let outputURL = Self.logDir.appendingPathComponent("\(id).log")
        fm.createFile(atPath: outputURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: outputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = HostedMCPEnvironment.scrubbingHostedMCPVariables(
            from: ProcessInfo.processInfo.environment
        )
        process.standardOutput = writeHandle
        process.standardError = writeHandle

        let entry = Entry(
            id: id, command: command, outputURL: outputURL,
            process: process, taskID: taskID, seq: seq, guardedPorts: confinement?.guardedPorts)

        // Mark finished + close the write handle when the child exits. The handler
        // for `terminationHandler` runs on an arbitrary queue — guard with the lock.
        // What the command left running in its group dies with it: a process that outlived its
        // shell would keep this command's profile — and any port it holds — with nothing here
        // tracking it. That signal is the command's, not the registry's: a registry gone by then
        // (none in the app; a test's) has long returned from this `start`, the one writer of
        // `entry.group`, so the group is read without it. A command with no recorded group — one
        // whose leader was not leading its own group at the spawn — has nothing to signal here:
        // the group numbered by its pid is somebody else's.
        process.terminationHandler = { [weak self] proc in
            try? writeHandle.close()
            let group: CommandProcessGroup?
            if let self {
                group = self.lock.withLock {
                    entry.running = false
                    entry.exitCode = proc.terminationStatus
                    return entry.group
                }
            } else {
                group = entry.group
            }
            group?.signal(SIGKILL)
        }

        // Spawned AND inserted under the lock: a reservation's scan (`stopConfinedCommands`)
        // either runs before this spawn — and `enforce`, right after the start, sees the port it
        // reserved — or after the insert, and sees the entry. Until 2026-11-08 the insert
        // followed the spawn outside the lock, and a reservation landing between the two
        // returned past a child it never saw. A spawn is milliseconds, and nothing else is
        // awaited here; a termination handler for a child that exits at once waits for this
        // lock and runs after it.
        //
        // Insert, then evict the oldest FINISHED entries of THIS TASK beyond the
        // per-task cap so a long-lived task running many background commands can't
        // accumulate unbounded Entry objects + log files. Running entries are never
        // evicted; one task's activity never evicts another task's output.
        let evicted: [Entry]
        do {
            evicted = try lock.withLock {
                try process.run()
                entry.group = CommandProcessGroup(leading: process)
                entries[id] = entry
            let snapshot = entries.values.map { (id: $0.id, running: $0.running, seq: $0.seq, taskID: $0.taskID) }
            let ids = Self.overflowFinishedIDs(
                entries: snapshot, cap: BashConstants.maxRetainedBackgroundCommands, taskID: taskID)
                let victims = ids.compactMap { entries[$0] }
                for id in ids { entries[id] = nil }
                return victims
            }
        } catch {
            try? writeHandle.close()
            try? fm.removeItem(at: outputURL)
            // NOT an unconditional `executableNotFound`: `bash` validates the
            // working directory exists before it gets here, but "exists" is not
            // "spawnable" — a directory the user cannot search (mode 0o000) still
            // passes `fileExists` and then fails the spawn with EACCES. Reporting
            // that as "Executable not found: /bin/zsh" is a false statement about
            // the one thing that is definitely fine.
            throw ProcessRunner.launchError(executable: executable, underlying: error)
        }
        reap(evicted)
        return id
    }

    /// Pure eviction policy, scoped to ONE task: among `entries` belonging to
    /// `taskID`, when that task's count exceeds `cap`, returns the ids of its
    /// OLDEST finished (`!running`) entries to drop, fewest needed to get back to
    /// `cap`. Entries of OTHER tasks are never returned (a task's background output
    /// is only evicted by that same task's later commands, never by unrelated
    /// activity). Running entries are never returned. If too few are finished,
    /// returns all this task's finished — the cap is then best-effort until more
    /// of its commands finish.
    static func overflowFinishedIDs(
        entries: [(id: String, running: Bool, seq: Int, taskID: Int)], cap: Int, taskID: Int
    ) -> [String] {
        let scoped = entries.filter { $0.taskID == taskID }
        guard scoped.count > cap else { return [] }
        let overflow = scoped.count - cap
        return scoped
            .filter { !$0.running }
            .sorted { $0.seq < $1.seq }
            .prefix(overflow)
            .map(\.id)
    }

    /// Splits a freshly-read byte run into the part that is decodable NOW and the part that
    /// must wait for more bytes.
    ///
    /// Reads are incremental against a process that is still writing, so a read routinely
    /// lands in the MIDDLE of a multi-byte character. The previous code did
    /// `String(data:encoding:.utf8) ?? ""` and then advanced the offset by `data.count`
    /// unconditionally: one straddling character nilled the decode of the WHOLE chunk, the
    /// empty string was reported as the new output, and the offset moved past bytes nobody
    /// had seen. The model got `{newOutput: "", running: true}` — indistinguishable from
    /// "nothing new yet" — and the lost bytes were unrecoverable. Any non-ASCII log hits
    /// this; this project's own logs are Russian.
    ///
    /// So: decode the longest complete prefix and CONSUME ONLY THAT, leaving a trailing
    /// incomplete sequence (at most 3 bytes) pending for the next read, which will find it
    /// completed.
    ///
    /// `moreBytesExpected` is what keeps that from becoming a different leak. Once the
    /// process has exited no further bytes are coming, so a trailing partial sequence would
    /// be withheld forever — output silently truncated at the last read. On that final read
    /// the remainder is flushed lossily instead: the replacement character is visible, an
    /// absent tail is not.
    ///
    /// Genuinely non-UTF-8 output (a command that writes binary to stdout) also decodes
    /// lossily and is consumed, because leaving it pending would wedge every subsequent read
    /// of that command on the same byte.
    static func decodeIncremental(_ data: Data, moreBytesExpected: Bool) -> (text: String, consumed: Int) {
        if data.isEmpty { return ("", 0) }
        if let whole = String(data: data, encoding: .utf8) { return (whole, data.count) }

        if moreBytesExpected {
            // Walk back over at most the 3 continuation bytes a 4-byte sequence can trail,
            // to the byte that starts the final sequence. If that sequence is short of the
            // length its lead byte declares, it is a straddle, not corruption.
            let bytes = [UInt8](data)
            let scanFloor = max(0, bytes.count - 4)
            var i = bytes.count - 1
            while i >= scanFloor {
                let b = bytes[i]
                let isContinuation = b & 0b1100_0000 == 0b1000_0000
                if !isContinuation {
                    let declared: Int
                    if b & 0b1000_0000 == 0 { declared = 1 }
                    else if b & 0b1110_0000 == 0b1100_0000 { declared = 2 }
                    else if b & 0b1111_0000 == 0b1110_0000 { declared = 3 }
                    else if b & 0b1111_1000 == 0b1111_0000 { declared = 4 }
                    else { declared = 0 }  // 0xF8… is never a legal lead byte
                    let present = bytes.count - i
                    if declared > present {
                        // The head is decoded LOSSILY, not strictly. Gating the straddle on
                        // the head decoding cleanly meant one invalid byte ANYWHERE earlier
                        // in the same read window sent control to the whole-chunk consume
                        // below — destroying a character that was legitimately split at the
                        // boundary and whose second half was already on its way. The
                        // invalid byte is already doomed to render as U+FFFD either way;
                        // the split character need not be. Measured: with the strict gate,
                        // `[0xFF] + "Привет".utf8.prefix(11)` loses `т` outright.
                        //
                        // `i == 0` (the whole chunk is one partial character) yields
                        // ("", 0): nothing consumed, so the next read retries from here.
                        return (String(decoding: data.prefix(i), as: UTF8.self), i)
                    }
                    break
                }
                i -= 1
            }
        }

        return (String(decoding: data, as: UTF8.self), data.count)
    }

    // MARK: - Read

    /// Returns output produced since the last read (incremental). `nil` if the
    /// command_id is unknown.
    ///
    /// The offset read, the file read, and the offset write happen under ONE lock
    /// acquisition so two concurrent `bash_output` reads of the same command_id
    /// (e.g. parallel roles) can't both consume from the same offset and
    /// double-report / skip output. The file I/O runs inside the lock; background
    /// logs are small and the only contender is the termination handler, which
    /// briefly waits on the same lock (no nested lock, no await → no deadlock).
    func read(commandID: String) -> ReadResult? {
        lock.withLock {
            guard let entry = entries[commandID] else { return nil }
            var newOutput = ""
            if let handle = try? FileHandle(forReadingFrom: entry.outputURL) {
                defer { try? handle.close() }
                try? handle.seek(toOffset: entry.readOffset)
                let data = (try? handle.readToEnd()) ?? Data()
                let decoded = Self.decodeIncremental(data, moreBytesExpected: entry.running)
                newOutput = decoded.text
                entry.readOffset += UInt64(decoded.consumed)
            }
            return ReadResult(
                command: entry.command,
                newOutput: newOutput,
                running: entry.running,
                exitCode: entry.exitCode,
                stopReason: entry.stopReason)
        }
    }

    // MARK: - Stop

    /// Stops a background command: SIGTERM to its whole process group, then SIGKILL if it is
    /// still running two seconds later. Returns `false` for unknown IDs.
    ///
    /// The recorded group, not `Process.terminate()`. That one does signal the group — measured
    /// 2026-11-08, as NSTask documents ("the receiver and all of its subtasks") — but only while
    /// the shell runs, and it never escalates: until 2026-11-08 a server that ignored SIGTERM, or
    /// one whose shell had already returned, survived `stop`. This is now the only way a role can
    /// stop its own background command, since a later `bash` call may not signal it
    /// (`(allow signal (target same-sandbox))`).
    @discardableResult
    func stop(commandID: String) -> Bool {
        let entry: Entry? = lock.withLock { entries[commandID] }
        guard let entry else { return false }
        Self.stopGracefully(entry.group, process: entry.process)
        return true
    }

    // MARK: - Stops a reservation decides

    /// Stops every running CONFINED command whose profile lacks one of `ports`, saying why
    /// (`reason` of the missing ports), with `SIGKILL` to its whole process group — the stop
    /// `LoopbackPortReservations.reserve(_:)` decides. An unconfined command is not one: with the
    /// sandbox off nothing is reserved for any command (`stopUnconfinedCommands`). Returns the ids
    /// it stopped; a command that had already ended keeps no stop reason.
    func stopConfinedCommands(lacking ports: Set<UInt16>, reason: (Set<UInt16>) -> String) -> [String] {
        let stale: [Entry] = lock.withLock {
            entries.values.filter { entry in
                guard entry.running, entry.stopReason == nil, let guarded = entry.guardedPorts else { return false }
                let missing = ports.subtracting(guarded)
                guard !missing.isEmpty else { return false }
                entry.stopReason = reason(missing)
                return true
            }
        }
        return kill(stale)
    }

    /// The commands with these ids — each process with its group — what a caller that just
    /// stopped them waits on (`CommandProcessGroup.awaitExit`).
    func commands(of commandIDs: [String]) -> [(process: Process, group: CommandProcessGroup?)] {
        lock.withLock { commandIDs.compactMap { entries[$0].map { (process: $0.process, group: $0.group) } } }
    }

    /// Stops one confined command with `reason` — the one `LoopbackPortReservations.enforce`
    /// found launched under a profile older than a reservation.
    func stopConfinedCommand(_ commandID: String, reason: String) {
        let entry: Entry? = lock.withLock {
            guard let entry = entries[commandID], entry.running, entry.stopReason == nil,
                  entry.guardedPorts != nil else { return nil }
            entry.stopReason = reason
            return entry
        }
        if let entry { _ = kill([entry]) }
    }

    /// Stops every background command that runs unconfined — started while the bash sandbox was
    /// off — once it is switched back on (`StoreConfiguration.bashSandboxEnabled`): nothing confines
    /// such a command, so it could hold any port and write anywhere, under a setting that now says
    /// otherwise. Returns the ids it stopped.
    @discardableResult
    func stopUnconfinedCommands() -> [String] {
        let unconfined: [Entry] = lock.withLock {
            entries.values.filter { entry in
                guard entry.running, entry.stopReason == nil, entry.guardedPorts == nil else { return false }
                entry.stopReason = Self.sandboxSwitchedOnStopReason
                return true
            }
        }
        return kill(unconfined)
    }

    static let sandboxSwitchedOnStopReason =
        "NanoTeams stopped this command: it was started while the bash sandbox was off, and the "
        + "sandbox is on now. Start it again to run it inside the sandbox."

    /// `SIGKILL` to each entry's group; the ids that received it, sorted. An entry nothing received
    /// it for had already ended on its own — between the scan that claimed it and this signal —
    /// and loses the stop reason set for it: nothing was stopped.
    private func kill(_ stale: [Entry]) -> [String] {
        var stopped: [String] = []
        for entry in stale {
            if CommandProcessGroup.kill(entry.group, process: entry.process) {
                stopped.append(entry.id)
            } else {
                lock.withLock { entry.stopReason = nil }
            }
        }
        return stopped.sorted()
    }

    #if DEBUG
    /// Puts a finished command back into the state between its exit and this registry's
    /// observation of it — `running` as a scan reads it, the process gone as the signal finds it.
    /// That is the window `kill(_:)` compensates for by dropping the reason the scan set, and it
    /// is microseconds wide: a test cannot land in it by timing, so it is put there.
    func _testSimulateExitNotYetObserved(_ commandID: String) {
        lock.withLock { entries[commandID]?.running = true }
    }
    #endif

    // MARK: - Lifecycle cleanup

    /// Terminates and forgets every background command owned by a task, deleting
    /// its log file. Called from `stopEngine(for:)` (task close / removal /
    /// delegation stop / recurrence supersede).
    func terminate(taskID: Int) {
        let toKill: [Entry] = lock.withLock {
            let matches = entries.values.filter { $0.taskID == taskID }
            for e in matches { entries[e.id] = nil }
            return Array(matches)
        }
        reap(toKill)
    }

    /// Terminates and forgets every background command (work-folder switch /
    /// shutdown), deleting their log files. Called from `stopAllEngines()`.
    func terminateAll() {
        let toKill: [Entry] = lock.withLock {
            let all = Array(entries.values)
            entries.removeAll()
            return all
        }
        reap(toKill)
    }

    /// Stops each command's whole group (`stopGracefully`) and deletes its log file.
    private func reap(_ entries: [Entry]) {
        for e in entries {
            Self.stopGracefully(e.group, process: e.process)
            try? FileManager.default.removeItem(at: e.outputURL)
        }
    }

    /// SIGTERM to the command — its group and its leader (`CommandProcessGroup.stop`; with no
    /// recorded group, the leader alone) — then SIGKILL two seconds later if it is still running.
    ///
    /// A command that has already finished is not signalled: its leftovers went down in the
    /// termination handler as it exited, and by any later moment its pid, and its empty group's
    /// id, may belong to something else — pids on this Mac are handed out sequentially and wrap
    /// in hours (measured 2026-11-08). Until then a finished command's group was signalled on
    /// `stop`, on task close and on folder switch, hours after it ended.
    private static func stopGracefully(_ group: CommandProcessGroup?, process: Process) {
        guard CommandProcessGroup.stop(SIGTERM, group: group, process: process) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
            CommandProcessGroup.kill(group, process: process)
        }
    }

    private func nextSeq() -> Int {
        lock.withLock {
            counter += 1
            return counter
        }
    }
}
