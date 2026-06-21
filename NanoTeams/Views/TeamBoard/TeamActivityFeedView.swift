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
        let tasksByID: [Int: NTMSTask] = Dictionary(
            uniqueKeysWithValues: store.allLoadedTasksIncludingChildren.map { ($0.id, $0) }
        )
        return ActivityFeedBuilder.resolveRunScopedDescendants(
            displayedRun: run,
            tasksByID: tasksByID,
            resolveTeam: { store.resolvedTeam(for: $0) }
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
            supervisorClippedTexts: task?.clippedTexts ?? [],
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
        viewModel.cachedSupervisorQuestions.map { q in
            TeamActivityActiveQuestion(
                stepID: q.stepID,
                role: q.role,
                question: q.question,
                paired: q.paired
            )
        }
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
        let baseID = role.baseID
        let roster = viewModel.roleDefinitionsByTaskID[originTaskID] ?? roleDefinitions
        if let def = roster.first(where: { $0.id == baseID }) { return def }
        return roster.first(where: { $0.systemRoleID == baseID || $0.name == baseID })
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

            if shouldShowComposer, let taskID = store.activeTaskID {
                // Single unified input card. The "To:" menu lets the Supervisor choose
                // between answering the pending question, queuing for the team, or
                // queuing for a specific working role.
                TeamActivityComposer(
                    roleDefinitions: roleDefinitions,
                    isChatMode: isChatMode,
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
        // LLM's `ask_supervisor`-paired reply is lost (no composer to surface it).
        // The fingerprint includes `composerVisible`, so this onChange forces a
        // rebuild even when no other state changed (e.g. terminal `.running` →
        // `.failed` with no new tool calls / messages).
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

    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @ScaledMetric(relativeTo: .body) private var scrollButtonSize: CGFloat = 26

    private var timelineScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.cachedTimelineItems) { tagged in
                    let isFirst = tagged.id == viewModel.cachedTimelineItems.first?.id
                    let isToolCall: Bool = {
                        if case .toolCall = tagged.item { return true }
                        return false
                    }()
                    let topPadding: CGFloat = isFirst ? 0
                        : tagged.showSectionHeader ? Spacing.s
                        : isToolCall ? 2
                        : Spacing.xs
                    VStack(alignment: .leading, spacing: 0) {
                        if let boundary = tagged.boundary {
                            TeamBoundaryBandView(boundary: boundary)
                        }
                        timelineItemView(for: tagged.item, showHeader: tagged.showSectionHeader)
                            .padding(.top, tagged.boundary == nil ? topPadding : 0)
                    }
                }
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
        // Geometry-based at-bottom detection + content-growth follow.
        //
        // `distanceFromBottom` SUBTRACTS `contentInsets.top`. The feed sits under a
        // ~79pt safe-area top bar (TeamBoardTopBar, added in the REDESIGN). A top
        // inset shifts the resting bottom content-offset down by exactly its own
        // height, so WITHOUT the `- insetTop` term the distance reads ~79 even when
        // the scroll is at the TRUE bottom — permanently above the 60pt threshold.
        // `isNearBottom` then latched false, which gated out every auto-scroll
        // (`shouldFollowGrowth` needs `wasAtBottom`) and pinned the button on. Live
        // geometry traces confirmed the invariant: at the resting bottom,
        // `contentH + insetBottom - containerH - offsetY == insetTop`, i.e. the
        // corrected distance is 0. (The earlier `.defaultScrollAnchor` attempt was
        // inert — the offset stayed frozen because the scroll never read as "at the
        // anchor"; removing it also restores top-alignment for short content.)
        .onScrollGeometryChange(for: TeamActivityFeedViewModel.ScrollFollowSnapshot.self) { geo in
            // Distance via the shared SSOT helper — production and the pinned tests
            // use the SAME formula, so a future tweak can't silently diverge.
            TeamActivityFeedViewModel.ScrollFollowSnapshot(
                distanceFromBottom: TeamActivityFeedViewModel.distanceFromBottom(
                    contentHeight: geo.contentSize.height,
                    bottomInset: geo.contentInsets.bottom,
                    topInset: geo.contentInsets.top,
                    containerHeight: geo.containerSize.height,
                    contentOffsetY: geo.contentOffset.y
                ),
                contentHeight: geo.contentSize.height
            )
        } action: { old, new in
            // Re-pin ONLY for a content-growth tick under a still-pinned scroll.
            // `shouldFollowGrowth` compares the distance delta against the content
            // growth, so a user dragging up DURING streaming (distance grows by MORE
            // than the content did) falls through to the gate recompute below and is
            // never yanked back to the bottom.
            if TeamActivityFeedViewModel.shouldFollowGrowth(
                oldContentHeight: old.contentHeight,
                newContentHeight: new.contentHeight,
                oldDistanceFromBottom: old.distanceFromBottom,
                newDistanceFromBottom: new.distanceFromBottom,
                wasAtBottom: viewModel.isNearBottom
            ) {
                scrollPosition.scrollTo(edge: .bottom)
                return
            }
            // Pure offset change (real user scroll, or the settle tick after a
            // re-pin) → recompute the gate.
            viewModel.isNearBottom =
                new.distanceFromBottom <= TeamActivityFeedViewModel.nearBottomThreshold
        }
        .onChange(of: viewModel.timelineVersion) { _, _ in
            switch viewModel.consumeScrollAction() {
            case .jump: scrollPosition.scrollTo(edge: .bottom)
            case .animate: scrollToBottomAnimated()
            case nil: break
            }
        }
        // The rebuild bumps `timelineVersion`, so the onChange above is the
        // single scroll site — no completion-scroll here (it would double-fire).
        .onChange(of: streamingManager.structuralVersion) { _, _ in
            viewModel.scheduleStructuralRebuild(context: buildContext())
        }
        .onChange(of: store.activeTaskID) { _, _ in
            viewModel.resetForTaskSwitch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollFeedToBottom)) { _ in
            scrollToBottomAnimated()
        }
        .onDisappear { viewModel.cancelStructuralRebuild() }
    }

    /// Smooth (non-bouncy) scroll to the bottom edge; also re-establishes the
    /// `ScrollPosition` bottom-edge association so the feed resumes following
    /// per-token content growth while streaming.
    private func scrollToBottomAnimated() {
        withAnimation(reduceMotion ? Animations.reducedMotion : Animations.smooth) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private var scrollToBottomButton: some View {
        Button {
            scrollToBottomAnimated()
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

        case .toolCall(let call, let role, _, let originTaskID):
            ToolCallItemView(
                call: call, role: role,
                roleDefinition: findRoleDefinition(for: role, originTaskID: originTaskID),
                showHeader: showHeader,
                teamRoles: viewModel.roleDefinitionsByTaskID[originTaskID] ?? roleDefinitions,
                onAvatarTap: showHeader ? avatarTap(for: role, originTaskID: originTaskID) : nil,
                roleLabelOverride: childRoleLabel(for: role, originTaskID: originTaskID),
                roleTeamSuffix: childTeamSuffix(for: originTaskID)
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
                onAvatarTap: avatarTap(for: .supervisor, originTaskID: originTaskID)
            )
            .equatable()
        }
    }

    // MARK: - Message Bubble (streaming wrapper)

    @ViewBuilder
    private func messageBubble(msg: LLMMessage, role: Role, stepID: String, originTaskID: Int, showHeader: Bool) -> some View {
        // Hoisted outside the TimelineView closure — these don't change per
        // tick. Pulling them inside would re-walk role/team lookups at 3.3Hz.
        let tap = showHeader ? avatarTap(for: role, originTaskID: originTaskID) : nil
        let labelOverride = childRoleLabel(for: role, originTaskID: originTaskID)
        let teamSuffix = childTeamSuffix(for: originTaskID)
        let resolvedDef = findRoleDefinition(for: role, originTaskID: originTaskID)
        // Schedule re-arms only on parent body re-eval; capture-at-parent
        // is correct here. The per-tick `snapshot.isStreaming` below reads
        // live so the streaming → committed transition doesn't lag behind
        // `streamingManager.commit` for up to one tick.
        let scheduleIsStreaming = streamingManager.isStreaming(messageID: msg.id)
        // Hoisted outside the TimelineView for the same reason as
        // `scheduleIsStreaming`: a per-bubble value invariant across heartbeat
        // ticks; recomputed on parent body re-eval via `runDataVersion`.
        let isImplicitStreamTarget = Self.resolveImplicitStreamTarget(
            stepID: stepID,
            messageID: msg.id,
            isPreviewTarget: scheduleIsStreaming,
            // The OWNING task's pool — stepID equals the role ID and is shared
            // across same-team tasks, so a descendant bubble resolved against the
            // active task's steps would match the WRONG task's step.
            allSteps: viewModel.steps(forOriginTaskID: originTaskID)
        )
        // During NSWindow live-resize, stretch the streaming heartbeat to
        // effectively infinity so the TimelineView arm is preserved (per
        // the structural-identity invariant documented below) but no new
        // ticks are queued. Per-bubble width re-measure via
        // `SelectableMessageText.sizeThatFits` still runs on every resize
        // delta, but the bubble's content snapshot stays frozen — no
        // streaming churn compounding the resize cost.
        let streamingInterval = Self.resolveStreamingInterval(
            isResizing: resizeMonitor.isResizing,
            reduceMotion: reduceMotion
        )
        let schedule = BubbleSchedule(
            isStreaming: scheduleIsStreaming,
            streamingInterval: streamingInterval
        )

        // Empty `.supervisorMessage` C4-race turns are filtered at
        // `ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage` so the
        // dispatcher renders one structural slot — `MessageBubbleView` —
        // unconditionally. Crossing two `_ConditionalContent` arms would
        // remount `SelectableMessageText` on the streaming → committed flip
        // and defeat the append-only optimization.
        TimelineView(schedule) { _ in
            let snapshot = Self.makeStreamingSnapshot(
                manager: streamingManager,
                messageID: msg.id,
                stepID: stepID,
                taskID: originTaskID
            )
            let inputs = Self.resolveBubbleInputs(msg: msg, streaming: snapshot)
            // `.equatable()` applied unconditionally rather than gated on
            // `inputs.isStreaming`. Reason: gating would require a
            // `_ConditionalContent` branch around the bubble, which would
            // remount `SelectableMessageText` on the streaming → committed
            // flip and defeat the append-only optimization (see the
            // structural-identity comment above). The cost of an extra
            // `==` per streaming tick is a handful of string compares;
            // the cost of remounting NSTextView is full TextKit re-shape.
            // For committed bubbles `==` returns true and SwiftUI skips
            // the entire subtree — the actual goal of this change.
            MessageBubbleView(
                message: msg, role: role,
                roleDefinition: resolvedDef,
                content: inputs.contentForBubble,
                thinking: inputs.thinkingForBubble,
                processingProgress: inputs.processingProgress,
                hasStreamActivity: inputs.hasStreamActivity,
                isStreamingToolCall: inputs.isStreamingToolCall,
                isStreaming: inputs.isStreaming,
                isImplicitStreamTarget: isImplicitStreamTarget,
                showHeader: showHeader,
                onAvatarTap: tap,
                roleLabelOverride: labelOverride,
                roleTeamSuffix: teamSuffix,
                attachmentPaths: inputs.attachmentPaths,
                clippedTexts: inputs.clippedTexts,
                workFolderURL: store.workFolderURL
            )
            .equatable()
        }
    }

}

