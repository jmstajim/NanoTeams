@testable import NanoTeams

/// A `TeamEditCommitQueue.Folder` the test can hold: each write is recorded, then — while
/// `isHolding` — parked until the test releases it, so "the write is still in flight" is a state
/// a test can look at. Shared by the queue's own tests and the Role and Artifact Editors' Save
/// tests.
///
/// A folder in the other respects as well: a lifecycle the test ended (`endedLifecycles`) is no
/// longer current, `storedTeam` answers what a successful write stored — or what the test put in
/// `stored` — while the lifecycle asked about is current, and the reconcile a write leaves owed is
/// counted, and held while `isHoldingReconcile`.
@MainActor
final class HeldTeamWriter: TeamEditCommitQueue.Folder {
    struct Call {
        let team: Team
        let lifecycle: WorkFolderLifecycle
    }

    private(set) var calls: [Call] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    /// Answered in order; `.persisted` once used up.
    var outcomes: [WorkFolderMutationOutcome] = []
    var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// Lifecycles a later open has ended; every other one is current.
    var endedLifecycles: Set<WorkFolderLifecycle> = []
    /// What the folder stores, by team id — what `storedTeam` answers.
    var stored: [NTMSID: Team] = [:]
    /// Reconcile passes started.
    private(set) var reconcileCount = 0
    var isHoldingReconcile = false
    private var heldReconciles: [CheckedContinuation<Void, Never>] = []

    func writeEditedTeam(_ team: Team, editedIn lifecycle: WorkFolderLifecycle) async -> WorkFolderMutationOutcome {
        calls.append(Call(team: team, lifecycle: lifecycle))
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if isHolding {
            await withCheckedContinuation { held.append($0) }
        }
        inFlight -= 1
        let outcome = outcomes.isEmpty ? .persisted : outcomes.removeFirst()
        if outcome.failureReason == nil { stored[team.id] = team }
        return outcome
    }

    func isCurrentFolderLifecycle(_ lifecycle: WorkFolderLifecycle) -> Bool {
        !endedLifecycles.contains(lifecycle)
    }

    func storedTeam(_ teamID: NTMSID, editedIn lifecycle: WorkFolderLifecycle) -> Team? {
        isCurrentFolderLifecycle(lifecycle) ? stored[teamID] : nil
    }

    func reconcileAfterTeamWrites() async {
        reconcileCount += 1
        if isHoldingReconcile {
            await withCheckedContinuation { heldReconciles.append($0) }
        }
    }

    /// Every held pass, so a defect that runs two at once cannot leave one parked forever.
    func releaseReconcile() {
        isHoldingReconcile = false
        let parked = heldReconciles
        heldReconciles = []
        for continuation in parked { continuation.resume() }
    }

    func releaseOne() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func releaseAll() {
        isHolding = false
        let parked = held
        held = []
        for continuation in parked { continuation.resume() }
        releaseReconcile()
    }
}
