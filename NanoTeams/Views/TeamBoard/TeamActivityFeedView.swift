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
        Self.computeRunDataVersion(run: run, descendants: resolvedDescendantTasks())
    }

    /// Pure implementation of `runDataVersion` — extracted so it's testable
    /// without instantiating the view. Pinned by
    /// `TeamActivityFeedLogicTests.testComputeRunDataVersion_*`:
    /// must respond to `step.needsSupervisorInput` flipping. The engine's
    /// escalation path (`setNeedsSupervisorInput` from drift/refusal/parse-
    /// failure caps in `LLMExecutionService+StepFlowControl.swift`) flips the
    /// flag without appending a tool call or LLM message — so a hash that only
    /// walked counts left `recomputeAndRebuild` un-triggered and the user had
    /// to switch tasks to force a fresh view rebuild.
    static func computeRunDataVersion(
        run: Run?,
        descendants: [ActivityFeedBuilder.DescendantTask]
    ) -> Int {
        var hasher = Hasher()
        if let run {
            hasher.combine(run.steps.count)
            for step in run.steps {
                hasher.combine(step.llmConversation.count)
                hasher.combine(step.toolCalls.count)
                hasher.combine(step.artifacts.count)
                hasher.combine(step.needsSupervisorInput)
                hasher.combine(step.status)
            }
            for meeting in run.meetings { hasher.combine(meeting.messages.count) }
            hasher.combine(run.changeRequests.count)
        }
        // Fold in descendant runs so child progress triggers rebuilds.
        for descendant in descendants {
            hasher.combine(descendant.task.id)
            hasher.combine(descendant.run.steps.count)
            for step in descendant.run.steps {
                hasher.combine(step.llmConversation.count)
                hasher.combine(step.toolCalls.count)
                hasher.combine(step.artifacts.count)
                hasher.combine(step.needsSupervisorInput)
                hasher.combine(step.status)
            }
            for meeting in descendant.run.meetings { hasher.combine(meeting.messages.count) }
            hasher.combine(descendant.run.changeRequests.count)
        }
        return hasher.finalize()
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

    /// Composer visibility policy. Chat-mode tasks keep the composer alive
    /// until the engine is genuinely failed or the task is closed — advisory
    /// roles never self-terminate, and engine state may transiently sit at
    /// `.done` after restart while the task is still meant to accept input.
    /// Non-chat tasks gate on engine state (`.done`/`.failed`/`nil` → hide).
    static func shouldShowComposer(
        isReadOnly: Bool,
        activeTaskID: Int?,
        closedAt: Date?,
        isChatMode: Bool,
        engineState: TeamEngineState?
    ) -> Bool {
        if isReadOnly { return false }
        guard activeTaskID != nil else { return false }
        guard closedAt == nil else { return false }
        if engineState == .failed { return false }
        if isChatMode { return true }
        switch engineState {
        case .done, nil: return false
        default:         return true
        }
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
            feedHeader
            Divider()

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
            }
            .frame(maxHeight: .infinity)

            if shouldShowComposer, let taskID = store.activeTaskID {
                // Single unified input card. The "To:" menu lets the Supervisor choose
                // between answering the pending question, queuing for the team, or
                // queuing for a specific working role.
                TeamActivityComposer(
                    roleDefinitions: roleDefinitions,
                    isChatMode: isChatMode,
                    taskID: taskID,
                    workingRoleIDs: workingRoleIDs,
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
                Color.clear.frame(height: 1).id("bottom")
                    .onAppear { viewModel.isNearBottom = true }
                    .onDisappear { viewModel.isNearBottom = false }
            }
            .padding()
            .padding(.bottom, Spacing.l)
        }
        .scrollPosition($scrollPosition)
        .onChange(of: viewModel.timelineVersion) { _, _ in
            if viewModel.needsScrollToBottom {
                viewModel.needsScrollToBottom = false
                scrollPosition.scrollTo(edge: .bottom)
            } else if viewModel.isNearBottom {
                withAnimation { scrollPosition.scrollTo(edge: .bottom) }
            }
        }
        .onChange(of: streamingManager.structuralVersion) { _, _ in
            viewModel.scheduleStructuralRebuild(context: buildContext()) {
                if viewModel.isNearBottom {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
        }
        .onChange(of: store.activeTaskID) { _, _ in
            viewModel.resetForTaskSwitch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollFeedToBottom)) { _ in
            withAnimation { scrollPosition.scrollTo(edge: .bottom) }
        }
        .onDisappear { viewModel.cancelStructuralRebuild() }
    }

    // MARK: - Header

    private var feedHeader: some View {
        HStack(spacing: Spacing.s) {
            if filterRoleID == nil {
                teamHeaderMenu
            }
            Spacer()
            debugToggle
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, filterRoleID != nil ? Spacing.xs : Spacing.s)
        .background(Colors.surfaceCard)
    }

    /// Debug-mode toggle (the only header control left after the inline expand
    /// buttons were removed in favor of standalone-window detail viewers).
    private var debugToggle: some View {
        @Bindable var config = config
        return Button {
            config.debugModeEnabled.toggle()
        } label: {
            Image(systemName: config.debugModeEnabled ? "ladybug.fill" : "ladybug")
                .font(.caption)
                .foregroundStyle(config.debugModeEnabled ? Colors.warning : Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .help(config.debugModeEnabled ? "Hide debug info (input & artifacts)" : "Show debug info (input & artifacts)")
    }

    // MARK: - Team Header Menu

    private var teamHeaderMenu: some View {
        // Hide the Generated Team placeholder — users pick it via the
        // dedicated "Generate Team..." entry in QuickCapture.
        let teams = (store.snapshot?.workFolder.teams ?? []).filter { $0.templateID != "generated" }
        let activeTeam = store.resolvedTeam(for: store.activeTask)
        return Menu {
            ForEach(teams) { team in
                Button {
                    Task { await store.switchTeam(to: team.id) }
                } label: {
                    HStack {
                        if team.id == activeTeam.id {
                            Image(systemName: "checkmark")
                        }
                        Text(team.name)
                        Text("(\(team.memberCount) members)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            Text(activeTeam.name)
                .font(Typography.subheadlineSemibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No activity yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let taskID = store.activeTaskID {
                Button {
                    Task { await store.startRun(taskID: taskID) }
                } label: {
                    Label("Start Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
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
            allSteps: viewModel.cachedAllSteps
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
            let snapshot = StreamingSnapshot(
                isStreaming: streamingManager.isStreaming(messageID: msg.id),
                content: streamingManager.streamingContent(for: stepID),
                thinking: streamingManager.streamingThinking(for: stepID),
                processingProgress: streamingManager.processingProgress[stepID],
                hasStreamActivity: streamingManager.hasReceivedStreamActivity(for: stepID)
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

    /// Visible-message filter mirrors `ActivityFeedBuilder.emitItems` —
    /// pinned by `testReturnsTrue_whenLatestVisibleMessage_evenIfToolTurnHasLaterTimestamp`.
    static func resolveImplicitStreamTarget(
        stepID: String,
        messageID: UUID,
        isPreviewTarget: Bool,
        allSteps: [StepExecution]
    ) -> Bool {
        if isPreviewTarget { return false }
        guard let step = allSteps.first(where: { $0.id == stepID }) else { return false }
        guard step.status == .running else { return false }
        let visible = step.llmConversation.filter { $0.role != .system && $0.role != .tool }
        guard let latest = visible.max(by: { $0.createdAt < $1.createdAt }) else { return false }
        return latest.id == messageID
    }

    // MARK: - Bubble inputs (testable resolver)

    /// Per-tick inputs for `MessageBubbleView`. The two cases mirror the
    /// two states the dispatcher resolves:
    /// - `.streaming` carries content/thinking + progress indicators; never
    ///   carries attachments (those belong to the committed turn only).
    /// - `.committed` carries content/thinking + attachments/clips; never
    ///   carries `processingProgress` or `hasStreamActivity`.
    /// The discriminated union prevents illegal cross-mode field leakage
    /// at compile time (no "streaming bubble with attachments").
    enum BubbleInputs: Equatable {
        case streaming(
            content: String,
            thinking: String?,
            processingProgress: Double?,
            hasStreamActivity: Bool
        )
        case committed(
            content: String,
            thinking: String?,
            attachmentPaths: [String],
            clippedTexts: [String]
        )

        var isStreaming: Bool {
            if case .streaming = self { return true }
            return false
        }

        // Case-derived accessors so `MessageBubbleView` has one call site.
        // Streaming-only fields return their genuine empty value when the
        // committed case is asked, and vice versa — never a sentinel.
        var contentForBubble: String {
            switch self {
            case .streaming(let c, _, _, _): return c
            case .committed(let c, _, _, _): return c
            }
        }

        var thinkingForBubble: String? {
            switch self {
            case .streaming(_, let t, _, _): return t
            case .committed(_, let t, _, _): return t
            }
        }

        var processingProgress: Double? {
            switch self {
            case .streaming(_, _, let p, _): return p
            case .committed: return nil
            }
        }

        var hasStreamActivity: Bool {
            switch self {
            case .streaming(_, _, _, let a): return a
            case .committed: return false
            }
        }

        var attachmentPaths: [String] {
            switch self {
            case .streaming: return []
            case .committed(_, _, let p, _): return p
            }
        }

        var clippedTexts: [String] {
            switch self {
            case .streaming: return []
            case .committed(_, _, _, let c): return c
            }
        }
    }

    /// Pure snapshot of streaming state passed into the static resolver,
    /// so tests don't need to touch `StreamingPreviewManager`.
    struct StreamingSnapshot: Equatable {
        let isStreaming: Bool
        let content: String?
        let thinking: String?
        let processingProgress: Double?
        let hasStreamActivity: Bool
    }

    /// Adaptive `TimelineSchedule`:
    /// - Streaming: emits at `streamingInterval` (3.3 Hz at 0.3s). Hot
    ///   path drives `MessageBubbleView` re-evaluation so token deltas
    ///   from `StreamingPreviewManager` (which is `@ObservationIgnored`)
    ///   propagate to the bubble.
    /// - Committed: emits exactly one entry, then terminates — no timer
    ///   heartbeat. Body re-evaluations come from parent state changes.
    ///
    /// Single concrete schedule type means a single `TimelineView` generic
    /// across both states, which preserves SwiftUI structural identity at
    /// the streaming → committed transition. `Equatable` synthesis lets
    /// SwiftUI's view diff fast-path skip TimelineView re-arming when
    /// neither field changed.
    struct BubbleSchedule: TimelineSchedule, Equatable {
        let isStreaming: Bool
        let streamingInterval: TimeInterval

        func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
            Entries(
                startDate: startDate,
                isStreaming: isStreaming,
                interval: streamingInterval
            )
        }

        nonisolated struct Entries: Sequence, IteratorProtocol {
            let startDate: Date
            let isStreaming: Bool
            let interval: TimeInterval
            var iteration: Int = 0

            mutating func next() -> Date? {
                guard isStreaming else {
                    // Committed bubbles emit exactly one entry, then end.
                    if iteration == 0 {
                        iteration = 1
                        return startDate
                    }
                    return nil
                }
                let entry = startDate.addingTimeInterval(Double(iteration) * interval)
                iteration += 1
                return entry
            }
        }
    }

    /// Resolves a per-tick `BubbleInputs` from `(msg, streaming snapshot)`.
    /// Static + injectable snapshot so it's callable from XCTest.
    ///
    /// For `.supervisorMessage` turns (queued chat delivery +
    /// `forward_to_team` injections — both producers tag with the same
    /// context), strips the embedded `## Attached Files` /
    /// `## Clipped Text` markers and surfaces their payloads as
    /// thumbnail cards via the same `ReadOnlyAttachmentGrid` used by
    /// `SupervisorTaskItemView` and `SupervisorInputCard`. Order
    /// matters: `displayContent` first strips the leading
    /// `Supervisor:\n` attribution prefix, then `stripAttachedFiles`
    /// Streaming tick interval for `BubbleSchedule`. Three-way table:
    ///
    /// | isResizing | reduceMotion | interval                  | rationale |
    /// |------------|--------------|---------------------------|-----------|
    /// | true       | any          | `.greatestFiniteMagnitude`| Freeze: TimelineView arm preserved (structural identity invariant) but no new ticks fire while the user drags the window. |
    /// | false      | true         | 1.0                       | Slower tick (1 Hz) for users with Reduce Motion — visible streaming progress without churn. |
    /// | false      | false        | 0.3                       | Default 3.3 Hz heartbeat — fast enough that token deltas feel live, slow enough to avoid LazyVStack thrash. |
    ///
    /// `nonisolated` because the math is pure — tests pin the truth table
    /// without instantiating the view. Pinned by `StreamingIntervalResolverTests`.
    nonisolated static func resolveStreamingInterval(
        isResizing: Bool,
        reduceMotion: Bool
    ) -> TimeInterval {
        if isResizing { return .greatestFiniteMagnitude }
        return reduceMotion ? 1.0 : 0.3
    }

    /// scans the remainder for marker sections.
    static func resolveBubbleInputs(msg: LLMMessage, streaming: StreamingSnapshot) -> BubbleInputs {
        if streaming.isStreaming {
            return .streaming(
                content: streaming.content ?? "",
                thinking: streaming.thinking,
                processingProgress: streaming.processingProgress,
                hasStreamActivity: streaming.hasStreamActivity
            )
        }
        let isSupervisorMsg = msg.sourceContext == .supervisorMessage
        let inputs = ActivityFeedBuilder.bubbleDisplayInputs(
            raw: msg.displayContent,
            isSupervisorMessage: isSupervisorMsg
        )
        return .committed(
            content: inputs.text,
            thinking: msg.thinking,
            attachmentPaths: inputs.paths,
            clippedTexts: inputs.clippedTexts
        )
    }
}

