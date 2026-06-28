import Foundation

/// Process-wide registry of background shell commands started by `bash` with
/// `run_in_background: true`. Each command runs as a detached `Process` whose
/// stdout+stderr are redirected to a log file under the temp directory; `bash_output`
/// reads incremental output and can stop the process.
///
/// Thread-safe (`NSLock`), NOT `@MainActor` — `bash` handlers execute inside the
/// detached tool batch (`executeToolCalls`), off the main actor. Lifecycle is
/// best-effort: `terminate(taskID:)` / `terminateAll()` are called on task
/// close / work-folder switch so a long-running background process doesn't
/// outlive its task.
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
        var running: Bool = true
        var exitCode: Int32?
        var readOffset: UInt64 = 0
        init(id: String, command: String, outputURL: URL, process: Process, taskID: Int, seq: Int) {
            self.id = id
            self.command = command
            self.outputURL = outputURL
            self.process = process
            self.taskID = taskID
            self.seq = seq
        }
    }

    struct ReadResult {
        let command: String
        let newOutput: String
        let running: Bool
        let exitCode: Int32?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var counter = 0

    private init() {}

    /// Directory holding background command logs.
    private static var logDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nanoteams-bg", isDirectory: true)
    }

    // MARK: - Start

    /// Launches a background command. Returns the assigned `command_id`, or throws
    /// if the process can't be started.
    func start(
        command: String,
        directory: URL,
        sandboxProfile: String?,
        taskID: Int
    ) throws -> String {
        let shell = ProcessRunner.loginShell()
        let executable: String
        let arguments: [String]
        if let profile = sandboxProfile {
            (executable, arguments) = SeatbeltSandbox.wrap(profile: profile, shell: shell, command: command)
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
        process.standardOutput = writeHandle
        process.standardError = writeHandle

        let entry = Entry(
            id: id, command: command, outputURL: outputURL,
            process: process, taskID: taskID, seq: seq)

        // Mark finished + close the write handle when the child exits. The handler
        // for `terminationHandler` runs on an arbitrary queue — guard with the lock.
        process.terminationHandler = { [weak self] proc in
            try? writeHandle.close()
            guard let self else { return }
            self.lock.withLock {
                entry.running = false
                entry.exitCode = proc.terminationStatus
            }
        }

        do {
            try process.run()
        } catch {
            try? writeHandle.close()
            try? fm.removeItem(at: outputURL)
            throw ProcessRunnerError.executableNotFound(executable)
        }

        // Insert, then evict the oldest FINISHED entries of THIS TASK beyond the
        // per-task cap so a long-lived task running many background commands can't
        // accumulate unbounded Entry objects + log files. Running entries are never
        // evicted; one task's activity never evicts another task's output.
        let evicted: [Entry] = lock.withLock {
            entries[id] = entry
            let snapshot = entries.values.map { (id: $0.id, running: $0.running, seq: $0.seq, taskID: $0.taskID) }
            let ids = Self.overflowFinishedIDs(
                entries: snapshot, cap: BashConstants.maxRetainedBackgroundCommands, taskID: taskID)
            let victims = ids.compactMap { entries[$0] }
            for id in ids { entries[id] = nil }
            return victims
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
                newOutput = String(data: data, encoding: .utf8) ?? ""
                entry.readOffset += UInt64(data.count)
            }
            return ReadResult(
                command: entry.command,
                newOutput: newOutput,
                running: entry.running,
                exitCode: entry.exitCode)
        }
    }

    // MARK: - Stop

    /// Terminates a background command (SIGTERM). Returns `false` for unknown IDs.
    @discardableResult
    func stop(commandID: String) -> Bool {
        let entry: Entry? = lock.withLock { entries[commandID] }
        guard let entry else { return false }
        if entry.process.isRunning { entry.process.terminate() }
        return true
    }

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

    /// SIGTERM each still-running process and delete its log file.
    private func reap(_ entries: [Entry]) {
        for e in entries {
            if e.process.isRunning { e.process.terminate() }
            try? FileManager.default.removeItem(at: e.outputURL)
        }
    }

    private func nextSeq() -> Int {
        lock.withLock {
            counter += 1
            return counter
        }
    }
}
