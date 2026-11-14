import Foundation
import Observation

/// One summary line of an external Autovisor MCP tool call in
/// `.nanoteams/internal/autovisor/external_activity.jsonl` (§11, Ш14, D13).
///
/// **What is deliberately absent from THIS line: bodies and credentials.**
/// The line answers "what did the external agent do with the teams and when" for the
/// external Autovisor pane (`ExternalAutovisorPane`, Ш21) and post-mortem diagnostics. It holds
/// only structured metadata and compact summaries — never raw task briefs, Supervisor answers,
/// messages, comments, Work Folder Context text, artifact contents, step logs, or bearer tokens.
///
/// The call in full — the arguments and the response — is kept BESIDE the log, one file per
/// call (`ExternalAutovisorFullCall`, `external_calls/<id>.json`, since 2026-11-08), for exactly
/// the rows the pane holds; a row opens it on tap.
nonisolated struct ExternalAutovisorActivityRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var agentID: UUID
    var agentLabel: String
    var tool: String
    var taskID: Int?
    /// The OTHER tasks the response named — the events of a `wait_for_events`, the rows of a
    /// `list_tasks`, a delegated child. Its full call carries their titles, questions and errors,
    /// so deleting any of them takes the call along (`forgetFullCalls(forTaskID:)`). `nil` when
    /// it named none, and on every line written before 2026-11-08.
    var namedTaskIDs: Set<Int>?
    var roleID: String?
    var action: String?
    var teamName: String?
    var taskTitle: String?
    var ok: Bool
    var errorCode: String?
    var resultBytes: Int
    var artifactNames: [String]
    var eventCount: Int?
    var argumentsSummary: String
    var outcomeSummary: String
    var durationMs: Double?

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        agentID: UUID,
        agentLabel: String,
        tool: String,
        taskID: Int? = nil,
        namedTaskIDs: Set<Int>? = nil,
        roleID: String? = nil,
        action: String? = nil,
        teamName: String? = nil,
        taskTitle: String? = nil,
        ok: Bool,
        errorCode: String? = nil,
        resultBytes: Int,
        artifactNames: [String] = [],
        eventCount: Int? = nil,
        argumentsSummary: String = "",
        outcomeSummary: String = "",
        durationMs: Double? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.agentID = agentID
        self.agentLabel = agentLabel
        self.tool = tool
        self.taskID = taskID
        self.namedTaskIDs = namedTaskIDs
        self.roleID = roleID
        self.action = action
        self.teamName = teamName
        self.taskTitle = taskTitle
        self.ok = ok
        self.errorCode = errorCode
        self.resultBytes = max(0, resultBytes)
        self.artifactNames = artifactNames
        self.eventCount = eventCount
        self.argumentsSummary = argumentsSummary
        self.outcomeSummary = outcomeSummary
        self.durationMs = durationMs
    }

    /// Every task this call is about: `taskID` and the tasks its response named.
    var concernedTaskIDs: Set<Int> {
        var ids = namedTaskIDs ?? []
        if let taskID { ids.insert(taskID) }
        return ids
    }

    /// Whether this call is about task `id` — its target, or a task its response named.
    func concerns(taskID id: Int) -> Bool {
        taskID == id || namedTaskIDs?.contains(id) == true
    }

    /// A call whose effect reaches every task in the folder without naming one: a replaced Work
    /// Folder Context, which the roles of every task on a team that reads it see. The pane keeps it under any task
    /// filter; deleting a task leaves its full call alone, since it is about no task
    /// (`concerns(taskID:)` stays false).
    var reachesEveryTask: Bool {
        ok && tool == ExternalAutovisorToolNames.setWorkFolderContext
    }

    /// Compact one-line human-readable description for the External Autovisor pane (§11).
    var headline: String {
        let taskPart = taskID.map { "#\($0)" } ?? "task"
        if !ok {
            let code = errorCode ?? "ERROR"
            if taskID != nil {
                return "\(agentLabel): \(tool) on task \(taskPart) failed (\(code))"
            }
            return "\(agentLabel): \(tool) failed (\(code))"
        }
        switch tool {
        case ExternalAutovisorToolNames.createManagedTask:
            let titlePart = taskTitle.map { " '\($0)'" } ?? ""
            if let teamName, !teamName.isEmpty {
                return "\(agentLabel) created task \(taskPart)\(titlePart) on team \(teamName)"
            }
            return "\(agentLabel) created task \(taskPart)\(titlePart)"

        case ExternalAutovisorToolNames.answerTaskQuestion:
            if let roleID, !roleID.isEmpty {
                return "\(agentLabel) answered question of role \(roleID) in task \(taskPart)"
            }
            return "\(agentLabel) answered question in task \(taskPart)"

        case ExternalAutovisorToolNames.manageRole:
            let verb = action ?? "updated"
            let rolePart = roleID ?? "role"
            return "\(agentLabel): \(verb) role \(rolePart) in task \(taskPart)"

        case ExternalAutovisorToolNames.controlTask:
            let verb = action ?? "controlled"
            return "\(agentLabel): \(verb) task \(taskPart)"

        case ExternalAutovisorToolNames.messageTask:
            if let roleID, !roleID.isEmpty {
                return "\(agentLabel) messaged role \(roleID) in task \(taskPart)"
            }
            return "\(agentLabel) messaged task \(taskPart)"

        case ExternalAutovisorToolNames.scheduleTask:
            return "\(agentLabel) updated schedule for task \(taskPart)"

        case ExternalAutovisorToolNames.setWorkFolderContext:
            return "\(agentLabel) replaced the Work Folder Context"

        case ExternalAutovisorToolNames.waitForEvents:
            if let count = eventCount, count > 0 {
                return "\(agentLabel) received \(count) event(s)"
            }
            return "\(agentLabel) waited for events"

        case ExternalAutovisorToolNames.taskResult:
            if !artifactNames.isEmpty {
                return "\(agentLabel) read result of task \(taskPart) (\(artifactNames.joined(separator: ", ")))"
            }
            return "\(agentLabel) read result of task \(taskPart)"

        case ExternalAutovisorToolNames.readArtifact:
            let namePart = artifactNames.first ?? "artifact"
            return "\(agentLabel) read artifact '\(namePart)' of task \(taskPart)"

        case ExternalAutovisorToolNames.taskLog:
            return "\(agentLabel) read log of task \(taskPart)"

        case ExternalAutovisorToolNames.taskStatus:
            return "\(agentLabel) checked status of task \(taskPart)"

        default:
            return "\(agentLabel) called \(tool)"
        }
    }
}

/// Activity log for external Autovisor agents (§5, §11, Ш14): a summary line per call, and the
/// call in full beside it.
///
/// Summaries persist to `.nanoteams/internal/autovisor/external_activity.jsonl` with size-bounded
/// rotation (`external_activity.jsonl.1` holds the previous generation when the active file
/// reaches `limits.maxFileBytes`) and `0o700` directory permissions
/// (`NTMSRepository.internalDirAttributes`). Exposes an observable in-memory tail (`records`,
/// `revision`, `onRecordAppended`) so the External Autovisor pane updates live without polling disk.
///
/// **Full calls** (`ExternalAutovisorFullCallStore`, `external_calls/<id>.json` beside the log)
/// are kept for exactly the records of the tail — the rows the pane can show: a record that
/// leaves the tail takes its file with it, and so does every call that names a deleted task,
/// whether it targeted the task or only mentioned it (`forgetFullCalls(forTaskID:)`); a call
/// still in flight when its task goes keeps no file at all. `fullCallIDs` is the directory's
/// truth intersected with the tail, so a row recorded before 2026-11-08, or whose file is gone,
/// is simply not openable.
/// Every write, read and removal runs on the one serial `ioQueue`, which is what orders a call's
/// write before its read and before its removal.
@Observable @MainActor
final class ExternalAutovisorActivityLog {

    nonisolated struct Limits: Equatable, Sendable {
        var maxFileBytes: Int
        var maxTailRecords: Int

        init(maxFileBytes: Int = 512 * 1024, maxTailRecords: Int = 200) {
            self.maxFileBytes = max(1, maxFileBytes)
            self.maxTailRecords = max(1, maxTailRecords)
        }
    }

    @ObservationIgnored private let ioQueue = DispatchQueue(
        label: "com.nanoteams.external-autovisor.activity-log",
        qos: .utility
    )
    @ObservationIgnored private let fileManager: FileManager

    private(set) var logURL: URL?
    private(set) var limits: Limits
    private(set) var records: [ExternalAutovisorActivityRecord] = []
    private(set) var revision: UInt64 = 0
    /// The records of the tail whose full call is on disk (`fullCall(id:)` reads one).
    private(set) var fullCallIDs: Set<UUID> = []
    /// Tasks deleted while this folder is armed. A call about one that completes AFTER the
    /// deletion — it was in flight — keeps no full call. Task ids never repeat within a folder
    /// (`TasksIndex.nextTaskID` only grows); a reset, which restarts them, disarms the log first.
    @ObservationIgnored private var deletedTaskIDs: Set<Int> = []

    /// Alias for `records` used by `ExternalAutovisorPane` (§11, Ш21).
    var entries: [ExternalAutovisorActivityRecord] { records }

    /// Optional live-update callback invoked on `@MainActor` whenever a new record is appended.
    @ObservationIgnored var onRecordAppended: (@MainActor (ExternalAutovisorActivityRecord) -> Void)?

    /// Rotated backup file URL (`external_activity.jsonl.1`) alongside `logURL`.
    var backupLogURL: URL? {
        guard let logURL else { return nil }
        return Self.rotatedBackupURL(for: logURL)
    }

    /// The full calls' directory (`external_calls/`) beside `logURL`, while a folder is armed.
    var callsDirectoryURL: URL? {
        guard let logURL else { return nil }
        return Self.callsDirectoryURL(for: logURL)
    }

    /// Derived from the log's own URL, the way the backup is, so the two can never name
    /// different folders.
    nonisolated static func callsDirectoryURL(for logURL: URL) -> URL {
        logURL.deletingLastPathComponent()
            .appendingPathComponent(ExternalAutovisorFullCallStore.directoryName, isDirectory: true)
    }

    init(limits: Limits = Limits(), fileManager: FileManager = .default) {
        self.limits = limits
        self.fileManager = fileManager
    }

    /// Updates rotation and tail limits (used by tests to verify rotation deterministically).
    func setLimits(_ limits: Limits) {
        self.limits = limits
        if records.count > limits.maxTailRecords {
            let evicted = records.prefix(records.count - limits.maxTailRecords)
            records = Array(records.suffix(limits.maxTailRecords))
            forgetFullCalls(of: evicted)
            revision &+= 1
        }
    }

    /// Arms the log for an open real work folder and loads the existing tail from disk.
    ///
    /// The full calls of the loaded tail become `fullCallIDs`; a file whose record is not in the
    /// tail is an orphan and goes — unless a log file could not be read. A file that exists and
    /// yields no record is a failed read, not an empty log, and deleting the bodies of its rows
    /// on the strength of it would leave each of them unopenable once the read succeeds again.
    func activateFolder(logURL: URL) {
        let maxTail = limits.maxTailRecords
        nonisolated(unsafe) let fm = fileManager
        let callsDir = Self.callsDirectoryURL(for: logURL)
        let loaded = ioQueue.sync {
            let tail = Self.loadTailFromDisk(logURL: logURL, maxRecords: maxTail, fileManager: fm)
            let stored = ExternalAutovisorFullCallStore.storedIDs(in: callsDir, fileManager: fm)
            return (records: tail.records, storedIDs: stored, readFailed: tail.readFailed)
        }
        let tailIDs = Set(loaded.records.map(\.id))
        self.logURL = logURL
        self.records = loaded.records
        self.fullCallIDs = loaded.storedIDs.intersection(tailIDs)
        self.deletedTaskIDs = []
        self.revision &+= 1

        let orphans = loaded.storedIDs.subtracting(tailIDs)
        guard !loaded.readFailed, !orphans.isEmpty else { return }
        ioQueue.async {
            ExternalAutovisorFullCallStore.remove(ids: orphans, in: callsDir, fileManager: fm)
        }
    }

    /// Disarms the log on folder transition or when returning to default internal storage.
    func disarmForFolderTransition() {
        logURL = nil
        if !records.isEmpty {
            records.removeAll()
        }
        if !fullCallIDs.isEmpty {
            fullCallIDs.removeAll()
        }
        deletedTaskIDs = []
        revision &+= 1
    }

    /// Returns the most recent `limit` records in chronological order (oldest first, newest last).
    func tail(limit: Int? = nil) -> [ExternalAutovisorActivityRecord] {
        let cap = limit.map { max(0, $0) } ?? limits.maxTailRecords
        guard cap < records.count else { return records }
        return Array(records.suffix(cap))
    }

    /// Appends one summary record to the in-memory tail and schedules a size-rotated JSONL write,
    /// and — when `fullCall` is given, a folder is armed and no task the call is about has been
    /// deleted meanwhile — the call in full beside it, filed under `entry.id` whatever id
    /// `fullCall` carries.
    func record(_ entry: ExternalAutovisorActivityRecord, fullCall: ExternalAutovisorFullCall? = nil) {
        records.append(entry)
        if records.count > limits.maxTailRecords {
            let overflow = records.count - limits.maxTailRecords
            let evicted = records.prefix(overflow)
            records.removeFirst(overflow)
            forgetFullCalls(of: evicted)
        }
        let targetURL = logURL
        nonisolated(unsafe) let fm = fileManager
        if let fullCall, let callsDir = callsDirectoryURL,
           deletedTaskIDs.isDisjoint(with: entry.concernedTaskIDs) {
            // Inserted before the line is written, the write queued after it: the one serial
            // queue runs a later `fullCall(id:)` read behind this write.
            fullCallIDs.insert(entry.id)
            let filed = ExternalAutovisorFullCall(id: entry.id, arguments: fullCall.arguments, response: fullCall.response)
            ioQueue.async {
                ExternalAutovisorFullCallStore.write(filed, in: callsDir, fileManager: fm)
            }
        }
        revision &+= 1
        onRecordAppended?(entry)

        guard let targetURL else { return }
        let maxBytes = limits.maxFileBytes
        guard var encoded = try? JSONCoderFactory.makeJSONLEncoder().encode(entry) else { return }
        encoded.append(0x0A)
        let line = encoded
        ioQueue.async {
            Self.appendLineToDisk(line, logURL: targetURL, maxFileBytes: maxBytes, fileManager: fm)
        }
    }

    /// The full call of row `id`, read off the main actor; `nil` when the row has none, it was
    /// forgotten, or the file does not read back.
    func fullCall(id: UUID) async -> ExternalAutovisorFullCall? {
        guard fullCallIDs.contains(id), let callsDir = callsDirectoryURL else { return nil }
        let queue = ioQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: ExternalAutovisorFullCallStore.read(id: id, in: callsDir))
            }
        }
    }

    /// Forgets the full calls of every row about `taskID` — the calls it was the target of and
    /// the calls whose response named it: a deleted task takes every copy of its text with it.
    /// The summary rows stay, unopenable; a call about it still in flight keeps none (`record`).
    func forgetFullCalls(forTaskID taskID: Int) {
        deletedTaskIDs.insert(taskID)
        var ids: Set<UUID> = []
        for record in records where record.concerns(taskID: taskID) {
            ids.insert(record.id)
        }
        forgetFullCalls(ids: ids)
    }

    private func forgetFullCalls(of evicted: ArraySlice<ExternalAutovisorActivityRecord>) {
        var ids: Set<UUID> = []
        for record in evicted {
            ids.insert(record.id)
        }
        forgetFullCalls(ids: ids)
    }

    private func forgetFullCalls(ids: Set<UUID>) {
        let held = ids.intersection(fullCallIDs)
        guard !held.isEmpty else { return }
        fullCallIDs.subtract(held)
        revision &+= 1
        guard let callsDir = callsDirectoryURL else { return }
        nonisolated(unsafe) let fm = fileManager
        ioQueue.async {
            ExternalAutovisorFullCallStore.remove(ids: held, in: callsDir, fileManager: fm)
        }
    }

    /// Waits for all pending disk writes to complete (used by tests and shutdown).
    nonisolated func flush() {
        ioQueue.sync {}
    }

    #if DEBUG
    /// Test seam: holds the I/O queue until `release` is signalled or `seconds` pass, so a test
    /// can keep a write in flight across the step that must drain it. The timeout is what keeps
    /// a step that DOES drain — `flush()`, which blocks the main actor — from hanging the test.
    nonisolated func _testHoldIOQueue(atMost seconds: Double, until release: DispatchSemaphore) {
        ioQueue.async { _ = release.wait(timeout: .now() + seconds) }
    }
    #endif

    // MARK: - Disk I/O (serial on ioQueue)

    nonisolated private static func rotatedBackupURL(for logURL: URL) -> URL {
        logURL.deletingLastPathComponent()
            .appendingPathComponent(logURL.lastPathComponent + ".1", isDirectory: false)
    }

    nonisolated private static func appendLineToDisk(
        _ line: Data,
        logURL: URL,
        maxFileBytes: Int,
        fileManager: FileManager
    ) {
        let dir = logURL.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: NTMSRepository.internalDirAttributes
        )
        try? fileManager.setAttributes(NTMSRepository.internalDirAttributes, ofItemAtPath: dir.path)

        let currentSize = (try? fileManager.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        if currentSize > 0 && currentSize + line.count > maxFileBytes {
            let backup = rotatedBackupURL(for: logURL)
            try? fileManager.removeItem(at: backup)
            try? fileManager.moveItem(at: logURL, to: backup)
        }

        if !fileManager.fileExists(atPath: logURL.path) {
            _ = fileManager.createFile(atPath: logURL.path, contents: line)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {}
    }

    /// The newest `maxRecords` records of the backup and the active file, oldest first.
    /// `readFailed` when either file exists and failed to read (`decodeLines`).
    nonisolated private static func loadTailFromDisk(
        logURL: URL,
        maxRecords: Int,
        fileManager: FileManager
    ) -> (records: [ExternalAutovisorActivityRecord], readFailed: Bool) {
        var all: [ExternalAutovisorActivityRecord] = []
        var readFailed = false
        for url in [rotatedBackupURL(for: logURL), logURL] where fileManager.fileExists(atPath: url.path) {
            let file = decodeLines(from: url)
            all.append(contentsOf: file.records)
            readFailed = readFailed || file.failed
        }
        guard all.count > maxRecords else { return (all, readFailed) }
        return (Array(all.suffix(maxRecords)), readFailed)
    }

    /// One file's records, decoded LINE BY LINE on the raw bytes: a torn line — a multi-byte
    /// character cut by a crash mid-append — costs that line, not the file, and a title holding
    /// U+2028 is not split in two (a JSON string never holds a raw 0x0A; it may hold U+2028).
    /// `failed` when the file does not read, or holds bytes and yields no record.
    nonisolated private static func decodeLines(from url: URL) -> (records: [ExternalAutovisorActivityRecord], failed: Bool) {
        guard let data = try? Data(contentsOf: url) else { return ([], true) }
        let decoder = JSONCoderFactory.makeDateDecoder()
        var records: [ExternalAutovisorActivityRecord] = []
        for line in data.split(separator: 0x0A) {
            if let record = try? decoder.decode(ExternalAutovisorActivityRecord.self, from: Data(line)) {
                records.append(record)
            }
        }
        return (records, records.isEmpty && !data.isEmpty)
    }
}

// MARK: - Orchestrator Activity Recording Helper

extension NTMSOrchestrator {

    /// Summarizes and records one completed external Autovisor tool call into `externalActivityLog`
    /// while the folder lifecycle that started the call is still current (§11, Ш14, D13).
    func recordExternalAutovisorActivity(
        tool: String,
        args: [String: Any],
        agent: AgentIdentity,
        preCallRoleID: String?,
        result: ToolExecutionResult,
        durationMs: Double,
        now: Date,
        cancelled: Bool = false,
        within lifecycle: WorkFolderLifecycle
    ) {
        guard hasRealWorkFolder, !isFolderTransitionInProgress, isCurrentFolderLifecycle(lifecycle) else { return }

        let scrubbedLabel = MCPTextSanitizer.singleLine(MCPRedaction.excerpt(agent.label, limit: 80))
        let resultBytes = result.outputJSON.utf8.count
        let parsedEnvelope = (result.outputJSON.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let dataDict = parsedEnvelope?["data"] as? [String: Any]
        let errorDict = parsedEnvelope?["error"] as? [String: Any]

        let ok = !result.isError && ((parsedEnvelope?["ok"] as? Bool) != false)
        let errorCode: String? = ok
            ? nil
            : ((errorDict?["code"] as? String) ?? ToolErrorCode.commandFailed.rawValue)

        let taskID: Int? = (dataDict?["task_id"] as? Int)
            ?? (try? requiredInt(args, "task_id"))
        var namedTaskIDs = parsedEnvelope.map(Self.namedTaskIDs(inResponse:)) ?? []
        if let taskID { namedTaskIDs.remove(taskID) }

        var roleID: String? = extractString(args, "role_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if roleID?.isEmpty == true { roleID = nil }
        if roleID == nil {
            roleID = (dataDict?["role_id"] as? String) ?? preCallRoleID
        }
        roleID = roleID.map { MCPTextSanitizer.singleLine(MCPRedaction.excerpt($0, limit: 80)) }

        var action: String? = extractString(args, "action")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if action?.isEmpty == true { action = nil }
        action = action.map { MCPTextSanitizer.singleLine(MCPRedaction.excerpt($0, limit: 40)) }

        var taskTitle: String? = extractString(args, "title")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if taskTitle?.isEmpty == true { taskTitle = nil }
        if taskTitle == nil, let taskID, let loaded = loadedTask(taskID) {
            taskTitle = loaded.title
        }
        taskTitle = taskTitle.map { MCPTextSanitizer.singleLine(MCPRedaction.excerpt($0, limit: 120)) }

        var teamName: String?
        if tool == ExternalAutovisorToolNames.createManagedTask {
            if let taskID, let loaded = loadedTask(taskID) {
                teamName = resolvedTeam(for: loaded).name
            } else if let rawTeam = (extractString(args, "team_id") ?? extractString(args, "team"))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawTeam.isEmpty
            {
                teamName = rawTeam
            }
            teamName = teamName.map { MCPTextSanitizer.singleLine(MCPRedaction.excerpt($0, limit: 80)) }
        }

        var artifactNames: [String] = []
        if tool == ExternalAutovisorToolNames.taskResult {
            let rows = (dataDict?["deliverables"] as? [[String: Any]]) ?? (dataDict?["index"] as? [[String: Any]]) ?? []
            artifactNames = rows.compactMap { row -> String? in
                guard let name = row["name"] as? String, !name.isEmpty else { return nil }
                return MCPTextSanitizer.singleLine(MCPRedaction.excerpt(name, limit: 80))
            }
        } else if tool == ExternalAutovisorToolNames.readArtifact {
            if let name = (dataDict?["name"] as? String) ?? extractString(args, "name"), !name.isEmpty {
                artifactNames = [MCPTextSanitizer.singleLine(MCPRedaction.excerpt(name, limit: 80))]
            }
        }

        var eventCount: Int?
        if tool == ExternalAutovisorToolNames.waitForEvents,
           let events = dataDict?["events"] as? [[String: Any]]
        {
            eventCount = events.count
        }

        let argumentsSummary = Self.summarizeExternalArguments(
            tool: tool,
            args: args,
            taskID: taskID,
            roleID: roleID,
            action: action,
            teamName: teamName,
            taskTitle: taskTitle
        )
        let outcomeSummary = Self.summarizeExternalOutcome(
            tool: tool,
            ok: ok,
            errorCode: errorCode,
            errorMessage: errorDict?["message"] as? String,
            dataDict: dataDict,
            resultBytes: resultBytes,
            artifactNames: artifactNames,
            eventCount: eventCount,
            cancelled: cancelled
        )

        let entry = ExternalAutovisorActivityRecord(
            createdAt: now,
            agentID: agent.id,
            agentLabel: scrubbedLabel.isEmpty ? "Agent" : scrubbedLabel,
            tool: tool,
            taskID: taskID,
            namedTaskIDs: namedTaskIDs.isEmpty ? nil : namedTaskIDs,
            roleID: roleID,
            action: action,
            teamName: teamName,
            taskTitle: taskTitle,
            ok: ok,
            errorCode: errorCode,
            resultBytes: resultBytes,
            artifactNames: artifactNames,
            eventCount: eventCount,
            argumentsSummary: argumentsSummary,
            outcomeSummary: outcomeSummary,
            durationMs: max(0, durationMs)
        )
        // The call in full beside the summary. The arguments are encoded HERE, on the main
        // actor, because `[String: Any]` is not `Sendable`; the token scrub and the write run
        // on the log's queue.
        let fullCall = ExternalAutovisorFullCall(
            id: entry.id,
            arguments: Self.fullCallArgumentsJSON(args),
            response: result.outputJSON
        )
        externalActivityLog.record(entry, fullCall: fullCall)
    }

    /// Every task id the response names, anywhere in it: each `task_id` / `…_task_id` at any
    /// depth (an event, a delegated child, a `next` hint) and the `id` of each row under `tasks`
    /// (`list_tasks`). Over-reading only forgets a call sooner; under-reading would keep a
    /// deleted task's text on disk.
    nonisolated static func namedTaskIDs(inResponse value: Any) -> Set<Int> {
        var ids: Set<Int> = []
        collectNamedTaskIDs(in: value, into: &ids)
        return ids
    }

    nonisolated private static func collectNamedTaskIDs(in value: Any, into ids: inout Set<Int>) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if key == "task_id" || key.hasSuffix("_task_id"), let id = child as? Int {
                    ids.insert(id)
                } else if key == "tasks", let rows = child as? [[String: Any]] {
                    for row in rows {
                        if let id = row["id"] as? Int { ids.insert(id) }
                    }
                }
                collectNamedTaskIDs(in: child, into: &ids)
            }
        } else if let array = value as? [Any] {
            for element in array {
                collectNamedTaskIDs(in: element, into: &ids)
            }
        }
    }

    /// The arguments as the server decoded them, as JSON: keys sorted, and slashes left as
    /// slashes — `encodeArgsToJSON` writes `\/`, which the window's Raw mode would show in every
    /// path of a brief. The arguments were decoded FROM JSON, so they always encode back; the
    /// `{}` is `encodeArgsToJSON`'s own answer for the impossible case.
    nonisolated static func fullCallArgumentsJSON(_ args: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    /// Builds a short argument summary that NEVER includes `brief`, `answer`, `message`, `comment`,
    /// or a context's `content` — of that one only its length, trimmed as it is stored.
    nonisolated private static func summarizeExternalArguments(
        tool: String,
        args: [String: Any],
        taskID: Int?,
        roleID: String?,
        action: String?,
        teamName: String?,
        taskTitle: String?
    ) -> String {
        var parts: [String] = []
        if let taskID { parts.append("task=#\(taskID)") }
        if let roleID, !roleID.isEmpty { parts.append("role=\(roleID)") }
        if let action, !action.isEmpty { parts.append("action=\(action)") }
        if let teamName, !teamName.isEmpty { parts.append("team=\(teamName)") }
        if let taskTitle, !taskTitle.isEmpty, tool == ExternalAutovisorToolNames.createManagedTask {
            parts.append("title=\(taskTitle)")
        }
        if tool == ExternalAutovisorToolNames.readArtifact,
           let name = extractString(args, "name"), !name.isEmpty
        {
            let clean = MCPTextSanitizer.singleLine(MCPRedaction.excerpt(name, limit: 80))
            parts.append("name=\(clean)")
        }
        if tool == ExternalAutovisorToolNames.scheduleTask {
            if (args["clear"] as? Bool) == true {
                parts.append("clear=true")
            }
            if let mins = try? requiredInt(args, "repeat_every_minutes") {
                parts.append("repeat_every_minutes=\(mins)")
            }
            if let daily = extractString(args, "repeat_daily_at"), !daily.isEmpty {
                let clean = MCPTextSanitizer.singleLine(MCPRedaction.excerpt(daily, limit: 40))
                parts.append("repeat_daily_at=\(clean)")
            }
            if let day = try? requiredInt(args, "repeat_monthly_day") {
                parts.append("repeat_monthly_day=\(day)")
            }
            if let once = extractString(args, "run_once_at"), !once.isEmpty {
                let clean = MCPTextSanitizer.singleLine(MCPRedaction.excerpt(once, limit: 40))
                parts.append("run_once_at=\(clean)")
            }
        }
        if tool == ExternalAutovisorToolNames.setWorkFolderContext,
           let content = args["content"] as? String
        {
            parts.append("characters=\(content.trimmingCharacters(in: .whitespacesAndNewlines).count)")
        }
        if tool == ExternalAutovisorToolNames.waitForEvents {
            if let cursor = extractString(args, "after") ?? extractString(args, "cursor"), !cursor.isEmpty {
                let clean = MCPTextSanitizer.singleLine(MCPRedaction.excerpt(cursorTail(cursor), limit: 40))
                parts.append("after=\(clean)")
            }
            if let timeout = try? requiredInt(args, "timeout_seconds") {
                parts.append("timeout=\(timeout)s")
            }
        }
        return parts.joined(separator: " ")
    }

    /// A cursor as a person reads it in a row: past its folder id — the same on every cursor of the
    /// folder, and all a 40-character excerpt used to show — to the epoch, the position and the
    /// filter that tell two waits apart. Anything that does not start with a folder id is shown
    /// as it came.
    nonisolated static func cursorTail(_ cursor: String) -> String {
        let parts = cursor.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil else { return cursor }
        return String(parts[1])
    }

    /// Builds a short outcome summary that NEVER includes artifact bodies or task log messages.
    nonisolated private static func summarizeExternalOutcome(
        tool: String,
        ok: Bool,
        errorCode: String?,
        errorMessage: String?,
        dataDict: [String: Any]?,
        resultBytes: Int,
        artifactNames: [String],
        eventCount: Int?,
        cancelled: Bool
    ) -> String {
        if !ok {
            let code = errorCode ?? "ERROR"
            if let errorMessage, !errorMessage.isEmpty {
                let clean = MCPTextSanitizer.singleLine(MCPRedaction.excerpt(errorMessage, limit: 120))
                return "\(code): \(clean)"
            }
            return code
        }
        switch tool {
        case ExternalAutovisorToolNames.waitForEvents:
            let count = eventCount ?? 0
            // The agent withdrew the call; it got no answer, so "no events" would claim one.
            if cancelled, count == 0 { return "cancelled" }
            let timedOut = (dataDict?["timed_out"] as? Bool) ?? false
            let events = count == 0 ? "no events" : (count == 1 ? "1 event" : "\(count) events")
            return timedOut ? "\(events), timed out" : events

        case ExternalAutovisorToolNames.taskResult:
            if artifactNames.isEmpty {
                return "\(resultBytes) B"
            }
            let deliverables = artifactNames.count == 1 ? "1 deliverable" : "\(artifactNames.count) deliverables"
            return "\(deliverables): \(artifactNames.joined(separator: ", ")) (\(resultBytes) B)"

        case ExternalAutovisorToolNames.readArtifact:
            let bytes = (dataDict?["bytes"] as? Int) ?? resultBytes
            return "\(bytes) B"

        case ExternalAutovisorToolNames.taskLog:
            let count = (dataDict?["messages"] as? [[String: Any]])?.count ?? 0
            return "\(count == 1 ? "1 message" : "\(count) messages") (\(resultBytes) B)"

        default:
            if let status = dataDict?["status"] as? String {
                let clean = MCPTextSanitizer.singleLine(MCPRedaction.excerpt(status, limit: 60))
                return "status=\(clean)"
            }
            return "ok (\(resultBytes) B)"
        }
    }
}
