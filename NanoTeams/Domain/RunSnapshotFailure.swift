import Foundation

/// The moment of a round a filesystem snapshot records (`TaskSnapshotService`): its `start`, or
/// one of the ways it ends. A round's `task_changes` compares its start with the LAST end
/// recorded for it, or with the work tree while the round is still open.
nonisolated enum TaskSnapshotPhase: String, Sendable, Codable, CaseIterable {
    case start
    case review
    case failure
    case restart
    case revision
    case stop
    case close

    /// Every phase but `start` — the snapshots that end a round.
    static let endPhases: [TaskSnapshotPhase] = allCases.filter { $0 != .start }

    var endsRound: Bool { self != .start }
}

/// A snapshot of a round that did not land when it was taken — the record `task_changes` reads
/// instead of guessing (N2, N3 of the F6 acceptance, 2026-11-12). Until then every trigger but
/// a run's start swallowed the failure (`_ = try?`), and the start's one record belonged to the
/// whole RUN: a slow first snapshot made `task_changes` refuse every later round too, and a lost
/// end snapshot silently turned a finished round's diff into a live one.
nonisolated struct RunSnapshotFailure: Codable, Equatable, Hashable, Sendable {
    /// Why the snapshot is missing or late.
    enum Reason: String, Codable, Sendable {
        /// The verb that took it stopped waiting (`TaskSnapshotConstants.captureWaitBudget`);
        /// it is still running in the background.
        case timedOut = "timed_out"
        /// It ended with an error — `detail` says which.
        case failed
        /// It finished after its verb stopped waiting: it exists, but a START snapshot taken
        /// that late may hold the round's first changes.
        case completedLate = "completed_late"
    }

    var round: Int
    var phase: TaskSnapshotPhase
    var reason: Reason
    /// What the failure said (git's stderr, a Cocoa error) — `nil` unless `reason == .failed`.
    var detail: String?
    var recordedAt: Date

    init(round: Int, phase: TaskSnapshotPhase, reason: Reason, detail: String? = nil, recordedAt: Date) {
        self.round = round
        self.phase = phase
        self.reason = reason
        self.detail = detail
        self.recordedAt = recordedAt
    }
}
