import Foundation

/// The repository an orchestrator writes through: every write passes `WorkFolderHold.authorizeWrite`
/// before it reaches the repository it wraps, and every read goes straight through (D-M18 R2,
/// 2026-11-12).
///
/// One seam for "only the process holding a folder's lock writes into it": the orchestrator builds
/// this around whatever repository it is given, and hands it to every service it builds, so a
/// writer added later goes through it without being told to — the protocol makes each new method a
/// decision here, and the compiler asks for it. A snapshot reaches the orchestrator's memory only
/// from an open (after its lock) or from one of these writes, so a folder this process does not
/// hold is neither written, loaded, nor run in.
///
/// The write gate in `NTMSRepository.preparePaths` stays as it is — a process-wide answer to "does
/// another process hold it?" for a repository used on its own (tests, tooling), which holds no folder.
nonisolated struct HeldWorkFolderRepository: NTMSRepositoryProtocol {
    let inner: any NTMSRepositoryProtocol
    let hold: WorkFolderHold

    // MARK: WorkFolderRepository

    func openOrCreateWorkFolder(at workFolderRoot: URL) throws -> WorkFolderContext {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.openOrCreateWorkFolder(at: workFolderRoot)
    }

    func updateWorkFolderState(
        at workFolderRoot: URL, activeTask: NTMSTask?, mutate: (inout WorkFolderState) -> Void
    ) throws -> WorkFolderContext {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.updateWorkFolderState(at: workFolderRoot, activeTask: activeTask, mutate: mutate)
    }

    func updateSettings(
        at workFolderRoot: URL, activeTask: NTMSTask?, mutate: (inout ProjectSettings) -> Void
    ) throws -> WorkFolderContext {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.updateSettings(at: workFolderRoot, activeTask: activeTask, mutate: mutate)
    }

    func updateTeams(
        at workFolderRoot: URL, activeTask: NTMSTask?, mutate: (inout [Team]) -> Void
    ) throws -> WorkFolderContext {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.updateTeams(at: workFolderRoot, activeTask: activeTask, mutate: mutate)
    }

    func removeWorkFolderData(at workFolderRoot: URL) throws {
        try hold.authorizeWrite(into: workFolderRoot)
        try inner.removeWorkFolderData(at: workFolderRoot)
    }

    func resetWorkFolderSettings(at workFolderRoot: URL) throws -> WorkFolderContext {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.resetWorkFolderSettings(at: workFolderRoot)
    }

    // MARK: TaskRepository

    func createTask(
        at workFolderRoot: URL, title: String, supervisorTask: String,
        preferredTeamID: NTMSID?, parentTaskID: Int?, parentRoleID: String?,
        delegationDepth: Int, makeActive: Bool, origin: TaskOrigin?, requestKey: String?
    ) throws -> (snapshot: WorkFolderContext, taskID: Int) {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.createTask(
            at: workFolderRoot, title: title, supervisorTask: supervisorTask,
            preferredTeamID: preferredTeamID, parentTaskID: parentTaskID, parentRoleID: parentRoleID,
            delegationDepth: delegationDepth, makeActive: makeActive, origin: origin, requestKey: requestKey)
    }

    func setActiveTask(at workFolderRoot: URL, taskID: Int?) throws -> WorkFolderContext {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.setActiveTask(at: workFolderRoot, taskID: taskID)
    }

    func setActiveTaskID(at workFolderRoot: URL, taskID: Int?) throws {
        try hold.authorizeWrite(into: workFolderRoot)
        try inner.setActiveTaskID(at: workFolderRoot, taskID: taskID)
    }

    func deleteTask(at workFolderRoot: URL, taskID: Int) throws -> WorkFolderContext {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.deleteTask(at: workFolderRoot, taskID: taskID)
    }

    /// A read: passes whoever holds the folder.
    func loadTask(at workFolderRoot: URL, taskID: Int) throws -> NTMSTask {
        try inner.loadTask(at: workFolderRoot, taskID: taskID)
    }

    func updateTaskOnly(at workFolderRoot: URL, task: NTMSTask) throws {
        try hold.authorizeWrite(into: workFolderRoot)
        try inner.updateTaskOnly(at: workFolderRoot, task: task)
    }

    // MARK: ToolRepository

    func updateTools(at workFolderRoot: URL, tools: [ToolDefinitionRecord]) throws -> WorkFolderContext {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.updateTools(at: workFolderRoot, tools: tools)
    }

    // MARK: ArtifactRepository

    func persistStepArtifactFile(
        at workFolderRoot: URL, taskID: Int, runID: Int, roleID: String, artifactName: String, content: String
    ) throws -> String {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.persistStepArtifactFile(
            at: workFolderRoot, taskID: taskID, runID: runID, roleID: roleID,
            artifactName: artifactName, content: content)
    }

    func persistStepArtifactBinary(
        at workFolderRoot: URL, taskID: Int, runID: Int, roleID: String, artifactName: String,
        data: Data, fileExtension: String
    ) throws -> String {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.persistStepArtifactBinary(
            at: workFolderRoot, taskID: taskID, runID: runID, roleID: roleID,
            artifactName: artifactName, data: data, fileExtension: fileExtension)
    }

    // MARK: AttachmentRepository

    func stageAttachment(at workFolderRoot: URL, draftID: UUID, sourceURL: URL) throws -> String {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.stageAttachment(at: workFolderRoot, draftID: draftID, sourceURL: sourceURL)
    }

    func finalizeAttachments(
        at workFolderRoot: URL, taskID: Int, stagedEntries: [(path: String, isProjectReference: Bool)]
    ) throws -> [String] {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.finalizeAttachments(at: workFolderRoot, taskID: taskID, stagedEntries: stagedEntries)
    }

    func finalizeAutovisorGoalAttachment(at workFolderRoot: URL, stagedRelativePath: String) throws -> String {
        try hold.authorizeWrite(into: workFolderRoot)
        return try inner.finalizeAutovisorGoalAttachment(at: workFolderRoot, stagedRelativePath: stagedRelativePath)
    }

    func removeStagedItem(at workFolderRoot: URL, relativePath: String) throws {
        try hold.authorizeWrite(into: workFolderRoot)
        try inner.removeStagedItem(at: workFolderRoot, relativePath: relativePath)
    }

    func cleanupStagedDraft(at workFolderRoot: URL, draftID: UUID) throws {
        try hold.authorizeWrite(into: workFolderRoot)
        try inner.cleanupStagedDraft(at: workFolderRoot, draftID: draftID)
    }

    func cleanupAllStagedDrafts(at workFolderRoot: URL) throws {
        try hold.authorizeWrite(into: workFolderRoot)
        try inner.cleanupAllStagedDrafts(at: workFolderRoot)
    }
}
