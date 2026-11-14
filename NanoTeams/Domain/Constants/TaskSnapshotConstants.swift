import Foundation

/// Tunables of the External Autovisor's filesystem snapshots (`TaskSnapshotService`).
nonisolated enum TaskSnapshotConstants {
    /// How long a lifecycle verb waits for the snapshots it takes — a run's start, a restart's
    /// or a revision's end-and-start, a close — before it goes on and leaves them to finish in
    /// the background. A snapshot that has not finished by then is recorded on its round as
    /// `timed_out`, and as `completed_late` or `failed` once it ends (`RunSnapshotFailure`).
    /// 5 s: an incremental snapshot of a 2,558-file folder takes ~75 ms and a cold one ~1.2 s,
    /// so only a first snapshot of a large folder without ignore rules reaches it.
    static let captureWaitBudget: Duration = .seconds(5)
}
