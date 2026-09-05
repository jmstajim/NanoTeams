import Foundation

nonisolated struct Run: Codable, Identifiable, Hashable {
    /// The run's POSITION in `NTMSTask.runs` — `RunService.createTeamRun`, the sole
    /// appender, stamps `id: task.runs.count`, and `RunService.runIndex` answers by-id
    /// questions in O(1) on that basis. `let`, so no site can relabel a run after
    /// construction (the compile-time leg of `Ratchet/RunIDIsPositionPinTests`).
    let id: Int
    var createdAt: Date
    var updatedAt: Date
    var steps: [StepExecution]

    /// Team meetings that occurred during this run.
    var meetings: [TeamMeeting]

    /// Current execution status for each role (roleID → status).
    var roleStatuses: [String: RoleExecutionStatus]

    /// Change requests made during this run (role-to-role revision requests).
    var changeRequests: [ChangeRequest]

    /// Per-role persistent consultation chats (keyed by role base ID).
    /// Each role has a separate chat for answering teammate questions and participating in meetings.
    /// These chats accumulate context across multiple interactions within a run.
    var consultationChats: [String: RoleConsultationChat]

    /// The team ID this run was created for.
    var teamID: NTMSID?

    /// Set when the run-timeout watchdog paused this run for exceeding its
    /// task's `runTimeoutSeconds`. Durable marker — guards the watchdog from
    /// re-firing on the same run, drives the Watchtower "timed out" notification
    /// and the Run-History "(timed out)" label.
    var timedOutAt: Date?

    init(
        id: Int,
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now(),
        steps: [StepExecution] = [],
        meetings: [TeamMeeting] = [],
        changeRequests: [ChangeRequest] = [],
        consultationChats: [String: RoleConsultationChat] = [:],
        roleStatuses: [String: RoleExecutionStatus] = [:],
        teamID: NTMSID? = nil,
        timedOutAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.steps = steps
        self.meetings = meetings
        self.changeRequests = changeRequests
        self.consultationChats = consultationChats
        self.roleStatuses = roleStatuses
        self.teamID = teamID
        self.timedOutAt = timedOutAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case steps
        case meetings
        case changeRequests
        case consultationChats
        case roleStatuses
        case teamID
        case timedOutAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.steps = try c.decodeIfPresent([StepExecution].self, forKey: .steps) ?? []
        self.meetings = try c.decodeIfPresent([TeamMeeting].self, forKey: .meetings) ?? []
        self.changeRequests = try c.decodeIfPresent([ChangeRequest].self, forKey: .changeRequests) ?? []
        self.consultationChats = try c.decodeIfPresent([String: RoleConsultationChat].self, forKey: .consultationChats) ?? [:]
        self.roleStatuses = try c.decodeIfPresent([String: RoleExecutionStatus].self, forKey: .roleStatuses) ?? [:]
        self.teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
        self.timedOutAt = try c.decodeIfPresent(Date.self, forKey: .timedOutAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(steps, forKey: .steps)
        try c.encode(meetings, forKey: .meetings)
        try c.encode(changeRequests, forKey: .changeRequests)
        try c.encode(consultationChats, forKey: .consultationChats)
        try c.encode(roleStatuses, forKey: .roleStatuses)
        try c.encodeIfPresent(teamID, forKey: .teamID)
        try c.encodeIfPresent(timedOutAt, forKey: .timedOutAt)
    }
}

nonisolated extension Run {
    // MARK: - Lookup Helpers

    /// Build a dictionary of roleBaseID → StepExecution for O(1) lookups.
    /// Useful in hot paths that iterate over `roleStatuses` and need the
    /// corresponding step (e.g., TeamEngine runLoop).
    func stepsByRoleBaseID() -> [String: StepExecution] {
        var dict: [String: StepExecution] = [:]
        dict.reserveCapacity(steps.count)
        for step in steps {
            dict[step.effectiveRoleID] = step
        }
        return dict
    }

    // MARK: - Step Status Summary

    /// Aggregated step status flags from a single-pass scan.
    struct StepStatusSummary {
        let allDone: Bool
        let hasFailed: Bool
        let hasNeedsSupervisorInput: Bool
        let hasPaused: Bool
        let hasNeedsApproval: Bool
        let hasRunning: Bool

        /// Base status derived from step flags.
        /// Priority: failed > needsSupervisorInput > paused > needsApproval (only when idle) > allDone > running.
        /// When steps are still running alongside needsApproval, returns .running so the sidebar
        /// does not misleadingly show "Paused". Watchtower notifications still surface the pending review.
        func derivedTaskStatus() -> TaskStatus {
            if hasFailed { return .failed }
            if hasNeedsSupervisorInput { return .needsSupervisorInput }
            if hasPaused { return .paused }
            if hasNeedsApproval && !hasRunning { return .paused }
            if allDone { return .done }
            return .running
        }
    }

    /// Single-pass scan of steps — returns aggregated status flags.
    func stepStatusSummary() -> StepStatusSummary {
        var allDone = true
        var hasFailed = false
        var hasNeedsSupervisorInput = false
        var hasPaused = false
        var hasNeedsApproval = false
        var hasRunning = false

        for step in steps {
            switch step.status {
            case .failed:
                hasFailed = true
            case .needsSupervisorInput:
                hasNeedsSupervisorInput = true
                allDone = false
            case .paused:
                hasPaused = true
                allDone = false
            case .needsApproval:
                hasNeedsApproval = true
                allDone = false
            case .done:
                break
            case .running:
                hasRunning = true
                allDone = false
            case .pending:
                allDone = false
            }
        }

        return StepStatusSummary(
            allDone: allDone,
            hasFailed: hasFailed,
            hasNeedsSupervisorInput: hasNeedsSupervisorInput,
            hasPaused: hasPaused,
            hasNeedsApproval: hasNeedsApproval,
            hasRunning: hasRunning
        )
    }

    // MARK: - Derived Status

    /// Derived status from step summary — used for run-level status display.
    func derivedStatus() -> TaskStatus {
        guard !steps.isEmpty else { return .running }
        return stepStatusSummary().derivedTaskStatus()
    }

    // MARK: - Artifact Resolution

    /// Record of a produced artifact with the role that produced it.
    struct ProducedArtifactRecord {
        let artifact: Artifact
        let roleID: String
    }

    /// Build a map of artifact name → most recent produced artifact record.
    /// Information Expert: Run owns steps and their artifacts.
    func producedArtifactsByName() -> [String: ProducedArtifactRecord] {
        var result: [String: ProducedArtifactRecord] = [:]
        for step in steps {
            for artifact in step.artifacts {
                let current = result[artifact.name]
                if current == nil || current!.artifact.updatedAt <= artifact.updatedAt {
                    result[artifact.name] = ProducedArtifactRecord(
                        artifact: artifact,
                        roleID: step.effectiveRoleID
                    )
                }
            }
        }
        return result
    }
}

// MARK: - Role Status Queries

nonisolated extension Run {
    /// Role IDs of non-supervisor, non-observer roles that have NOT reached a terminal
    /// (`isComplete`) status — the roles still doing or owing work. Iterates `definitions`
    /// (not the status dict) so a role with no status entry counts as active (`.idle`).
    /// Single source of truth for "is this team finished": `TeamEngine.allRolesComplete`
    /// and the Autovisor's chat-task close decision both read `.isEmpty` on this.
    static func activeWorkRoleIDs(
        roleStatuses: [String: RoleExecutionStatus],
        definitions: [TeamRoleDefinition]
    ) -> [String] {
        definitions.compactMap { role in
            guard !role.isSupervisor, !role.isObserver else { return nil }
            let status = roleStatuses[role.id] ?? .idle
            return status.isComplete ? nil : role.id
        }
    }

    /// `activeWorkRoleIDs` with resolved display names, sorted by name — for
    /// manager-facing "Still active: …" messages.
    func activeWorkRoles(definitions: [TeamRoleDefinition]) -> [(roleID: String, roleName: String)] {
        let activeIDs = Set(Run.activeWorkRoleIDs(roleStatuses: roleStatuses, definitions: definitions))
        return definitions
            .filter { activeIDs.contains($0.id) }
            .map { ($0.id, $0.name) }
            .sorted { $0.1 < $1.1 }
    }

    /// Finalizes every non-terminal role status to `.done` when the task is closed —
    /// closing is an implicit acceptance of completed work AND a finalization of roles
    /// that never ran. `.failed` is preserved (a failed role stays failed for the record).
    /// `RunService` seeds `initialRoleStatuses` for ALL roles up front while steps are
    /// created on demand, so a mid-run close otherwise strands idle / ready /
    /// revisionRequested / needsAcceptance pills on the team graph (it reads `roleStatuses`
    /// raw). Supersedes the old needsAcceptance-only pass in `closeTask`.
    mutating func finalizeRoleStatusesForClose() {
        for (roleID, status) in roleStatuses where !status.isComplete && status != .failed {
            roleStatuses[roleID] = .done
        }
    }


    /// Roles in needsAcceptance status with resolved display names.
    func rolesNeedingAcceptance(definitions: [TeamRoleDefinition]) -> [(roleID: String, roleName: String)] {
        roleStatuses.compactMap { (roleID, status) -> (String, String)? in
            guard status == .needsAcceptance else { return nil }
            return (roleID, definitions.roleName(for: roleID))
        }
        .sorted { $0.1 < $1.1 }
    }
}

// MARK: - Change Request

/// A formal request from one role to change another role's completed work.
nonisolated struct ChangeRequest: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    /// Role ID of the role requesting changes.
    var requestingRoleID: String
    /// Role ID of the role whose work needs changes.
    var targetRoleID: String
    /// Description of the requested changes.
    var changes: String
    /// Reasoning for why changes are needed.
    var reasoning: String
    /// ID of the voting meeting (nil if validation failed before meeting).
    var meetingID: UUID?
    /// Current status of the change request.
    var status: ChangeRequestStatus

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        requestingRoleID: String,
        targetRoleID: String,
        changes: String,
        reasoning: String,
        meetingID: UUID? = nil,
        status: ChangeRequestStatus = .pending
    ) {
        self.id = id
        self.createdAt = createdAt
        self.requestingRoleID = requestingRoleID
        self.targetRoleID = targetRoleID
        self.changes = changes
        self.reasoning = reasoning
        self.meetingID = meetingID
        self.status = status
    }
}

nonisolated enum ChangeRequestStatus: String, Codable, Hashable {
    case pending
    case approved
    case rejected
    case escalated
    case supervisorApproved
    case supervisorRejected
    case failed

    private static let displayNameMap: [ChangeRequestStatus: String] = [
        .pending: "Pending",
        .approved: "Approved",
        .rejected: "Rejected",
        .escalated: "Escalated",
        .supervisorApproved: "Supervisor Approved",
        .supervisorRejected: "Supervisor Rejected",
        .failed: "Failed",
    ]

    var displayName: String { Self.displayNameMap[self] ?? rawValue }
}
