import Foundation

// MARK: - ISP-split Repository Protocols
//
// Clients should depend on the narrowest sub-protocol they actually need.
// `NTMSRepositoryProtocol` is a composition typealias kept for callers that
// genuinely use repository functionality across multiple domains (e.g.
// `NTMSOrchestrator` as the composition root).

/// Work-folder (project) lifecycle and metadata operations.
protocol WorkFolderRepository {
    func openOrCreateWorkFolder(at workFolderRoot: URL) throws -> WorkFolderContext
    func updateWorkFolderDescription(at workFolderRoot: URL, description: String) throws -> WorkFolderContext
    func updateSelectedScheme(at workFolderRoot: URL, scheme: String?) throws -> WorkFolderContext
    func updateWorkFolderState(at workFolderRoot: URL, mutate: (inout WorkFolderState) -> Void) throws -> WorkFolderContext
    func updateSettings(at workFolderRoot: URL, mutate: (inout ProjectSettings) -> Void) throws -> WorkFolderContext
    func updateTeams(at workFolderRoot: URL, mutate: (inout [Team]) -> Void) throws -> WorkFolderContext
    func resetWorkFolderSettings(at workFolderRoot: URL) throws -> WorkFolderContext
}

/// Task CRUD and active-task selection.
protocol TaskRepository {
    func createTask(at workFolderRoot: URL, title: String, supervisorTask: String, preferredTeamID: NTMSID?) throws -> WorkFolderContext
    func setActiveTask(at workFolderRoot: URL, taskID: Int?) throws -> WorkFolderContext
    func deleteTask(at workFolderRoot: URL, taskID: Int) throws -> WorkFolderContext
    func updateTask(at workFolderRoot: URL, task: NTMSTask) throws -> WorkFolderContext
    func loadTask(at workFolderRoot: URL, taskID: Int) throws -> NTMSTask
    func updateTaskOnly(at workFolderRoot: URL, task: NTMSTask) throws
}

/// Tool definition storage.
protocol ToolRepository {
    func updateTools(at workFolderRoot: URL, tools: [ToolDefinitionRecord]) throws -> WorkFolderContext
}

/// Step artifact file persistence.
///
/// Note: `persistBuildDiagnosticsPersisted` is intentionally NOT part of this
/// protocol — it has no production consumers through the protocol surface and
/// remains only as a concrete `NTMSRepository` method for direct use (e.g. tests).
protocol ArtifactRepository {
    func persistStepArtifactFile(at workFolderRoot: URL, taskID: Int, runID: Int, roleID: String, artifactName: String, content: String) throws -> String
    func persistStepArtifactBinary(at workFolderRoot: URL, taskID: Int, runID: Int, roleID: String, artifactName: String, data: Data, fileExtension: String) throws -> String
}

/// Staged-attachment lifecycle (Quick Capture → finalized task attachments).
protocol AttachmentRepository {
    func stageAttachment(at workFolderRoot: URL, draftID: UUID, sourceURL: URL) throws -> String
    func finalizeAttachments(at workFolderRoot: URL, taskID: Int, stagedEntries: [(path: String, isProjectReference: Bool)]) throws -> [String]
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

extension NTMSRepository: WorkFolderRepository,
                          TaskRepository,
                          ToolRepository,
                          ArtifactRepository,
                          AttachmentRepository {}
