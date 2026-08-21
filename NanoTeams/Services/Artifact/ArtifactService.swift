import Foundation

/// Service for managing artifact file I/O operations.
nonisolated final class ArtifactService: @unchecked Sendable {

    private let fileManager: FileManager

    /// No repository dependency, on purpose (wave 32): every artifact READ is a static
    /// (`readContent`), and both instance methods are pure file I/O through `fileManager` —
    /// the stored repository had zero readers, so requiring one forced every construction
    /// site to fabricate a dependency nothing consumed.
    init(fileManager: FileManager = .default) {
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
            guard data.count > maxBytes else {
                // Not our cut: a file that fails to decode here is genuinely not
                // UTF-8, and must still be rejected rather than salvaged.
                return String(data: data, encoding: .utf8)
            }
            guard let text = decodeUTF8SnappingToBoundary(data.prefix(maxBytes)) else { return nil }
            return text + "\n... (truncated)"
        } catch {
            return nil
        }
    }

    /// UTF-8-decodes a byte prefix WE cut, backing off up to three bytes so a cut
    /// landing inside a multi-byte sequence truncates the artifact instead of
    /// losing it.
    ///
    /// `Data.prefix(maxBytes)` cuts on a byte boundary, so an artifact past
    /// `maxContentBytes` whose 51200th byte falls mid-character decoded to `nil`
    /// and the whole document read as unreadable — silently, with no error
    /// surfaced, and most easily on the non-ASCII text this project routinely
    /// produces. Artifacts are injected into downstream roles' conversations in
    /// full, so the downstream role simply saw no content.
    ///
    /// Three is exhaustive: the longest UTF-8 sequence is four bytes, so at most
    /// three trailing bytes can be a partial one. Anything still failing after
    /// that is not UTF-8 and correctly returns `nil`.
    ///
    /// The String-side twin of this is `DocumentTextExtractor.truncateToUTF8Bytes`,
    /// which cannot be reused here: it takes an already-decoded `String`, and
    /// decoding the whole file first is precisely the cost the byte cap exists
    /// to avoid.
    static func decodeUTF8SnappingToBoundary(_ data: Data) -> String? {
        for drop in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    /// Checks if build diagnostics file exists for a step.
    /// - Parameters:
    ///   - runID: The run ID.
    ///   - stepID: The step ID.
    ///   - workFolderRoot: The project root URL.
    /// - Returns: The relative path within .nanoteams if exists, nil otherwise.
    func buildDiagnosticsRelativePath(taskID: Int, runID: Int, roleID: String, workFolderRoot: URL, ancestors: [Int] = []) -> String? {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let jsonURL = paths.buildDiagnosticsJSON(taskID: taskID, runID: runID, roleID: roleID, ancestors: ancestors)
        guard fileManager.fileExists(atPath: jsonURL.path) else { return nil }
        return paths.relativePathWithinNanoteams(for: jsonURL)
    }

    /// Persists an empty/summary build diagnostics artifact for successful builds.
    /// Called when build completes with no errors (so no diagnostic data file exists).
    /// - Returns: The relative path within .nanoteams, or nil if persistence failed
    func persistEmptyBuildDiagnostics(taskID: Int, runID: Int, roleID: String, workFolderRoot: URL, ancestors: [Int] = []) throws -> String? {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let jsonURL = paths.buildDiagnosticsJSON(taskID: taskID, runID: runID, roleID: roleID, ancestors: ancestors)

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
    nonisolated deinit {}
}
