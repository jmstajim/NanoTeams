import Foundation

/// Service for managing artifact file I/O operations.
final class ArtifactService {

    private let repository: any NTMSRepositoryProtocol
    private let fileManager: FileManager

    init(repository: any NTMSRepositoryProtocol,
         fileManager: FileManager = .default) {
        self.repository = repository
        self.fileManager = fileManager
    }

    // MARK: - Artifact CRUD (REMOVED: Artifacts are now per-team, managed via Team.artifacts)

    // These methods are no longer valid - artifacts are now part of team configuration,
    // not global project state. Use Team.addArtifact() / Team.removeArtifact() instead.

    /// Reads the content of an artifact file.
    /// - Parameters:
    ///   - artifact: The artifact to read.
    ///   - workFolderRoot: The project root URL.
    /// - Returns: The artifact content, or nil if the file cannot be read.
    static func readContent(artifact: Artifact, workFolderRoot: URL) -> String? {
        guard let rel = artifact.relativePath, !rel.isEmpty else { return nil }

        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let fileURL = paths.nanoteamsDir.appendingPathComponent(rel)

        do {
            let data = try Data(contentsOf: fileURL)
            let maxBytes = ArtifactConstants.maxContentBytes
            let prefix = data.prefix(maxBytes)
            guard let text = String(data: prefix, encoding: .utf8) else { return nil }

            if data.count > maxBytes {
                return text + "\n... (truncated)"
            }
            return text
        } catch {
            return nil
        }
    }

    /// Checks if build diagnostics file exists for a step.
    /// - Parameters:
    ///   - runID: The run ID.
    ///   - stepID: The step ID.
    ///   - workFolderRoot: The project root URL.
    /// - Returns: The relative path within .nanoteams if exists, nil otherwise.
    func buildDiagnosticsRelativePath(taskID: Int, runID: Int, roleID: String, workFolderRoot: URL) -> String? {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let jsonURL = paths.buildDiagnosticsJSON(taskID: taskID, runID: runID, roleID: roleID)
        guard fileManager.fileExists(atPath: jsonURL.path) else { return nil }
        return paths.relativePathWithinNanoteams(for: jsonURL)
    }

    /// Persists an empty/summary build diagnostics artifact for successful builds.
    /// Called when build completes with no errors (so no diagnostic data file exists).
    /// - Returns: The relative path within .nanoteams, or nil if persistence failed
    func persistEmptyBuildDiagnostics(taskID: Int, runID: Int, roleID: String, workFolderRoot: URL) throws -> String? {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let jsonURL = paths.buildDiagnosticsJSON(taskID: taskID, runID: runID, roleID: roleID)

        // Create directory if needed (restricted permissions — internal data)
        try fileManager.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: NTMSRepository.internalDirAttributes)

        // Create summary diagnostics JSON for successful build
        let summaryDiagnostics: [String: Any] = [
            "schemaVersion": 1,
            "createdAt": JSONCoderFactory.iso8601Formatter.string(from: MonotonicClock.shared.now()),
            "skipped": true,
            "skipReason": "clean_build",
            "errorCount": 0,
            "warningCount": 0,
            "issues": []
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: summaryDiagnostics, options: .prettyPrinted)
        try jsonData.write(to: jsonURL)

        return paths.relativePathWithinNanoteams(for: jsonURL)
    }
}
