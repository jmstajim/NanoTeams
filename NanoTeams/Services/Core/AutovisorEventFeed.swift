import Foundation

/// Event kinds emitted by `AutovisorEventFeed` for external MCP agents (§9).
nonisolated enum AutovisorEventKind: String, CaseIterable, Codable, Hashable, Sendable {
    case question = "question"
    case acceptanceGate = "acceptance_gate"
    case review = "review"
    case failed = "failed"
    case paused = "paused"
    case stuck = "stuck"
    case resumed = "resumed"
    case closed = "closed"
    case deleted = "deleted"

    /// The kinds that report a condition STANDING on a task — a level a snapshot reads off the
    /// task — in the order a snapshot reports them. A type of their own, so what asks a level or
    /// builds a standing instance (`AutovisorEventFeed.levelHolds`, `.standing`) takes one and has
    /// no arm for a moment. Until 2026-11-08 those switches ran over all nine kinds and answered
    /// `false` / `[]` for the two moments — arms no caller could reach, since every caller had
    /// already filtered by `isStanding`.
    ///
    /// Only conditions that wait on somebody stand. `closed` stood until 2026-11-09, and every
    /// snapshot repeated every task the agent had ever closed — a closed task with a failed step
    /// as `failed`, forever (`NTMSTask.derivedStatusFromActiveRun`).
    enum Standing: CaseIterable, Hashable, Sendable {
        case question, acceptanceGate, review, failed, paused, stuck

        var kind: AutovisorEventKind {
            switch self {
            case .question: .question
            case .acceptanceGate: .acceptanceGate
            case .review: .review
            case .failed: .failed
            case .paused: .paused
            case .stuck: .stuck
            }
        }
    }

    /// The kinds a candidate carries as a MOMENT — somebody resumed, closed or deleted the task —
    /// with the actor who did it, never read off a task. There is no `created`: only the agent
    /// that creates a task owns it, so its creation could reach nobody but as an echo of its own
    /// call (`ControlActor.isExternalAgent`).
    enum Moment: Hashable, Sendable {
        case resumed, closed, deleted
    }

    /// What a kind reports: a condition that stands, or a moment.
    enum Shape: Hashable, Sendable {
        case standing(Standing)
        case moment(Moment)
    }

    /// The one switch that sorts the nine kinds into the two shapes.
    var shape: Shape {
        switch self {
        case .question: .standing(.question)
        case .acceptanceGate: .standing(.acceptanceGate)
        case .review: .standing(.review)
        case .failed: .standing(.failed)
        case .paused: .standing(.paused)
        case .stuck: .standing(.stuck)
        case .resumed: .moment(.resumed)
        case .closed: .moment(.closed)
        case .deleted: .moment(.deleted)
        }
    }

    /// Whether a condition of this kind can wait on the agent to act. Every standing kind can and
    /// no moment does — a moment reports what already happened; whether a pause DOES depends on
    /// its reason (`AutovisorEvent.awaitsItsAgent`).
    var mayAwaitItsAgent: Bool {
        switch shape {
        case .standing: true
        case .moment: false
        }
    }
}

/// Reason a task entered the `.paused` state (§9).
nonisolated enum AutovisorPauseReason: String, CaseIterable, Codable, Hashable, Sendable {
    /// A Pause pressed in the app — by the person, or by the built-in Autovisor acting there.
    case byPerson = "by_person"
    /// A Pause an external agent asked for — only a task's own agent can (`control_task pause`).
    case byAgent = "by_agent"
    case timedOut = "timed_out"
    case iterationLimit = "iteration_limit"
    case recovered = "recovered"

    /// Whether resuming a pause for this reason is the agent's to do: its own Pause, and a pause
    /// the app made — the run timeout, the iteration limit, a quit that interrupted the run. Not
    /// a Pause pressed in the app (`by_person`), which is the person's to lift.
    var awaitsTheAgent: Bool {
        switch self {
        case .byAgent, .timedOut, .iterationLimit, .recovered: true
        case .byPerson: false
        }
    }

    /// Whether top-level `task` stands in the person's Pause — `by_person`, and not the built-in
    /// Autovisor's own Pause, which reads the same on the wire. The one rule behind
    /// `NTMSOrchestrator.isPausedInTheApp` and every reader that has only the task: `enginePaused`
    /// counts a delegating task's Pause (its step stays running), `liveIterationLimitPause` the
    /// engine's flag. A reader with no engine at hand passes `false` for both and loses only those
    /// two shapes — neither has a `.paused` step. `false` for a delegated child, paused and resumed
    /// by the role that delegated it.
    static func isThePersons(task: NTMSTask, enginePaused: Bool, liveIterationLimitPause: Bool) -> Bool {
        guard task.parentTaskID == nil else { return false }
        let reason = resolve(
            run: task.runs.last,
            taskStatus: task.status,
            isPaused: task.derivedStatusFromActiveRun() == .paused || enginePaused,
            liveIterationLimitPause: liveIterationLimitPause
        )
        return reason == .byPerson && task.runs.last?.pauseRequestedBy != .builtInAutovisor
    }

    /// Why the run stands paused: the engine's live iteration-limit flag while this process runs
    /// it, else the cause the code that paused it recorded on the run (`Run.pauseCause`). The
    /// run's record is durable, so a relaunch reads the same reason — the feed's own memory of
    /// the task does not survive one, and `timedOutAt` stays set after the person resumes the
    /// timed-out run and pauses it again.
    ///
    /// A recorded `.requested` is read BEFORE the task's `.paused` latch: a Pause leaves the role
    /// `.working` beside its parked step, status recovery reads that pair on the next cold load
    /// as interrupted work and arms the latch over it, and reading the latch first told the agent
    /// after every relaunch that a pause somebody made had been the app's. The latch decides only
    /// for a run with no recorded cause — one written before the field.
    ///
    /// Extracted from the feed's pause builder (`materializePaused`, now `standingPause`) on
    /// 2026-11-08 so `task_status` answers the same question the same way: an agent that
    /// reconnects reads status rather than replaying the event that carried the reason, and the
    /// four values need four different remedies.
    /// `nil` when the task is not paused at all — and when the Resume that recorded `.resumed` is
    /// still restarting the steps it found parked: no pause stands then (`Run.PauseCause.resumed`).
    static func resolve(
        run: Run?,
        taskStatus: TaskStatus,
        isPaused: Bool,
        liveIterationLimitPause: Bool
    ) -> AutovisorPauseReason? {
        guard isPaused || liveIterationLimitPause else { return nil }
        if liveIterationLimitPause || run?.pauseCause == .iterationLimit {
            return .iterationLimit
        }
        if run?.latestPauseIsItsTimeout == true { return .timedOut }
        if run?.pauseCause == .requested {
            if case .externalAgent = run?.pauseRequestedBy { return .byAgent }
            return .byPerson
        }
        if run?.pauseCause == .recovered || taskStatus == .paused { return .recovered }
        // A Resume lifted the latest pause and no pause recorded since: steps still parked are the
        // ones it is restarting. Read by the fall-through below, the Resume's own write told a
        // wait open across it `paused(by_person)` — the agent's own Resume too — and the person's
        // gate refused the agent for a pause nobody pressed (2026-11-12).
        if run?.pauseCause == .resumed { return nil }
        if let run, !run.stepStatusSummary().hasPaused,
           AcceptanceService.hasAcceptanceGate(run: run) {
            return nil
        }
        return .byPerson
    }
}

/// Reason an event cursor was reset to a snapshot (§8.1, §9).
nonisolated enum AutovisorCursorResetReason: String, CaseIterable, Codable, Hashable, Sendable {
    case folderChanged = "folder_changed"
    case restarted = "restarted"
    case gap = "gap"
    /// The cursor was returned for other `task_ids` than this call names: its position skipped the
    /// candidates of the tasks the earlier call did not watch.
    case filterChanged = "filter_changed"
}

/// Reason a blocking `wait_for_events` call terminated early without normal event delivery or timeout (§9).
nonisolated enum AutovisorWaitStopReason: String, CaseIterable, Codable, Hashable, Sendable {
    case superseded = "superseded"
    case folderChanged = "folder_changed"
    case driverChanged = "driver_changed"
    case notReady = "not_ready"
    case shuttingDown = "shutting_down"

    /// The stop a wait begun in readiness `state` ends with at once — `nil` for `.ready`, the one
    /// state a wait can be answered in. The same stop a wait already in progress gets when the
    /// state changes under it: an open under way is a folder change, the built-in driver is a
    /// driver change, no folder or the Autovisor off is not ready. Until 2026-11-09 a wait begun
    /// in any of them parked for its whole timeout, and the agent's next call parked again.
    static func immediate(for state: ExternalAutovisorReadiness.State) -> AutovisorWaitStopReason? {
        switch state {
        case .ready: nil
        case .folderTransition: .folderChanged
        case .builtInDriver: .driverChanged
        case .noWorkFolder, .folderInUse, .autovisorDisabled: .notReady
        }
    }
}

/// Concurrency bucket for `wait_for_events` (§9):
/// - Legacy era: ≤ 2 concurrent waits per `(agentID, sessionID)`.
/// - Modern era (`sessionID == nil`): ≤ 4 concurrent waits per `agentID`.
nonisolated enum AutovisorWaitConcurrencyScope: Hashable, Sendable {
    case legacySession(agentID: UUID, sessionID: String)
    case modernAgent(agentID: UUID)

    var maxConcurrentWaits: Int {
        switch self {
        case .legacySession: return 2
        case .modernAgent: return 4
        }
    }
}

/// One validated event delivered to an external agent by `AutovisorEventFeed` (§9).
nonisolated struct AutovisorEvent: Codable, Hashable, Sendable {
    /// The event's place in the feed — `nil` for an event of a snapshot, which reports what
    /// stands now rather than something that happened at a place in the feed.
    var seq: Int?
    var taskID: Int
    var kind: AutovisorEventKind
    var title: String
    var roleID: String?
    var question: String?
    var pauseReason: AutovisorPauseReason?
    var origin: TaskOrigin?
    var errorMessage: String?
    /// Who resumed, closed or deleted the task — set on those moments only.
    var by: ControlActor?
    /// Round execution summary for review events.
    var roundSummary: RoundSummaryDTO?

    init(
        seq: Int?,
        taskID: Int,
        kind: AutovisorEventKind,
        title: String,
        roleID: String? = nil,
        question: String? = nil,
        pauseReason: AutovisorPauseReason? = nil,
        origin: TaskOrigin? = nil,
        errorMessage: String? = nil,
        by: ControlActor? = nil,
        roundSummary: RoundSummaryDTO? = nil
    ) {
        self.seq = seq
        self.taskID = taskID
        self.kind = kind
        self.title = title
        self.roleID = roleID
        self.question = question
        self.pauseReason = pauseReason
        self.origin = origin
        self.errorMessage = errorMessage
        self.by = by
        self.roundSummary = roundSummary
    }

    /// Whether this event reports something that waits on the agent to act — a question to
    /// answer, a gate or a review to decide, a failure or a stall to see to, a pause that is the
    /// agent's to resume. What the auto-off banner means by "tasks still needed it" under the
    /// external driver (`AutovisorEventFeed.hasConditionAwaitingAnAgent`).
    var awaitsItsAgent: Bool {
        guard kind.mayAwaitItsAgent else { return false }
        // Only a pause depends on more than its kind: whoever paused it on purpose lifts it.
        guard kind == .paused else { return true }
        return pauseReason?.awaitsTheAgent ?? false
    }
}

/// Outcome of a `wait_for_events` call on `AutovisorEventFeed` (§8.1, §9).
nonisolated struct AutovisorWaitResult: Equatable, Sendable {
    var events: [AutovisorEvent]
    var cursor: String?
    var waitedSeconds: Double
    var timedOut: Bool
    var cursorResetReason: AutovisorCursorResetReason?
    var superseded: Bool
    var stopReason: AutovisorWaitStopReason?
    var tasks: [TaskHeartbeatSummary]?

    init(
        events: [AutovisorEvent] = [],
        cursor: String? = nil,
        waitedSeconds: Double = 0,
        timedOut: Bool = false,
        cursorResetReason: AutovisorCursorResetReason? = nil,
        superseded: Bool = false,
        stopReason: AutovisorWaitStopReason? = nil,
        tasks: [TaskHeartbeatSummary]? = nil
    ) {
        self.events = events
        self.cursor = cursor
        self.waitedSeconds = waitedSeconds
        self.timedOut = timedOut
        self.cursorResetReason = cursorResetReason
        self.superseded = superseded
        self.stopReason = stopReason
        self.tasks = tasks
    }

    /// A wait this server ended for `reason` with the agent's cursor at `cursor` — whether it
    /// waited first or ended at once (`AutovisorWaitStopReason.immediate`). It keeps the cursor,
    /// so a candidate that landed with the stop reaches the next call — except across a folder
    /// change, after which the old folder's cursor names nothing: it is dropped and the reset
    /// said. One builder for both, which until 2026-11-09 disagreed: the immediate stop dropped
    /// the cursor without saying why.
    static func stopped(_ reason: AutovisorWaitStopReason, keeping cursor: String?, waitedSeconds: Double) -> AutovisorWaitResult {
        let folderChanged = reason == .folderChanged
        return AutovisorWaitResult(
            cursor: folderChanged ? nil : cursor,
            waitedSeconds: waitedSeconds,
            cursorResetReason: folderChanged ? .folderChanged : nil,
            stopReason: reason
        )
    }
}

/// Per-folder ring buffer and waiter coordinator for external-agent `wait_for_events` (§9).
@MainActor
final class AutovisorEventFeed {
    nonisolated static let defaultRingCapacity = 2048
    nonisolated static let defaultDeliveredIdentityCap = 2048

    nonisolated fileprivate struct Candidate: Sendable {
        let seq: Int
        let taskID: Int
        let kind: AutovisorEventKind
        let rowStamp: Date
        let origin: TaskOrigin?
        let title: String?
        /// Who caused a moment — resumed, closed, deleted. `nil` for a standing kind, whose
        /// author, where it has one, is read off the task (`Run.pauseRequestedBy`).
        let actor: ControlActor?
    }

    nonisolated fileprivate enum InstanceIdentity: Hashable, Sendable {
        case question(
            taskID: Int,
            stepID: String,
            callID: UUID?,
            inquiryQuestionIDs: [String],
            questionText: String,
            stepUpdatedAt: Date
        )
        case acceptanceGate(taskID: Int, runID: Int, roleID: String, stepCompletedAt: Date?)
        case review(taskID: Int, runID: Int, latestStepCompletedAt: Date?)
        case failed(taskID: Int, runID: Int, stamp: Date)
        case paused(taskID: Int, runID: Int, reason: AutovisorPauseReason, stamp: Date)
        case stuck(taskID: Int, episodeStart: Date)
        case resumed(taskID: Int, at: Date)
        case closed(taskID: Int, closedAt: Date)
        case deleted(taskID: Int)
    }

    /// One instance of a condition standing on a task, as `wait_for_events` would tell it: the
    /// identity that keeps it from being told twice, and the event that tells it. Built without
    /// touching what was delivered (`standingInstances`), so the snapshot and the auto-off banner
    /// read the same conditions and only the snapshot delivers them (`deliverNew`).
    nonisolated fileprivate struct StandingInstance: Sendable {
        let identity: InstanceIdentity
        let event: AutovisorEvent
    }

    nonisolated fileprivate struct BoundedIdentitySet: Sendable {
        let capacity: Int
        private var set: Set<InstanceIdentity> = []
        private var order: [InstanceIdentity] = []

        init(capacity: Int = AutovisorEventFeed.defaultDeliveredIdentityCap) {
            self.capacity = max(1, capacity)
        }

        mutating func insertIfNew(_ identity: InstanceIdentity) -> Bool {
            guard !set.contains(identity) else { return false }
            if order.count >= capacity, let oldest = order.first {
                order.removeFirst()
                set.remove(oldest)
            }
            set.insert(identity)
            order.append(identity)
            return true
        }
    }

    nonisolated fileprivate enum WaitResolution: Sendable {
        case candidateArrived
        case timedOut
        case cancelled
        case superseded
        case interrupted(AutovisorWaitStopReason)
    }

    fileprivate struct ActiveWaiter {
        let bridgeID: UUID
        let callID: UUID
        let registrationSeq: Int
        let scope: AutovisorWaitConcurrencyScope
        let agentID: UUID
        let bridge: ApprovalWaiter<WaitResolution>
    }

    weak var store: NTMSOrchestrator?
    let ringCapacity: Int
    let deliveredIdentityCap: Int

    private(set) var isArmed: Bool = false
    private(set) var folderID: UUID?
    private(set) var epoch: Int = 0
    /// This process's launch, the half of a cursor's epoch that a relaunch changes
    /// (`epochToken`).
    let launchID: String
    private(set) var headSeq: Int = 0
    private(set) var isShuttingDown: Bool = false
    private(set) var waiterCount: Int = 0

    private var ring: [Candidate] = []
    private var deliveredIdentitiesByAgent: [UUID: BoundedIdentitySet] = [:]
    private var activeStuckEpisodeStartByTaskID: [Int: Date] = [:]
    private var activeWaitersByScope: [AutovisorWaitConcurrencyScope: [ActiveWaiter]] = [:]
    private var nextWaiterRegistrationSeq: Int = 0

    /// One wait's place in `waitsInProgress`: the folder it began in and the agent it is for.
    private struct WaitInProgressKey: Hashable {
        let folderID: UUID
        let agentID: UUID
    }

    /// Waits in their blocking phase, by the folder each began in and the agent each is for — the
    /// one count both "is anyone waiting here" (`hasWaitInProgress`, the auto-off tick) and "is
    /// this agent waiting" (`hasWaitInProgress(forAgentID:)`, its presence) are read from. Counted
    /// per CALL, not per registered bridge: a candidate wakes and drops every bridge at once, and a
    /// wait that finds nothing of its own re-registers only on its next turn —
    /// `activeWaitersByScope` is empty in between while the wait is still the agent's. Until
    /// 2026-11-08 presence read that registry and an agent flashed away mid-wait.
    private var waitsInProgress: [WaitInProgressKey: Int] = [:]

    /// Whether any wait — any agent's, any scope's — is in progress in the folder the feed is armed
    /// for. The auto-off tick reads it: under the external driver a parked wait is the agent
    /// supervising, however long ago the call began (`evaluateAutovisorAutoDisable`).
    var hasWaitInProgress: Bool {
        guard isArmed, let folderID else { return false }
        return waitsInProgress.keys.contains { $0.folderID == folderID }
    }

    /// Whether `agentID` has a wait in progress in the folder the feed is armed for — the half of
    /// an agent's presence that does not age (`HostedMCPAgentStore.isAgentPresent`, §6). A wait
    /// interrupted by a folder transition is not one in the next folder, even before it returns.
    func hasWaitInProgress(forAgentID agentID: UUID) -> Bool {
        guard isArmed, let folderID else { return false }
        return waitsInProgress[WaitInProgressKey(folderID: folderID, agentID: agentID)] != nil
    }

    /// A token for this process's launch: eight hex digits, drawn once per process.
    nonisolated static let processLaunchID = String(UUID().uuidString.lowercased().prefix(8))

    init(
        ringCapacity: Int = AutovisorEventFeed.defaultRingCapacity,
        deliveredIdentityCap: Int = AutovisorEventFeed.defaultDeliveredIdentityCap,
        launchID: String = AutovisorEventFeed.processLaunchID
    ) {
        self.ringCapacity = max(1, ringCapacity)
        self.deliveredIdentityCap = max(1, deliveredIdentityCap)
        self.launchID = launchID
    }

    /// The epoch as a cursor carries it: this process's launch, then the counter a folder open or
    /// a server enable moves (`<launch>.<n>`). The counter alone starts over at every launch, and
    /// the folder open and the server start race for the first two values, so until 2026-11-09 a
    /// cursor from the previous process was taken for this one's: its position was read against a
    /// ring it had never seen, and the events of this process up to that position were skipped
    /// without a reset.
    var epochToken: String {
        "\(launchID).\(epoch)"
    }

    var currentCursor: String? {
        guard isArmed, let folderID else { return nil }
        return Self.formatCursor(folderID: folderID, epoch: epochToken, seq: headSeq)
    }

    /// `<folder_id>:<epoch>:<seq>`, and for a call that named `task_ids` a fourth part listing them
    /// in ascending order (`…:0,5,12`; empty for an empty set). A cursor belongs to the filter it was
    /// returned for: a call with a filter skips the candidates of the agent's other tasks, so its
    /// position says nothing about them, and a call with another filter starts over with a
    /// snapshot (`AutovisorCursorResetReason.filterChanged`). The epoch is `epochToken`'s.
    nonisolated static func formatCursor(folderID: UUID, epoch: String, seq: Int, taskIDs: Set<Int>? = nil) -> String {
        let base = "\(folderID.uuidString):\(epoch):\(seq)"
        guard let taskIDs else { return base }
        return base + ":" + taskIDs.sorted().map(String.init).joined(separator: ",")
    }

    /// The parts of a cursor `formatCursor` wrote — `nil` for anything else. The epoch is compared
    /// whole, never read: one from another launch, or from a build that wrote a bare counter, is
    /// simply not this epoch.
    nonisolated static func parseCursor(_ raw: String) -> (folderID: UUID, epoch: String, seq: Int, taskIDs: Set<Int>?)? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 4,
              let folderID = UUID(uuidString: String(parts[0])),
              !parts[1].isEmpty,
              let seq = Int(parts[2]),
              seq >= 0
        else { return nil }
        let epoch = String(parts[1])
        guard parts.count == 4 else { return (folderID, epoch, seq, nil) }
        var taskIDs = Set<Int>()
        for item in parts[3].split(separator: ",", omittingEmptySubsequences: false) where !parts[3].isEmpty {
            guard let id = Int(item), id >= 0 else { return nil }
            taskIDs.insert(id)
        }
        return (folderID, epoch, seq, taskIDs)
    }

    // MARK: - Folder & Server Epoch Lifecycle

    /// Disarms the feed at `beginFolderTransition` and `discardWorkFolderState` so unwinding
    /// steps from the outgoing folder cannot write candidates into the next epoch (M1).
    func disarmForFolderTransition() {
        isArmed = false
        folderID = nil
        headSeq = 0
        ring.removeAll(keepingCapacity: true)
        deliveredIdentitiesByAgent.removeAll()
        activeStuckEpisodeStartByTaskID.removeAll()
        wakeAllWaiters(with: .interrupted(.folderChanged))
    }

    /// Arms a fresh epoch when a work folder commits (`openWorkFolder`).
    func activateFolder(folderID: UUID) {
        self.folderID = folderID
        self.epoch &+= 1
        self.headSeq = 0
        self.ring.removeAll(keepingCapacity: true)
        self.deliveredIdentitiesByAgent.removeAll()
        self.activeStuckEpisodeStartByTaskID.removeAll()
        self.isShuttingDown = false
        self.isArmed = true
    }

    /// Starts a new epoch when the MCP server is enabled so prior cursors reset with `.restarted` (§9).
    func bumpEpochForServerEnable() {
        guard isArmed else { return }
        epoch &+= 1
        headSeq = 0
        ring.removeAll(keepingCapacity: true)
        deliveredIdentitiesByAgent.removeAll()
        activeStuckEpisodeStartByTaskID.removeAll()
    }

    // MARK: - Candidate Recording

    /// Synchronous O(1) row-edge hook called by `TaskFactsProjection.apply` and `replaceAll` (§9).
    func handleRowUpdated(from previous: TaskSummary?, to current: TaskSummary) {
        guard isArmed else { return }
        guard current.parentTaskID == nil else { return }

        if current.status != .running {
            activeStuckEpisodeStartByTaskID.removeValue(forKey: current.id)
        }

        // 1. question
        let wasWaiting = previous.map { $0.isWaitingForSupervisor && $0.status != .running } ?? false
        let isWaiting = current.isWaitingForSupervisor && current.status != .running
        let prevCount = previous?.pendingSupervisorQuestionCount ?? (wasWaiting ? 1 : 0)
        let currCount = current.pendingSupervisorQuestionCount ?? (isWaiting ? 1 : 0)
        if isWaiting && (!wasWaiting || currCount > prevCount || current.updatedAt != previous?.updatedAt) {
            appendCandidate(
                taskID: current.id,
                kind: .question,
                rowStamp: current.updatedAt,
                origin: current.origin,
                title: current.title
            )
        }

        // 2. acceptance_gate
        let wasGate = previous.map {
            NTMSOrchestrator.AutovisorAttentionTrigger.acceptanceGate.levelHolds(for: $0)
        } ?? false
        let isGate = NTMSOrchestrator.AutovisorAttentionTrigger.acceptanceGate.levelHolds(for: current)
        if isGate && (!wasGate || current.updatedAt != previous?.updatedAt) {
            appendCandidate(
                taskID: current.id,
                kind: .acceptanceGate,
                rowStamp: current.updatedAt,
                origin: current.origin,
                title: current.title
            )
        }

        // 3. review
        let wasReview = previous.map {
            NTMSOrchestrator.AutovisorAttentionTrigger.completed.levelHolds(for: $0)
        } ?? false
        let isReview = NTMSOrchestrator.AutovisorAttentionTrigger.completed.levelHolds(for: current)
        if isReview && (!wasReview || current.updatedAt != previous?.updatedAt) {
            appendCandidate(
                taskID: current.id,
                kind: .review,
                rowStamp: current.updatedAt,
                origin: current.origin,
                title: current.title
            )
        }

        // 4. failed
        let wasFailed = previous.map {
            NTMSOrchestrator.AutovisorAttentionTrigger.failed.levelHolds(for: $0)
        } ?? false
        let isFailed = NTMSOrchestrator.AutovisorAttentionTrigger.failed.levelHolds(for: current)
        if isFailed && (!wasFailed || current.updatedAt != previous?.updatedAt) {
            appendCandidate(
                taskID: current.id,
                kind: .failed,
                rowStamp: current.updatedAt,
                origin: current.origin,
                title: current.title
            )
        }

        // 5. paused
        let wasPaused = (previous?.status == .paused)
        let isPaused = (current.status == .paused)
        if isPaused && (!wasPaused || current.updatedAt != previous?.updatedAt) {
            appendCandidate(
                taskID: current.id,
                kind: .paused,
                rowStamp: current.updatedAt,
                origin: current.origin,
                title: current.title
            )
        }
    }

    /// `actor` resumed a paused task (`resumeRun`).
    func recordResumed(taskID: Int, by actor: ControlActor) {
        appendCandidate(taskID: taskID, kind: .resumed, rowStamp: MonotonicClock.shared.now(), actor: actor)
    }

    /// `actor` closed the task (`closeTask`).
    func recordClosed(taskID: Int, by actor: ControlActor) {
        appendCandidate(taskID: taskID, kind: .closed, rowStamp: MonotonicClock.shared.now(), actor: actor)
    }

    /// `actor` deleted the task (`removeTask`). It carries the task's origin and title: the task
    /// is gone by the time the candidate is read.
    func recordDeleted(taskID: Int, origin: TaskOrigin?, title: String?, by actor: ControlActor) {
        activeStuckEpisodeStartByTaskID.removeValue(forKey: taskID)
        appendCandidate(
            taskID: taskID,
            kind: .deleted,
            rowStamp: MonotonicClock.shared.now(),
            origin: origin,
            title: title,
            actor: actor
        )
    }

    func recordStuckTasks(_ stuckTaskIDs: Set<Int>, now: Date = MonotonicClock.shared.now()) {
        guard isArmed else { return }
        for existingID in Array(activeStuckEpisodeStartByTaskID.keys) where !stuckTaskIDs.contains(existingID) {
            activeStuckEpisodeStartByTaskID.removeValue(forKey: existingID)
        }
        for taskID in stuckTaskIDs.sorted() {
            let episodeStart = activeStuckEpisodeStartByTaskID[taskID] ?? now
            activeStuckEpisodeStartByTaskID[taskID] = episodeStart
            appendCandidate(taskID: taskID, kind: .stuck, rowStamp: episodeStart)
        }
    }

    func recordIterationLimitPause(taskID: Int) {
        appendCandidate(
            taskID: taskID,
            kind: .paused,
            rowStamp: MonotonicClock.shared.now()
        )
    }

    func handleReadinessWake(_ reason: ExternalAutovisorWakeReason) {
        switch reason {
        case .folderChanged:
            wakeAllWaiters(with: .interrupted(.folderChanged))
        case .driverChanged:
            wakeAllWaiters(with: .interrupted(.driverChanged))
        case .autovisorDisabled:
            wakeAllWaiters(with: .interrupted(.notReady))
        case .shuttingDown:
            isShuttingDown = true
            wakeAllWaiters(with: .interrupted(.shuttingDown))
        case .readinessChanged:
            // The same reading a wait begun in that state gets at once — until 2026-11-09 this
            // told a folder transition `not_ready` and the immediate stop told it `folder_changed`.
            if let store, let stop = AutovisorWaitStopReason.immediate(for: store.externalAutovisorReadiness.state) {
                wakeAllWaiters(with: .interrupted(stop))
            }
        }
    }

    private func appendCandidate(
        taskID: Int,
        kind: AutovisorEventKind,
        rowStamp: Date,
        origin: TaskOrigin? = nil,
        title: String? = nil,
        actor: ControlActor? = nil
    ) {
        guard isArmed else { return }
        headSeq &+= 1
        let candidate = Candidate(
            seq: headSeq,
            taskID: taskID,
            kind: kind,
            rowStamp: rowStamp,
            origin: origin,
            title: title,
            actor: actor
        )
        ring.append(candidate)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        wakeAllWaiters(with: .candidateArrived)
    }

    // MARK: - Waiting & Delivery

    func waitForEvents(
        agentID: UUID,
        sessionID: String? = nil,
        after: String? = nil,
        taskIDs: Set<Int>? = nil,
        timeoutSeconds: TimeInterval = 50
    ) async -> AutovisorWaitResult {
        let startedAt = Date()
        func elapsed() -> Double { max(0, Date().timeIntervalSince(startedAt)) }

        if isShuttingDown {
            return AutovisorWaitResult(waitedSeconds: elapsed(), stopReason: .shuttingDown)
        }
        guard isArmed, let initialFolderID = folderID, let store else {
            return AutovisorWaitResult(waitedSeconds: elapsed(), stopReason: .notReady)
        }
        let initialEpoch = epochToken
        // The state this wait answers for, compared with the current state after every wake
        // (§9). A wake reaches only the bridges registered at that moment, and a waiter that a
        // candidate woke stays unregistered until its continuation runs: a folder switch, a lost
        // readiness or the app quitting in that gap reaches it as one more candidate, or not at
        // all. That gap is the common case, not a race — `apply` appends candidates for lagging
        // rows just before the readiness signal fires.
        let initialLifecycle = store.currentFolderLifecycle
        let initialSettings = store.snapshot?.workFolder.settings
        let initialDriver = initialSettings?.autovisorDriver ?? .builtInModel
        let initialEnabled = initialSettings?.autovisorEnabled ?? false

        func stopSinceEntry() -> AutovisorWaitStopReason? {
            if isShuttingDown { return .shuttingDown }
            if !isArmed || folderID != initialFolderID || !store.isCurrentFolderLifecycle(initialLifecycle) {
                return .folderChanged
            }
            let settings = store.snapshot?.workFolder.settings
            if (settings?.autovisorDriver ?? .builtInModel) != initialDriver { return .driverChanged }
            if initialEnabled && settings?.autovisorEnabled != true { return .notReady }
            return nil
        }

        // Every cursor this call returns carries its `task_ids`: its scan skips the candidates of
        // the agent's other tasks, so its position holds only for these (`formatCursor`).
        func cursor(at seq: Int) -> String {
            Self.formatCursor(folderID: initialFolderID, epoch: initialEpoch, seq: seq, taskIDs: taskIDs)
        }
        func headCursor() -> String? {
            guard isArmed, let folderID else { return nil }
            return Self.formatCursor(folderID: folderID, epoch: epochToken, seq: headSeq, taskIDs: taskIDs)
        }

        // 1. Classify cursor (`after`).
        var scanSeq = headSeq
        if let after, !after.isEmpty {
            let minSeq = ring.first?.seq
            var resetReason: AutovisorCursorResetReason?
            if let parsed = Self.parseCursor(after) {
                if parsed.folderID != initialFolderID {
                    resetReason = .folderChanged
                } else if parsed.epoch != initialEpoch {
                    resetReason = .restarted
                } else if (minSeq != nil && parsed.seq + 1 < minSeq!) || parsed.seq > headSeq {
                    resetReason = .gap
                } else if let watched = parsed.taskIDs, !(taskIDs.map { $0.isSubset(of: watched) } ?? false) {
                    // The cursor's call watched only `watched` and skipped the rest, so a call
                    // that watches a task outside it would never see that task's candidates up
                    // to here. Narrowing loses nothing; a cursor without a filter skipped no task.
                    resetReason = .filterChanged
                } else {
                    scanSeq = parsed.seq
                }
            } else {
                resetReason = .restarted
            }
            if let resetReason {
                let snapshot = buildSnapshot(for: agentID, taskIDs: taskIDs, store: store)
                return AutovisorWaitResult(
                    events: snapshot,
                    cursor: headCursor(),
                    waitedSeconds: elapsed(),
                    timedOut: false,
                    cursorResetReason: resetReason
                )
            }
        } else {
            // No cursor passed: synthesize snapshot of current standing conditions.
            let snapshot = buildSnapshot(for: agentID, taskIDs: taskIDs, store: store)
            if !snapshot.isEmpty || timeoutSeconds <= 0 {
                return AutovisorWaitResult(
                    events: snapshot,
                    cursor: headCursor(),
                    waitedSeconds: elapsed(),
                    timedOut: false,
                    cursorResetReason: nil
                )
            }
        }

        let clampedTimeout = max(0, min(TimeInterval(HostedMCPConstants.maxWaitSeconds), timeoutSeconds))
        let deadline = startedAt.addingTimeInterval(clampedTimeout)
        let scope: AutovisorWaitConcurrencyScope = if let sessionID, !sessionID.isEmpty {
            .legacySession(agentID: agentID, sessionID: sessionID)
        } else {
            .modernAgent(agentID: agentID)
        }
        let callID = UUID()
        nextWaiterRegistrationSeq &+= 1
        let registrationSeq = nextWaiterRegistrationSeq

        // A stopped wait hands back the position it scanned, never the head, so a candidate that
        // landed with the stop reaches the next call (`AutovisorWaitResult.stopped`).
        func stopped(_ reason: AutovisorWaitStopReason) -> AutovisorWaitResult {
            AutovisorWaitResult.stopped(reason, keeping: cursor(at: scanSeq), waitedSeconds: elapsed())
        }

        // In progress from here to whichever return ends the loop (`hasWaitInProgress`). The agent's
        // presence turns on this count, so the end of its last wait moves the revision the panes
        // re-read presence on: it may come after a wake or `cancelWaiters` has already emptied the
        // registry, and then nothing else says the agent stopped waiting. The start needs no bump
        // of its own — a wait that suspends parks on a bridge first, and registering one bumps.
        let inProgress = WaitInProgressKey(folderID: initialFolderID, agentID: agentID)
        waitsInProgress[inProgress, default: 0] += 1
        defer {
            // The count a wait leaves behind is the count it found less one; the LAST wait of this
            // agent in this folder removes the key and is the one whose end moves presence.
            if let count = waitsInProgress[inProgress], count > 1 {
                waitsInProgress[inProgress] = count - 1
            } else {
                waitsInProgress[inProgress] = nil
                store.hostedMCPAgentsRevision &+= 1
            }
        }

        var deadlineReached = false
        while true {
            if let reason = stopSinceEntry() { return stopped(reason) }
            let hasRingGap = ring.first.map { scanSeq + 1 < $0.seq } ?? false
            if epochToken != initialEpoch || hasRingGap {
                let snapshot = buildSnapshot(for: agentID, taskIDs: taskIDs, store: store)
                return AutovisorWaitResult(
                    events: snapshot,
                    cursor: headCursor(),
                    waitedSeconds: elapsed(),
                    timedOut: false,
                    cursorResetReason: epochToken != initialEpoch ? .restarted : .gap
                )
            }

            if headSeq > scanSeq {
                let targetHead = headSeq
                let slice = candidatesSlice(after: scanSeq, upTo: targetHead)
                scanSeq = targetHead
                let delivered = collectValidatedEvents(
                    from: slice,
                    agentID: agentID,
                    taskIDs: taskIDs,
                    store: store
                )
                if !delivered.isEmpty {
                    return AutovisorWaitResult(
                        events: delivered,
                        cursor: cursor(at: scanSeq),
                        waitedSeconds: elapsed(),
                        timedOut: false
                    )
                }
            }

            if Task.isCancelled {
                return AutovisorWaitResult(
                    events: [],
                    cursor: cursor(at: headSeq),
                    waitedSeconds: elapsed(),
                    timedOut: false
                )
            }

            let remaining = deadline.timeIntervalSinceNow
            if clampedTimeout <= 0 || deadlineReached || remaining <= 0 {
                return AutovisorWaitResult(
                    events: [],
                    cursor: cursor(at: scanSeq),
                    waitedSeconds: elapsed(),
                    timedOut: clampedTimeout > 0
                )
            }

            let bridgeID = UUID()
            let bridge = ApprovalWaiter<WaitResolution>()
            let waiter = ActiveWaiter(
                bridgeID: bridgeID,
                callID: callID,
                registrationSeq: registrationSeq,
                scope: scope,
                agentID: agentID,
                bridge: bridge
            )
            registerActiveWaiter(waiter)

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                bridge.resolve(.timedOut)
            }
            defer {
                timeoutTask.cancel()
                removeActiveWaiter(scope: scope, bridgeID: bridgeID)
            }

            let resolution = await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<WaitResolution, Never>) in
                    bridge.attach(cont)
                }
            } onCancel: {
                bridge.resolve(.cancelled)
            }

            timeoutTask.cancel()
            removeActiveWaiter(scope: scope, bridgeID: bridgeID)

            switch resolution {
            case .superseded:
                return AutovisorWaitResult(
                    events: [],
                    cursor: headCursor(),
                    waitedSeconds: elapsed(),
                    timedOut: false,
                    superseded: true,
                    stopReason: .superseded
                )
            case .interrupted(let reason):
                return stopped(reason)
            case .cancelled:
                return AutovisorWaitResult(
                    events: [],
                    cursor: cursor(at: headSeq),
                    waitedSeconds: elapsed(),
                    timedOut: false
                )
            case .timedOut:
                // Reported from the loop's top, after the same checks as any other wake: the
                // state may have moved with no wake left to say so, and a candidate may have
                // landed after the timer resolved the bridge.
                deadlineReached = true
                continue
            case .candidateArrived:
                continue
            }
        }
    }

    // MARK: - Ring Slicing & Waiter Registry

    private func candidatesSlice(after scanSeq: Int, upTo targetHead: Int) -> ArraySlice<Candidate> {
        guard let firstSeq = ring.first?.seq, targetHead >= firstSeq else { return [] }
        let startOffset = max(0, (scanSeq + 1) - firstSeq)
        let endOffset = min(ring.count, (targetHead - firstSeq) + 1)
        guard startOffset < endOffset else { return [] }
        return ring[startOffset..<endOffset]
    }

    private func registerActiveWaiter(_ waiter: ActiveWaiter) {
        var bucket = activeWaitersByScope[waiter.scope] ?? []
        let overflowCount = (bucket.count + 1) - waiter.scope.maxConcurrentWaits
        if overflowCount > 0 {
            let countToEvict = min(overflowCount, bucket.count)
            for idx in 0..<countToEvict {
                bucket[idx].bridge.resolve(.superseded)
            }
            bucket.removeFirst(countToEvict)
            waiterCount = max(0, waiterCount - countToEvict)
        }
        bucket.append(waiter)
        activeWaitersByScope[waiter.scope] = bucket
        waiterCount += 1
        store?.hostedMCPAgentsRevision &+= 1
    }

    private func removeActiveWaiter(scope: AutovisorWaitConcurrencyScope, bridgeID: UUID) {
        guard let bucket = activeWaitersByScope[scope] else { return }
        var retained: [ActiveWaiter] = []
        var removed = 0
        for entry in bucket {
            if entry.bridgeID == bridgeID { removed += 1 } else { retained.append(entry) }
        }
        guard removed > 0 else { return }
        waiterCount = max(0, waiterCount - removed)
        activeWaitersByScope[scope] = retained.isEmpty ? nil : retained
        store?.hostedMCPAgentsRevision &+= 1
    }

    /// Immediately wakes and cancels all active `wait_for_events` calls for `agentID`
    /// when the agent's token is rotated or revoked (§6).
    func cancelWaiters(forAgentID agentID: UUID) {
        deliveredIdentitiesByAgent.removeValue(forKey: agentID)
        var toWake: [ActiveWaiter] = []
        for (scope, bucket) in activeWaitersByScope where bucket.first?.agentID == agentID {
            toWake.append(contentsOf: bucket)
            activeWaitersByScope.removeValue(forKey: scope)
        }
        guard !toWake.isEmpty else { return }
        waiterCount = max(0, waiterCount - toWake.count)
        store?.hostedMCPAgentsRevision &+= 1
        for waiter in toWake {
            waiter.bridge.resolve(.cancelled)
        }
    }

    private func wakeAllWaiters(with resolution: WaitResolution) {
        guard !activeWaitersByScope.isEmpty else { return }
        let buckets = activeWaitersByScope.values
        activeWaitersByScope.removeAll()
        waiterCount = 0
        store?.hostedMCPAgentsRevision &+= 1
        for bucket in buckets {
            for waiter in bucket {
                waiter.bridge.resolve(resolution)
            }
        }
    }

    // MARK: - Snapshot & Candidate Validation

    private func recordDeliveredIfNew(agentID: UUID, identity: InstanceIdentity) -> Bool {
        var set = deliveredIdentitiesByAgent[agentID] ?? BoundedIdentitySet(capacity: deliveredIdentityCap)
        let inserted = set.insertIfNew(identity)
        deliveredIdentitiesByAgent[agentID] = set
        return inserted
    }

    /// The events of `instances` this agent has not been told yet, each recorded as told.
    private func deliverNew(_ instances: [StandingInstance], to agentID: UUID) -> [AutovisorEvent] {
        var events: [AutovisorEvent] = []
        for instance in instances where recordDeliveredIfNew(agentID: agentID, identity: instance.identity) {
            events.append(instance.event)
        }
        return events
    }

    /// The agent that created a task, or `nil` for one the person or the built-in manager did.
    private func owningAgentID(of origin: TaskOrigin?) -> UUID? {
        guard case .externalAgent(let identity) = origin else { return nil }
        return identity.id
    }

    private func taskBelongsToAgent(_ origin: TaskOrigin?, agentID: UUID) -> Bool {
        owningAgentID(of: origin) == agentID
    }

    private func readHydratedTask(_ taskID: Int, from store: NTMSOrchestrator) -> NTMSTask? {
        if let loaded = store.loadedTask(taskID) {
            return loaded
        }
        _ = store.ensureTaskLoadedSync(taskID)
        return store.loadedTask(taskID)
    }

    // MARK: - Standing conditions — one reading for the snapshot and the auto-off banner

    /// The kinds a task can carry as a condition that STANDS, in the order a snapshot reports them.
    private static let standingKinds = AutovisorEventKind.Standing.allCases

    /// Whether a condition of `kind` stands by `summary` — asked of a task's index row before the
    /// task is hydrated (`tasksWithStandingConditions`) and of the hydrated task's own summary after
    /// (`standingInstances`): one definition of each level, for both.
    private func levelHolds(_ kind: AutovisorEventKind.Standing, for summary: TaskSummary, store: NTMSOrchestrator) -> Bool {
        switch kind {
        case .question:
            return NTMSOrchestrator.summaryAwaitsSupervisor(summary, engineState: store.taskEngineStates[summary.id])
        case .acceptanceGate:
            return NTMSOrchestrator.AutovisorAttentionTrigger.acceptanceGate.levelHolds(for: summary)
        case .review:
            return NTMSOrchestrator.AutovisorAttentionTrigger.completed.levelHolds(for: summary)
        case .failed:
            return NTMSOrchestrator.AutovisorAttentionTrigger.failed.levelHolds(for: summary)
        case .paused:
            if store.taskEngines[summary.id]?.pausedIterationLimit != nil { return true }
            guard summary.status == .paused else { return false }
            if summary.hasRoleAtAcceptanceGate {
                return (readHydratedTask(summary.id, from: store).flatMap { store.autovisorPauseReason(of: $0) }) != nil
            }
            return true
        case .stuck:
            return activeStuckEpisodeStartByTaskID[summary.id] != nil
        }
    }

    /// The tasks whose standing conditions are read: top-level, not the built-in manager's, created
    /// by an agent `isOwner` accepts, narrowed to `taskIDs` when the call named some, open, and on
    /// a row where a condition of a kind `wanted` accepts may stand — hydrated, since each
    /// condition is read off the task itself. A row that does not name its origin is hydrated to
    /// learn it. A closed task waits on nobody, whatever its last run left behind: one with a
    /// failed step derives `failed` (`NTMSTask.derivedStatusFromActiveRun`).
    private func tasksWithStandingConditions(
        ownedBy isOwner: (UUID) -> Bool,
        taskIDs: Set<Int>?,
        ofKind wanted: (AutovisorEventKind.Standing) -> Bool,
        store: NTMSOrchestrator
    ) -> [NTMSTask] {
        guard let summaries = store.snapshot?.tasksIndex.tasks else { return [] }
        let managerID = store.autovisorTaskID
        var tasks: [NTMSTask] = []
        for summary in summaries where summary.parentTaskID == nil && summary.id != managerID {
            if let taskIDs, !taskIDs.contains(summary.id) { continue }
            if let rowOrigin = summary.origin, owningAgentID(of: rowOrigin).map(isOwner) != true { continue }
            guard Self.standingKinds.contains(where: { wanted($0) && levelHolds($0, for: summary, store: store) }),
                  let task = readHydratedTask(summary.id, from: store),
                  task.parentTaskID == nil,
                  task.closedAt == nil,
                  owningAgentID(of: task.origin).map(isOwner) == true
            else { continue }
            tasks.append(task)
        }
        return tasks
    }

    /// The conditions standing on `task` now, of the kinds `wanted` accepts, in the order a
    /// snapshot reports them — what a snapshot delivers (`buildSnapshot`) and what the auto-off
    /// banner counts (`hasConditionAwaitingAnAgent`). Each kind asks its level of the task's own
    /// summary, then its builder whether there is anything to tell.
    private func standingInstances(
        on task: NTMSTask,
        seq: Int?,
        ofKind wanted: (AutovisorEventKind.Standing) -> Bool,
        store: NTMSOrchestrator
    ) -> [StandingInstance] {
        let liveSummary = task.toSummary()
        var instances: [StandingInstance] = []
        for kind in Self.standingKinds where wanted(kind) && levelHolds(kind, for: liveSummary, store: store) {
            instances.append(contentsOf: standing(kind, seq: seq, task: task, store: store))
        }
        return instances
    }

    /// The instances of `kind` on `task`, each builder under its own guard — an answerable step, a
    /// role at the gate, a run, a stuck episode while the task runs — and whatever was delivered.
    /// A candidate's kind reaches here with no level asked first, as it always did. The moments
    /// are carried by a candidate, never read off a task — and not `Standing`, so they cannot be
    /// asked for here.
    private func standing(
        _ kind: AutovisorEventKind.Standing,
        seq: Int?,
        task: NTMSTask,
        store: NTMSOrchestrator
    ) -> [StandingInstance] {
        switch kind {
        case .question: standingQuestions(seq: seq, task: task)
        case .acceptanceGate: standingAcceptanceGates(seq: seq, task: task)
        case .review: standingReview(seq: seq, task: task)
        case .failed: standingFailure(seq: seq, task: task)
        case .paused: standingPause(seq: seq, task: task, store: store)
        case .stuck: standingStall(seq: seq, task: task, store: store)
        }
    }

    /// Whether a condition stands on some external agent's task that waits on that agent to act —
    /// the auto-off banner's "while tasks still needed it" under the external driver
    /// (`NTMSOrchestrator.autovisorHasUnresolvedAttention`). Read through the snapshot's own
    /// selection and conditions, so what the person is told the agent was still needed for and
    /// what `wait_for_events` tells the agent stand on one definition; what was already delivered
    /// does not matter — a question the agent was told and has not answered still waits on it.
    /// Until 2026-11-08 the banner kept its own list of what asks something of the agent, with no
    /// pause in it, though the feed wakes the agent for every pause and three of the four reasons
    /// are the agent's to resume.
    func hasConditionAwaitingAnAgent() -> Bool {
        guard isArmed, let store else { return false }
        let mayAwait: (AutovisorEventKind.Standing) -> Bool = { $0.kind.mayAwaitItsAgent }
        let tasks = tasksWithStandingConditions(ownedBy: { _ in true }, taskIDs: nil, ofKind: mayAwait, store: store)
        return tasks.contains { task in
            standingInstances(on: task, seq: headSeq, ofKind: mayAwait, store: store)
                .contains { $0.event.awaitsItsAgent }
        }
    }

    private func buildSnapshot(
        for agentID: UUID,
        taskIDs: Set<Int>?,
        store: NTMSOrchestrator
    ) -> [AutovisorEvent] {
        deliveredIdentitiesByAgent[agentID] = BoundedIdentitySet(capacity: deliveredIdentityCap)
        let everyKind: (AutovisorEventKind.Standing) -> Bool = { _ in true }
        var events: [AutovisorEvent] = []
        let tasks = tasksWithStandingConditions(
            ownedBy: { $0 == agentID }, taskIDs: taskIDs, ofKind: everyKind, store: store)
        for task in tasks {
            // A snapshot reports what stands, the agent's own pause included, and at no place in
            // the feed — its events carry no `seq`.
            events.append(contentsOf: deliverNew(
                standingInstances(on: task, seq: nil, ofKind: everyKind, store: store),
                to: agentID
            ))
        }
        return events
    }

    /// A task and one of the kinds that stand on it — what `collectValidatedEvents` reads once per
    /// slice.
    private struct StandingSlot: Hashable {
        let taskID: Int
        let kind: AutovisorEventKind.Standing
    }

    /// The events `candidates` tell, in their order — every moment, and of the standing candidates
    /// only the LAST of each task and kind.
    ///
    /// A standing candidate is read here, at the wait, not when it was appended: it tells what
    /// stands NOW (`standing`), and every candidate of one task and kind in the slice reads the
    /// same instances. Read at the first one, a condition that stands now took a place before
    /// moments it came after. On 2026-11-12 (task 21) the person's Resume and then their Pause
    /// reached the agent as `paused(by_person)` at seq 5 and `resumed` at seq 6 — the last event
    /// said the task ran while it stood paused: seq 5 was the Resume's own write, the run's steps
    /// still parked, and it was read as the Pause that came after; the Pause's own candidate, seq
    /// 7, told nothing new. A condition that stands began with a row edge that appended a
    /// candidate of its kind (`handleRowUpdated`, `recordIterationLimitPause`,
    /// `recordStuckTasks`), so the last one of its kind is never before its start, and a moment
    /// after that candidate came after the condition began.
    private func collectValidatedEvents(
        from candidates: ArraySlice<Candidate>,
        agentID: UUID,
        taskIDs: Set<Int>?,
        store: NTMSOrchestrator
    ) -> [AutovisorEvent] {
        var lastStandingSeq: [StandingSlot: Int] = [:]
        for candidate in candidates {
            guard case .standing(let kind) = candidate.kind.shape else { continue }
            lastStandingSeq[StandingSlot(taskID: candidate.taskID, kind: kind)] = candidate.seq
        }
        var events: [AutovisorEvent] = []
        for candidate in candidates {
            if let taskIDs, !taskIDs.contains(candidate.taskID) { continue }
            if case .standing(let kind) = candidate.kind.shape,
               lastStandingSeq[StandingSlot(taskID: candidate.taskID, kind: kind)] != candidate.seq {
                continue
            }
            let materialized = validateAndMaterialize(
                candidate: candidate,
                agentID: agentID,
                store: store
            )
            events.append(contentsOf: materialized)
        }
        return events
    }

    private func loadHydratedAgentTask(
        taskID: Int,
        agentID: UUID,
        store: NTMSOrchestrator
    ) -> NTMSTask? {
        if let row = store.taskFacts.summary(for: taskID) {
            if row.parentTaskID != nil { return nil }
            if let rowOrigin = row.origin, !taskBelongsToAgent(rowOrigin, agentID: agentID) {
                return nil
            }
        }
        guard let task = readHydratedTask(taskID, from: store),
              task.parentTaskID == nil,
              taskBelongsToAgent(task.origin, agentID: agentID)
        else { return nil }
        return task
    }

    private func validateAndMaterialize(
        candidate: Candidate,
        agentID: UUID,
        store: NTMSOrchestrator
    ) -> [AutovisorEvent] {
        switch candidate.kind.shape {
        case .moment(let moment):
            // An echo: the agent did this itself and has the result from its own call.
            if candidate.actor?.isExternalAgent(agentID) == true { return [] }
            return materializeMoment(moment, candidate: candidate, agentID: agentID, store: store)

        case .standing(let kind):
            guard let task = loadHydratedAgentTask(taskID: candidate.taskID, agentID: agentID, store: store),
                  task.closedAt == nil
            else { return [] }
            var instances = standing(kind, seq: candidate.seq, task: task, store: store)
            // The agent's own Pause is an echo too: only a task's own agent can ask for one, and
            // it has the result from its call. A snapshot still reports it — it stands.
            instances.removeAll { $0.event.pauseReason == .byAgent }
            return deliverNew(instances, to: agentID)
        }
    }

    /// The event a moment's candidate tells, once: who caused it, on a task that still belongs to
    /// the agent and still shows it — a deleted task still gone, a closed one still closed.
    private func materializeMoment(
        _ moment: AutovisorEventKind.Moment,
        candidate: Candidate,
        agentID: UUID,
        store: NTMSOrchestrator
    ) -> [AutovisorEvent] {
        switch moment {
        case .deleted:
            guard taskBelongsToAgent(candidate.origin, agentID: agentID),
                  store.taskFacts.summary(for: candidate.taskID) == nil,
                  recordDeliveredIfNew(agentID: agentID, identity: .deleted(taskID: candidate.taskID))
            else { return [] }
            return [AutovisorEvent(
                seq: candidate.seq,
                taskID: candidate.taskID,
                kind: .deleted,
                title: candidate.title ?? "#\(candidate.taskID)",
                origin: candidate.origin,
                by: candidate.actor
            )]

        case .closed:
            guard let task = loadHydratedAgentTask(taskID: candidate.taskID, agentID: agentID, store: store),
                  let closedAt = task.closedAt,
                  recordDeliveredIfNew(agentID: agentID, identity: .closed(taskID: task.id, closedAt: closedAt))
            else { return [] }
            return [AutovisorEvent(seq: candidate.seq, taskID: task.id, kind: .closed, title: task.title, by: candidate.actor)]

        case .resumed:
            guard let task = loadHydratedAgentTask(taskID: candidate.taskID, agentID: agentID, store: store),
                  task.closedAt == nil,
                  recordDeliveredIfNew(agentID: agentID, identity: .resumed(taskID: task.id, at: candidate.rowStamp))
            else { return [] }
            return [AutovisorEvent(seq: candidate.seq, taskID: task.id, kind: .resumed, title: task.title, by: candidate.actor)]
        }
    }

    private func standingQuestions(seq: Int?, task: NTMSTask) -> [StandingInstance] {
        task.answerableSupervisorSteps.map { step in
            StandingInstance(
                identity: .question(
                    taskID: task.id,
                    stepID: step.effectiveRoleID,
                    callID: step.activeSupervisorQuestionID,
                    inquiryQuestionIDs: step.supervisorInquiry?.questions.map(\.id) ?? [],
                    questionText: step.supervisorQuestion ?? "",
                    stepUpdatedAt: step.updatedAt
                ),
                event: AutovisorEvent(
                    seq: seq,
                    taskID: task.id,
                    kind: .question,
                    title: task.title,
                    roleID: step.effectiveRoleID,
                    question: step.formattedSupervisorQuestion ?? step.supervisorQuestion
                )
            )
        }
    }

    private func standingAcceptanceGates(seq: Int?, task: NTMSTask) -> [StandingInstance] {
        let summary = task.toSummary()
        guard NTMSOrchestrator.AutovisorAttentionTrigger.acceptanceGate.levelHolds(for: summary),
              let run = task.runs.last
        else { return [] }
        var seenRoles: Set<String> = []
        var out: [StandingInstance] = []
        var completedAtByRoleID: [String: Date] = [:]
        var candidateRoleIDs: [String] = []
        for step in run.steps {
            let roleID = step.effectiveRoleID
            candidateRoleIDs.append(roleID)
            if completedAtByRoleID[roleID] == nil { completedAtByRoleID[roleID] = step.completedAt }
        }
        candidateRoleIDs.append(contentsOf: run.roleStatuses.keys)
        for roleID in candidateRoleIDs {
            guard seenRoles.insert(roleID).inserted,
                  run.roleStatuses[roleID] == .needsAcceptance
            else { continue }
            out.append(StandingInstance(
                identity: .acceptanceGate(
                    taskID: task.id,
                    runID: run.id,
                    roleID: roleID,
                    stepCompletedAt: completedAtByRoleID[roleID]
                ),
                event: AutovisorEvent(
                    seq: seq,
                    taskID: task.id,
                    kind: .acceptanceGate,
                    title: task.title,
                    roleID: roleID
                )
            ))
        }
        return out
    }

    private func standingReview(seq: Int?, task: NTMSTask) -> [StandingInstance] {
        let summary = task.toSummary()
        guard NTMSOrchestrator.AutovisorAttentionTrigger.completed.levelHolds(for: summary),
              let run = task.runs.last
        else { return [] }
        let latestStepCompletedAt = run.steps.compactMap(\.completedAt).max()
        let roundSummary = RoundSummaryDTO.build(for: run)
        return [StandingInstance(
            identity: .review(taskID: task.id, runID: run.id, latestStepCompletedAt: latestStepCompletedAt),
            event: AutovisorEvent(seq: seq, taskID: task.id, kind: .review, title: task.title, roundSummary: roundSummary)
        )]
    }

    private func standingFailure(seq: Int?, task: NTMSTask) -> [StandingInstance] {
        let summary = task.toSummary()
        guard NTMSOrchestrator.AutovisorAttentionTrigger.failed.levelHolds(for: summary),
              let run = task.runs.last
        else { return [] }
        var failedStep: StepExecution?
        var failStamp = run.updatedAt
        var hasStepStamp = false
        for step in run.steps where step.status == .failed {
            failedStep = step
            let stamp = step.completedAt ?? step.updatedAt
            if !hasStepStamp || stamp >= failStamp {
                failStamp = stamp
                hasStepStamp = true
            }
        }
        var errText: String?
        if let messages = failedStep?.messages {
            for msg in messages.reversed() where msg.content.hasPrefix(StepExecution.llmErrorNotePrefix) {
                errText = msg.content
                break
            }
        }
        return [StandingInstance(
            identity: .failed(taskID: task.id, runID: run.id, stamp: failStamp),
            event: AutovisorEvent(
                seq: seq,
                taskID: task.id,
                kind: .failed,
                title: task.title,
                roleID: failedStep?.effectiveRoleID,
                errorMessage: errText
            )
        )]
    }

    private func standingPause(seq: Int?, task: NTMSTask, store: NTMSOrchestrator) -> [StandingInstance] {
        let summary = task.toSummary()
        let liveIterationLimitPause = store.taskEngines[task.id]?.pausedIterationLimit != nil
        guard summary.status == .paused || liveIterationLimitPause else { return [] }
        let run = task.runs.last
        // The rule itself lives on `AutovisorPauseReason`, read through the store so `task_status`
        // answers identically.
        guard let reason = store.autovisorPauseReason(of: task) else { return [] }
        let runID = run.map(\.id) ?? -1
        // The pause's stamp. For the pause a timeout caused, the timeout's moment: steady while
        // that pause stands, whatever is written meanwhile. Otherwise the newest paused step,
        // which a write to the run alone — `manage_role accept` on another role — leaves as it
        // is. The run and the task stand in only for a pause with no paused step.
        var latestPausedStepStamp: Date?
        for step in run?.steps ?? [] where step.status == .paused {
            if latestPausedStepStamp.map({ step.updatedAt > $0 }) ?? true {
                latestPausedStepStamp = step.updatedAt
            }
        }
        var pauseStamp = latestPausedStepStamp ?? run?.updatedAt ?? task.updatedAt
        if reason == .timedOut, let timedOutAt = run?.timedOutAt {
            pauseStamp = timedOutAt
        }
        return [StandingInstance(
            identity: .paused(taskID: task.id, runID: runID, reason: reason, stamp: pauseStamp),
            event: AutovisorEvent(seq: seq, taskID: task.id, kind: .paused, title: task.title, pauseReason: reason)
        )]
    }

    private func standingStall(seq: Int?, task: NTMSTask, store: NTMSOrchestrator) -> [StandingInstance] {
        guard let episodeStart = activeStuckEpisodeStartByTaskID[task.id],
              store.taskEngineStates[task.id] == .running || task.toSummary().status == .running
        else { return [] }
        return [StandingInstance(
            identity: .stuck(taskID: task.id, episodeStart: episodeStart),
            event: AutovisorEvent(seq: seq, taskID: task.id, kind: .stuck, title: task.title)
        )]
    }
}
