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
            // NOT an unconditional `executableNotFound`: `bash` validates the
            // working directory exists before it gets here, but "exists" is not
            // "spawnable" — a directory the user cannot search (mode 0o000) still
            // passes `fileExists` and then fails the spawn with EACCES. Reporting
            // that as "Executable not found: /bin/zsh" is a false statement about
            // the one thing that is definitely fine.
            throw ProcessRunner.launchError(executable: executable, underlying: error)
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
