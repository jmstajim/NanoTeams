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

    /// Creates a `Binding` into `viewModel.expansion` for a given key path.
    private func expansionBinding<T>(_ keyPath: WritableKeyPath<TeamActivityFeedViewModel.ExpansionState, T>) -> Binding<T> {
        Binding(
            get: { viewModel.expansion[keyPath: keyPath] },
            set: { viewModel.expansion[keyPath: keyPath] = $0 }
        )
    }

    // MARK: - Change Detection

    /// Lightweight version hash derived from run data counts.
    /// Used by `onChange` to detect structural changes without expensive `Run` equality checks.
    /// Uses Hasher for collision resistance (simple sum is vulnerable to count swaps).
    /// Note: supervisor-question lifecycle changes (`needsSupervisorInput` / `supervisorAnswer`)
    /// don't bump this directly — invalidation rides on the subsequent `llmConversation` /
    /// `toolCalls` append after the role resumes. `TimelineFingerprint` independently
    /// includes `supervisorInputCount`, so the recompute does pick the answer up.
    private var runDataVersion: Int {
        guard let run else { return 0 }
        var hasher = Hasher()
        hasher.combine(run.steps.count)
        for step in run.steps {
            hasher.combine(step.llmConversation.count)
            hasher.combine(step.toolCalls.count)
            hasher.combine(step.artifacts.count)
        }
        for meeting in run.meetings { hasher.combine(meeting.messages.count) }
        hasher.combine(run.changeRequests.count)
        return hasher.finalize()
    }

    /// Builds a `BuildContext` snapshot from current environment values.
    /// Called at every VM orchestration entry point so the VM never holds environment references.
    private func buildContext() -> TeamActivityFeedViewModel.BuildContext {
        let task = store.activeTask
        return TeamActivityFeedViewModel.BuildContext(
            run: run,
            roleDefinitions: roleDefinitions,
            filterRoleID: filterRoleID,
            activeTaskID: store.activeTaskID,
            supervisorBrief: task?.effectiveSupervisorBrief,
            supervisorBriefDate: task?.createdAt,
            supervisorTask: task?.supervisorTask,
            supervisorClippedTexts: task?.clippedTexts ?? [],
            supervisorAttachmentPaths: task?.attachmentPaths ?? [],
            supervisorProjectFolderURL: store.workFolderURL,
            workFolderURL: store.workFolderURL,
            debugModeEnabled: config.debugModeEnabled,
            thinkingExpandedByDefault: config.thinkingExpandedByDefault,
            toolCallsExpandedByDefault: config.toolCallsExpandedByDefault,
            artifactsExpandedByDefault: config.artifactsExpandedByDefault,
            isStreaming: { streamingManager.isStreaming(messageID: $0) }
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
                question: q.question
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

    private func findRoleDefinition(for role: Role) -> TeamRoleDefinition? {
        let baseID = role.baseID
        if let def = roleDefinitions.first(where: { $0.id == baseID }) { return def }
        return roleDefinitions.first(where: { $0.systemRoleID == baseID || $0.name == baseID })
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
                    timelineItemView(for: tagged.item, showHeader: tagged.showSectionHeader)
                        .padding(.top, topPadding)
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
            expansionControls
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, filterRoleID != nil ? Spacing.xs : Spacing.s)
        .background(Colors.surfaceCard)
    }

    private var expansionControls: some View {
        ActivityFeedExpansionControls(
            thinkingExpanded: Bindable(config).thinkingExpandedByDefault,
            toolCallsExpanded: Bindable(config).toolCallsExpandedByDefault,
            artifactsExpanded: Bindable(config).artifactsExpandedByDefault,
            debugEnabled: Bindable(config).debugModeEnabled,
            onThinkingToggle: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.applyExpansionToAll(thinking: config.thinkingExpandedByDefault, workFolderURL: store.workFolderURL)
                }
            },
            onToolCallsToggle: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.applyExpansionToAll(toolCalls: config.toolCallsExpandedByDefault, workFolderURL: store.workFolderURL)
                }
            },
            onArtifactsToggle: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.applyExpansionToAll(artifacts: config.artifactsExpandedByDefault, workFolderURL: store.workFolderURL)
                }
            },
            onDebugToggle: { }
        )
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

    private func avatarTap(for role: Role) -> (() -> Void)? {
        guard let onSelectRole else { return nil }
        let resolvedID = findRoleDefinition(for: role)?.id ?? role.baseID
        return { onSelectRole(resolvedID) }
    }

    @ViewBuilder
    private func timelineItemView(for item: TeamActivityTimelineItem, showHeader: Bool) -> some View {
        switch item {
        case .llmMessage(let msg, let role, let stepID):
            messageBubble(msg: msg, role: role, stepID: stepID, showHeader: showHeader)

        case .toolCall(let call, let role, _):
            ToolCallItemView(
                call: call, role: role,
                roleDefinition: findRoleDefinition(for: role),
                showHeader: showHeader,
                teamRoles: roleDefinitions,
                onAvatarTap: showHeader ? avatarTap(for: role) : nil,
                toolCallsExpanded: expansionBinding(\.toolCalls)
            )

        case .artifact(let artifact, let role, _):
            ArtifactItemView(
                artifact: artifact, role: role,
                roleDefinition: findRoleDefinition(for: role),
                showHeader: showHeader,
                content: viewModel.artifactContentCache[artifact.id],
                workFolderURL: store.workFolderURL,
                onAvatarTap: showHeader ? avatarTap(for: role) : nil,
                artifactsExpanded: expansionBinding(\.artifacts),
                onExpand: { art in viewModel.loadArtifactContentIfNeeded(art, workFolderURL: store.workFolderURL) }
            )

        case .meetingMessage(let msg, _):
            MeetingMessageItemView(
                message: msg,
                roleDefinition: findRoleDefinition(for: msg.role),
                showHeader: showHeader,
                onAvatarTap: showHeader ? avatarTap(for: msg.role) : nil,
                meetingThinkingExpanded: expansionBinding(\.meetingThinking),
                meetingToolsExpanded: expansionBinding(\.meetingTools)
            )

        case .changeRequest(let request, let targetRoleName):
            ChangeRequestItemView(request: request, targetRoleName: targetRoleName)

        case .notification(let stepID, let role, let type, _):
            let answerBinding = Binding<String>(
                get: { viewModel.supervisorAnswerText[stepID] ?? "" },
                set: { viewModel.supervisorAnswerText[stepID] = $0 }
            )
            let attachmentsBinding = Binding<[StagedAttachment]>(
                get: { viewModel.supervisorAnswerAttachments[stepID] ?? [] },
                set: { viewModel.supervisorAnswerAttachments[stepID] = $0 }
            )
            NotificationItemView(
                stepID: stepID, role: role, type: type, isChatMode: isChatMode,
                workFolderURL: store.workFolderURL,
                thinkingExpanded: expansionBinding(\.thinking),
                answerText: answerBinding,
                answerAttachments: attachmentsBinding,
                isSubmittingAnswer: viewModel.isSubmittingAnswer.contains(stepID),
                isAutoAnswering: isAutonomousMode,
                onSubmitAnswer: { viewModel.submitSupervisorAnswer(stepID: stepID, store: store, embedFiles: config.embedFilesInPrompt) },
                onStageAttachment: { url in
                    let draftUUID = UUID()
                    return store.stageAttachment(url: url, draftID: draftUUID)
                },
                onRemoveAttachment: { attachment in
                    store.removeStagedAttachment(attachment)
                }
            )

        case .supervisorTask(_, let taskCreatedAt, let taskText, let clips, let paths, let folderURL):
            SupervisorTaskItemView(
                createdAt: taskCreatedAt,
                supervisorTask: taskText,
                clippedTexts: clips,
                attachmentPaths: paths,
                workFolderURL: folderURL,
                onAvatarTap: avatarTap(for: .supervisor)
            )
        }
    }

    // MARK: - Message Bubble (streaming wrapper)

    @ViewBuilder
    private func messageBubble(msg: LLMMessage, role: Role, stepID: String, showHeader: Bool) -> some View {
        let isStreaming = streamingManager.isStreaming(messageID: msg.id)
        let tap = showHeader ? avatarTap(for: role) : nil

        if isStreaming {
            TimelineView(.periodic(from: .now, by: reduceMotion ? 1.0 : 0.15)) { _ in
                MessageBubbleView(
                    message: msg, role: role,
                    roleDefinition: findRoleDefinition(for: role),
                    content: streamingManager.streamingContent(for: stepID) ?? "",
                    thinking: streamingManager.streamingThinking(for: stepID),
                    processingProgress: streamingManager.processingProgress[stepID],
                    isStreaming: true,
                    showHeader: showHeader,
                    thinkingExpandedByDefault: config.thinkingExpandedByDefault,
                    onAvatarTap: tap,
                    thinkingExpanded: expansionBinding(\.thinking)
                )
            }
        } else {
            MessageBubbleView(
                message: msg, role: role,
                roleDefinition: findRoleDefinition(for: role),
                // `displayContent` strips the "Supervisor:\n" header for
                // supervisor-injected turns — the role name is already in the
                // bubble header, so the prefix would duplicate attribution.
                content: msg.displayContent,
                thinking: msg.thinking,
                processingProgress: nil,
                isStreaming: false,
                showHeader: showHeader,
                thinkingExpandedByDefault: config.thinkingExpandedByDefault,
                onAvatarTap: tap,
                thinkingExpanded: expansionBinding(\.thinking)
            )
        }
    }
}

