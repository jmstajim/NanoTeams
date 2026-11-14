import Foundation

/// One snapshot a lifecycle verb takes: the round it belongs to and the moment it records.
nonisolated struct TaskSnapshotRequest: Hashable, Sendable {
    let round: Int
    let phase: TaskSnapshotPhase
}

/// The ONE way a lifecycle verb takes the External Autovisor's filesystem snapshots (N2–N5 of the
/// F6 acceptance, 2026-11-12).
///
/// Until then each trigger called the service itself: a run's start waited at most 5 s and wrote
/// one run-wide reason, every other trigger dropped its failure (`_ = try?`), restart, revision
/// and close waited for full snapshots with no bound, and the start wrote its reason after the
/// wait without asking whether the folder was still the one it began in. Here every outcome is
/// recorded on the snapshot's ROUND (`Run.snapshotFailures`), the wait is bounded where a verb
/// waits, a snapshot that outlives the wait finishes in the background and rewrites its record,
/// and nothing is written after a folder transition.
extension NTMSOrchestrator {

    /// What one snapshot came to.
    nonisolated enum TaskSnapshotOutcome: Sendable, Equatable {
        case landed
        case failed(String)
    }

    /// Takes `requests` in order, as one sequence, for `runID` of `taskID` — when the task's
    /// snapshots are taken at all (`shouldCaptureTaskSnapshots`) and `lifecycle` is still the
    /// folder's. With `waitBudget`, returns once the sequence finished or the budget ran out,
    /// whichever is first; what is still running then is recorded `timed_out` and goes on in the
    /// background. With none, returns when the sequence finished. Returns whether it finished.
    @discardableResult
    func captureTaskSnapshots(
        _ requests: [TaskSnapshotRequest],
        taskID: Int,
        runID: Int,
        within lifecycle: WorkFolderLifecycle,
        waitBudget: Duration?
    ) async -> Bool {
        guard !requests.isEmpty,
              isCurrentFolderLifecycle(lifecycle),
              shouldCaptureTaskSnapshots(taskID: taskID),
              let folder = workFolderURL
        else { return true }
        let service = taskSnapshotService
        let progress = TaskSnapshotProgress(count: requests.count)
        // Asked by each snapshot before it sweeps or runs anything in the folder: a sequence goes
        // on after a switch to another folder lets this one go (a cold `add -A` is not killed), and
        // another NanoTeams may have opened it since (D-M18 R8).
        let hold = workFolderHold
        let folderStillHeld: @Sendable () -> Bool = { hold.holds(folder) }
        let sequence = Task { @MainActor in
            for (index, request) in requests.enumerated() {
                do {
                    try await service.takeSnapshot(
                        workFolder: folder, taskID: taskID, runID: runID,
                        round: request.round, phase: request.phase, folderStillHeld: folderStillHeld)
                    progress.outcomes[index] = .landed
                } catch {
                    progress.outcomes[index] = .failed(Self.snapshotFailureDetail(error))
                }
            }
        }

        if let waitBudget, !(await Self.finishes(sequence, within: waitBudget)) {
            // What finished in time is recorded as it came; the rest as still running.
            let settled = progress.settled(requests)
            let pending = requests.enumerated().filter { progress.outcomes[$0.offset] == nil }.map(\.element)
            await recordSnapshotOutcomes(
                settled, timedOut: pending, late: false, taskID: taskID, runID: runID, within: lifecycle)
            Task { @MainActor [weak self] in
                await sequence.value
                guard let self else { return }
                let late = requests.enumerated()
                    .filter { pending.contains($0.element) }
                    .compactMap { item in progress.outcomes[item.offset].map { (item.element, $0) } }
                await self.recordSnapshotOutcomes(
                    late, timedOut: [], late: true, taskID: taskID, runID: runID, within: lifecycle)
            }
            return false
        }
        await sequence.value
        await recordSnapshotOutcomes(
            progress.settled(requests), timedOut: [], late: false, taskID: taskID, runID: runID, within: lifecycle)
        return true
    }

    /// Writes what the snapshots came to onto their run — only when it changes the record, and
    /// only in the folder they were taken in, with the task still loaded there (N4: a write
    /// after a transition landed in the next folder's task of the same number, or raised
    /// "Cannot persist task N: task not loaded.").
    private func recordSnapshotOutcomes(
        _ outcomes: [(TaskSnapshotRequest, TaskSnapshotOutcome)],
        timedOut: [TaskSnapshotRequest],
        late: Bool,
        taskID: Int,
        runID: Int,
        within lifecycle: WorkFolderLifecycle
    ) async {
        guard isCurrentFolderLifecycle(lifecycle),
              let task = loadedTask(taskID),
              let runIndex = RunService.runIndex(in: task, runID: runID)
        else { return }
        let run = task.runs[runIndex]
        let updated = Self.snapshotFailures(
            run.snapshotFailures, applying: outcomes, timedOut: timedOut, late: late,
            at: MonotonicClock.shared.now())
        guard updated != run.snapshotFailures else { return }
        await mutateTask(taskID: taskID) { task in
            guard let index = RunService.runIndex(in: task, runID: runID) else { return }
            task.runs[index].snapshotFailures = Self.snapshotFailures(
                task.runs[index].snapshotFailures, applying: outcomes, timedOut: timedOut, late: late,
                at: MonotonicClock.shared.now())
        }
    }

    /// The record after these outcomes. A snapshot that landed in time clears its own record —
    /// and an END snapshot that landed clears every end record of its round, since the last end
    /// is what `task_changes` reads. One that landed late is recorded `completed_late`: a start
    /// taken after the round began may hold its first changes, an end taken after the next round
    /// began may hold the next round's. A failure is recorded with what it said.
    nonisolated static func snapshotFailures(
        _ current: [RunSnapshotFailure],
        applying outcomes: [(TaskSnapshotRequest, TaskSnapshotOutcome)],
        timedOut: [TaskSnapshotRequest],
        late: Bool,
        at now: Date
    ) -> [RunSnapshotFailure] {
        var failures = current
        func set(_ request: TaskSnapshotRequest, _ reason: RunSnapshotFailure.Reason, _ detail: String?) {
            failures.removeAll { $0.round == request.round && $0.phase == request.phase }
            failures.append(RunSnapshotFailure(
                round: request.round, phase: request.phase, reason: reason, detail: detail, recordedAt: now))
        }
        for (request, outcome) in outcomes {
            switch outcome {
            case .landed where late:
                set(request, .completedLate, nil)
            case .landed:
                failures.removeAll {
                    $0.round == request.round
                        && ($0.phase == request.phase || (request.phase.endsRound && $0.phase.endsRound))
                }
            case .failed(let detail):
                set(request, .failed, detail)
            }
        }
        for request in timedOut {
            set(request, .timedOut, nil)
        }
        return failures
    }

    /// What a snapshot failure said — the git error the service raised, not Foundation's generic
    /// "The operation couldn't be completed".
    nonisolated static func snapshotFailureDetail(_ error: any Error) -> String {
        if let error = error as? ExternalAutovisorError { return error.message }
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }

    /// Whether `task` ends before `budget` runs out. The task is never cancelled: a snapshot
    /// left behind finishes in the background.
    static func finishes(_ task: Task<Void, Never>, within budget: Duration) async -> Bool {
        let race = SnapshotWaitRace()
        return await withCheckedContinuation { continuation in
            race.timer = Task { @MainActor in
                try? await Task.sleep(for: budget)
                race.settle(false, continuation)
            }
            Task { @MainActor in
                await task.value
                race.settle(true, continuation)
            }
        }
    }

    /// Whether the round `task_changes` reads is still going: the run's current round of a task
    /// not closed, with an engine that is working, paused or waiting for an answer — so an end
    /// snapshot the round already has is not its end (N7). An engine at acceptance, done or
    /// failed, or no engine (stopped, closed, not resumed since a relaunch) has ended it.
    func taskChangesRoundIsOpen(task: NTMSTask, round: Int?) -> Bool {
        guard task.closedAt == nil, let run = task.runs.last, round == nil || round == run.round else {
            return false
        }
        switch engineState[task.id] {
        case .pending?, .running?, .paused?, .needsSupervisorInput?:
            return true
        case .needsAcceptance?, .done?, .failed?, nil:
            return false
        }
    }
}

/// The outcomes of a snapshot sequence as they come — read by the verb that stopped waiting and
/// by the background completion. Main-actor: both readers and the writer run there.
@MainActor
private final class TaskSnapshotProgress {
    var outcomes: [NTMSOrchestrator.TaskSnapshotOutcome?]

    init(count: Int) {
        outcomes = Array(repeating: nil, count: count)
    }

    func settled(_ requests: [TaskSnapshotRequest]) -> [(TaskSnapshotRequest, NTMSOrchestrator.TaskSnapshotOutcome)] {
        requests.enumerated().compactMap { item in outcomes[item.offset].map { (item.element, $0) } }
    }
}

/// Which of a bounded wait's two sides spoke first; the other is ignored.
@MainActor
private final class SnapshotWaitRace {
    var timer: Task<Void, Never>?
    private var settled = false

    func settle(_ finished: Bool, _ continuation: CheckedContinuation<Bool, Never>) {
        guard !settled else { return }
        settled = true
        if finished { timer?.cancel() }
        continuation.resume(returning: finished)
    }
}
