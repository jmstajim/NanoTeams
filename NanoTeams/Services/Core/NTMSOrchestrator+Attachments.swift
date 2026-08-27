import AppKit
import Foundation

/// No `fileName`, on purpose (wave 32): finalization consumes only the path + the
/// project-reference flag, and the display name lives on the panel-side
/// `StagedAttachment` — the copy here had zero readers.
struct TaskCreationStagedAttachment: Hashable {
    let projectRelativePath: String
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

    /// Creates the task, finalizes its attachments and materializes its first run —
    /// then returns. The board is renderable at exactly that point, so the caller can
    /// open the chat immediately; the run's LAUNCH (agent-instruction and role-skill
    /// rescan, engine start) continues in a registered background task behind it.
    ///
    /// The boundary moved here because the previous one was wrong by construction:
    /// this method used to `await startRun`, so the chat stayed closed for the whole
    /// prompt warm-up — a recursive walk of the work folder for CLAUDE.md-class files
    /// plus a scan of every installed skill — none of which the first frame needs.
    /// Both scans run off the MainActor, which is why the UI never froze and the
    /// symptom was only ever "the chat opens late".
    ///
    /// Callers that need the run to have actually STARTED — tests, headless runs —
    /// join `runStartTask(for:)`. Concurrency is unchanged: the launch keeps holding
    /// the run-start claim, so a competing `startRun` is refused for its whole
    /// duration exactly as before.
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
        #if DEBUG
        SubmitLatencyProbe.mark("createTask")
        #endif

        do {
            let finalAttachmentPaths = try repository.finalizeAttachments(
                at: workFolderRoot,
                taskID: newTaskID,
                stagedEntries: request.stagedAttachments.map {
                    (path: $0.projectRelativePath, isProjectReference: $0.isProjectReference)
                }
            )

            await mutateTask(taskID: newTaskID) { task in
                task.clippedTexts = [Clip].minting(normalizedClips)
                task.attachmentPaths = finalAttachmentPaths
            }
        } catch {
            await removeTask(newTaskID)
            lastErrorMessage = error.localizedDescription
            return nil
        }
        #if DEBUG
        SubmitLatencyProbe.mark("attachments")
        #endif

        // No-op today — `createTask(makeActive:)` already promoted this id — but kept
        // so the "the active task is this one" precondition the board renders against
        // is stated here rather than inherited from another method's default argument.
        await switchTask(to: newTaskID)

        // Phase 1 inline, phase 2 behind the chat. `claimRunStart` is the same guard
        // `startRun` takes, so a Play click or a queue-flush wake arriving during the
        // background launch is refused exactly as it would have been mid-`startRun`.
        if let generation = claimRunStart(taskID: newTaskID) {
            await materializeRun(taskID: newTaskID)
            spawnBackgroundRunLaunch(taskID: newTaskID, generation: generation)
        }
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
