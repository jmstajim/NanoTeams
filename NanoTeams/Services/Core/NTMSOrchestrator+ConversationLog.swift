import Foundation

// MARK: - Write coordination

/// Monotonic generation stamp assigned at render START (on the main actor, so the
/// increment is serialized). A render that starts later always gets a higher stamp.
@MainActor
private enum ConversationLogGeneration {
    private static var counter = 0
    static func next() -> Int { counter += 1; return counter }
}

/// Pure stale-drop decision for `conversation_log.md` writes. A render's generation stamp
/// is monotonic (assigned at render START on the main actor), so a write should land only
/// when it is at least as new as the last write recorded for that task. Extracted for unit
/// testing; the actor owns the per-task state.
nonisolated enum ConversationLogWritePolicy {
    static func shouldWrite(generation: Int, lastWritten: Int?) -> Bool {
        guard let lastWritten else { return true }
        return generation >= lastWritten
    }
}

/// Serializes `conversation_log.md` disk writes and DROPS stale snapshots. The per-turn
/// render cadence + parallel role steps (CLAUDE.md #45) spawn concurrent `Task.detached`
/// builds for the same run; without coordination a slow earlier build could land its
/// (older-snapshot) write after a newer one, leaving a stale transcript — exactly the
/// drift the audit pair exists to catch. Each write carries the render's generation stamp;
/// the actor only writes when the stamp is newer than the last one written for that task.
private actor ConversationLogWriter {
    static let shared = ConversationLogWriter()
    private var lastWrittenGeneration: [Int: Int] = [:]

    func write(_ markdown: String, to url: URL, taskID: Int, generation: Int) {
        guard ConversationLogWritePolicy.shouldWrite(
            generation: generation, lastWritten: lastWrittenGeneration[taskID]
        ) else { return }
        lastWrittenGeneration[taskID] = generation
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort debug artifact — never propagate. Signalled in DEBUG to match
            // NetworkLogger.append / loadArtifactContentsForStepSync (a swallowed write
            // would otherwise leave a stale file with no diagnostic).
            #if DEBUG
            print("[ConversationLog] write failed at \(url.path): \(error)")
            #endif
        }
    }
}

// MARK: - Conversation Log (displayed-side audit artifact)

/// Renders `conversation_log.md` from the **activity feed** (what the user actually sees)
/// — the displayed side of the audit pair whose wire side is `network_log.json`. Reusing
/// `ActivityFeedBuilder` (the single source of truth for the feed) guarantees the log can
/// never silently drift from what's on screen, which is the whole point of being able to
/// diff the two files.
extension NTMSOrchestrator {

    /// Re-renders the current run's `conversation_log.md`. Fire-and-forget, best-effort,
    /// gated on `loggingEnabled`. Snapshots Sendable state on the main actor, then does the
    /// disk I/O (artifact reads + write) off-main so the per-turn cadence never blocks UI.
    /// Satisfies `LLMStateDelegate.renderConversationLog(taskID:)`.
    func renderConversationLog(taskID: Int) {
        guard loggingEnabled else { return }
        guard let task = loadedTask(taskID), let run = task.runs.last else { return }
        guard let logURL = conversationLogURL(taskID: taskID, runID: run.id) else { return }

        let generation = ConversationLogGeneration.next()
        let teamRoles = resolvedTeam(for: task).roles
        let debug = configuration.debugModeEnabled
        let isChatMode = task.isChatMode
        let workFolderRoot = workFolderURL

        // Supervisor-brief fields — same set `TeamActivityFeedView.buildContext` passes.
        let supervisorBrief = task.effectiveSupervisorBrief
        let supervisorBriefDate = task.createdAt
        let supervisorTask = task.supervisorTask
        let supervisorClippedTexts = task.clippedTexts
        let supervisorAttachmentPaths = task.attachmentPaths

        // All captured values are Sendable; ActivityFeedBuilder / the renderer are pure.
        Task.detached {
            // Artifact-content cache is only used for message↔artifact dedup, which the
            // builder skips in debug mode — so skip the disk reads there too.
            var cache: [String: Set<String>] = [:]
            if !debug {
                for step in run.steps where !step.artifacts.isEmpty {
                    cache[step.id] = ActivityFeedBuilder.loadArtifactContentsForStepSync(
                        step, workFolderURL: workFolderRoot
                    )
                }
            }

            // Pending (unanswered) supervisor questions are owned by the composer, not the
            // timeline — surface them too (the wire shows the ask_supervisor immediately).
            let pending = ActivityFeedBuilder.activeSupervisorQuestions(steps: run.steps)

            // `descendantTasks: []` keeps this log 1:1 with the run's own network_log.json
            // (also per-run); child runs render their own log the same way.
            let items = ActivityFeedBuilder.buildTimelineItems(
                steps: run.steps,
                run: run,
                teamRoles: teamRoles,
                activeTaskID: taskID,
                descendantTasks: [],
                supervisorBrief: supervisorBrief,
                supervisorBriefDate: supervisorBriefDate,
                supervisorTask: supervisorTask,
                supervisorClippedTexts: supervisorClippedTexts,
                supervisorAttachmentPaths: supervisorAttachmentPaths,
                supervisorProjectFolderURL: workFolderRoot,
                stepArtifactContentCache: cache,
                debugModeEnabled: debug,
                activeQuestions: pending,
                isStreaming: { _ in false }
            )

            let markdown = ConversationTranscriptRenderer.render(
                items: items,
                pending: pending,
                teamRoles: teamRoles,
                isChatMode: isChatMode,
                generatedAt: Date()
            )
            // Serialized + stale-drop write: a slower earlier render can't clobber a newer one.
            await ConversationLogWriter.shared.write(
                markdown, to: logURL, taskID: taskID, generation: generation
            )
        }
    }
}
