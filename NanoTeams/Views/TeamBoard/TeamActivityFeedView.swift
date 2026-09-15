import SwiftUI

// MARK: - Team Activity Feed View

/// Unified activity feed showing all team members work chronologically.
/// Activity timeline showing role execution progression.
struct TeamActivityFeedView: View {
    let run: Run?
    let roleDefinitions: [TeamRoleDefinition]
    let supervisorReviewArtifacts: [String]
    let producedArtifacts: Set<String>
    let isFinalReviewStage: Bool
    var isChatMode: Bool = false
    var isReadOnly: Bool = false
    var filterRoleID: String? = nil
    var onSelectRole: ((String) -> Void)? = nil
    var onReviewTask: (() -> Void)? = nil
    var onRequestChanges: ((String, String) -> Void)? = nil

    @Environment(NTMSOrchestrator.self) private var store
    @Environment(OrchestratorEngineState.self) private var engineStateEnv
    @Environment(StoreConfiguration.self) private var config
    @Environment(StreamingPreviewManager.self) private var streamingManager
    @Environment(DictationService.self) private var dictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowResizeMonitor) private var resizeMonitor

    @State private var viewModel = TeamActivityFeedViewModel()
    @State private var revisionRoleID: String? = nil
    @State private var revisionComment: String = ""
    @State private var isShowingRevisionSheet: Bool = false
    /// Activity-feed pane height, measured live via `onGeometryChange` on the outer
    /// VStack. Used to cap the docked composer at 2/3 of the visible pane so a long
    /// answer can grow into the available space without occluding the timeline
    /// entirely. Seeded with `.infinity` so the first render doesn't clamp the
    /// composer to zero (CLAUDE.md #18).
    @State private var paneHeight: CGFloat = .infinity

    // MARK: - Change Detection

    /// Lightweight version hash derived from run data counts (active run + all
    /// loaded descendants). Used by `onChange` to detect structural changes
    /// without expensive `Run` equality checks. Without descendant data the
    /// parent feed wouldn't react to a child's mid-flight messages — the
    /// interleaved timeline would freeze until the user manually scrolled.
    private var runDataVersion: Int {
        Self.computeRunDataVersion(
            run: run,
            descendants: resolvedDescendantTasks()
        )
    }


    /// Resolve the delegated descendants to interleave into the feed, **scoped
    /// to the displayed `run`**. Only children delegated within this run (via
    /// each step's `delegationChildIDs` history, walked transitively) are
    /// included — so a fresh run, or a role restarted via `reset()`, no longer
    /// leaks the previous run's delegated-team activity (the run-agnostic
    /// `tasksIndex.descendantIDs` did). Filters out descendants whose task or
    /// run has been unloaded since the last build (graceful for stale state
    /// during transitions). Each descendant carries everything the builder
    /// needs (run, team roles, team name, delegating role).
    private func resolvedDescendantTasks() -> [ActivityFeedBuilder.DescendantTask] {
        guard store.activeTaskID != nil, let run else { return [] }
        // `loadedTask(_:)` per id — an O(1) dictionary read — instead of materializing
        // every loaded task (and every delegated child) into an array and then a map.
        // This is reached from `runDataVersion`, which is the `onChange` value, so it ran
        // on EVERY body pass, and a second time from `buildContext` whenever a rebuild
        // fired. `loadedTasks` only ever grows within a session (eviction is
        // opportunistic), and the walk looks up a handful of ids.
        return ActivityFeedBuilder.resolveRunScopedDescendants(
            displayedRun: run,
            resolveTeam: { store.resolvedTeam(for: $0) },
            resolveTask: { store.loadedTask($0) }
        )
    }

    /// Builds a `BuildContext` snapshot from current environment values.
    /// Called at every VM orchestration entry point so the VM never holds environment references.
    private func buildContext() -> TeamActivityFeedViewModel.BuildContext {
        let task = store.activeTask
        let descendants = resolvedDescendantTasks()
        let activeID = store.activeTaskID
        let activeTeam = store.resolvedTeam(for: task)
        var roleMap: [Int: [TeamRoleDefinition]] = [:]
        var teamNameMap: [Int: String] = [:]
        if let id = activeID {
            roleMap[id] = activeTeam.roles
            teamNameMap[id] = activeTeam.name
        }
        for d in descendants {
            roleMap[d.task.id] = d.teamRoles
            if let name = d.teamName { teamNameMap[d.task.id] = name }
        }
        return TeamActivityFeedViewModel.BuildContext(
            run: run,
            roleDefinitions: roleDefinitions,
            filterRoleID: filterRoleID,
            activeTaskID: activeID,
            supervisorBrief: task?.effectiveSupervisorBrief,
            supervisorBriefDate: task?.createdAt,
            supervisorTask: task?.supervisorTask,
            supervisorClippedTexts: task?.clippedTexts.texts ?? [],
            supervisorAttachmentPaths: task?.attachmentPaths ?? [],
            supervisorProjectFolderURL: store.workFolderURL,
            workFolderURL: store.workFolderURL,
            debugModeEnabled: config.debugModeEnabled,
            isStreaming: { streamingManager.isStreaming(messageID: $0) },
            descendantTasks: descendants,
            roleDefinitionsByTaskID: roleMap,
            teamNameByTaskID: teamNameMap,
            composerVisible: shouldShowComposer
        )
    }

    // MARK: - Action Bar Data

    private var rolesNeedingAcceptance: [(roleID: String, roleName: String)] {
        run?.rolesNeedingAcceptance(definitions: roleDefinitions) ?? []
    }

    private var revisionRoleName: String {
        guard let roleID = revisionRoleID else { return "" }
        return roleDefinitions.roleName(for: roleID)
    }

    private var hasActionBarContent: Bool {
        !rolesNeedingAcceptance.isEmpty || isFinalReviewStage
    }

    /// Persistent composer is visible on any live (non-historical, non-terminal) run so
    /// the Supervisor can always send a message. The composer dispatches by recipient:
    /// `.answer` → `store.answerSupervisorQuestion`; `.team` / `.role` → queue via
    /// `QuickCaptureController.queueChatMessage`. Corrections to a paused role go
    /// through `CorrectRoleSheet` on the graph/banner, not through this composer.
    ///
    /// Role IDs currently `.working` — used to narrow the composer's "To:" menu.
    private var workingRoleIDs: Set<String> {
        guard let statuses = run?.roleStatuses else { return [] }
        return Set(statuses.compactMap { id, status in status == .working ? id : nil })
    }

    /// Role IDs currently `.failed` — the composer names one of these as the retry target
    /// ("Send a message to X to retry…") so the resume path (commit "Resume a paused or
    /// failed task by sending a message") gets a meaningful label instead of an arbitrary
    /// `candidateRoles.first`.
    private var failedRoleIDs: Set<String> {
        guard let statuses = run?.roleStatuses else { return [] }
        return Set(statuses.compactMap { id, status in status == .failed ? id : nil })
    }

    private var allowsRoleFallback: Bool {
        Self.allowsRoleFallback(
            isChatMode: isChatMode,
            engineState: store.activeTaskID.flatMap { engineStateEnv[$0] }
        )
    }


    /// All active supervisor questions, mapped into the composer's lightweight snapshot
    /// type. The engine runs ready roles in parallel (CLAUDE.md #45), so several roles
    /// can sit in `.needsSupervisorInput` simultaneously — the composer renders one
    /// Answer chip per entry in input order. For team tasks `StepExecution.id == roleID`,
    /// so `q.stepID` doubles as the asking-role id (computed via `askingRoleID`).
    private var activeQuestionsForComposer: [TeamActivityActiveQuestion] {
        viewModel.cachedSupervisorQuestions.map(TeamActivityActiveQuestion.init(pending:))
    }

    private var shouldShowComposer: Bool {
        Self.shouldShowComposer(
            isReadOnly: isReadOnly,
            activeTaskID: store.activeTaskID,
            closedAt: store.activeTask?.closedAt,
            isChatMode: isChatMode,
            engineState: store.activeTaskID.flatMap { engineStateEnv[$0] }
        )
    }


    // MARK: - Supervisor Mode

    private var isAutonomousMode: Bool {
        let team = store.resolvedTeam(for: store.activeTask)
        return team.settings.supervisorMode == .autonomous
    }

    // MARK: - Helpers

    /// Resolves a `TeamRoleDefinition` for a `Role`, scoped to the team that
    /// owns the timeline item. Falls back to the active team if the per-task
    /// lookup map doesn't contain the originTaskID (defensive — e.g. during
    /// a transition where the descendant has unloaded but a stale tagged item
    /// is still in the cached timeline).
    private func findRoleDefinition(for role: Role, originTaskID: Int) -> TeamRoleDefinition? {
        let index = viewModel.roleIndexByTaskID[originTaskID] ?? viewModel.activeRoleIndex
        return index.role(forBaseID: role.baseID)
    }

    /// True when `originTaskID` refers to a delegated descendant (not the active task).
    /// Drives the `RoleName.TeamName` label suffix on child-team items.
    private func isChildTeamOrigin(_ originTaskID: Int) -> Bool {
        store.activeTaskID.map { $0 != originTaskID } ?? false
    }

    /// Render-time team name lookup for child-team labels.
    private func teamName(for originTaskID: Int) -> String? {
        viewModel.teamNameByTaskID[originTaskID]
    }

    /// Returns the bare role name override for delegated child-team items —
    /// the resolved name from the child team's roster (so two teams sharing
    /// a `Role` enum case still render under their own role labels).
    /// `nil` for active-team items (caller falls through to roleDefinition.name).
    private func childRoleLabel(for role: Role, originTaskID: Int) -> String? {
        guard isChildTeamOrigin(originTaskID) else { return nil }
        return findRoleDefinition(for: role, originTaskID: originTaskID)?.name ?? role.displayName
    }

    /// Returns the child team's name for delegated items, rendered as
    /// ` from <Team>` in secondary gray after the role name. `nil` for
    /// active-team items (no suffix needed).
    private func childTeamSuffix(for originTaskID: Int) -> String? {
        guard isChildTeamOrigin(originTaskID) else { return nil }
        return teamName(for: originTaskID)
    }

    private var hasContent: Bool {
        viewModel.hasEverHadContent || !viewModel.cachedTimelineItems.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if hasContent {
                    timelineScrollView
                } else {
                    emptyStateView
                }

                if !viewModel.cachedSupervisorQuestions.isEmpty || hasActionBarContent {
                    LinearGradient(
                        colors: [Colors.surfaceFadeClear, Colors.surfacePrimary],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Spacing.l)
                    .allowsHitTesting(false)
                }

                if hasContent && !viewModel.isNearBottom {
                    scrollToBottomButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, Spacing.m)
                        .padding(.bottom, Spacing.m)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            .animationWithReduceMotion(Animations.quick, value: viewModel.isNearBottom)

            // Held-bash-command approval cards render INDEPENDENT of the composer gate:
            // a command can be held while the Supervisor browses a historical run
            // (`isReadOnly`, composer hidden), and the gate's await needs its
            // Allow/Deny UI to stay reachable. Self-hides when nothing is held.
            if let taskID = store.activeTaskID {
                BashApprovalCardList(taskID: taskID, roleDefinitions: roleDefinitions)
                    .padding(.horizontal, Spacing.s)
                ComputerUseApprovalCardList(taskID: taskID, roleDefinitions: roleDefinitions)
                    .padding(.horizontal, Spacing.s)
            }

            if shouldShowComposer, let taskID = store.activeTaskID {
                // Single unified input card. The "To:" menu lets the Supervisor choose
                // between answering the pending question, queuing for the team, or
                // queuing for a specific working role.
                TeamActivityComposer(
                    roleDefinitions: roleDefinitions,
                    taskID: taskID,
                    workingRoleIDs: workingRoleIDs,
                    failedRoleIDs: failedRoleIDs,
                    allowsRoleFallback: allowsRoleFallback,
                    activeQuestions: activeQuestionsForComposer,
                    maxHeight: paneHeight * 2 / 3
                )
                .background(Colors.surfaceCard)
            }

            if hasActionBarContent {
                ActivityFeedActionBar(
                    isFinalReviewStage: isFinalReviewStage,
                    rolesNeedingAcceptance: rolesNeedingAcceptance,
                    onSelectRole: onSelectRole,
                    onReviewTask: onReviewTask,
                    onAcceptRole: { roleID in
                        guard let taskID = store.activeTaskID else { return }
                        _ = await store.acceptRole(taskID: taskID, roleID: roleID)
                    },
                    onRequestChanges: { roleID in
                        revisionRoleID = roleID
                        revisionComment = ""
                        isShowingRevisionSheet = true
                    },
                    filterRoleID: filterRoleID,
                    supervisorReviewArtifacts: supervisorReviewArtifacts,
                    producedArtifacts: producedArtifacts
                )
            }

        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            paneHeight = newHeight
        }
        .onAppear {
            let context = buildContext()
            // Seed fingerprint + initial synchronous rebuild, then refresh artifact content async.
            viewModel.recomputeAndRebuild(context: context)
            Task {
                await viewModel.refreshAndRebuild(context: buildContext())
            }
        }
        .onChange(of: runDataVersion) { _, _ in
            viewModel.recomputeAndRebuild(context: buildContext())
        }
        .onChange(of: config.debugModeEnabled) { _, _ in
            Task { await viewModel.refreshAndRebuild(context: buildContext()) }
        }
        .onChange(of: filterRoleID) { _, _ in
            Task { await viewModel.refreshAndRebuild(context: buildContext()) }
        }
        // Composer visibility gates paired-message suppression. When the composer
        // hides (engine `.failed`, task closed, view enters read-only), the
        // previously-suppressed bubble must reappear in the feed — otherwise the
        // turn's `thinking` is lost with no card to surface it. (Its PROSE is
        // never at stake: since the suppression was narrowed to
        // `isFullyRenderedByQuestionCard`, only contentless turns are suppressed
        // at all — so this gate now covers reasoning-only turns, which is the
        // whole of what the card would have shown.) The fingerprint includes
        // `composerVisible`, so this onChange forces a rebuild even when no other
        // state changed (e.g. terminal `.running` → `.failed` with no new tool
        // calls / messages).
        .onChange(of: shouldShowComposer) { _, _ in
            viewModel.recomputeAndRebuild(context: buildContext())
        }
        .sheet(isPresented: $isShowingRevisionSheet) {
            RevisionSheet(
                roleName: revisionRoleName,
                comment: $revisionComment,
                isPresented: $isShowingRevisionSheet
            ) {
                if let roleID = revisionRoleID {
                    onRequestChanges?(roleID, revisionComment)
                }
            }
            // Re-inject — SwiftUI has historically dropped `@Observable`
            // environment values when presenting sheets on macOS.
            .environment(dictation)
        }
    }

    // MARK: - Timeline Scroll

    @ScaledMetric(relativeTo: .body) private var scrollButtonSize: CGFloat = 26

    /// Offset-based scroll position. The settle-scroll targets an EXACT `scrollTo(y:)`
    /// computed from live geometry (see `bottomTargetY`); `scrollTo(edge:.bottom)` is
    /// the fallback when no geometry tick has stashed a target yet (fresh task switch).
    /// Historical (LazyVStack era): an `id`-based scroll couldn't reach a sentinel
    /// pushed out of the lazy-realization window, and edge-scrolls overshot from the
    /// transient mid-commit content-size — the burst-resets below still gate every
    /// fire to AFTER a commit's spike→collapse settles.
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// The follow bookkeeping — last bottom target and distance, settle burst, pending settle
    /// and gate-release tasks. No body reads it, so it is a reference rather than `@State`
    /// values: the geometry action writes it on every tick, and a `@State` write schedules a
    /// transaction on the window whether or not anything reads it. The timing constants and
    /// the fire-time decision live there too.
    @State private var scrollFollow = ScrollFollowState()

    /// Top padding for one feed row — two tiers plus a zero.
    ///
    /// Items of one model turn hug; a row that opens a turn gets clear air.
    /// `showSectionHeader` needs no tier of its own: a role change IS a turn
    /// change (`ActivityFeedBuilder.continuesTurn` rejects it), and the header
    /// row supplies its own separation on top of the gap.
    ///
    /// Pinned by `ActivityFeedBuilderTests.testRowTopPadding_tiers`.
    static func rowTopPadding(isFirst: Bool, continuesTurn: Bool) -> CGFloat {
        if isFirst { return 0 }
        return continuesTurn
            ? ActivityCardTokens.turnHugSpacing
            : ActivityCardTokens.turnGapSpacing
    }

    /// The one thing the feed can honestly say between Send and the first token: the
    /// run's start is in flight.
    ///
    /// Deliberately NOT a `cachedTimelineItems` entry. That list is a pure projection of
    /// the TASK, replayed by `ConversationTranscriptRenderer` into
    /// `conversation_log.md` — a live spinner has no business in a transcript, and a
    /// timeline case would have to be filtered back out there. This is view state, so it
    /// renders as view state, from the observable fact and nothing else.
    ///
    /// It covers the window up to `engine.start()`. What follows — prompt assembly — is
    /// already answered by `MessageBubbleStreamingIndicator`, which claims `Processing…`
    /// on `beginStreaming`, i.e. BEFORE the request is sent and therefore across the
    /// whole model load.
    @ViewBuilder
    private var runInitializationRow: some View {
        if !isReadOnly, let taskID = store.activeTaskID,
           engineStateEnv.isInitializingRun(taskID) {
            MessageLoaderLabel(RunInitializationDisplay.caption)
                // The content column, not the pane edge: this reads as a status row of the
                // same family as `Thinking…` / `Processing…`, and those sit inside a
                // bubble's `HStack` past the avatar gutter. Without the inset it rendered a
                // full gutter to their left, which is what made it look like page furniture
                // instead of the run talking.
                .padding(.leading, ActivityCardTokens.contentColumnLeading)
                .padding(.top, Spacing.m)
                .transition(.opacity)
        }
    }

    private var timelineScrollView: some View {
        ScrollView {
            // NON-lazy on purpose (was LazyVStack — reverted 2026-07-07 after two
            // live blank-feed reproductions). LazyVStack ESTIMATES unrealized row
            // heights from the average of REALIZED ones; one >viewport realized row
            // (a long supervisor brief / LLM message) skews every estimate 4-12x
            // (trace: ~2200px/item vs ~186px real), and the bottom-pin's
            // `scrollTo(y:)` then parks the offset inside estimated "phantom" space
            // where no realized row exists → blank feed. From geometry alone that
            // state is indistinguishable from the user scrolling up (dist large
            // positive), so the follow gate releases and NOTHING recovers until a
            // manual scroll forces realization. A plain VStack realizes every row:
            // contentSize is always exact, phantom space cannot exist. Cost is
            // bounded: text shaping is memoized per (length, width) by
            // MessageTextLayoutCache, rows are Equatable-wrapped so streaming ticks
            // re-evaluate only the live bubble, and non-text rows are lineLimit-
            // capped cards. Pinned by TeamActivityFeedContainerInvariantTests.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.cachedTimelineItems) { tagged in
                    let topPadding = Self.rowTopPadding(
                        isFirst: tagged.id == viewModel.cachedTimelineItems.first?.id,
                        continuesTurn: tagged.continuesTurn
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        if let boundary = tagged.boundary {
                            // The band introduces the item, so the gap belongs
                            // ABOVE the band — otherwise the feed's single most
                            // significant structural transition would breathe
                            // less than an ordinary turn change.
                            TeamBoundaryBandView(boundary: boundary)
                                .padding(.top, topPadding)
                        }
                        timelineItemView(for: tagged.item, showHeader: tagged.showSectionHeader)
                            .padding(.top, tagged.boundary == nil ? topPadding : 0)
                    }
                }
                runInitializationRow
            }
            .padding(.top)
            .padding(.trailing)
            .padding(.leading, ActivityCardTokens.cardPadding)
            .padding(.bottom, Spacing.l)
            // Kill rubber-band scrolling on the feed's NSScrollView. Placed on
            // the content (not the ScrollView) so `enclosingScrollView` resolves.
            .background(ScrollBounceDisabler())
        }
        .scrollPosition($scrollPosition)
        // At-bottom detection + bottom-pin maintenance. `distanceFromBottom` SUBTRACTS
        // `contentInsets.top` (the ~79pt TeamBoardTopBar safe-area inset); at the true
        // bottom the corrected distance is 0. The `action` keeps the pin through
        // content growth (via `shouldFollowGrowth`) but DEFERS the actual scroll to
        // `requestSettleScroll()` — so it lands on the SETTLED height, never on a
        // transient mid-commit spike (the old overshoot). `isNearBottom` is the pin /
        // button gate; the deferred scroll re-checks it at fire time.
        .onScrollGeometryChange(for: TeamActivityFeedViewModel.ScrollFollowSnapshot.self) { geo in
            let distance = TeamActivityFeedViewModel.distanceFromBottom(
                contentHeight: geo.contentSize.height,
                bottomInset: geo.contentInsets.bottom,
                topInset: geo.contentInsets.top,
                containerHeight: geo.containerSize.height,
                contentOffsetY: geo.contentOffset.y
            )
            // The `y` to feed `scrollTo(y:)` so the feed lands where `dist == 0`.
            // NOT the resting offset: `scrollTo(y:)` undershoots its argument by the
            // top safe-area inset, so the target drops the `- insTop` term (see
            // `bottomTargetY`). Passing the resting offset directly was the bug —
            // every settle-scroll landed `insTop` short, leaving `dist == insTop`
            // above the gate threshold and latching auto-follow off. Computed here
            // (pure), stashed into `@State` from the action closure.
            let targetY = TeamActivityFeedViewModel.bottomTargetY(
                contentHeight: geo.contentSize.height,
                bottomInset: geo.contentInsets.bottom,
                containerHeight: geo.containerSize.height
            )
            return TeamActivityFeedViewModel.ScrollFollowSnapshot(
                distanceFromBottom: distance,
                contentHeight: geo.contentSize.height,
                bottomTargetY: targetY
            )
        } action: { old, new in
            // Stash the scroll-to-bottom target (= resting offset + insTop; see
            // `bottomTargetY`) and the distance the settle decides on. Written in the
            // ACTION, never the transform (that would be dropped as "state mutation during
            // view update") — and into `scrollFollow`, a reference, so this per-tick write
            // schedules no transaction.
            scrollFollow.lastBottomTargetY = new.bottomTargetY
            scrollFollow.lastDistanceFromBottom = new.distanceFromBottom
            // A content-growth-under-pinned-scroll tick keeps the pin; otherwise the
            // pin is recomputed from the (real-offset) geometry — that's where a
            // deliberate user scroll up/down flips it.
            let follow = TeamActivityFeedViewModel.shouldFollowGrowth(
                oldContentHeight: old.contentHeight,
                newContentHeight: new.contentHeight,
                oldDistanceFromBottom: old.distanceFromBottom,
                newDistanceFromBottom: new.distanceFromBottom,
                wasAtBottom: viewModel.isNearBottom
            )
            let nowNear = new.distanceFromBottom <= TeamActivityFeedViewModel.nearBottomThreshold
            if follow || nowNear {
                // Following growth, or back within the band → engage/keep the pin NOW.
                scrollFollow.gateReleaseTask?.cancel()
                scrollFollow.gateReleaseTask = nil
                if !viewModel.isNearBottom {
                    viewModel.isNearBottom = true
                }
            } else if viewModel.isNearBottom, scrollFollow.gateReleaseTask == nil {
                // dist > threshold and not a growth tick. This is EITHER a deliberate
                // scroll-up OR a transient layout-negotiation blip (e.g. a commit's
                // spike→collapse, or a settle-scroll briefly landing off). Debounce the
                // release so only a SUSTAINED departure drops follow — a blip that
                // recovers within the window is cancelled above by a near/growth tick.
                scrollFollow.gateReleaseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(ScrollFollowState.gateReleaseDelayMs))
                    guard !Task.isCancelled else { return }
                    scrollFollow.gateReleaseTask = nil
                    // Guarded: an `@Observable` setter notifies on every write, equal or not.
                    if viewModel.isNearBottom {
                        viewModel.isNearBottom = false
                    }
                }
            }
            // A SHRINK means we're inside a commit's spike→collapse oscillation (a fast
            // stream is monotonic). Reset the max-wait burst so this tick can only fire
            // on the QUIET settle (after the collapse), never via a mid-transient
            // force-fire — that mid-transient fire is what left the scroll past the
            // collapsed bottom (dist≈-550) until the next settle corrected it.
            if new.contentHeight < old.contentHeight { scrollFollow.settleBurstStart = nil }
            // Reschedule the deferred scroll on EVERY geometry change so it fires only
            // after the layout quiesces (the commit spike→collapse fully settles).
            requestSettleScroll()
        }
        .onChange(of: viewModel.timelineVersion) { _, _ in
            switch viewModel.consumeScrollAction() {
            case .jump:
                // Task switch: force the pin and place at the bottom once settled.
                viewModel.isNearBottom = true
                requestSettleScroll()
            case .animate:
                // New structural item while at bottom → settle-scroll (no-op if not pinned).
                requestSettleScroll()
            case nil:
                break
            }
        }
        // The rebuild bumps `timelineVersion`, so the onChange above is the
        // single rebuild-driven scroll site — no completion-scroll here.
        .onChange(of: streamingManager.structuralVersion) { _, _ in
            // A structural change (preview commit / new bubble) is the start of a content
            // glitch. Reset the max-wait burst so the follow can't force-fire mid-spike —
            // it waits for the QUIET settle after the spike→collapse, where the edge
            // content-size is correct (no overshoot).
            scrollFollow.settleBurstStart = nil
            viewModel.scheduleStructuralRebuild(context: buildContext())
        }
        .onChange(of: store.activeTaskID) { _, _ in
            // Cancels both pending tasks AND drops the stashed geometry: a target from the
            // previous task's feed must never be applied to this one.
            scrollFollow.resetForTaskSwitch()
            viewModel.resetForTaskSwitch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollFeedToBottom)) { _ in
            viewModel.isNearBottom = true
            requestSettleScroll()
        }
        .onDisappear {
            scrollFollow.cancelPending()
            viewModel.cancelStructuralRebuild()
        }
    }

    /// Coalesced bottom-follow. Every geometry tick (and the button / task-switch /
    /// notification surfaces) calls this; it reschedules a single scroll for
    /// `scrollSettleQuietMs` after the LAST tick — so a commit's spike→collapse burst
    /// collapses to ONE scroll — but never later than `scrollSettleMaxWaitMs` after the
    /// burst began, so FAST continuous streaming (no quiet window) still follows. A commit
    /// additionally resets the burst (geo-action shrink + the `structuralVersion` onChange),
    /// so the fire always lands AFTER the spike→collapse settles — where the content size is
    /// correct, so no overshoot. What the fire does is `ScrollFollowState.settleScroll`:
    /// the exact bottom offset from live geometry (not the edge, which lags), the edge only
    /// when no tick has stashed a target yet, and nothing at all when the feed already sits
    /// at its bottom — a `ScrollPosition` write is a transaction and a scroll commit even
    /// when it moves nothing.
    private func requestSettleScroll() {
        scrollFollow.scrollSettleTask?.cancel()
        let now = Date()
        let burstStart = scrollFollow.settleBurstStart ?? now
        scrollFollow.settleBurstStart = burstStart
        let delayMs = ScrollFollowState.settleDelayMs(now: now, burstStart: burstStart)
        scrollFollow.scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            scrollFollow.settleBurstStart = nil
            switch ScrollFollowState.settleScroll(
                isNearBottom: viewModel.isNearBottom,
                bottomTargetY: scrollFollow.lastBottomTargetY,
                distanceFromBottom: scrollFollow.lastDistanceFromBottom
            ) {
            case .toY(let targetY):
                scrollPosition.scrollTo(y: targetY)
            case .toBottomEdge:
                scrollPosition.scrollTo(edge: .bottom)
            case nil:
                break
            }
        }
    }

    private var scrollToBottomButton: some View {
        Button {
            viewModel.isNearBottom = true
            requestSettleScroll()
        } label: {
            Image(systemName: "chevron.down")
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textPrimary)
                .frame(width: scrollButtonSize, height: scrollButtonSize)
                .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceElevated))
                .overlay(RoundedRectangle.squircle(CornerRadius.small).strokeBorder(Colors.borderSubtle, lineWidth: 1))
                .shadow(.card)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to bottom")
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(Typography.term2xl)
                .foregroundStyle(Colors.textTertiary)
            Text("No activity yet")
                .font(Typography.subheadline)
                .foregroundStyle(Colors.textSecondary)
            if let taskID = store.activeTaskID {
                Button {
                    Task { await store.startRun(taskID: taskID) }
                } label: {
                    Label("Start Run", systemImage: "play")
                }
                .buttonStyle(.terminalPrimary)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Timeline Item Dispatcher

    private func avatarTap(for role: Role, originTaskID: Int) -> (() -> Void)? {
        guard let onSelectRole else { return nil }
        // Selection is scoped to the active team; tapping a child-team avatar
        // is a no-op (V1 — keyboard nav and selection stay on layer 0).
        guard let activeID = store.activeTaskID, activeID == originTaskID else { return nil }
        let resolvedID = findRoleDefinition(for: role, originTaskID: originTaskID)?.id ?? role.baseID
        return { onSelectRole(resolvedID) }
    }

    @ViewBuilder
    private func timelineItemView(for item: TeamActivityTimelineItem, showHeader: Bool) -> some View {
        switch item {
        case .llmMessage(let msg, let role, let stepID, let originTaskID):
            messageBubble(msg: msg, role: role, stepID: stepID, originTaskID: originTaskID, showHeader: showHeader)

        case .toolCall(let call, let role, let stepID, let originTaskID):
            ToolCallItemView(
                call: call, role: role,
                roleDefinition: findRoleDefinition(for: role, originTaskID: originTaskID),
                showHeader: showHeader,
                teamRoles: viewModel.roleDefinitionsByTaskID[originTaskID] ?? roleDefinitions,
                onAvatarTap: showHeader ? avatarTap(for: role, originTaskID: originTaskID) : nil,
                roleLabelOverride: childRoleLabel(for: role, originTaskID: originTaskID),
                roleTeamSuffix: childTeamSuffix(for: originTaskID),
                waitKey: TaskStepKey(taskID: originTaskID, stepID: stepID)
            )
            .equatable()

        case .artifact(let artifact, let role, _, let originTaskID):
            ArtifactItemView(
                artifact: artifact, role: role,
                roleDefinition: findRoleDefinition(for: role, originTaskID: originTaskID),
                showHeader: showHeader,
                originTaskID: originTaskID,
                workFolderURL: store.workFolderURL,
                onAvatarTap: showHeader ? avatarTap(for: role, originTaskID: originTaskID) : nil,
                roleLabelOverride: childRoleLabel(for: role, originTaskID: originTaskID),
                roleTeamSuffix: childTeamSuffix(for: originTaskID)
            )
            .equatable()

        case .meetingMessage(let msg, _, let originTaskID):
            MeetingMessageItemView(
                message: msg,
                roleDefinition: findRoleDefinition(for: msg.role, originTaskID: originTaskID),
                showHeader: showHeader,
                onAvatarTap: showHeader ? avatarTap(for: msg.role, originTaskID: originTaskID) : nil,
                roleLabelOverride: childRoleLabel(for: msg.role, originTaskID: originTaskID),
                roleTeamSuffix: childTeamSuffix(for: originTaskID)
            )
            .equatable()

        case .changeRequest(let request, let targetRoleName, _):
            ChangeRequestItemView(request: request, targetRoleName: targetRoleName)
                .equatable()

        case .notification(let stepID, let role, let type, _, _):
            NotificationItemView(
                stepID: stepID, role: role, type: type, isChatMode: isChatMode,
                workFolderURL: store.workFolderURL,
                isAutoAnswering: isAutonomousMode
            )

        case .supervisorTask(_, let taskCreatedAt, let taskText, let clips, let paths, let folderURL, let originTaskID):
            SupervisorTaskItemView(
                createdAt: taskCreatedAt,
                supervisorTask: taskText,
                clippedTexts: clips,
                attachmentPaths: paths,
                workFolderURL: folderURL,
                roleDefinition: findRoleDefinition(for: .supervisor, originTaskID: originTaskID),
                onAvatarTap: avatarTap(for: .supervisor, originTaskID: originTaskID)
            )
            .equatable()
        }
    }

    // MARK: - Message Bubble (streaming wrapper)

    private func messageBubble(msg: LLMMessage, role: Role, stepID: String, originTaskID: Int, showHeader: Bool) -> some View {
        // Read on the parent pass. `structuralVersion` — which this body observes through its
        // `onChange` key — moves when a stream begins or commits, so the flip reaches here and
        // becomes a new poll id below; within a stream the bubble's own poll reads live.
        let isStreaming = streamingManager.isStreaming(messageID: msg.id)
        // O(1) set membership. This used to call `resolveImplicitStreamTarget`,
        // which walks the step's whole conversation — once per rendered bubble,
        // inside a non-lazy `VStack`, i.e. Θ(M²) per body pass in chat mode. The
        // walk now happens once per step per rebuild in the view model; the ids
        // are globally unique UUIDs, so no per-task pool lookup is needed here.
        // `isPreviewTarget` stays live at the call site: it flips between
        // rebuilds, and freezing it into the set would lag the streaming →
        // committed transition by a tick.
        let isImplicitStreamTarget = !isStreaming
            && viewModel.implicitStreamTargetIDs.contains(msg.id)

        // Empty `.supervisorMessage` C4-race turns are filtered at
        // `ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage`, so every message renders
        // through this one slot; `LiveMessageBubble` keeps `MessageBubbleView` unconditional
        // inside it, so the streaming → committed flip never remounts `SelectableMessageText`.
        return LiveMessageBubble(
            message: msg,
            role: role,
            roleDefinition: findRoleDefinition(for: role, originTaskID: originTaskID),
            stepID: stepID,
            originTaskID: originTaskID,
            isImplicitStreamTarget: isImplicitStreamTarget,
            showHeader: showHeader,
            onAvatarTap: showHeader ? avatarTap(for: role, originTaskID: originTaskID) : nil,
            roleLabelOverride: childRoleLabel(for: role, originTaskID: originTaskID),
            roleTeamSuffix: childTeamSuffix(for: originTaskID),
            workFolderURL: store.workFolderURL,
            pollInterval: LiveMessageBubble.pollInterval(
                isStreaming: isStreaming,
                isResizing: resizeMonitor.isResizing,
                reduceMotion: reduceMotion
            )
        )
    }

}

