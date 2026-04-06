import Foundation

// MARK: - Step Artifact Persistence

extension NTMSRepository {

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
        let roleDir = paths.roleDir(taskID: taskID, runID: runID, roleID: roleID)
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

    /// Persist a build diagnostics JSON file under .nanoteams/internal/tasks/<taskID>/runs/<runID>/roles/<roleID>/build_diagnostics.json
    /// and return the relative path within .nanoteams/.
    func persistBuildDiagnosticsPersisted(
        at workFolderRoot: URL,
        taskID: Int,
        runID: Int,
        roleID: String,
        diagnostics: BuildDiagnosticsPersisted
    ) throws -> String {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let jsonURL = paths.buildDiagnosticsJSON(taskID: taskID, runID: runID, roleID: roleID)
        try fileManager.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: Self.internalDirAttributes)

        let data = try JSONCoderFactory.makeExportEncoder().encode(diagnostics)
        try data.write(to: jsonURL, options: [.atomic])

        return paths.relativePathWithinNanoteams(for: jsonURL)
    }
}
