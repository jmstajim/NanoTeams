import Foundation

/// What the orchestrator and the `task_changes` handler need of the snapshot store — the seam
/// tests replace through `TestOrchestrator.make(taskSnapshotService:)`.
nonisolated protocol TaskSnapshotProtocol: Sendable {
    /// `folderStillHeld` is asked once the folder's store is this snapshot's alone, before
    /// anything in the folder is swept or run: `false` — this process no longer holds the folder
    /// (`WorkFolderHold`), so another NanoTeams may be using its store — ends the snapshot there,
    /// having touched nothing (D-M18 R8).
    func takeSnapshot(
        workFolder: URL,
        taskID: Int,
        runID: Int,
        round: Int,
        phase: TaskSnapshotService.SnapshotPhase,
        folderStillHeld: @escaping @Sendable () -> Bool
    ) async throws

    /// `roundIsOpen`: the round is still going, so an end snapshot it already has is not its
    /// end and the diff is against the work tree (N7).
    func diffChanges(
        workFolder: URL,
        folderID: String,
        taskID: Int,
        runID: Int?,
        round: Int?,
        roundIsOpen: Bool,
        page: Int?,
        pageSize: Int?,
        filePath: String?
    ) async throws -> TaskSnapshotService.TaskChangesResult

    func listTaskRefs(
        workFolder: URL,
        taskID: Int
    ) async throws -> [String]

    func cleanupTask(
        workFolder: URL,
        taskID: Int
    ) async throws
}

nonisolated extension TaskSnapshotProtocol {
    /// For a caller that holds no folder of its own — the folder is taken as held throughout.
    func takeSnapshot(
        workFolder: URL,
        taskID: Int,
        runID: Int,
        round: Int,
        phase: TaskSnapshotService.SnapshotPhase
    ) async throws {
        try await takeSnapshot(
            workFolder: workFolder, taskID: taskID, runID: runID, round: round, phase: phase,
            folderStillHeld: { true })
    }

    func takeSnapshot(
        workFolder: URL,
        taskID: Int,
        round: Int,
        phase: TaskSnapshotService.SnapshotPhase
    ) async throws {
        try await takeSnapshot(workFolder: workFolder, taskID: taskID, runID: 0, round: round, phase: phase)
    }

    /// A round asked about as ended — its last end snapshot, when it has one.
    func diffChanges(
        workFolder: URL,
        folderID: String,
        taskID: Int,
        runID: Int?,
        round: Int?,
        page: Int?,
        pageSize: Int?,
        filePath: String?
    ) async throws -> TaskSnapshotService.TaskChangesResult {
        try await diffChanges(
            workFolder: workFolder, folderID: folderID, taskID: taskID, runID: runID, round: round,
            roundIsOpen: false, page: page, pageSize: pageSize, filePath: filePath)
    }

    func diffChanges(
        workFolder: URL,
        folderID: String,
        taskID: Int,
        round: Int?,
        page: Int?,
        pageSize: Int?,
        filePath: String?
    ) async throws -> TaskSnapshotService.TaskChangesResult {
        try await diffChanges(
            workFolder: workFolder,
            folderID: folderID,
            taskID: taskID,
            runID: nil,
            round: round,
            roundIsOpen: false,
            page: page,
            pageSize: pageSize,
            filePath: filePath
        )
    }
}
