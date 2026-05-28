import Foundation

// MARK: - Step Artifact Persistence

nonisolated extension NTMSRepository {

    /// Persist a text artifact under .nanoteams/tasks/<taskID>/runs/<runID>/roles/<roleID>/artifact_<slug>.md
    /// and return the relative path within .nanoteams/.
    func persistStepArtifactFile(
        at workFolderRoot: URL,
        taskID: Int,
        runID: Int,
        roleID: String,
        artifactName: String,
        content: String
    ) throws -> String {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let ancestors = ancestorChain(for: taskID, paths: paths)
        let roleDir = paths.roleDir(taskID: taskID, runID: runID, roleID: roleID, ancestors: ancestors)
        try fileManager.createDirectory(at: roleDir, withIntermediateDirectories: true)

        let slug = Artifact.slugify(artifactName)
        let fileURL = roleDir.appendingPathComponent("artifact_\(slug).md", isDirectory: false)

        let cleaned = ModelTokenCleaner.clean(content)
        guard let data = cleaned.data(using: .utf8) else {
            throw NTMSRepositoryError.unableToEncodeReport
        }

        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw NTMSRepositoryError.unableToWriteReport(fileURL, underlying: error)
        }

        return paths.relativePathWithinNanoteams(for: fileURL)
    }

    /// Persist a binary-format artifact (PDF, RTF, DOCX) alongside the markdown original.
    /// Returns the relative path within .nanoteams/.
    func persistStepArtifactBinary(
        at workFolderRoot: URL,
        taskID: Int,
        runID: Int,
        roleID: String,
        artifactName: String,
        data: Data,
        fileExtension: String
    ) throws -> String {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let ancestors = ancestorChain(for: taskID, paths: paths)
        let roleDir = paths.roleDir(taskID: taskID, runID: runID, roleID: roleID, ancestors: ancestors)
        try fileManager.createDirectory(at: roleDir, withIntermediateDirectories: true)

        let slug = Artifact.slugify(artifactName)
        let fileURL = roleDir.appendingPathComponent("artifact_\(slug).\(fileExtension)", isDirectory: false)

        try data.write(to: fileURL, options: [.atomic])
        return paths.relativePathWithinNanoteams(for: fileURL)
    }

    /// Persist a build diagnostics JSON file under .nanoteams/internal/tasks/<taskID>/runs/<runID>/roles/<roleID>/build_diagnostics.json
    /// (or the appropriate nested path for delegated child tasks) and return the
    /// relative path within .nanoteams/.
    func persistBuildDiagnosticsPersisted(
        at workFolderRoot: URL,
        taskID: Int,
        runID: Int,
        roleID: String,
        diagnostics: BuildDiagnosticsPersisted
    ) throws -> String {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let ancestors = ancestorChain(for: taskID, paths: paths)
        let jsonURL = paths.buildDiagnosticsJSON(taskID: taskID, runID: runID, roleID: roleID, ancestors: ancestors)
        try fileManager.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: Self.internalDirAttributes)

        let data = try JSONCoderFactory.makeExportEncoder().encode(diagnostics)
        try data.write(to: jsonURL, options: [.atomic])

        return paths.relativePathWithinNanoteams(for: jsonURL)
    }

    /// Reads `tasks_index.json` and walks the ancestor chain for the given task ID.
    /// Top-level tasks (or unknown IDs, which behave as top-level for path resolution)
    /// produce an empty array — matches the original flat layout.
    ///
    /// Returns `[]` (treats as top-level) if the index file is missing or unreadable.
    /// This keeps callers that operate without a fully-bootstrapped work folder
    /// (e.g. unit tests that exercise `persistStepArtifactFile` directly) working.
    func ancestorChain(for taskID: Int, paths: NTMSPaths) -> [Int] {
        guard fileManager.fileExists(atPath: paths.tasksIndexJSON.path) else { return [] }
        guard let index = try? store.read(TasksIndex.self, from: paths.tasksIndexJSON) else {
            return []
        }
        return index.ancestorIDs(of: taskID)
    }
}
