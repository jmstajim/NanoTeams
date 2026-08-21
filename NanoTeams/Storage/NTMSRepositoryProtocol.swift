import Foundation

// MARK: - ISP-split Repository Protocols
//
// Clients should depend on the narrowest sub-protocol they actually need.
// `NTMSRepositoryProtocol` is a composition typealias kept for callers that
// genuinely use repository functionality across multiple domains (e.g.
// `NTMSOrchestrator` as the composition root).

/// Work-folder (project) lifecycle and metadata operations.
nonisolated protocol WorkFolderRepository: Sendable {
    func openOrCreateWorkFolder(at workFolderRoot: URL) throws -> WorkFolderContext
    func updateWorkFolderContext(at workFolderRoot: URL, context: String) throws -> WorkFolderContext
    func updateSelectedScheme(at workFolderRoot: URL, scheme: String?) throws -> WorkFolderContext
    func updateWorkFolderState(at workFolderRoot: URL, mutate: (inout WorkFolderState) -> Void) throws -> WorkFolderContext
    func updateSettings(at workFolderRoot: URL, mutate: (inout ProjectSettings) -> Void) throws -> WorkFolderContext
    func updateTeams(at workFolderRoot: URL, mutate: (inout [Team]) -> Void) throws -> WorkFolderContext
    func resetWorkFolderSettings(at workFolderRoot: URL) throws -> WorkFolderContext
}

/// Task CRUD and active-task selection.
nonisolated protocol TaskRepository: Sendable {
    /// Creates a new task and returns the post-mutation snapshot together with
    /// the freshly allocated `taskID`. The id is returned explicitly because
    /// child tasks (delegation) do not become the active task — callers cannot
    /// recover the id from `snapshot.activeTaskID` and must NOT infer it from
    /// `tasksIndex.nextTaskID - 1` (race-prone, breaks if the counter ever
    /// changes shape).
    func createTask(
        at workFolderRoot: URL,
        title: String,
        supervisorTask: String,
        preferredTeamID: NTMSID?,
        parentTaskID: Int?,
        parentRoleID: String?,
        delegationDepth: Int,
        makeActive: Bool
    ) throws -> (snapshot: WorkFolderContext, taskID: Int)
    func setActiveTask(at workFolderRoot: URL, taskID: Int?) throws -> WorkFolderContext
    /// Persists `activeTaskID` to `workfolder.json` without rebuilding the full
    /// `WorkFolderContext`. Callers on the cached fast-path already have the
    /// authoritative in-memory snapshot, so the `assembleContext` work that
    /// `setActiveTask` does (read settings.json + teams.json — the largest of
    /// the three workfolder files — + tasks_index.json + active task.json) is
    /// wasted overhead. Now that the active-task pointer is awaited rather
    /// than fire-and-forget, that overhead directly inflates user-perceived
    /// switch latency on the fast path.
    func setActiveTaskID(at workFolderRoot: URL, taskID: Int?) throws
    func deleteTask(at workFolderRoot: URL, taskID: Int) throws -> WorkFolderContext
    func loadTask(at workFolderRoot: URL, taskID: Int) throws -> NTMSTask
    func updateTaskOnly(at workFolderRoot: URL, task: NTMSTask) throws
}

/// Tool definition storage.
nonisolated protocol ToolRepository: Sendable {
    func updateTools(at workFolderRoot: URL, tools: [ToolDefinitionRecord]) throws -> WorkFolderContext
}

/// Step artifact file persistence.
nonisolated protocol ArtifactRepository: Sendable {
    func persistStepArtifactFile(at workFolderRoot: URL, taskID: Int, runID: Int, roleID: String, artifactName: String, content: String) throws -> String
    func persistStepArtifactBinary(at workFolderRoot: URL, taskID: Int, runID: Int, roleID: String, artifactName: String, data: Data, fileExtension: String) throws -> String
}

/// Staged-attachment lifecycle (Quick Capture → finalized task attachments).
nonisolated protocol AttachmentRepository: Sendable {
    func stageAttachment(at workFolderRoot: URL, draftID: UUID, sourceURL: URL) throws -> String
    func finalizeAttachments(at workFolderRoot: URL, taskID: Int, stagedEntries: [(path: String, isProjectReference: Bool)]) throws -> [String]
    func finalizeAutovisorGoalAttachment(at workFolderRoot: URL, stagedRelativePath: String) throws -> String
    func removeStagedItem(at workFolderRoot: URL, relativePath: String) throws
    func cleanupStagedDraft(at workFolderRoot: URL, draftID: UUID) throws
    func cleanupAllStagedDrafts(at workFolderRoot: URL) throws
}

/// Composition of all repository sub-protocols. Used by composition-root types
/// (e.g. `NTMSOrchestrator`) that legitimately exercise the full surface.
typealias NTMSRepositoryProtocol = WorkFolderRepository
    & TaskRepository
    & ToolRepository
    & ArtifactRepository
    & AttachmentRepository

// `NTMSRepository`'s sub-protocol conformances live alongside the type
// declaration in `NTMSRepository.swift` — Swift 6 forbids declaring `Sendable`
// conformance retroactively, and the sub-protocols here inherit from `Sendable`.
