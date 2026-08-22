import Foundation

// MARK: - Write coordination

/// Render coalescing: at most ONE render in flight per task, plus one pending.
///
/// The per-turn cadence re-renders the WHOLE run — every step, every message,
/// every artifact — so turn k used to pay O(run-so-far) even when a render was
/// already running: N commits during one slow render queued N more full renders,
/// each building a timeline the stale-drop below would then discard. Now a turn
/// that lands mid-render just marks the task dirty, and the finishing render
/// triggers exactly ONE follow-up (which snapshots FRESH state, so nothing the
/// discarded renders would have shown is lost). O(turns²) becomes O(renders x
/// run) with renders ~= "turns that landed while idle".
@MainActor
enum ConversationLogRenderCoalescer {
    private static var inFlight: Set<Int> = []
    private static var dirty: Set<Int> = []

    /// True → the caller owns the render slot. False → a render is already in
    /// flight; the task is marked dirty and the caller must NOT render.
    static func begin(_ taskID: Int) -> Bool {
        if inFlight.contains(taskID) {
            dirty.insert(taskID)
            return false
        }
        inFlight.insert(taskID)
        return true
    }

    /// Releases the slot; true → a turn landed mid-render and one follow-up
    /// render is owed.
    static func finish(_ taskID: Int) -> Bool {
        inFlight.remove(taskID)
        return dirty.remove(taskID) != nil
    }

    #if DEBUG
    static func _testReset() {
        inFlight.removeAll()
        dirty.removeAll()
    }
    #endif
}

/// Serializes `conversation_log.md` disk writes.
///
/// It used to also DROP stale snapshots, keyed on a monotonic generation stamp.
/// That mechanism was unreachable from the day `ConversationLogRenderCoalescer`
/// landed: `begin` is the only entry to a render, `finish` releases the slot
/// strictly AFTER the write, and both call sites are `@MainActor` — so render
/// n+1 for a task cannot start until write n has landed, and the incoming stamp
/// was always the newest. It was also the wrong lever for cost: the drop
/// happened after `buildTimelineItems` and `render` had already run. Removed
/// rather than left standing with a doc comment that made it read as live
/// (CLAUDE.md #79/#90); the coalescer is the mechanism that actually holds the
/// ordering, and it stays.
private actor ConversationLogWriter {
    static let shared = ConversationLogWriter()

    func write(_ markdown: String, to url: URL, taskID: Int) {
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
        // Defense-in-depth: every path into `loadedTasks` hydrates, but a
        // metadata-only task here would overwrite the on-disk log with an
        // empty "_No activity recorded._" transcript — refuse rather than clobber.
        guard task.streamsHydrated else { return }
        guard let logURL = conversationLogURL(taskID: taskID, runID: run.id) else { return }
        // After the cheap guards, so a task that cannot render never occupies the slot.
        guard ConversationLogRenderCoalescer.begin(taskID) else { return }

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
            // Serialized write; the coalescer guarantees at most one render per task
            // is in flight, so ordering needs no second mechanism.
            await ConversationLogWriter.shared.write(markdown, to: logURL, taskID: taskID)
            // Release the slot; if turns landed mid-render, run ONE follow-up that
            // snapshots the now-current state (self is the long-lived orchestrator).
            await MainActor.run {
                if ConversationLogRenderCoalescer.finish(taskID) {
                    self.renderConversationLog(taskID: taskID)
                }
            }
        }
    }
}
