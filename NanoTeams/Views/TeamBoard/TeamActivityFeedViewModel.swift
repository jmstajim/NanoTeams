import Foundation
import Observation

// MARK: - Team Activity Feed View Model

/// Manages application-state owned by TeamActivityFeedView:
/// artifact content loading (disk I/O), supervisor answer submission, timeline caching, and item initialization tracking.
/// UI-only state (expansion, scroll, dialogs) remains in the View.
@Observable
@MainActor
final class TeamActivityFeedViewModel {

    // MARK: - Expansion State

    /// Consolidated expansion state for all collapsible timeline items.
    struct ExpansionState {
        var thinking: Set<UUID> = []
        var meetingThinking: Set<UUID> = []
        var meetingTools: Set<UUID> = []
        var toolCalls: Set<UUID> = []
        var artifacts: Set<String> = []
    }

    var expansion = ExpansionState()

    /// Apply default expansion settings to newly added timeline items.
    func applyDefaultsToNewItems(
        thinkingExpandedByDefault: Bool,
        toolCallsExpandedByDefault: Bool,
        artifactsExpandedByDefault: Bool,
        workFolderURL: URL?
    ) {
        for tagged in cachedTimelineItems {
            let itemID = tagged.id
            guard !initializedItemIDs.contains(itemID) else { continue }
            initializedItemIDs.insert(itemID)

            switch tagged.item {
            case .llmMessage(let msg, _, _):
                if thinkingExpandedByDefault,
                   let thinking = msg.thinking, !thinking.isEmpty {
                    expansion.thinking.insert(msg.id)
                }
            case .toolCall(let call, _, _):
                if toolCallsExpandedByDefault { expansion.toolCalls.insert(call.id) }
            case .artifact(let artifact, _, _):
                if artifactsExpandedByDefault {
                    expansion.artifacts.insert(artifact.id)
                    loadArtifactContentIfNeeded(artifact, workFolderURL: workFolderURL)
                }
            case .meetingMessage, .changeRequest, .notification, .supervisorTask:
                break
            }
        }
    }

    /// Expand or collapse all items of a given type. Caller wraps in `withAnimation`.
    func applyExpansionToAll(
        thinking: Bool? = nil,
        toolCalls: Bool? = nil,
        artifacts: Bool? = nil,
        workFolderURL: URL?
    ) {
        // Handle collapse-all cases upfront (no iteration needed)
        if thinking == false { expansion.thinking.removeAll() }
        if toolCalls == false { expansion.toolCalls.removeAll() }
        if artifacts == false { expansion.artifacts.removeAll() }

        // Single pass for expand-all cases
        let expandThinking = thinking == true
        let expandToolCalls = toolCalls == true
        let expandArtifacts = artifacts == true
        guard expandThinking || expandToolCalls || expandArtifacts else { return }

        for tagged in cachedTimelineItems {
            switch tagged.item {
            case .llmMessage(let msg, _, _):
                if expandThinking, let content = msg.thinking, !content.isEmpty {
                    expansion.thinking.insert(msg.id)
                }
            case .toolCall(let call, _, _):
                if expandToolCalls { expansion.toolCalls.insert(call.id) }
            case .artifact(let artifact, _, _):
                if expandArtifacts {
                    expansion.artifacts.insert(artifact.id)
                    loadArtifactContentIfNeeded(artifact, workFolderURL: workFolderURL)
                }
            case .meetingMessage, .changeRequest, .notification, .supervisorTask:
                break
            }
        }
    }

    // MARK: - Build Context

    /// Bundle of inputs required to recompute + rebuild the timeline.
    /// The view builds one of these per frame (cheap value type) and passes it into VM methods.
    struct BuildContext {
        var run: Run?
        var roleDefinitions: [TeamRoleDefinition]
        var filterRoleID: String?
        var activeTaskID: Int?
        var supervisorBrief: String?
        var supervisorBriefDate: Date?
        var supervisorTask: String?
        var supervisorClippedTexts: [String]
        var supervisorAttachmentPaths: [String]
        var supervisorProjectFolderURL: URL?
        var workFolderURL: URL?
        var debugModeEnabled: Bool
        var thinkingExpandedByDefault: Bool
        var toolCallsExpandedByDefault: Bool
        var artifactsExpandedByDefault: Bool
        var isStreaming: (UUID) -> Bool
    }

    // MARK: - Step + Question Cache

    /// Steps for the active team, filtered by `filterRoleID` when set. Rebuilt via `recomputeSteps`.
    private(set) var cachedAllSteps: [StepExecution] = []

    /// Active supervisor questions extracted from cached steps. Rebuilt via `recomputeSteps`.
    private(set) var cachedSupervisorQuestions: [ActivityFeedBuilder.ActiveSupervisorQuestion] = []

    // MARK: - Timeline Cache

    /// Latch: once true, stays true until `resetForTaskSwitch()`. Prevents empty-state flash
    /// between timeline rebuilds (e.g. during async artifact cache loading).
    private(set) var hasEverHadContent: Bool = false

    /// Cached timeline items, rebuilt only when TimelineFingerprint changes.
    private(set) var cachedTimelineItems: [ActivityFeedBuilder.TaggedItem] = []

    /// Last fingerprint used for change detection. `recomputeAndRebuild` short-circuits when unchanged.
    private(set) var lastFingerprint: TimelineFingerprint?

    /// In-flight debounce task for structural rebuilds triggered by streaming activity.
    /// Cancelled on subsequent triggers, task switch, and view disappearance.
    private var structuralRebuildTask: Task<Void, Never>?

    /// Lightweight fingerprint to detect when timeline needs rebuilding.
    struct TimelineFingerprint: Equatable {
        let activeTaskID: Int?
        let stepCount: Int
        let artifactCount: Int
        let meetingMessageCount: Int
        let llmMessageCount: Int
        let toolCallCount: Int
        let changeRequestCount: Int
        let supervisorInputCount: Int
        let failedStepCount: Int
    }

    /// Compute a fingerprint from current step/run data.
    func computeFingerprint(steps: [StepExecution], run: Run?, activeTaskID: Int?) -> TimelineFingerprint {
        let meetingMsgCount = (run?.meetings ?? []).reduce(0) { $0 + $1.messages.count }
        let llmMsgCount = steps.reduce(0) { $0 + $1.llmConversation.count }
        let toolCallCount = steps.reduce(0) { $0 + $1.toolCalls.count }
        return TimelineFingerprint(
            activeTaskID: activeTaskID,
            stepCount: steps.count,
            artifactCount: steps.reduce(0) { $0 + $1.artifacts.count },
            meetingMessageCount: meetingMsgCount,
            llmMessageCount: llmMsgCount,
            toolCallCount: toolCallCount,
            changeRequestCount: run?.changeRequests.count ?? 0,
            supervisorInputCount: steps.filter { $0.needsSupervisorInput && $0.supervisorAnswer == nil }.count,
            failedStepCount: steps.filter { $0.status == .failed }.count
        )
    }

    /// Rebuild the timeline items from current data.
    func rebuildTimeline(
        steps: [StepExecution],
        run: Run?,
        teamRoles: [TeamRoleDefinition] = [],
        supervisorBrief: String? = nil,
        supervisorBriefDate: Date? = nil,
        supervisorTask: String? = nil,
        supervisorClippedTexts: [String] = [],
        supervisorAttachmentPaths: [String] = [],
        supervisorProjectFolderURL: URL? = nil,
        debugModeEnabled: Bool,
        isStreaming: @escaping (UUID) -> Bool
    ) {
        timelineVersion += 1
        cachedTimelineItems = ActivityFeedBuilder.buildTimelineItems(
            steps: steps,
            run: run,
            teamRoles: teamRoles,
            supervisorBrief: supervisorBrief,
            supervisorBriefDate: supervisorBriefDate,
            supervisorTask: supervisorTask,
            supervisorClippedTexts: supervisorClippedTexts,
            supervisorAttachmentPaths: supervisorAttachmentPaths,
            supervisorProjectFolderURL: supervisorProjectFolderURL,
            stepArtifactContentCache: stepArtifactContentCache,
            debugModeEnabled: debugModeEnabled,
            isStreaming: isStreaming
        )
        if !cachedTimelineItems.isEmpty { hasEverHadContent = true }
    }

    // MARK: - Artifact Content Cache

    /// Maps artifact.id (String slug) → file content for inline display.
    private(set) var artifactContentCache: [String: String] = [:]

    /// Maps step.id → set of artifact file contents for message filtering (debug-off mode).
    private(set) var stepArtifactContentCache: [String: Set<String>] = [:]

    // MARK: - Supervisor Answer

    var supervisorAnswerText: [String: String] = [:]
    var supervisorAnswerAttachments: [String: [StagedAttachment]] = [:]
    private(set) var isSubmittingAnswer: Set<String> = []

    // MARK: - Scroll Position Tracking

    /// Whether the user is near the bottom of the scroll view. Used to decide whether to auto-scroll on new items.
    var isNearBottom: Bool = true

    /// Set when task switches — consumed after timeline rebuild to scroll to bottom.
    var needsScrollToBottom: Bool = false

    /// Incremented on every `rebuildTimeline` call. Used to trigger scroll after rebuild.
    private(set) var timelineVersion: Int = 0

    // MARK: - Initialization Tracking

    /// IDs of timeline items that have already had their default expansion applied.
    var initializedItemIDs: Set<String> = []

    // MARK: - Task Switch

    /// Resets all cached state when switching to a different task.
    /// Cancels any in-flight structural rebuild task so stale debounced work does not leak across tasks.
    func resetForTaskSwitch() {
        structuralRebuildTask?.cancel()
        structuralRebuildTask = nil
        hasEverHadContent = false
        initializedItemIDs.removeAll()
        cachedTimelineItems.removeAll()
        cachedAllSteps = []
        cachedSupervisorQuestions = []
        lastFingerprint = nil
        cacheGeneration += 1  // invalidate in-flight async cache loads
        stepArtifactContentCache.removeAll()
        artifactContentCache.removeAll()
        expansion = ExpansionState()
        supervisorAnswerText.removeAll()
        supervisorAnswerAttachments.removeAll()
        needsScrollToBottom = true
    }

    /// Cancels any pending debounced structural rebuild. Call from the view's `onDisappear`.
    func cancelStructuralRebuild() {
        structuralRebuildTask?.cancel()
        structuralRebuildTask = nil
    }

    // MARK: - Steps & Timeline Orchestration

    /// Recompute `cachedAllSteps` and `cachedSupervisorQuestions` from the current run,
    /// applying team-membership filtering and optional single-role filtering.
    ///
    /// Includes the systemRoleID bridge fallback for steps whose role UUID does not match
    /// any team member directly (handles team restore / migration edge case).
    func recomputeSteps(context: BuildContext) {
        cachedAllSteps = Self.computeAllSteps(
            run: context.run,
            roleDefinitions: context.roleDefinitions,
            filterRoleID: context.filterRoleID
        )
        cachedSupervisorQuestions = ActivityFeedBuilder.activeSupervisorQuestions(steps: cachedAllSteps)
    }

    /// Recompute steps, check fingerprint, refresh artifact cache if artifact count changed,
    /// then rebuild the timeline and apply default expansion. Short-circuits when nothing changed.
    func recomputeAndRebuild(context: BuildContext) {
        recomputeSteps(context: context)
        let newFingerprint = computeFingerprint(
            steps: cachedAllSteps, run: context.run, activeTaskID: context.activeTaskID
        )
        guard newFingerprint != lastFingerprint else { return }
        let oldFingerprint = lastFingerprint
        lastFingerprint = newFingerprint

        if let old = oldFingerprint, old.artifactCount != newFingerprint.artifactCount {
            Task {
                await refreshStepArtifactContentCacheAsync(
                    steps: cachedAllSteps,
                    debugModeEnabled: context.debugModeEnabled,
                    workFolderURL: context.workFolderURL
                )
                rebuildTimeline(context: context)
                applyDefaults(context: context)
            }
        } else {
            rebuildTimeline(context: context)
            applyDefaults(context: context)
        }
    }

    /// Debounced structural rebuild triggered by streaming activity.
    /// Cancels any previous in-flight task, sleeps for `delayMilliseconds`, then rebuilds.
    /// `onComplete` runs on the main actor after rebuild (used by the view for scroll adjustment).
    func scheduleStructuralRebuild(
        context: BuildContext,
        delayMilliseconds: UInt64 = 50,
        onComplete: (@MainActor () -> Void)? = nil
    ) {
        structuralRebuildTask?.cancel()
        structuralRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self else { return }
            self.rebuildTimeline(context: context)
            onComplete?()
        }
    }

    /// Force-refresh the artifact cache and rebuild from current context. Used on first-appear
    /// and when `debugModeEnabled` / `filterRoleID` change (mode switches need a full refresh).
    func refreshAndRebuild(context: BuildContext) async {
        recomputeSteps(context: context)
        await refreshStepArtifactContentCacheAsync(
            steps: cachedAllSteps,
            debugModeEnabled: context.debugModeEnabled,
            workFolderURL: context.workFolderURL
        )
        rebuildTimeline(context: context)
        applyDefaults(context: context)
    }

    /// Rebuild the timeline using the current cached steps and supplied context.
    private func rebuildTimeline(context: BuildContext) {
        rebuildTimeline(
            steps: cachedAllSteps,
            run: context.run,
            teamRoles: context.roleDefinitions,
            supervisorBrief: context.supervisorBrief,
            supervisorBriefDate: context.supervisorBriefDate,
            supervisorTask: context.supervisorTask,
            supervisorClippedTexts: context.supervisorClippedTexts,
            supervisorAttachmentPaths: context.supervisorAttachmentPaths,
            supervisorProjectFolderURL: context.supervisorProjectFolderURL,
            debugModeEnabled: context.debugModeEnabled,
            isStreaming: context.isStreaming
        )
    }

    /// Seed default expansion state for newly added timeline items.
    private func applyDefaults(context: BuildContext) {
        applyDefaultsToNewItems(
            thinkingExpandedByDefault: context.thinkingExpandedByDefault,
            toolCallsExpandedByDefault: context.toolCallsExpandedByDefault,
            artifactsExpandedByDefault: context.artifactsExpandedByDefault,
            workFolderURL: context.workFolderURL
        )
    }

    /// Pure step filtering: team membership + optional single-role filter + systemRoleID fallback.
    private static func computeAllSteps(
        run: Run?,
        roleDefinitions: [TeamRoleDefinition],
        filterRoleID: String?
    ) -> [StepExecution] {
        guard let steps = run?.steps else { return [] }
        let members = Set(roleDefinitions.map(\.id))
        var teamSteps = steps.filter { members.contains($0.effectiveRoleID) }

        // Fallback: include steps whose role.baseID matches a team member's systemRoleID
        // (handles UUID mismatch after team restore/migration)
        if teamSteps.count < steps.count {
            let sysIDToMember = Dictionary(
                roleDefinitions.compactMap { def in
                    def.systemRoleID.map { ($0, def.id) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            for step in steps where !members.contains(step.effectiveRoleID) {
                if sysIDToMember[step.role.baseID] != nil {
                    #if DEBUG
                    print("[ActivityFeed] UUID mismatch fallback: step \(step.role.baseID) matched via systemRoleID bridge")
                    #endif
                    teamSteps.append(step)
                }
            }
        }

        guard let filterID = filterRoleID else { return teamSteps }

        let filtered = teamSteps.filter { $0.effectiveRoleID == filterID }
        if !filtered.isEmpty { return filtered }

        // Fallback: match by role.baseID via systemRoleID bridge
        if let roleDef = roleDefinitions.first(where: { $0.id == filterID }),
           let sysID = roleDef.systemRoleID {
            let fallback = teamSteps.filter { $0.role.baseID == sysID }
            #if DEBUG
            if !fallback.isEmpty {
                print("[ActivityFeed] Filter fallback: roleID \(filterID) matched \(fallback.count) step(s) via systemRoleID '\(sysID)'")
            }
            #endif
            return fallback
        }
        return []
    }

    // MARK: - Artifact Loading

    /// Loads artifact file content into the cache if not already cached.
    func loadArtifactContentIfNeeded(_ artifact: Artifact, workFolderURL: URL?) {
        guard artifactContentCache[artifact.id] == nil else { return }

        guard let relativePath = artifact.relativePath,
              let projectURL = workFolderURL
        else {
            artifactContentCache[artifact.id] = "(Content not available)"
            return
        }

        let fileURL = projectURL
            .appendingPathComponent(".nanoteams")
            .appendingPathComponent(relativePath)
        do {
            artifactContentCache[artifact.id] = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            artifactContentCache[artifact.id] = "Error loading content: \(error.localizedDescription)"
        }
    }

    /// Generation counter for async artifact cache loads.
    /// Incremented on each load and on `resetForTaskSwitch()` to invalidate in-flight results.
    private var cacheGeneration: Int = 0

    /// Refreshes the step artifact content cache asynchronously (disk I/O off main thread).
    /// Only performs I/O when `debugModeEnabled` is false — in debug mode the cache is unused.
    /// Uses `cacheGeneration` to discard stale results after task switch.
    func refreshStepArtifactContentCacheAsync(
        steps: [StepExecution],
        debugModeEnabled: Bool,
        workFolderURL: URL?
    ) async {
        guard !debugModeEnabled else { return }
        let stepsWithArtifacts = steps.filter { !$0.artifacts.isEmpty }
        guard !stepsWithArtifacts.isEmpty else {
            stepArtifactContentCache = [:]
            return
        }
        cacheGeneration += 1
        let expectedGeneration = cacheGeneration
        let url = workFolderURL
        let newCache = await Task.detached {
            var cache: [String: Set<String>] = [:]
            for step in stepsWithArtifacts {
                cache[step.id] = Self.loadArtifactContentsForStepSync(step, workFolderURL: url)
            }
            return cache
        }.value
        guard cacheGeneration == expectedGeneration else { return }
        stepArtifactContentCache = newCache
    }

    // MARK: - Supervisor Answer Submission

    func submitSupervisorAnswer(stepID: String, store: NTMSOrchestrator, embedFiles: Bool = false) {
        let answer = supervisorAnswerText[stepID] ?? ""
        let attachments = supervisorAnswerAttachments[stepID] ?? []
        guard !answer.isEmpty || !attachments.isEmpty else { return }
        guard !isSubmittingAnswer.contains(stepID) else { return }
        isSubmittingAnswer.insert(stepID)
        Task {
            if let taskID = store.activeTaskID {
                let result = AnswerTextBuilder.build(
                    text: answer,
                    attachments: attachments,
                    embedFiles: embedFiles
                )
                if !result.failedFiles.isEmpty {
                    store.lastErrorMessage = "Could not embed \(result.failedFiles.count) file(s) as text: \(result.failedFiles.joined(separator: ", ")). They may be binary files."
                }
                let success = await store.answerSupervisorQuestion(
                    stepID: stepID, taskID: taskID,
                    answer: result.answer, attachments: attachments
                )
                isSubmittingAnswer.remove(stepID)
                if success {
                    supervisorAnswerText.removeValue(forKey: stepID)
                    supervisorAnswerAttachments.removeValue(forKey: stepID)
                }
            } else {
                isSubmittingAnswer.remove(stepID)
                store.lastErrorMessage = "No active task — answer not submitted."
            }
        }
    }

    // MARK: - Private Helpers

    private nonisolated static func loadArtifactContentsForStepSync(
        _ step: StepExecution,
        workFolderURL: URL?
    ) -> Set<String> {
        guard let projectURL = workFolderURL else { return [] }
        var contents: Set<String> = []
        for artifact in step.artifacts {
            guard let relativePath = artifact.relativePath else { continue }
            let fileURL = projectURL
                .appendingPathComponent(".nanoteams")
                .appendingPathComponent(relativePath)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                contents.insert(content)
            } else {
                #if DEBUG
                print("[ActivityFeed] Failed to load artifact content at \(fileURL.path)")
                #endif
            }
        }
        return contents
    }
    nonisolated deinit {}
}
