import Foundation

struct NTMSTask: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    /// Supervisor's task/brief for this task.
    var supervisorTask: String
    /// Clipped text entries captured during task creation (multiple clips supported).
    var clippedTexts: [String]
    /// Persisted status (kept for quick summaries). UI should prefer derived status for the active task.
    var status: TaskStatus
    var createdAt: Date
    var updatedAt: Date
    var runs: [Run]

    /// When the Supervisor explicitly closed/accepted the task. nil = not yet closed.
    var closedAt: Date?

    /// Optional per-task acceptance mode override (nil = use team default).
    var acceptanceMode: AcceptanceMode?

    /// Optional per-task acceptance checkpoints (for customCheckpoints mode).
    var acceptanceCheckpoints: Set<String>?

    /// Optional preferred team for this task (nil = use project's activeTeam).
    var preferredTeamID: NTMSID?

    /// Work-folder-root-relative file paths attached to this task (images, documents, etc.).
    var attachmentPaths: [String]

    /// Whether this task operates in open-ended chat mode (set at creation from team config).
    var isChatMode: Bool

    init(
        id: Int,
        title: String,
        supervisorTask: String,
        clippedTexts: [String] = [],
        status: TaskStatus = .running,
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now(),
        runs: [Run] = [],
        closedAt: Date? = nil,
        acceptanceMode: AcceptanceMode? = nil,
        acceptanceCheckpoints: Set<String>? = nil,
        preferredTeamID: NTMSID? = nil,
        attachmentPaths: [String] = [],
        isChatMode: Bool = false
    ) {
        self.id = id
        self.title = title
        self.supervisorTask = supervisorTask
        self.clippedTexts = clippedTexts
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.runs = runs
        self.closedAt = closedAt
        self.acceptanceMode = acceptanceMode
        self.acceptanceCheckpoints = acceptanceCheckpoints
        self.preferredTeamID = preferredTeamID
        self.attachmentPaths = attachmentPaths
        self.isChatMode = isChatMode
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case supervisorTask
        case clippedTexts
        case clippedText
        case status
        case createdAt
        case updatedAt
        case runs
        case closedAt
        case acceptanceMode
        case acceptanceCheckpoints
        case preferredTeamID
        case attachmentPaths
        case isChatMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.supervisorTask = try container.decodeIfPresent(String.self, forKey: .supervisorTask) ?? ""
        if let clips = try container.decodeIfPresent([String].self, forKey: .clippedTexts) {
            self.clippedTexts = clips
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .clippedText),
                  !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.clippedTexts = [legacy]
        } else {
            self.clippedTexts = []
        }
        self.status = try container.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .running
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.runs = try container.decodeIfPresent([Run].self, forKey: .runs) ?? []
        self.closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
        self.acceptanceMode = try container.decodeIfPresent(AcceptanceMode.self, forKey: .acceptanceMode)
        self.acceptanceCheckpoints = try container.decodeIfPresent(Set<String>.self, forKey: .acceptanceCheckpoints)
        self.preferredTeamID = try container.decodeIfPresent(String.self, forKey: .preferredTeamID)
        self.attachmentPaths = try container.decodeIfPresent([String].self, forKey: .attachmentPaths) ?? []
        self.isChatMode = try container.decodeIfPresent(Bool.self, forKey: .isChatMode) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(supervisorTask, forKey: .supervisorTask)
        try container.encode(clippedTexts, forKey: .clippedTexts)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(runs, forKey: .runs)
        try container.encodeIfPresent(closedAt, forKey: .closedAt)
        try container.encodeIfPresent(acceptanceMode, forKey: .acceptanceMode)
        try container.encodeIfPresent(acceptanceCheckpoints, forKey: .acceptanceCheckpoints)
        try container.encodeIfPresent(preferredTeamID, forKey: .preferredTeamID)
        try container.encode(attachmentPaths, forKey: .attachmentPaths)
        try container.encode(isChatMode, forKey: .isChatMode)
    }
}

enum TaskStatus: String, Codable, CaseIterable, Hashable {
    case running
    case done
    case paused
    case waiting
    case needsSupervisorInput
    case needsSupervisorAcceptance
    case failed
}

extension TaskStatus {
    private static let displayLabelMap: [TaskStatus: String] = [
        .running: "Working",
        .done: "Done",
        .paused: "Paused",
        .waiting: "Waiting",
        .needsSupervisorInput: "Needs Supervisor",
        .needsSupervisorAcceptance: "Review",
        .failed: "Failed",
    ]

    var displayLabel: String {
        Self.displayLabelMap[self] ?? rawValue
    }
}

/// Stored in .nanoteams/internal/tasks_index.json
struct TasksIndex: Codable, Hashable {
    var schemaVersion: Int
    var tasks: [TaskSummary]
    /// Monotonically increasing counter for assigning task IDs.
    var nextTaskID: Int

    init(schemaVersion: Int = 1, tasks: [TaskSummary] = [], nextTaskID: Int = 0) {
        self.schemaVersion = schemaVersion
        self.tasks = tasks
        self.nextTaskID = nextTaskID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.tasks = try c.decodeIfPresent([TaskSummary].self, forKey: .tasks) ?? []
        self.nextTaskID = try c.decodeIfPresent(Int.self, forKey: .nextTaskID)
            ?? ((self.tasks.map(\.id).max()).map { $0 + 1 } ?? 0)
    }
}

struct TaskSummary: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var status: TaskStatus
    var updatedAt: Date
    var isChatMode: Bool

    init(id: Int, title: String, status: TaskStatus, updatedAt: Date = MonotonicClock.shared.now(), isChatMode: Bool = false) {
        self.id = id
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.isChatMode = isChatMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.status = try container.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .running
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.isChatMode = try container.decodeIfPresent(Bool.self, forKey: .isChatMode) ?? false
    }
}

extension NTMSTask {
    var hasInitialInput: Bool {
        let trimmedTask = supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasClips = clippedTexts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !trimmedTask.isEmpty || hasClips || !attachmentPaths.isEmpty
    }

    var effectiveSupervisorBrief: String {
        var sections: [String] = []

        let trimmedTask = supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTask.isEmpty {
            sections.append(trimmedTask)
        }

        let nonEmptyClips = clippedTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for (i, clip) in nonEmptyClips.enumerated() {
            let parsed = SourceContext.parse(clip)
            let header: String
            if let parsed {
                header = nonEmptyClips.count == 1
                    ? "--- Clipped Text (\(parsed.source)) ---"
                    : "--- Clipped Text (\(i + 1) of \(nonEmptyClips.count), \(parsed.source)) ---"
            } else {
                header = nonEmptyClips.count == 1
                    ? "--- Clipped Text ---"
                    : "--- Clipped Text (\(i + 1) of \(nonEmptyClips.count)) ---"
            }
            sections.append("\(header)\n\(parsed?.body ?? clip)")
        }

        if !attachmentPaths.isEmpty {
            let pathList = attachmentPaths
                .map { "- \($0)" }
                .joined(separator: "\n")
            sections.append("--- Attached Files ---\n\(pathList)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Derived status from the active run's step summary, with task-level overrides.
    func derivedStatusFromActiveRun() -> TaskStatus {
        guard let run = runs.last else { return status }
        guard !run.steps.isEmpty else {
            return .running
        }

        let s = run.stepStatusSummary()
        let base = s.derivedTaskStatus()

        // Task-level overrides on top of base priority
        switch base {
        case .running where status == .paused && !s.hasRunning:
            return .paused
        case .done where isChatMode:
            return closedAt != nil ? .done : .running
        case .done:
            if !run.roleStatuses.isEmpty {
                let allRolesComplete = run.roleStatuses.values.allSatisfy { $0.isComplete }
                if !allRolesComplete {
                    // Distinguish "roles still working" from "roles waiting for acceptance"
                    let onlyAcceptanceOrComplete = run.roleStatuses.values.allSatisfy {
                        $0.isComplete || $0 == .needsAcceptance
                    }
                    if onlyAcceptanceOrComplete {
                        return closedAt != nil ? .done : .needsSupervisorAcceptance
                    }
                    return .running
                }
            }
            return closedAt != nil ? .done : .needsSupervisorAcceptance
        default:
            return base
        }
    }

    /// Whether the task is ready for final Supervisor acceptance
    /// (all roles individually accepted, no roles awaiting review).
    var isReadyForFinalAcceptance: Bool {
        guard !isChatMode else { return false }
        guard let run = runs.last else { return false }
        return derivedStatusFromActiveRun() == .needsSupervisorAcceptance
            && run.roleStatuses.values.allSatisfy { $0.isComplete }
    }

    func toSummary() -> TaskSummary {
        TaskSummary(id: id, title: title, status: derivedStatusFromActiveRun(), updatedAt: updatedAt, isChatMode: isChatMode)
    }
}
