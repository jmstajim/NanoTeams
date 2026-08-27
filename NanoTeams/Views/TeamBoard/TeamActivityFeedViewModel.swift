import Foundation
import Observation
#if DEBUG
import Synchronization
#endif

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
        /// `isReadOnly`, closed task), suppression MUST NOT fire — otherwise a
        /// suppressed turn disappears from the feed with no question card to
        /// surface it. Only contentless turns are ever suppressed (see
        /// `PairedAssistantMessage.isFullyRenderedByQuestionCard`), so what this
        /// gate protects is their `thinking` row. Default `true` so callers that
        /// don't care (preview, tests) get the historical behavior.
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

    /// Message ids that are the implicit stream target of a `.running` step —
    /// at most one per running step, computed ONCE per rebuild.
    ///
    /// Lives here rather than at the bubble because the feed's `VStack` is
    /// deliberately non-lazy (it realizes every row on every body pass), so the
    /// per-bubble spelling walked the step's whole conversation once per bubble:
    /// Θ(M²) per pass in chat mode, where one step holds the entire session.
    /// Computed in `rebuildTimeline` — the single funnel every rebuild path goes
    /// through — and NOT in `recomputeSteps`, which `scheduleStructuralRebuild`
    /// bypasses; a set built there would go stale exactly on the streaming-commit
    /// path that moves the target.
    ///
    /// The `isPreviewTarget` term is deliberately NOT folded in here: it flips
    /// between rebuilds and the call site reads it live, so freezing it would
    /// re-introduce a one-tick stale indicator at the streaming → committed
    /// transition.
    private(set) var implicitStreamTargetIDs: Set<UUID> = []

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
        /// rebuild and those turns would stay hidden.
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
            // misses the multi-round race window (see `StepExecution.hasActiveSupervisorInput`).
            supervisorInputCount: steps.count(where: \.hasActiveSupervisorInput),
            failedStepCount: steps.count { $0.status == .failed },
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
        #if DEBUG
        TimelineRebuildProbe.notePerformed()
        #endif
        timelineVersion += 1
        // Suppress the paired-message bubble ONLY when the composer is rendered
        // to surface it. When the composer is hidden (engine `.failed`, read-only
        // history, closed task) we must keep the feed bubble visible — otherwise
        // the turn disappears with no UI to fall back to. This is one of two
        // conditions; the builder applies the other (only turns the card fully
        // renders are suppressible at all).
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

        // One pass per step, in lockstep with the items it annotates. The union
        // over pools is safe because `LLMMessage.id` is globally unique, and it
        // mirrors `steps(forOriginTaskID:)`, whose fallback is `cachedAllSteps`.
        //
        // `cachedAllSteps` is walked here ONLY when the pools cannot already contain it.
        // `recomputeSteps` files `cachedAllSteps` into `cachedStepsByTaskID` under the
        // active task id, so walking both unconditionally walked the ACTIVE task's whole
        // conversation TWICE on every rebuild — and `implicitStreamTargetID` is itself a
        // walk of `step.llmConversation`, which grows with the session. The fallback arm
        // survives because the map has no key to file the steps under when
        // `context.activeTaskID` is nil, which is exactly when `steps(forOriginTaskID:)`
        // falls back to `cachedAllSteps` too — the two must agree or a bubble resolves
        // against a pool the resolver never saw.
        var targets: Set<UUID> = []
        let activePoolIsFiled = cachedActiveTaskID.map { cachedStepsByTaskID[$0] != nil } ?? false
        if !activePoolIsFiled {
            for step in cachedAllSteps {
                if let id = TeamActivityFeedView.implicitStreamTargetID(in: step) {
                    targets.insert(id)
                }
            }
        }
        for pool in cachedStepsByTaskID.values {
            for step in pool {
                if let id = TeamActivityFeedView.implicitStreamTargetID(in: step) {
                    targets.insert(id)
                }
            }
        }
        implicitStreamTargetIDs = targets
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

    /// Per-task roster INDEX — the same rosters as `roleDefinitionsByTaskID`, keyed for
    /// O(1) lookup instead of two linear scans.
    ///
    /// `findRoleDefinition` is called once or twice per rendered timeline item, and the
    /// feed's `VStack` is deliberately NON-lazy (see the note at its `ForEach`), so every
    /// item is realized on every body pass. Two `first(where:)` scans of the roster per
    /// item made that Θ(items × roles) per pass, with `items` growing with the whole
    /// conversation and the pass driven by `store.snapshot` — i.e. every `mutateTask`.
    /// Built once per rebuild here, where the rosters already arrive.
    private(set) var roleIndexByTaskID: [Int: RoleRosterIndex] = [:]

    /// Stash the per-task lookup tables out of the BuildContext so the dispatcher
    /// can read them at render time without rebuilding the context. Called from
    /// `recomputeAndRebuild` and `refreshAndRebuild`.
    func updatePerTaskLookups(from context: BuildContext) {
        roleDefinitionsByTaskID = context.roleDefinitionsByTaskID
        teamNameByTaskID = context.teamNameByTaskID
        roleIndexByTaskID = context.roleDefinitionsByTaskID
            .mapValues { RoleRosterIndex(roster: $0) }
        activeRoleIndex = RoleRosterIndex(roster: context.roleDefinitions)
    }

    /// Index of the ACTIVE team's roster — the fallback `findRoleDefinition` uses when a
    /// timeline item's origin task has no entry (a descendant that unloaded while a
    /// tagged item is still in the cached timeline).
    private(set) var activeRoleIndex = RoleRosterIndex(roster: [])

    // MARK: - Scroll Position Tracking

    /// Whether the user is near the bottom of the scroll view. Used to decide whether to auto-scroll on new items.
    /// Updated from the view's `onScrollGeometryChange` action by recomputing the gate from
    /// `ScrollFollowSnapshot.distanceFromBottom` (built via the shared `distanceFromBottom(...)` helper).
    var isNearBottom: Bool = true

    /// Pixel slack within which (≤) the scroll position still counts as "at bottom"
    /// and auto-scroll/follow engages.
    nonisolated static let nearBottomThreshold: CGFloat = 50

    /// Tolerance (pt) for the growth-follow disambiguator. A pure content-growth tick
    /// (scroll offset frozen) moves `distanceFromBottom` by exactly the content
    /// growth; a concurrent user drag-up moves it by MORE. The slack absorbs
    /// sub-pixel / fractional jitter so a real growth tick keeps the pin while an
    /// intentional drag releases it.
    nonisolated static let growthFollowSlack: CGFloat = 4

    /// Distance (pt) from the resting bottom of the scroll view. SINGLE SOURCE OF
    /// TRUTH for the at-bottom geometry: the view's `onScrollGeometryChange`
    /// transform builds `ScrollFollowSnapshot.distanceFromBottom` from this exact
    /// helper and `isNearBottom` delegates to it, so production and the pinned tests
    /// can never silently diverge.
    ///
    /// `topInset` is SUBTRACTED: a safe-area top inset (e.g. the TeamBoardTopBar)
    /// shifts the resting bottom content-offset down by exactly its own height, so
    /// at the TRUE bottom `contentHeight + bottomInset - containerHeight -
    /// contentOffsetY` equals `topInset`, not 0. Omitting the term over-reports the
    /// distance by `topInset` and, when that exceeds `threshold`, latches the feed
    /// out of auto-scroll. Verified against live geometry traces.
    nonisolated static func distanceFromBottom(
        contentHeight: CGFloat,
        bottomInset: CGFloat,
        topInset: CGFloat,
        containerHeight: CGFloat,
        contentOffsetY: CGFloat
    ) -> CGFloat {
        contentHeight + bottomInset - topInset - containerHeight - contentOffsetY
    }

    /// The `y` value to pass to `ScrollPosition.scrollTo(y:)` to land the feed at
    /// the TRUE bottom — i.e. at the offset where `distanceFromBottom == 0`.
    ///
    /// This is deliberately NOT the resting bottom `contentOffset.y`. SwiftUI's
    /// `scrollTo(y:)` lands the offset `topInset` SHORT of its `y` argument (the
    /// argument is in a content space shifted down by the top safe-area inset, so
    /// `offset == y − topInset`). The resting bottom offset, per the
    /// `distanceFromBottom` SSOT, is `cH + insBot − insTop − container`. To make
    /// `scrollTo` LAND there, the argument must be `insTop` HIGHER, which cancels
    /// the inset term: `cH + insBot − container`.
    ///
    /// Why this exists: the prior code passed the resting offset directly, so every
    /// settle-scroll landed `insTop` (≈79pt) short. `distanceFromBottom` then read
    /// `insTop`, above `nearBottomThreshold`, which latched the feed out of
    /// auto-follow even though `cH` was the correct, stable height — the documented
    /// "autoscroll stopped / can't re-pin" bug, verified in the live geometry trace
    /// (`scrollTo(y:)` consistently landed exactly `insTop` short; resting `dist`
    /// pinned at 79 for ~70 ticks). Note `topInset` is therefore NOT a parameter:
    /// it cancels out by construction.
    ///
    /// Robust under both inset models: if `scrollTo(y:)` were instead exact (no
    /// `insTop` undershoot), this lands at `dist == −insTop` — still ≤ threshold,
    /// still "at bottom" (a sub-pixel overscroll that snaps back). The prior
    /// formula, by contrast, lands at `dist == +insTop` and latches false.
    nonisolated static func bottomTargetY(
        contentHeight: CGFloat,
        bottomInset: CGFloat,
        containerHeight: CGFloat
    ) -> CGFloat {
        contentHeight + bottomInset - containerHeight
    }

    /// Distance from the bottom edge ≤ threshold counts as "at bottom".
    /// Content shorter than the container is always at bottom (distance ≤ 0).
    /// Delegates the geometry to `distanceFromBottom(...)` so there is exactly one
    /// distance formula shared by production and tests.
    nonisolated static func isNearBottom(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat,
        topInset: CGFloat = 0,
        threshold: CGFloat = nearBottomThreshold
    ) -> Bool {
        distanceFromBottom(
            contentHeight: contentHeight,
            bottomInset: bottomInset,
            topInset: topInset,
            containerHeight: containerHeight,
            contentOffsetY: contentOffsetY
        ) <= threshold
    }

    /// Equatable snapshot of the scroll geometry the view feeds into
    /// `onScrollGeometryChange`. Built from the SwiftUI `ScrollGeometry` (plain
    /// `CGFloat`s only, so it stays test-reachable). The `action` closure reads BOTH
    /// the `contentHeight` delta and the `distanceFromBottom` delta to tell "content
    /// grew under a pinned scroll" (keep the pin) from "user scrolled (release the
    /// pin)".
    nonisolated struct ScrollFollowSnapshot: Equatable {
        let distanceFromBottom: CGFloat
        let contentHeight: CGFloat
        /// The `y` to feed `scrollTo(y:)` to land at the true bottom — see
        /// `bottomTargetY(contentHeight:bottomInset:containerHeight:)`. Carried in the
        /// snapshot (computed in the pure transform) so the view can stash it into
        /// `@State` from the ACTION closure — a `@State` write in the transform is
        /// dropped as "state mutation during view update", which left the deferred
        /// scroll targeting y=0 (the top).
        let bottomTargetY: CGFloat
    }

    /// Keep the bottom-pin through a content-growth tick under a STILL-pinned scroll.
    /// The growth-vs-drag disambiguator: when content grows by Δ while the scroll
    /// offset is frozen (the streaming case), `distanceFromBottom` grows by ≤ Δ. If
    /// the user ALSO dragged up on the same coalesced geometry tick, the distance
    /// grows by MORE than Δ — so the pin must release, otherwise a user scrolling up
    /// DURING streaming is yanked back. `wasAtBottom` is the stored pin; a shrink or a
    /// pure offset change is never a growth tick (the caller recomputes the gate then).
    nonisolated static func shouldFollowGrowth(
        oldContentHeight: CGFloat,
        newContentHeight: CGFloat,
        oldDistanceFromBottom: CGFloat,
        newDistanceFromBottom: CGFloat,
        wasAtBottom: Bool,
        slack: CGFloat = growthFollowSlack
    ) -> Bool {
        guard wasAtBottom else { return false }
        let heightDelta = newContentHeight - oldContentHeight
        guard heightDelta > 0 else { return false }
        let distanceDelta = newDistanceFromBottom - oldDistanceFromBottom
        return distanceDelta <= heightDelta + slack
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

#if DEBUG
/// Work-bound seam for the activity feed: how many FULL timeline rebuilds have actually
/// been performed since the last reset.
///
/// Deliberately NOT `timelineVersion`. That counter is the view's sole rebuild-driven
/// scroll trigger, and the existing coalescing test asserts on it — its own docstring
/// records the trap: it "relies on `rebuildTimeline` bumping unconditionally (no
/// fingerprint guard on the scheduled path) — if that changes, this assertion no longer
/// distinguishes coalescing from a no-op second rebuild". Gating the scheduled path
/// while pinning the same counter would have turned that test VACUOUSLY GREEN rather
/// than red, so the count of performed work gets a home of its own (CLAUDE.md #104).
///
/// `buildTimelineItems` walks every message, tool call, artifact, meeting turn and change
/// request of the displayed run plus every loaded descendant, and sorts the result with a
/// comparator that calls an escaping `isStreaming` closure twice per comparison — so a
/// rebuild is the unit of cost worth counting.
nonisolated enum TimelineRebuildProbe {
    private static let _performed = Atomic<Int>(0)
    static func notePerformed() { _performed.wrappingAdd(1, ordering: .relaxed) }
    static func performed() -> Int { _performed.load(ordering: .relaxed) }
    static func reset() { _performed.store(0, ordering: .relaxed) }
}
#endif
