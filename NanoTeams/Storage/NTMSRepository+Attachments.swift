import Foundation

// MARK: - Attachment Staging

extension NTMSRepository {

    func stageAttachment(
        at workFolderRoot: URL,
        draftID: UUID,
        sourceURL: URL
    ) throws -> String {
        let paths = try preparePaths(at: workFolderRoot)
        let draftDir = paths.stagedAttachmentDir(draftID: draftID)
        try fileManager.createDirectory(at: draftDir, withIntermediateDirectories: true,
                                         attributes: Self.internalDirAttributes)

        let destinationURL = uniqueFileURL(
            in: draftDir,
            preferredName: sourceURL.lastPathComponent
        )
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return paths.relativePathFromProjectRoot(for: destinationURL)
    }

    func finalizeAttachments(
        at workFolderRoot: URL,
        taskID: Int,
        stagedEntries: [(path: String, isProjectReference: Bool)]
    ) throws -> [String] {
        guard !stagedEntries.isEmpty else { return [] }

        let paths = try preparePaths(at: workFolderRoot)
        let needsCopy = stagedEntries.contains { !$0.isProjectReference }

        // Only create attachments dir when at least one file needs copying.
        let attachmentsDir = paths.taskAttachmentsDir(taskID: taskID)
        if needsCopy {
            try fileManager.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        }

        var createdURLs: [URL] = []
        do {
            return try stagedEntries.map { entry in
                if entry.isProjectReference {
                    return entry.path
                }
                let stagedURL = try resolvedProjectRelativeURL(
                    workFolderRoot: workFolderRoot,
                    relativePath: entry.path
                )
                let destinationURL = uniqueFileURL(
                    in: attachmentsDir,
                    preferredName: stagedURL.lastPathComponent
                )
                try fileManager.copyItem(at: stagedURL, to: destinationURL)
                createdURLs.append(destinationURL)
                return paths.relativePathFromProjectRoot(for: destinationURL)
            }
        } catch {
            for url in createdURLs {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    func removeStagedItem(at workFolderRoot: URL, relativePath: String) throws {
        let itemURL = try resolvedProjectRelativeURL(workFolderRoot: workFolderRoot, relativePath: relativePath)
        guard fileManager.fileExists(atPath: itemURL.path) else { return }
        try fileManager.removeItem(at: itemURL)
    }

    func cleanupStagedDraft(at workFolderRoot: URL, draftID: UUID) throws {
        let paths = try preparePaths(at: workFolderRoot)
        let draftDir = paths.stagedAttachmentDir(draftID: draftID)
        guard fileManager.fileExists(atPath: draftDir.path) else { return }
        try fileManager.removeItem(at: draftDir)
    }

    func cleanupAllStagedDrafts(at workFolderRoot: URL) throws {
        let paths = try preparePaths(at: workFolderRoot)
        let draftsDir = paths.stagedAttachmentsDir
        guard fileManager.fileExists(atPath: draftsDir.path) else { return }
        try fileManager.removeItem(at: draftsDir)
    }

    // MARK: - Private Helpers

    private func resolvedProjectRelativeURL(workFolderRoot: URL, relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NTMSRepositoryError.invalidProjectFolder(workFolderRoot)
        }

        let candidate = workFolderRoot
            .appendingPathComponent(trimmed, isDirectory: false)
            .standardizedFileURL
        let root = workFolderRoot.standardizedFileURL

        let baseComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        let isWithinRoot = candidateComponents.count >= baseComponents.count
            && Array(candidateComponents.prefix(baseComponents.count)) == baseComponents

        guard isWithinRoot else {
            throw NTMSRepositoryError.invalidProjectFolder(workFolderRoot)
        }

        return candidate
    }

    private func uniqueFileURL(in directory: URL, preferredName: String) -> URL {
        let preferred = preferredName.isEmpty ? UUID().uuidString : preferredName
        let ext = (preferred as NSString).pathExtension
        let stem = ((preferred as NSString).deletingPathExtension).trimmingCharacters(in: .whitespacesAndNewlines)
        let safeStem = stem.isEmpty ? "attachment" : stem

        var candidate = directory.appendingPathComponent(preferred, isDirectory: false)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let fileName = ext.isEmpty ? "\(safeStem)-\(suffix)" : "\(safeStem)-\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(fileName, isDirectory: false)
            suffix += 1
        }

        return candidate
    }
}
