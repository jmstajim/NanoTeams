import AppKit
import Foundation

struct TaskCreationStagedAttachment: Hashable {
    let projectRelativePath: String
    let fileName: String
    let isProjectReference: Bool
}

struct TaskCreationRequest: Hashable {
    let title: String
    let rawSupervisorTask: String
    let preferredTeamID: NTMSID?
    let clippedTexts: [String]
    let stagedAttachments: [TaskCreationStagedAttachment]
}

extension NTMSOrchestrator {

    @discardableResult
    func createPreparedTaskAndStart(request: TaskCreationRequest) async -> Int? {
        if workFolderURL == nil {
            await bootstrapDefaultStorageIfNeeded()
        }
        guard let workFolderRoot = workFolderURL else { return nil }

        let trimmedTask = request.rawSupervisorTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle: String = {
            let raw = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { return raw }
            // Auto-derive title from task description: take first line, truncate to 60 chars
            let firstLine = trimmedTask.components(separatedBy: .newlines).first ?? trimmedTask
            let truncated = firstLine.prefix(60)
            return truncated.count < firstLine.count
                ? String(truncated) + "…"
                : String(truncated)
        }()
        guard !trimmedTitle.isEmpty else { return nil }
        let normalizedClips = request.clippedTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let newTaskID = await createTask(
            title: trimmedTitle,
            supervisorTask: trimmedTask,
            preferredTeamID: request.preferredTeamID
        ) else {
            return nil
        }

        do {
            let finalAttachmentPaths = try repository.finalizeAttachments(
                at: workFolderRoot,
                taskID: newTaskID,
                stagedEntries: request.stagedAttachments.map {
                    (path: $0.projectRelativePath, isProjectReference: $0.isProjectReference)
                }
            )

            await mutateTask(taskID: newTaskID) { task in
                task.clippedTexts = normalizedClips
                task.attachmentPaths = finalAttachmentPaths
            }
        } catch {
            await removeTask(newTaskID)
            lastErrorMessage = error.localizedDescription
            return nil
        }

        await switchTask(to: newTaskID)
        await startRun(taskID: newTaskID)
        return newTaskID
    }

    func stageAttachment(url: URL, draftID: UUID) -> StagedAttachment? {
        guard let workFolderRoot = workFolderURL else {
            lastErrorMessage = "No project folder available for staging attachments."
            return nil
        }

        let standardized = url.standardizedFileURL
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)

        // In-project file (outside .nanoteams/)? Store reference directly — no copy needed.
        if SandboxPathResolver.isWithin(candidate: standardized, container: workFolderRoot)
            && !SandboxPathResolver.isWithin(candidate: standardized, container: paths.nanoteamsDir)
            && fileManager.fileExists(atPath: standardized.path) {
            let relativePath = paths.relativePathFromProjectRoot(for: standardized)
            do {
                return try StagedAttachment(url: standardized, stagedRelativePath: relativePath, isProjectReference: true)
            } catch {
                lastErrorMessage = error.localizedDescription
                return nil
            }
        }

        do {
            let relativePath = try repository.stageAttachment(
                at: workFolderRoot,
                draftID: draftID,
                sourceURL: url
            )
            let stagedURL = workFolderRoot
                .appendingPathComponent(relativePath, isDirectory: false)
                .standardizedFileURL
            return try StagedAttachment(url: stagedURL, stagedRelativePath: relativePath)
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    func removeStagedAttachment(_ attachment: StagedAttachment) {
        guard !attachment.isProjectReference else { return }
        guard let workFolderRoot = workFolderURL else {
            lastErrorMessage = "No project folder available."
            return
        }
        do {
            try repository.removeStagedItem(
                at: workFolderRoot,
                relativePath: attachment.stagedRelativePath
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func discardStagedDraft(draftID: UUID) {
        guard let workFolderRoot = workFolderURL else {
            lastErrorMessage = "No project folder available."
            return
        }
        do {
            try repository.cleanupStagedDraft(at: workFolderRoot, draftID: draftID)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Convenience: builds a `TaskCreationRequest` from form fields, creates the task, starts it,
    /// and cleans up the draft. Returns the new task ID on success.
    @discardableResult
    func submitQuickCaptureForm(
        title: String,
        supervisorTask: String,
        teamID: NTMSID?,
        clippedTexts: [String],
        attachments: [StagedAttachment],
        draftID: UUID
    ) async -> Int? {
        let request = TaskCreationRequest(
            title: title,
            rawSupervisorTask: supervisorTask,
            preferredTeamID: teamID,
            clippedTexts: clippedTexts,
            stagedAttachments: attachments.map {
                TaskCreationStagedAttachment(
                    projectRelativePath: $0.stagedRelativePath,
                    fileName: $0.fileName,
                    isProjectReference: $0.isProjectReference
                )
            }
        )
        guard let taskID = await createPreparedTaskAndStart(request: request) else { return nil }
        discardStagedDraft(draftID: draftID)
        return taskID
    }

    func revealTaskAttachments(_ task: NTMSTask) {
        guard let workFolderRoot = workFolderURL else {
            lastErrorMessage = "No project folder available."
            return
        }
        let urls = task.attachmentPaths.map {
            workFolderRoot.appendingPathComponent($0, isDirectory: false)
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
