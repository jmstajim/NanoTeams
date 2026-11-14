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

    /// The timeout budget limit (in seconds) that triggered `timedOutAt`.
    /// When `task.runTimeoutSeconds` is increased past this limit, the watchdog re-arms
    /// while preserving `timedOutAt` as a historical marker (§5.1, C2).
    var timedOutAtLimit: TimeInterval?

    /// Why the run's latest pause happened, written by the code that paused it: `pauseRun`
    /// (`.requested`, or `.runTimedOut` from the run-timeout watchdog), the engine's
    /// iteration-limit pause and status recovery on relaunch — and `.resumed` once a Resume
    /// lifted it (since 2026-11-09), so a later pause that writes no cause of its own is not read
    /// as the lifted one. Readers consult it only while the run is paused. `nil` for a run
    /// persisted before 2026-11-07, or never paused since.
    var pauseCause: PauseCause?

    /// Who asked for the run's latest pause when `pauseCause` is `.requested` — the person, the
    /// built-in Autovisor or an external agent. Written by `pauseRun` together with the cause and
    /// only when that pause stopped something (CLAUDE.md #365); `nil` for every other cause, and
    /// for a run paused before 2026-11-09, which reads as the person's, as it always did. Until
    /// then a requested pause recorded no requester, and the agent that pressed Pause itself was
    /// told the person had (`AutovisorPauseReason.byAgent`).
    var pauseRequestedBy: ControlActor?

    /// Who paused a run (`pauseCause`).
    nonisolated enum PauseCause: String, Codable, Hashable, Sendable, CaseIterable {
        /// `pauseRun` on a person's, an agent's or a delegation cascade's request.
        case requested
        /// The run-timeout watchdog (`evaluateRunTimeouts`), which also stamps `timedOutAt`.
        case runTimedOut
        /// The engine stopped the run at its iteration limit.
        case iterationLimit
        /// Status recovery parked a run interrupted by the app quitting.
        case recovered
        /// No pause stands: a Resume lifted the latest one. A run found paused with this cause was
        /// paused by something that recorded no cause — status recovery's latch over a role left
        /// `.working` beside a `.pending` step — and reads `recovered`; one whose steps are still
        /// parked with no latch is the Resume restarting them and reads no pause at all
        /// (`AutovisorPauseReason.resolve`).
        case resumed
    }

    /// Whether the run's latest pause is the one its timeout caused. `timedOutAt` alone cannot
    /// say: it stays set after the person resumes the run and pauses it again. A run with a
    /// timeout stamp and no cause predates `pauseCause` and keeps the reading it always had.
    /// Callers still ask whether the task is paused now.
    var latestPauseIsItsTimeout: Bool {
        guard timedOutAt != nil else { return false }
        return (pauseCause ?? .runTimedOut) == .runTimedOut
    }

    /// Chronological system timeline events authored by an external Supervisor agent
    /// (e.g. `<agent> accepted` / `<agent> closed`), rendered in the task activity feed
    /// and `conversation_log.md` without polluting any role's LLM wire prompt.
    var supervisorEvents: [SupervisorTimelineEvent]

    /// Current execution round (1-based), incremented on revision requests or role restart.
    var round: Int

    /// When the current round began. Used to partition round-scoped tool calls and snapshots.
    var roundStartedAt: Date

    /// The snapshots of this run's rounds that did not land when they were taken, each with its
    /// round and phase (N2, N3 of the F6 acceptance). A snapshot that lands later removes or
    /// rewrites its record (`NTMSOrchestrator.captureTaskSnapshots`).
    var snapshotFailures: [RunSnapshotFailure]

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
        self.init(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            steps: steps,
            meetings: meetings,
            changeRequests: changeRequests,
            consultationChats: consultationChats,
            roleStatuses: roleStatuses,
            teamID: teamID,
            timedOutAt: timedOutAt,
            supervisorEvents: []
        )
    }

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
        timedOutAt: Date? = nil,
        supervisorEvents: [SupervisorTimelineEvent]
    ) {
        self.init(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            steps: steps,
            meetings: meetings,
            changeRequests: changeRequests,
            consultationChats: consultationChats,
            roleStatuses: roleStatuses,
            teamID: teamID,
            timedOutAt: timedOutAt,
            supervisorEvents: supervisorEvents,
            round: 1,
            roundStartedAt: createdAt
        )
    }

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
        timedOutAt: Date? = nil,
        timedOutAtLimit: TimeInterval? = nil,
        supervisorEvents: [SupervisorTimelineEvent] = [],
        round: Int,
        roundStartedAt: Date? = nil,
        snapshotFailures: [RunSnapshotFailure] = []
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
        self.timedOutAtLimit = timedOutAtLimit
        self.supervisorEvents = supervisorEvents
        self.round = round
        self.roundStartedAt = roundStartedAt ?? createdAt
        self.snapshotFailures = snapshotFailures
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
        case timedOutAtLimit
        case pauseCause
        case pauseRequestedBy
        case supervisorEvents
        case round
        case roundStartedAt
        case snapshotFailures
        /// Read, never written: the run-wide reason of the unreleased F1/F2 builds, which only a
        /// run's START wrote — read as round 1's start.
        case snapshotUnavailableReason
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
        self.timedOutAtLimit = try c.decodeIfPresent(TimeInterval.self, forKey: .timedOutAtLimit)
        // An unknown cause (a later build's) reads as none rather than failing the whole task.
        self.pauseCause = (try? c.decodeIfPresent(PauseCause.self, forKey: .pauseCause)) ?? nil
        // The same for a requester a later build may name differently.
        self.pauseRequestedBy = (try? c.decodeIfPresent(ControlActor.self, forKey: .pauseRequestedBy)) ?? nil
        self.supervisorEvents = try c.decodeIfPresent([SupervisorTimelineEvent].self, forKey: .supervisorEvents) ?? []
        self.round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 1
        self.roundStartedAt = try c.decodeIfPresent(Date.self, forKey: .roundStartedAt) ?? self.createdAt
        if let failures = try? c.decodeIfPresent([RunSnapshotFailure].self, forKey: .snapshotFailures) {
            self.snapshotFailures = failures
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .snapshotUnavailableReason) {
            self.snapshotFailures = [RunSnapshotFailure(
                round: 1, phase: .start,
                reason: RunSnapshotFailure.Reason(rawValue: legacy) ?? .failed,
                recordedAt: self.createdAt)]
        } else {
            self.snapshotFailures = []
        }
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
        try c.encodeIfPresent(timedOutAtLimit, forKey: .timedOutAtLimit)
        try c.encodeIfPresent(pauseCause, forKey: .pauseCause)
        try c.encodeIfPresent(pauseRequestedBy, forKey: .pauseRequestedBy)
        if !supervisorEvents.isEmpty {
            try c.encode(supervisorEvents, forKey: .supervisorEvents)
        }
        try c.encode(round, forKey: .round)
        try c.encode(roundStartedAt, forKey: .roundStartedAt)
        if !snapshotFailures.isEmpty {
            try c.encode(snapshotFailures, forKey: .snapshotFailures)
        }
    }
}

/// System timeline record of a Supervisor ACTION on a run: an automated Supervisor accepting a
/// role's output or closing the task (`§11`: «`<agent> accepted / closed`»), and anyone's Pause
/// and Resume — `task_log` reads every one of them back to the agent with its author, and the
/// feed draws the automated ones (`isDrawnInTheFeed`).
nonisolated struct SupervisorTimelineEvent: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case roleAccepted
        case taskClosed
        /// A Pause that stopped the run, written by `pauseRun` beside `Run.pauseRequestedBy`.
        case runPaused
        /// A Resume that lifted a pause, written by `resumeRun` before it restarts anything.
        case runResumed
    }

    var id: UUID
    var createdAt: Date
    var kind: Kind
    var authorLabel: String
    var roleID: String?
    /// Who acted. Every event since 2026-11-09 records it; an older one — only ever an external
    /// agent's accept or close — reads as `nil` and keeps the reading it had (CLAUDE.md #371).
    var actor: ControlActor?

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        kind: Kind,
        authorLabel: String,
        roleID: String? = nil,
        actor: ControlActor? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.authorLabel = authorLabel
        self.roleID = roleID
        self.actor = actor
    }

    /// An event `actor` wrote, signed with the actor's own label.
    init(createdAt: Date = MonotonicClock.shared.now(), kind: Kind, by actor: ControlActor, roleID: String? = nil) {
        self.init(createdAt: createdAt, kind: kind, authorLabel: actor.label, roleID: roleID, actor: actor)
    }

    /// Whether the task's feed draws this event as a line: an external agent's action, which the
    /// person did not see happen (§11) — and an event recorded before the actor, which only an
    /// external agent wrote. Not the person's own Pause and Resume, whose state the board already
    /// shows, nor the built-in Autovisor's, which its own chat shows (DEBTS D-M15).
    var isDrawnInTheFeed: Bool {
        switch actor {
        case nil, .externalAgent?: true
        case .person?, .builtInAutovisor?: false
        }
    }

    /// Human-readable one-line summary for `conversation_log.md`: the author, then
    /// ``actionText(roleName:)``.
    func summaryText(roleName: String? = nil) -> String {
        "\(authorLabel) \(actionText(roleName: roleName))"
    }

    /// What the author did, without the author — `closed task`, `accepted Coder`. The feed's
    /// event row inks the author and the action differently, so it needs them apart; the
    /// transcript joins them through ``summaryText(roleName:)``, which is this plus the author.
    func actionText(roleName: String? = nil) -> String {
        switch kind {
        case .roleAccepted:
            if let roleName, !roleName.isEmpty {
                return "accepted \(roleName)"
            }
            return "accepted"
        case .taskClosed:
            return "closed task"
        case .runPaused:
            return "paused task"
        case .runResumed:
            return "resumed task"
        }
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
    /// Whether the run's roles are each done or waiting for acceptance, and at least one of them
    /// has a status — the run waits on a decision, not on work. One rule for the two readers
    /// that ask it: `NTMSTask.derivedStatusFromActiveRun` (a finished run whose roles are not
    /// all complete reads Review rather than Working) and the external mapper (a run paused by
    /// nobody at that point reads `acceptance_gate`). They held a copy each until 2026-11-12
    /// (F6 C14), and an edit to one would have split the task's status from its event.
    var everyRoleIsCompleteOrAwaitingAcceptance: Bool {
        !roleStatuses.isEmpty && roleStatuses.values.allSatisfy { $0.isComplete || $0 == .needsAcceptance }
    }

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
    /// When the change request was resolved (approved, rejected, escalated, or failed).
    /// Used for cursor re-delivery in task_log (§5.3).
    var resolvedAt: Date?

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        requestingRoleID: String,
        targetRoleID: String,
        changes: String,
        reasoning: String,
        meetingID: UUID? = nil,
        status: ChangeRequestStatus = .pending,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.requestingRoleID = requestingRoleID
        self.targetRoleID = targetRoleID
        self.changes = changes
        self.reasoning = reasoning
        self.meetingID = meetingID
        self.status = status
        self.resolvedAt = resolvedAt
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

    /// Whether a request in this status counts against `TeamLimits.maxChangeRequestsPerRun`.
    /// A decided vote spent its slot, and a vote under way (`.pending`) holds one: two roles
    /// running in parallel (CLAUDE.md #45) must not both be voted on for the run's last slot. A
    /// vote that ended without a decision (`.failed` — Pause, Stop, the run timeout, a folder
    /// switch) frees its slot. In memory a `.pending` is always a vote under way: the handler
    /// closes every vote it starts, and one an earlier build or a quit left `.pending` is closed
    /// `.failed` when its task is loaded (`StatusRecoveryService`) (F6 C5, review R3, 2026-11-12).
    ///
    /// Before F4 recorded the request ahead of its vote, an interrupted vote was written
    /// `.rejected` — the meeting answered "Meeting cancelled.", the handler still saw its step
    /// live and recorded a vote that did not run — and so it spent a slot; only a cancel that
    /// outlived the bounded wait left no record at all.
    var countsAgainstTheRunsBudget: Bool {
        switch self {
        case .failed: false
        case .pending, .approved, .rejected, .escalated, .supervisorApproved, .supervisorRejected: true
        }
    }
}
