import Foundation

/// Tracks per-actor task creation budgets and synchronous in-flight slot reservations
/// across the built-in Autovisor manager and external agents.
nonisolated struct AutovisorCreationLedger: Sendable {
    struct Reservation: Hashable, Sendable {
        let id: UUID
        let actor: AutovisorActor
        let generation: UInt64
        /// The external agent's `request_key` for this creation, held in flight with the slot.
        var requestKey: String? = nil
    }

    enum RejectionReason: Error, Equatable, Sendable {
        case tooManyRunning(count: Int, limit: Int)
        case reviewCreationLimitReached(limit: Int)
        case tooManyOpenTasks(count: Int, limit: Int)
        case windowCreationLimitReached(limit: Int, windowMinutes: Int)
    }

    private(set) var generation: UInt64 = 0
    private(set) var builtInCreatedThisReview: Int = 0
    private var builtInInFlightReservations: Set<UUID> = []
    private var externalCreationTimestamps: [UUID: [Date]] = [:]
    private var externalInFlightReservations: [UUID: Set<UUID>] = [:]
    /// The `request_key`s of creations reserved and not yet committed or rolled back, per agent.
    /// A committed one is the task's own (`NTMSTask.requestKey`, on its index row too), which is
    /// what a retry finds afterwards; until the commit there is no task to find, and a retry
    /// that arrived then — a client that gave up waiting and called again — created a second.
    private var externalInFlightRequestKeys: [UUID: Set<String>] = [:]

    var builtInInFlightCount: Int {
        builtInInFlightReservations.count
    }

    /// Whether a creation with `requestKey` is under way for `agentID` — reserved, not yet
    /// committed or rolled back.
    func isRequestInFlight(_ requestKey: String, for agentID: UUID) -> Bool {
        externalInFlightRequestKeys[agentID]?.contains(requestKey) == true
    }

    /// The moments each agent's creations were committed — what `ExternalCreationWindowStore`
    /// keeps across a relaunch (F6 L4).
    var externalCreationStamps: [UUID: [Date]] { externalCreationTimestamps }

    /// Puts back the creations a previous process committed in this folder. Called once per open,
    /// after `resetForFolderTransition`; a stamp the ledger already holds is not doubled.
    mutating func restoreExternalCreations(_ stamps: [UUID: [Date]]) {
        for (agentID, dates) in stamps {
            let held = Set(externalCreationTimestamps[agentID] ?? [])
            let restored = dates.filter { !held.contains($0) }
            guard !restored.isEmpty else { continue }
            externalCreationTimestamps[agentID, default: []].append(contentsOf: restored)
            externalCreationTimestamps[agentID]?.sort()
        }
    }

    func externalWindowCount(
        for agentID: UUID,
        windowMinutes: Int,
        now: Date = MonotonicClock.shared.now()
    ) -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(max(1, windowMinutes) * 60))
        return (externalCreationTimestamps[agentID] ?? []).count { $0 >= cutoff }
    }

    /// When the sliding window next admits a creation for `agentID`: the moment the oldest
    /// creation inside it ages out. `nil` when the window holds none.
    func externalWindowReopensAt(
        for agentID: UUID,
        windowMinutes: Int,
        now: Date = MonotonicClock.shared.now()
    ) -> Date? {
        let window = TimeInterval(max(1, windowMinutes) * 60)
        let cutoff = now.addingTimeInterval(-window)
        var oldest: Date?
        for stamp in externalCreationTimestamps[agentID] ?? [] where stamp >= cutoff {
            oldest = min(oldest ?? stamp, stamp)
        }
        return oldest.map { $0.addingTimeInterval(window) }
    }

    mutating func setBuiltInCreatedThisReview(_ value: Int) {
        builtInCreatedThisReview = max(0, value)
    }

    mutating func resetBuiltInReview() {
        builtInCreatedThisReview = 0
        builtInInFlightReservations.removeAll()
    }

    mutating func resetForFolderTransition() {
        generation &+= 1
        builtInCreatedThisReview = 0
        builtInInFlightReservations.removeAll()
        externalCreationTimestamps.removeAll()
        externalInFlightReservations.removeAll()
        externalInFlightRequestKeys.removeAll()
    }

    mutating func tryReserveSlot(
        for actor: AutovisorActor,
        tuning: AutovisorTuning,
        runningCount: Int,
        openExternalCount: Int = 0,
        requestKey: String? = nil,
        now: Date = MonotonicClock.shared.now()
    ) -> Result<Reservation, RejectionReason> {
        switch actor {
        case .builtInManager:
            let inFlight = builtInInFlightReservations.count
            let effectiveRunning = runningCount + inFlight
            if effectiveRunning >= tuning.maxConcurrentManagedTasks {
                return .failure(
                    .tooManyRunning(count: effectiveRunning, limit: tuning.maxConcurrentManagedTasks)
                )
            }
            let effectiveCreated = builtInCreatedThisReview + inFlight
            if effectiveCreated >= tuning.maxManagedTasksPerReview {
                return .failure(
                    .reviewCreationLimitReached(limit: tuning.maxManagedTasksPerReview)
                )
            }
            let reservation = Reservation(id: UUID(), actor: actor, generation: generation)
            builtInInFlightReservations.insert(reservation.id)
            return .success(reservation)

        case .externalAgent(let identity, _):
            let windowMinutes = max(1, tuning.externalCreationWindowMinutes)
            // Stamps are dropped past the RETENTION, not the window: they are what the store
            // keeps across a relaunch, and a window raised later must still find them.
            let retentionCutoff = now.addingTimeInterval(
                -TimeInterval(ExternalCreationWindowStore.retentionMinutes(forWindow: windowMinutes) * 60))
            if let existing = externalCreationTimestamps[identity.id] {
                let pruned = existing.filter { $0 >= retentionCutoff }
                if pruned.isEmpty {
                    externalCreationTimestamps.removeValue(forKey: identity.id)
                } else {
                    externalCreationTimestamps[identity.id] = pruned
                }
            }

            let inFlight = externalInFlightReservations[identity.id]?.count ?? 0
            let effectiveRunning = runningCount + inFlight
            if effectiveRunning >= tuning.maxConcurrentManagedTasks {
                return .failure(
                    .tooManyRunning(count: effectiveRunning, limit: tuning.maxConcurrentManagedTasks)
                )
            }

            let effectiveOpen = openExternalCount + inFlight
            if effectiveOpen >= tuning.maxOpenExternalTasks {
                return .failure(
                    .tooManyOpenTasks(count: effectiveOpen, limit: tuning.maxOpenExternalTasks)
                )
            }

            let committedInWindow = externalWindowCount(for: identity.id, windowMinutes: windowMinutes, now: now)
            let effectiveWindow = committedInWindow + inFlight
            if effectiveWindow >= tuning.maxExternalCreationsPerWindow {
                return .failure(
                    .windowCreationLimitReached(
                        limit: tuning.maxExternalCreationsPerWindow,
                        windowMinutes: windowMinutes
                    )
                )
            }

            let reservation = Reservation(id: UUID(), actor: actor, generation: generation, requestKey: requestKey)
            externalInFlightReservations[identity.id, default: []].insert(reservation.id)
            if let requestKey {
                externalInFlightRequestKeys[identity.id, default: []].insert(requestKey)
            }
            return .success(reservation)
        }
    }

    mutating func commit(_ reservation: Reservation, now: Date = MonotonicClock.shared.now()) {
        guard reservation.generation == generation else { return }
        switch reservation.actor {
        case .builtInManager:
            guard builtInInFlightReservations.remove(reservation.id) != nil else { return }
            builtInCreatedThisReview += 1
        case .externalAgent(let identity, _):
            guard externalInFlightReservations[identity.id]?.remove(reservation.id) != nil else { return }
            if externalInFlightReservations[identity.id]?.isEmpty == true {
                externalInFlightReservations.removeValue(forKey: identity.id)
            }
            releaseRequestKey(of: reservation, for: identity.id)
            externalCreationTimestamps[identity.id, default: []].append(now)
        }
    }

    mutating func rollback(_ reservation: Reservation) {
        guard reservation.generation == generation else { return }
        switch reservation.actor {
        case .builtInManager:
            builtInInFlightReservations.remove(reservation.id)
        case .externalAgent(let identity, _):
            externalInFlightReservations[identity.id]?.remove(reservation.id)
            if externalInFlightReservations[identity.id]?.isEmpty == true {
                externalInFlightReservations.removeValue(forKey: identity.id)
            }
            releaseRequestKey(of: reservation, for: identity.id)
        }
    }

    private mutating func releaseRequestKey(of reservation: Reservation, for agentID: UUID) {
        guard let requestKey = reservation.requestKey else { return }
        externalInFlightRequestKeys[agentID]?.remove(requestKey)
        if externalInFlightRequestKeys[agentID]?.isEmpty == true {
            externalInFlightRequestKeys.removeValue(forKey: agentID)
        }
    }
}
