import Foundation

/// Aggregates prompt-prefix cache misses for the UI, and decides which of them earn a banner.
///
/// Two surfaces, because one is not enough:
///
/// - **The count** is the always-on surface. The banner slot is a single coalescing slot with a
///   4 s auto-dismiss shared by ~140 writers, so a recurring signal cannot live there — a second
///   write inside the window silently replaces the first. A count, by contrast, is idempotent
///   under repetition: 47 misses render as `×47` with no windowing algorithm needed.
/// - **The banner** fires at most once per `(taskID, runID, causeClass)`, and only for the task
///   actually on screen.
///
/// `runID` alone would not do: `Run.id` is per-task sequential (`RunService`: `id: task.runs.count`),
/// so task A's run 0 and task B's run 0 collide — one `Int` latch would both suppress B's first
/// miss and re-arm A's when any task starts a new run. The Autovisor makes that concrete: it
/// starts a fresh run on every wake, so a bare `runID` latch would banner once a minute forever.
///
/// `causeClass` rather than `Cause`: two rewrites at different message indices call for the same
/// action from the user, so they must not each earn a banner.
@MainActor
@Observable
final class PrefixCacheReporter {

    // MARK: - Aggregate (drives the status pill)

    private(set) var missCount = 0
    private(set) var discardedTokensTotal = 0
    private(set) var countsByCause: [PrefixCachePolicy.CauseClass: Int] = [:]
    /// Keyed by `LLMCallOwner.displayName` — a LABEL, not an identity. The status-pill popover
    /// renders this key verbatim as a row via `ForEach(id: \.0)`, so keying by the owner and
    /// mapping to a label at render time would let two owners collapse onto one row label and
    /// produce a duplicate `ForEach` ID (CLAUDE.md #22).
    private(set) var countsByOwner: [String: Int] = [:]

    /// Distinct suspects seen per cause class, so the popover can name a lead.
    ///
    /// `countsByCause` keys on `CauseClass`, which erases `Cause.serverDroppedCache`'s payload —
    /// that is correct for the banner-dedup job it was written for, and it is also why the popover
    /// row could never say anything beyond "Server dropped the cached prefix". Collected here
    /// instead of widening the dedup key, so two evictions still share one banner.
    ///
    /// A `Set`, not the last value: with several distinct suspects there IS no lead, and picking
    /// one would read as an accusation the data does not support.
    private(set) var suspectsByCause: [PrefixCachePolicy.CauseClass: Set<String>] = [:]

    /// Wall-clock the misses cost: measured where the server priced it, estimated otherwise.
    ///
    /// Accumulated per miss rather than derived from `discardedTokensTotal`, because the two
    /// summands are no longer the same kind of number — one miss can be measured and the next
    /// estimated, and a single token total cannot represent that.
    private(set) var estimatedSecondsLost: Double = 0

    // MARK: - On-screen routing

    /// The task the user is actually LOOKING at.
    ///
    /// Deliberately not `NTMSOrchestrator.activeTaskID`: that is "last task ever opened", it is
    /// never reset to nil, and opening the Autovisor pane calls `switchTask(to:)` — so a manager
    /// waking every 60 s would banner forever even while the user sits on the Watchtower. The UI
    /// sets this from its own navigation selection.
    var onScreenTaskID: Int?

    // MARK: - Banner latch

    private struct BannerKey: Hashable {
        let taskID: Int
        let runID: Int
        let causeClass: PrefixCachePolicy.CauseClass
    }

    private var bannerFired: Set<BannerKey> = []

    // MARK: - Reporting

    /// Record a miss. Returns the banner text when this one earns a banner, `nil` when it should
    /// only move the counter.
    @discardableResult
    func report(_ miss: PrefixCacheMiss) -> String? {
        missCount += 1
        discardedTokensTotal += miss.diagnosis.discardedTokens
        estimatedSecondsLost += miss.diagnosis.estimatedSeconds
        countsByCause[miss.diagnosis.cause.causeClass, default: 0] += 1
        countsByOwner[miss.owner.displayName, default: 0] += 1
        if case .serverDroppedCache(let suspect) = miss.diagnosis.cause,
            let suspect, !suspect.isEmpty
        {
            suspectsByCause[.serverDroppedCache, default: []].insert(
                LLMCallOwner.displayName(forKey: suspect))
        }

        guard let taskID = miss.taskID, let runID = miss.runID, taskID == onScreenTaskID
        else { return nil }

        let key = BannerKey(
            taskID: taskID, runID: runID, causeClass: miss.diagnosis.cause.causeClass)
        guard bannerFired.insert(key).inserted else { return nil }

        return PrefixCachePolicy.warningMessage(
            modelName: miss.modelName, diagnosis: miss.diagnosis)
    }

    /// Clear the counters for a fresh look at a run.
    ///
    /// Scoped to one task, never global: the Autovisor starts a run on every wake, and a global
    /// reset there would discard the counts of the user's own tasks on the manager's cadence.
    func resetCounters(forTaskID taskID: Int) {
        bannerFired = bannerFired.filter { $0.taskID != taskID }
        // The aggregate is a "since you last looked" figure for the whole app, so it is only
        // zeroed when the run the user is watching restarts.
        guard taskID == onScreenTaskID else { return }
        missCount = 0
        discardedTokensTotal = 0
        estimatedSecondsLost = 0
        countsByCause.removeAll()
        countsByOwner.removeAll()
        suspectsByCause.removeAll()
    }

    /// The lead to show beside a cause row, or `nil` when there is none to show.
    ///
    /// Exactly one distinct suspect is a lead. Zero is silence, and several is a scatter — naming
    /// one of them would be an accusation the aggregate cannot support.
    func suspectLead(for cause: PrefixCachePolicy.CauseClass) -> String? {
        guard let suspects = suspectsByCause[cause], suspects.count == 1 else { return nil }
        return suspects.first
    }

    #if DEBUG
    func _testBannerFiredCount() -> Int { bannerFired.count }
    #endif
}
