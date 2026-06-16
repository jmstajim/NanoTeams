import Foundation
import Observation

// MARK: - Team Activity Feed View Model

/// Manages application-state owned by TeamActivityFeedView:
/// step artifact content loading for message dedup filtering, supervisor
/// answer submission, timeline caching, and item initialization tracking.
/// UI-only state (scroll, dialogs) remains in the View. Expandable details
/// (thinking, tool calls, artifacts, meeting tools) open in standalone
/// windows via `ActivityDetailWindow` — no inline expansion state lives here.
@Observable
@MainActor
final class TeamActivityFeedViewModel {

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
        var isStreaming: (UUID) -> Bool
        /// Loaded delegated descendants of the active task to interleave into
        /// the timeline. Empty for non-delegating tasks (V1 default).
        var descendantTasks: [ActivityFeedBuilder.DescendantTask] = []
        /// Per-task role definitions, indexed by task ID. Used by the dispatcher
        /// to resolve the right `TeamRoleDefinition` for items emitted from
        /// child teams (their roster ≠ active team's roster).
        var roleDefinitionsByTaskID: [Int: [TeamRoleDefinition]] = [:]
        /// Per-task team name, indexed by task ID. Used to render
        /// `RoleName.TeamName` labels on child-team items.
        var teamNameByTaskID: [Int: String] = [:]
        /// Whether the composer is currently rendered. Gates paired-message
        /// bubble suppression: when the composer is hidden (engine `.failed`,
        /// `isReadOnly`, closed task), suppression MUST NOT fire — otherwise
        /// the LLM's reply disappears from the feed with no preview card to
        /// surface it. Default `true` so callers that don't care (preview,
        /// tests) get the historical behavior.
        var composerVisible: Bool = true
    }

    // MARK: - Step + Question Cache

    /// Steps for the active team, filtered by `filterRoleID` when set. Rebuilt via `recomputeSteps`.
    private(set) var cachedAllSteps: [StepExecution] = []

    /// Per-ORIGIN-task step pools for the merged delegation timeline, rebuilt via
    /// `recomputeSteps`: active task → `cachedAllSteps`, each loaded descendant →
    /// its run's steps. `StepExecution.id` is the role ID, shared across tasks on
    /// the same team — so a bubble's implicit-stream-target resolution must search
    /// the pool of the bubble's OWNING task, not the active task's (otherwise a
    /// descendant message is matched against the parent's same-named step).
    private(set) var cachedStepsByTaskID: [Int: [StepExecution]] = [:]
    private var cachedActiveTaskID: Int?

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
    ///
    /// Includes a `descendantSummary` so the parent feed reactively rebuilds
    /// when a delegated child task's run gains/loses items — without this,
    /// `runDataVersion` (which only walks the active task's run) would miss
    /// child progress and the interleaved timeline would freeze.
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
        /// Aggregated counts across all loaded descendants + a stable hash of
        /// the descendant ID set. ID-set hash detects descendants
        /// appearing/disappearing even when total counts collide.
        let descendantSummary: DescendantSummary
        /// Whether the composer is rendered. Gates paired-message suppression
        /// in the builder — when this flips (engine `.failed`, task closed,
        /// view enters read-only), the cached timeline must invalidate so
        /// previously-suppressed bubbles reappear. Without this in the
        /// fingerprint, `recomputeAndRebuild`'s short-circuit would skip the
        /// rebuild and the LLM's reply would stay hidden.
        let composerVisible: Bool
    }

    struct DescendantSummary: Equatable {
        let descendantIDsHash: Int
        let stepCount: Int
        let artifactCount: Int
        let meetingMessageCount: Int
        let llmMessageCount: Int
        let toolCallCount: Int
        let changeRequestCount: Int

        static let empty = DescendantSummary(
            descendantIDsHash: 0,
            stepCount: 0, artifactCount: 0,
            meetingMessageCount: 0, llmMessageCount: 0,
            toolCallCount: 0, changeRequestCount: 0
        )

        static func compute(_ descendants: [ActivityFeedBuilder.DescendantTask]) -> DescendantSummary {
            guard !descendants.isEmpty else { return .empty }
            var hasher = Hasher()
            for d in descendants.sorted(by: { $0.task.id < $1.task.id }) {
                hasher.combine(d.task.id)
            }
            var stepCount = 0
            var artifactCount = 0
            var meetingMsgCount = 0
            var llmMsgCount = 0
            var toolCallCount = 0
            var changeRequestCount = 0
            for d in descendants {
                stepCount += d.run.steps.count
                for step in d.run.steps {
                    artifactCount += step.artifacts.count
                    llmMsgCount += step.llmConversation.count
                    toolCallCount += step.toolCalls.count
                }
                meetingMsgCount += d.run.meetings.reduce(0) { $0 + $1.messages.count }
                changeRequestCount += d.run.changeRequests.count
            }
            return DescendantSummary(
                descendantIDsHash: hasher.finalize(),
                stepCount: stepCount,
                artifactCount: artifactCount,
                meetingMessageCount: meetingMsgCount,
                llmMessageCount: llmMsgCount,
                toolCallCount: toolCallCount,
                changeRequestCount: changeRequestCount
            )
        }
    }

    /// Compute a fingerprint from current step/run data.
    func computeFingerprint(
        steps: [StepExecution],
        run: Run?,
        activeTaskID: Int?,
        descendants: [ActivityFeedBuilder.DescendantTask] = [],
        composerVisible: Bool = true
    ) -> TimelineFingerprint {
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
            // Shared with `emitItems` and `activeSupervisorQuestions` so the
            // rebuild trigger, the feed skip, and the composer chip all agree
            // on which steps are actively waiting. The naive
            // `needsSupervisorInput && supervisorAnswer == nil` predicate
            // misses the multi-round race window (see `stepHasActiveSupervisorInput`).
            supervisorInputCount: steps.filter(ActivityFeedBuilder.stepHasActiveSupervisorInput).count,
            failedStepCount: steps.filter { $0.status == .failed }.count,
            descendantSummary: DescendantSummary.compute(descendants),
            composerVisible: composerVisible
        )
    }

    /// Rebuild the timeline items from current data.
    func rebuildTimeline(
        steps: [StepExecution],
        run: Run?,
        teamRoles: [TeamRoleDefinition] = [],
        activeTaskID: Int = 0,
        descendantTasks: [ActivityFeedBuilder.DescendantTask] = [],
        supervisorBrief: String? = nil,
        supervisorBriefDate: Date? = nil,
        supervisorTask: String? = nil,
        supervisorClippedTexts: [String] = [],
        supervisorAttachmentPaths: [String] = [],
        supervisorProjectFolderURL: URL? = nil,
        debugModeEnabled: Bool,
        composerVisible: Bool = true,
        isStreaming: @escaping (UUID) -> Bool
    ) {
        timelineVersion += 1
        // Suppress the paired-message bubble ONLY when the composer is rendered
        // to surface it. When the composer is hidden (engine `.failed`, read-only
        // history, closed task) we must keep the feed bubble visible — otherwise
        // the LLM's substantive reply disappears with no UI to fall back to.
        let activeQuestions = composerVisible ? cachedSupervisorQuestions : []
        cachedTimelineItems = ActivityFeedBuilder.buildTimelineItems(
            steps: steps,
            run: run,
            teamRoles: teamRoles,
            activeTaskID: activeTaskID,
            descendantTasks: descendantTasks,
            supervisorBrief: supervisorBrief,
            supervisorBriefDate: supervisorBriefDate,
            supervisorTask: supervisorTask,
            supervisorClippedTexts: supervisorClippedTexts,
            supervisorAttachmentPaths: supervisorAttachmentPaths,
            supervisorProjectFolderURL: supervisorProjectFolderURL,
            stepArtifactContentCache: stepArtifactContentCache,
            debugModeEnabled: debugModeEnabled,
            activeQuestions: activeQuestions,
            isStreaming: isStreaming
        )
        if !cachedTimelineItems.isEmpty { hasEverHadContent = true }
    }

    // MARK: - Artifact Content Cache

    /// Maps step.id → set of artifact file contents for message filtering (debug-off mode).
    /// Inline artifact content rendering was removed — artifact viewers now open
    /// in standalone windows and load their own content from disk. This cache
    /// stays only because `ActivityFeedBuilder.buildTimelineItems` uses it to
    /// hide LLM messages whose content fully duplicates an artifact body.
    private(set) var stepArtifactContentCache: [String: Set<String>] = [:]

    /// Per-task team role definitions, indexed by task ID. The dispatcher uses
    /// this map to resolve the right `TeamRoleDefinition` for items emitted
    /// from delegated child teams (their roster ≠ active team's roster).
    private(set) var roleDefinitionsByTaskID: [Int: [TeamRoleDefinition]] = [:]

    /// Per-task team display name, indexed by task ID. Used to render
    /// `RoleName.TeamName` labels on child-team items.
    private(set) var teamNameByTaskID: [Int: String] = [:]

    /// Stash the per-task lookup tables out of the BuildContext so the dispatcher
    /// can read them at render time without rebuilding the context. Called from
    /// `recomputeAndRebuild` and `refreshAndRebuild`.
    func updatePerTaskLookups(from context: BuildContext) {
        roleDefinitionsByTaskID = context.roleDefinitionsByTaskID
        teamNameByTaskID = context.teamNameByTaskID
    }

    // MARK: - Scroll Position Tracking

    /// Whether the user is near the bottom of the scroll view. Used to decide whether to auto-scroll on new items.
    /// Updated from the view's `onScrollGeometryChange` via `isNearBottom(contentOffsetY:...)`.
    var isNearBottom: Bool = true

    /// Pixel slack within which (≤) the scroll position still counts as "at bottom".
    nonisolated static let nearBottomThreshold: CGFloat = 60

    /// Distance from the bottom edge ≤ threshold counts as "at bottom".
    /// Content shorter than the container is always at bottom (distance ≤ 0).
    nonisolated static func isNearBottom(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat,
        threshold: CGFloat = nearBottomThreshold
    ) -> Bool {
        (contentHeight + bottomInset - containerHeight - contentOffsetY) <= threshold
    }

    /// Set when task switches — consumed after timeline rebuild to scroll to bottom.
    var needsScrollToBottom: Bool = false

    /// Incremented on every `rebuildTimeline` call. Used to trigger scroll after rebuild.
    private(set) var timelineVersion: Int = 0

    /// How the view should scroll after a timeline rebuild.
    nonisolated enum ScrollToBottomAction {
        /// Instant jump (task switch — animation would replay the whole feed travel).
        case jump
        /// Smooth animated scroll (new items while the user is at the bottom).
        case animate
    }

    /// Scroll decision for one timeline rebuild. Task-switch `needsScrollToBottom`
    /// outranks the at-bottom gate and is consumed exactly once; otherwise scroll
    /// only when the user is at the bottom (never yank them up from history).
    func consumeScrollAction() -> ScrollToBottomAction? {
        if needsScrollToBottom {
            needsScrollToBottom = false
            return .jump
        }
        return isNearBottom ? .animate : nil
    }

    // MARK: - Task Switch

    /// Resets all cached state when switching to a different task.
    /// Cancels any in-flight structural rebuild task so stale debounced work does not leak across tasks.
    func resetForTaskSwitch() {
        structuralRebuildTask?.cancel()
        structuralRebuildTask = nil
        hasEverHadContent = false
        cachedTimelineItems.removeAll()
        cachedAllSteps = []
        cachedStepsByTaskID = [:]
        cachedActiveTaskID = nil
        cachedSupervisorQuestions = []
        lastFingerprint = nil
        cacheGeneration += 1  // invalidate in-flight async cache loads
        stepArtifactContentCache.removeAll()
        needsScrollToBottom = true
        // Reset before the new task's geometry lands — a stale `false` carried
        // across the switch would flash the scroll-to-bottom button.
        isNearBottom = true
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
        // Active supervisor questions drive the composer chip + paired-message
        // suppression. `cachedAllSteps` is the displayed run's steps, so a
        // `needsSupervisorInput` flag on one of them is always the live question.
        cachedSupervisorQuestions = ActivityFeedBuilder.activeSupervisorQuestions(steps: cachedAllSteps)

        cachedActiveTaskID = context.activeTaskID
        var byTask: [Int: [StepExecution]] = [:]
        if let activeID = context.activeTaskID { byTask[activeID] = cachedAllSteps }
        for descendant in context.descendantTasks {
            byTask[descendant.task.id] = descendant.run.steps
        }
        cachedStepsByTaskID = byTask
    }

    /// The step pool for a timeline item's owning task. Active task → the
    /// (role-filtered) `cachedAllSteps`; loaded descendant → its run's steps;
    /// unknown origin (stale item during a transition) → empty, so the
    /// implicit-stream-target resolver answers `false` instead of matching a
    /// same-named step of a DIFFERENT task.
    func steps(forOriginTaskID originTaskID: Int) -> [StepExecution] {
        if let pool = cachedStepsByTaskID[originTaskID] { return pool }
        return originTaskID == cachedActiveTaskID ? cachedAllSteps : []
    }

    /// Recompute steps, check fingerprint, refresh artifact cache if artifact count changed,
    /// then rebuild the timeline. Short-circuits when nothing changed.
    func recomputeAndRebuild(context: BuildContext) {
        updatePerTaskLookups(from: context)
        recomputeSteps(context: context)
        let newFingerprint = computeFingerprint(
            steps: cachedAllSteps, run: context.run, activeTaskID: context.activeTaskID,
            descendants: context.descendantTasks,
            composerVisible: context.composerVisible
        )
        guard newFingerprint != lastFingerprint else { return }
        let oldFingerprint = lastFingerprint
        lastFingerprint = newFingerprint

        // Refresh the artifact cache when active OR descendant artifact counts changed.
        let artifactCountChanged = oldFingerprint.map { old in
            old.artifactCount != newFingerprint.artifactCount
                || old.descendantSummary.artifactCount != newFingerprint.descendantSummary.artifactCount
        } ?? false

        if artifactCountChanged {
            Task {
                await refreshStepArtifactContentCacheAsync(
                    steps: cachedAllSteps,
                    debugModeEnabled: context.debugModeEnabled,
                    workFolderURL: context.workFolderURL
                )
                rebuildTimeline(context: context)
            }
        } else {
            rebuildTimeline(context: context)
        }
    }

    /// Debounced structural rebuild triggered by streaming activity.
    /// Cancels any previous in-flight task, sleeps for `delayMilliseconds`, then rebuilds.
    /// The rebuild bumps `timelineVersion`, the view's sole rebuild-driven scroll
    /// trigger — callers must not add a completion-scroll here (it would double-fire).
    func scheduleStructuralRebuild(
        context: BuildContext,
        delayMilliseconds: UInt64 = 50
    ) {
        structuralRebuildTask?.cancel()
        structuralRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self else { return }
            self.rebuildTimeline(context: context)
        }
    }

    /// Force-refresh the artifact cache and rebuild from current context. Used on first-appear
    /// and when `debugModeEnabled` / `filterRoleID` change (mode switches need a full refresh).
    func refreshAndRebuild(context: BuildContext) async {
        updatePerTaskLookups(from: context)
        recomputeSteps(context: context)
        await refreshStepArtifactContentCacheAsync(
            steps: cachedAllSteps,
            debugModeEnabled: context.debugModeEnabled,
            workFolderURL: context.workFolderURL
        )
        rebuildTimeline(context: context)
    }

    /// Rebuild the timeline using the current cached steps and supplied context.
    private func rebuildTimeline(context: BuildContext) {
        rebuildTimeline(
            steps: cachedAllSteps,
            run: context.run,
            teamRoles: context.roleDefinitions,
            activeTaskID: context.activeTaskID ?? 0,
            descendantTasks: context.descendantTasks,
            supervisorBrief: context.supervisorBrief,
            supervisorBriefDate: context.supervisorBriefDate,
            supervisorTask: context.supervisorTask,
            supervisorClippedTexts: context.supervisorClippedTexts,
            supervisorAttachmentPaths: context.supervisorAttachmentPaths,
            supervisorProjectFolderURL: context.supervisorProjectFolderURL,
            debugModeEnabled: context.debugModeEnabled,
            composerVisible: context.composerVisible,
            isStreaming: context.isStreaming
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
            return teamSteps.filter { $0.role.baseID == sysID }
        }
        return []
    }

    // MARK: - Artifact Loading

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
                cache[step.id] = ActivityFeedBuilder.loadArtifactContentsForStepSync(step, workFolderURL: url)
            }
            return cache
        }.value
        guard cacheGeneration == expectedGeneration else { return }
        stepArtifactContentCache = newCache
    }

    nonisolated deinit {}
}
