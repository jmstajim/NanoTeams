import Foundation

nonisolated struct NTMSTask: Codable, Identifiable, Hashable {
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

    /// Optional recurrence schedule. When set + enabled, the background automation
    /// scheduler re-runs this task (appending a new `Run`) at `recurrence.nextFireAt`.
    var recurrence: TaskRecurrence?

    /// Optional max wall-clock duration for a single run, in seconds. When a run
    /// exceeds it the run is paused and the Supervisor notified (once per run).
    var runTimeoutSeconds: TimeInterval?

    /// Parentage / delegation depth bundled as a discriminated union so the
    /// invariant `(parentTaskID == nil) ↔ (parentRoleID == nil) ↔ (depth == 0)`
    /// is enforced structurally — illegal combinations (e.g. `depth == 5`
    /// without a parent task) are unrepresentable. The legacy flat fields
    /// (`parentTaskID`, `parentRoleID`, `delegationDepth`) survive as
    /// read-only computed properties so existing read sites compile
    /// unchanged.
    private(set) var lineage: TaskLineage

    // MARK: - Back-compat read accessors

    /// Parent task that delegated this task via `delegate_to_team`. `nil`
    /// means this is a top-level Supervisor task. Child tasks are hidden
    /// from the sidebar/watchtower — they exist only as internal state of
    /// the parent's tool call.
    var parentTaskID: Int? {
        if case let .delegated(parentTaskID, _, _) = lineage { return parentTaskID }
        return nil
    }

    /// Role within the parent task that called `delegate_to_team`. The
    /// canonical `TeamRoleDefinition.id` (same shape as `StepExecution.id`)
    /// — the escalation path looks up the parent step via
    /// `step.id == parentRoleID`, so identifier shape must match.
    /// `nil` iff `parentTaskID` is `nil`.
    var parentRoleID: String? {
        if case let .delegated(_, parentRoleID, _) = lineage { return parentRoleID }
        return nil
    }

    /// Depth in the delegation chain. `0` for top-level Supervisor tasks;
    /// child = parent + 1. Hard-capped at
    /// `DelegationConstants.maxDelegationDepth` (the `TaskLineage` factory
    /// clamps any input to that bound — depth > max is unrepresentable).
    var delegationDepth: Int { lineage.depth }

    /// Backing storage for `isChatMode`. Set at creation from team config.
    /// Use `isChatMode` publicly — it prefers `generatedTeam.isChatMode` when present
    /// so the display always reflects whether Supervisor has any incoming artifacts.
    private var storedIsChatMode: Bool

    /// Whether this task operates in open-ended chat mode.
    /// Derived from the supervisor's incoming artifacts in the resolved team:
    /// `generatedTeam.isChatMode` if a team was generated, otherwise the value stored
    /// at task creation (from the preferred team's `supervisorRequiredArtifacts`).
    /// Get-only — generated teams override stored value, so a setter would be a footgun.
    /// Use `setStoredChatMode(_:)` to update the pre-generation default.
    var isChatMode: Bool {
        if let generated = generatedTeam {
            return generated.isChatMode
        }
        return storedIsChatMode
    }

    /// Updates the pre-generation chat-mode default. No effect on the observed
    /// `isChatMode` while `generatedTeam != nil` — the generated team dominates.
    mutating func setStoredChatMode(_ value: Bool) {
        storedIsChatMode = value
    }

    /// Transient team generated at task runtime (when `preferredTeamID` points to the
    /// "Generated Team" template). Takes precedence over `preferredTeamID` in `resolvedTeam`
    /// lookups. Cleared when the user saves the team via the "Save Team" action.
    /// Mutated only via `adoptGeneratedTeam(_:)` / `clearGeneratedTeam()` so the lifecycle
    /// stays observable from a single call site.
    private(set) var generatedTeam: Team?

    /// Installs an LLM-generated team on this task. Called by `runTeamGeneration` on
    /// success; flips the observed `isChatMode` to the generated team's value.
    /// Also syncs `storedIsChatMode` so the fallback remains correct after
    /// `clearGeneratedTeam()` (e.g. from the Save Team flow).
    mutating func adoptGeneratedTeam(_ team: Team) {
        generatedTeam = team
        storedIsChatMode = team.isChatMode
    }

    /// Clears the generated team reference, typically because it has been promoted
    /// into the project's persisted teams list (see `saveGeneratedTeam`).
    mutating func clearGeneratedTeam() {
        generatedTeam = nil
    }

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
        recurrence: TaskRecurrence? = nil,
        runTimeoutSeconds: TimeInterval? = nil,
        isChatMode: Bool = false,
        generatedTeam: Team? = nil,
        parentTaskID: Int? = nil,
        parentRoleID: String? = nil,
        delegationDepth: Int = 0
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
        self.recurrence = recurrence
        self.runTimeoutSeconds = runTimeoutSeconds
        self.storedIsChatMode = isChatMode
        self.generatedTeam = generatedTeam
        // Aggregate the three legacy parentage parameters into the typed
        // enum. The factory enforces the invariant
        // `(parent==nil)↔(role==nil)↔(depth==0)` AND clamps depth to
        // `[0, maxDelegationDepth]` so malformed inputs (e.g. depth=5 with
        // parent==nil) silently normalize to `.root` rather than producing
        // an unrepresentable state. Strict enforcement at construction
        // means every read site is guaranteed a coherent `TaskLineage`.
        self.lineage = TaskLineage.from(
            parentTaskID: parentTaskID,
            parentRoleID: parentRoleID,
            depth: delegationDepth
        )
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
        case recurrence
        case runTimeoutSeconds
        case isChatMode
        case generatedTeam
        // New aggregated shape (preferred on encode + decode).
        case lineage
        // Legacy flat keys (decode-only fallback for files written by
        // builds prior to the I8 refactor; never re-emitted on encode).
        case parentTaskID
        case parentRoleID
        case delegationDepth
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
        self.recurrence = try container.decodeIfPresent(TaskRecurrence.self, forKey: .recurrence)
        self.runTimeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .runTimeoutSeconds)
        self.storedIsChatMode = try container.decodeIfPresent(Bool.self, forKey: .isChatMode) ?? false
        self.generatedTeam = try container.decodeIfPresent(Team.self, forKey: .generatedTeam)
        // Lineage: prefer the new bundled shape, fall back to the three
        // legacy keys for files written by earlier builds. The factory
        // clamps malformed combinations (e.g. depth=5 with parent==nil)
        // to `.root` — strict enforcement on every load.
        if let bundled = try container.decodeIfPresent(TaskLineage.self, forKey: .lineage) {
            self.lineage = bundled.normalized()
        } else {
            let legacyParentTask = try container.decodeIfPresent(Int.self, forKey: .parentTaskID)
            let legacyParentRole = try container.decodeIfPresent(String.self, forKey: .parentRoleID)
            let legacyDepth = try container.decodeIfPresent(Int.self, forKey: .delegationDepth) ?? 0
            self.lineage = TaskLineage.from(
                parentTaskID: legacyParentTask,
                parentRoleID: legacyParentRole,
                depth: legacyDepth
            )
        }
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
        try container.encodeIfPresent(recurrence, forKey: .recurrence)
        try container.encodeIfPresent(runTimeoutSeconds, forKey: .runTimeoutSeconds)
        try container.encode(storedIsChatMode, forKey: .isChatMode)
        try container.encodeIfPresent(generatedTeam, forKey: .generatedTeam)
        // Encode the new bundled shape only when non-root — keeps top-level
        // tasks' JSON concise (no nested lineage block to mean "root").
        // Legacy flat keys are no longer written (decode-only fallback).
        if !lineage.isRoot {
            try container.encode(lineage, forKey: .lineage)
        }
    }
}

// MARK: - TaskLineage

/// Discriminated union describing a task's place in the delegation tree.
/// Replaces three previously-flat fields on `NTMSTask`
/// (`parentTaskID`, `parentRoleID`, `delegationDepth`) so the cross-field
/// invariant — "a task is either root, or it has BOTH a parent task and
/// parent role AND a non-zero depth" — is enforced structurally instead
/// of by convention.
///
/// **Construction policy**: ALWAYS construct via
/// `TaskLineage.from(parentTaskID:parentRoleID:depth:)`. That factory is
/// the only path that clamps `depth` into `[1, maxDelegationDepth]` and
/// rejects half-set parentage. Direct case construction (`.delegated(...)`)
/// is technically legal in Swift (case visibility follows enum visibility),
/// but it BYPASSES the depth clamp — a `.delegated(..., depth: 99)`
/// constructed directly is a domain-invariant violation. The Codable
/// decode paths (both new bundled shape and legacy-flat shape) sanitize
/// via `from(...)` / `normalized()` so deserialized state is always
/// well-formed; only freshly-typed code can produce a bad value, and the
/// test-suite invariant `DelegationStateAndLineageTests.testTaskLineage_directDelegatedCase_clampsViaNormalized`
/// pins that `.normalized()` always repairs whatever direct construction
/// produced.
nonisolated enum TaskLineage: Codable, Hashable {
    /// Direct case construction skips the depth clamp — call sites MUST
    /// either go through `TaskLineage.from(...)` or always pipe the value
    /// through `.normalized()` before persistence/use.
    case root
    /// Direct case construction skips the depth clamp — call sites MUST
    /// either go through `TaskLineage.from(...)` or always pipe the value
    /// through `.normalized()` before persistence/use.
    case delegated(parentTaskID: Int, parentRoleID: String, depth: Int)

    /// Depth field — `0` for root, `1...maxDelegationDepth` for delegated.
    var depth: Int {
        if case let .delegated(_, _, depth) = self { return depth }
        return 0
    }

    var isRoot: Bool {
        if case .root = self { return true }
        return false
    }

    /// Smart factory used by `NTMSTask.init(...)` and the legacy-Codable
    /// fallback path. Folds the three legacy parameters into the typed
    /// enum and applies invariants:
    ///   - both `parentTaskID` and `parentRoleID` must be non-nil for the
    ///     `.delegated` branch (either-but-not-both → `.root`, since the
    ///     escalation path needs both)
    ///   - depth is clamped into `[1, maxDelegationDepth]` for `.delegated`
    ///     and forced to `0` for `.root`
    static func from(parentTaskID: Int?, parentRoleID: String?, depth: Int) -> TaskLineage {
        guard let parent = parentTaskID, let role = parentRoleID else {
            return .root
        }
        let clamped = max(1, min(DelegationConstants.maxDelegationDepth, depth))
        return .delegated(parentTaskID: parent, parentRoleID: role, depth: clamped)
    }

    /// Used after Codable decode of the new bundled shape to re-apply the
    /// depth-clamp invariant — guards against a hand-edited `task.json`
    /// shipping `depth: 99` inside a `.delegated` payload. `.root` is
    /// unchanged.
    func normalized() -> TaskLineage {
        switch self {
        case .root:
            return .root
        case let .delegated(parent, role, depth):
            let clamped = max(1, min(DelegationConstants.maxDelegationDepth, depth))
            return .delegated(parentTaskID: parent, parentRoleID: role, depth: clamped)
        }
    }
}

nonisolated enum TaskStatus: String, Codable, CaseIterable, Hashable {
    case running
    case done
    case paused
    case waiting
    case needsSupervisorInput
    case needsSupervisorAcceptance
    case failed
}

nonisolated extension TaskStatus {
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
nonisolated struct TasksIndex: Codable, Hashable {
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

nonisolated extension TasksIndex {
    /// Walks `parentTaskID` links from `taskID` up to the root, returning ancestor
    /// IDs in root-first order. Empty array if the task is top-level (or unknown).
    /// Used by `NTMSPaths` to build nested storage paths
    /// (`.nanoteams/tasks/{root}/subtasks/{level1}/.../subtasks/{taskID}/`).
    ///
    /// Cycle safety: caps at `DelegationConstants.treeTraversalSafetyCap`
    /// (`maxDelegationDepth * cycleSafetyMultiplier`) and additionally tracks
    /// a `visited` set to detect a true cycle (parent points back to a task
    /// already in the chain). Real chains never exceed `maxDelegationDepth`;
    /// anything beyond is corruption — we bail rather than truncate silently.
    func ancestorIDs(of taskID: Int) -> [Int] {
        var ancestors: [Int] = []
        var visited: Set<Int> = [taskID]
        var current: Int? = tasks.first(where: { $0.id == taskID })?.parentTaskID
        var safety = 0
        let cap = DelegationConstants.treeTraversalSafetyCap
        while let pid = current, safety < cap {
            // Cycle: parent already seen on this chain. Bail without
            // appending — the caller would otherwise get a finite but wrong
            // ancestor list including the cycle.
            if visited.contains(pid) { break }
            visited.insert(pid)
            ancestors.insert(pid, at: 0)
            current = tasks.first(where: { $0.id == pid })?.parentTaskID
            safety += 1
        }
        return ancestors
    }

    /// BFS-walks the `parentTaskID`-reverse tree from `taskID`, returning every
    /// transitive descendant in level order. Used by the activity feed to
    /// surface delegated child runs alongside the parent (delegation V1 UI).
    ///
    /// Cycle safety: caps at `DelegationConstants.treeTraversalSafetyCap`
    /// AND tracks visited IDs to short-circuit cycles. Without the visited
    /// set, a corrupted child→parent self-link would produce duplicates in
    /// `result` until the cap was hit.
    func descendantIDs(of taskID: Int) -> [Int] {
        var result: [Int] = []
        var visited: Set<Int> = [taskID]
        var frontier: [Int] = [taskID]
        var safety = 0
        let cap = DelegationConstants.treeTraversalSafetyCap
        while !frontier.isEmpty && safety < cap {
            var next: [Int] = []
            for parentID in frontier {
                for summary in tasks where summary.parentTaskID == parentID {
                    if visited.contains(summary.id) { continue }
                    visited.insert(summary.id)
                    result.append(summary.id)
                    next.append(summary.id)
                }
            }
            frontier = next
            safety += 1
        }
        return result
    }
}

nonisolated struct TaskSummary: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var status: TaskStatus
    var updatedAt: Date
    var isChatMode: Bool
    /// Parent task ID for child tasks created via `delegate_to_team`. `nil` for top-level
    /// Supervisor tasks. Used to filter child tasks out of sidebar/watchtower lists.
    var parentTaskID: Int?
    /// Next scheduled recurrence fire, if the task has an enabled recurrence.
    /// `nil` otherwise. The scheduler scans this in-memory to find due tasks
    /// cheaply, and the sidebar shows a "recurring" badge when non-nil.
    var nextRecurrenceFireAt: Date?

    /// The team the task's active run is pinned to (`runs.last?.teamID`). Mirrored
    /// into the index so `teamIsInUseByActiveRun` can authoritatively block deleting
    /// a team that backs ANY non-closed task — including ones paused/evicted from
    /// `loadedTasks` — without loading every task blob.
    var pinnedTeamID: NTMSID?

    init(id: Int, title: String, status: TaskStatus, updatedAt: Date = MonotonicClock.shared.now(), isChatMode: Bool = false, parentTaskID: Int? = nil, nextRecurrenceFireAt: Date? = nil, pinnedTeamID: NTMSID? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.isChatMode = isChatMode
        self.parentTaskID = parentTaskID
        self.nextRecurrenceFireAt = nextRecurrenceFireAt
        self.pinnedTeamID = pinnedTeamID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.status = try container.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .running
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.isChatMode = try container.decodeIfPresent(Bool.self, forKey: .isChatMode) ?? false
        self.parentTaskID = try container.decodeIfPresent(Int.self, forKey: .parentTaskID)
        self.nextRecurrenceFireAt = try container.decodeIfPresent(Date.self, forKey: .nextRecurrenceFireAt)
        self.pinnedTeamID = try container.decodeIfPresent(String.self, forKey: .pinnedTeamID)
    }
}

nonisolated extension NTMSTask {
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

        // Shared with AnswerTextBuilder.build so skill + clip section formatting
        // stays identical across the live-submit and persisted-task paths.
        sections.append(contentsOf: AnswerTextBuilder.clipSections(from: clippedTexts))

        if !attachmentPaths.isEmpty {
            let pathList = attachmentPaths
                .map { "- \($0)" }
                .joined(separator: "\n")
            sections.append("## Attached Files\n\(pathList)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Derived status from the active run's step summary, with task-level overrides.
    func derivedStatusFromActiveRun() -> TaskStatus {
        // A task closed before it ever created a run is still terminal — closing is
        // the Supervisor's explicit "done", regardless of the stored `status`.
        guard let run = runs.last else { return closedAt != nil ? .done : status }
        guard !run.steps.isEmpty else {
            // A Supervisor-closed run that never created steps is still terminal.
            // Safe: createNewRun clears closedAt before a fresh (empty) run exists.
            return closedAt != nil ? .done : .running
        }

        let s = run.stepStatusSummary()

        // A Supervisor-closed task is terminal once nothing is actively executing.
        // `closedAt` is set only by closeTask (which also stops the engine) and is
        // cleared by createNewRun / restartRole *before* a run can become active,
        // so under normal flow a closed task never has a running step. Gating on
        // `!hasRunning` is defense-in-depth: resumeRun has no closedAt guard, so
        // even if some path resumed a closed task, a live run still surfaces its
        // true status instead of a false "Done". This covers every leftover shape
        // closeTask doesn't normalize — pending / needsApproval steps, idle / ready
        // downstream roles that never ran — which would otherwise read as .running.
        if closedAt != nil && !s.hasRunning {
            return s.hasFailed ? .failed : .done
        }

        let base = s.derivedTaskStatus()

        // Task-level overrides on top of base priority. Past the guard above,
        // `base == .done` implies `allDone ⇒ !hasRunning`, so `closedAt` is provably
        // nil in every `.done` branch below — the closed-task cases collapse to the
        // open-task result.
        switch base {
        // `status` here is the recovery LATCH, not a live status — see
        // `clearRecoveryPauseLatch()`. It exists so a recovered run whose remaining
        // steps are all `.pending` (no `.paused` step to trip the summary's own
        // `hasPaused` arm) reads "Paused" rather than "Working".
        case .running where status == .paused && !s.hasRunning:
            return .paused
        case .done where isChatMode:
            return .running
        case .done:
            if !run.roleStatuses.isEmpty {
                let allRolesComplete = run.roleStatuses.values.allSatisfy { $0.isComplete }
                if !allRolesComplete {
                    // Distinguish "roles still working" from "roles waiting for acceptance"
                    let onlyAcceptanceOrComplete = run.roleStatuses.values.allSatisfy {
                        $0.isComplete || $0 == .needsAcceptance
                    }
                    if onlyAcceptanceOrComplete {
                        return .needsSupervisorAcceptance
                    }
                    return .running
                }
            }
            return .needsSupervisorAcceptance
        default:
            return base
        }
    }

    /// Clears the recovery pause latch.
    ///
    /// `status` is a one-bit LATCH, not a live status. Three writers, and this function
    /// is the third: seeded at `createTask`, ARMED (`.paused`) by `StatusRecoveryService`
    /// when a launch found work parked mid-flight, and RETIRED here — from `createNewRun`,
    /// `resumeRun` and `restartRole` (named again at the end of this comment; count them
    /// from the call sites, not from a sentence). This paragraph said "exactly two
    /// writers" until 2026-08-10, inside the doc of the writer it left out, which reads
    /// as "nothing clears it" — precisely the pre-fix state the paragraph below
    /// describes. Everything user-facing reads the DERIVED
    /// status instead (`derivedStatusFromActiveRun`, `toSummary`), and the only thing
    /// that consults the stored value is the `.running where status == .paused` guard
    /// above — which exists so a recovered run with all-`.pending` steps reads "Paused".
    ///
    /// Because nothing used to clear it, the latch stayed armed for the rest of the
    /// task's life: every LATER run then rendered "Paused" at any moment when no step
    /// happened to be `.running` (e.g. an upstream step just finished while downstream
    /// steps are still `.pending`). Every transition back to live must clear it —
    /// today `createNewRun`, `resumeRun` and `restartRole`.
    mutating func clearRecoveryPauseLatch() {
        guard status == .paused else { return }
        status = .running
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
        TaskSummary(
            id: id,
            title: title,
            status: derivedStatusFromActiveRun(),
            updatedAt: updatedAt,
            isChatMode: isChatMode,
            parentTaskID: parentTaskID,
            nextRecurrenceFireAt: recurrence.flatMap { $0.isEnabled ? $0.nextFireAt : nil },
            pinnedTeamID: runs.last?.teamID
        )
    }
}
