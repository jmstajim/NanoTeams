import SwiftUI

/// What the External Autovisor pane draws: the server and its agents, a banner per agent whose
/// tasks wait while it is offline, the agent's tasks, and the activity log. Pure — every fact
/// comes in as `ExternalAutovisorPanePresentation`, every action goes out as a closure.
///
/// The activity log is a terminal transcript, one line per call — `glyph title → result · #N ·
/// time` — in one card, in the shape of `ToolCallItemView`'s command line. It was a card per
/// call with a 13pt title, a subtitle that repeated the title and a chevron that opened the
/// subtitle again, until the design review of 2026-11-07: an agent polling every 50 s fills the
/// log with 70 identical cards an hour, and the one answer or close among them was invisible.
/// Like `ToolCallItemView`, a line opens its call in full — arguments and response — on a tap
/// (`onOpenFullCall`, 2026-11-08); there is no chevron. The card's header is the Watchtower's
/// own (`ActivityFilterBar`): a task filter, and a hide control that moves the one cutoff both
/// activity lists read.
struct ExternalAutovisorPaneContent: View {
    let presentation: ExternalAutovisorPanePresentation
    let onToggleAutovisor: @MainActor (Bool) -> Void
    let onOpenTask: @MainActor (Int) -> Void
    let onOpenExternalAgents: @MainActor () -> Void
    let onOpenFullCall: @MainActor (ExternalAutovisorFeedItem) -> Void
    let onSelectActivityTaskFilter: @MainActor (Int?) -> Void
    let onHideActivity: @MainActor () -> Void

    var body: some View {
        let current = presentation
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                headerCard(current)
                ForEach(current.offlineBanners) { banner in
                    offlineBannerCard(banner)
                }
                tasksSection(current.externalTasks, showsAgentTag: current.showsAgentTagOnTaskRows)
                activitySection(current.activity)
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NTMSBackground())
        .navigationTitle("")
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    // MARK: - Header

    private func headerCard(_ current: ExternalAutovisorPanePresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .center, spacing: Spacing.m) {
                // `isRunning: false` — the glow means "the Autovisor is working", and an agent
                // being connected is not that; it lit the switch whenever anything was online.
                AutovisorPowerToggle(isOn: current.isAutovisorEnabled, isRunning: false) {
                    onToggleAutovisor(!current.isAutovisorEnabled)
                }

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.s) {
                        Text("External Autovisor")
                            .font(Typography.termLg)
                            .foregroundStyle(Colors.textPrimary)
                        readinessBadge(current.readiness)
                    }
                    Text(current.listenerStatusText)
                        .font(Typography.caption)
                        .foregroundStyle(current.isServerListening ? Colors.textSecondary : Colors.warning)
                }

                Spacer()

                Button {
                    onOpenExternalAgents()
                } label: {
                    Label("External Agents", systemImage: "network")
                        .font(Typography.caption)
                }
                .buttonStyle(.terminalSecondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.xs) {
                MonoLabel(text: "Agents")
                if current.agents.isEmpty {
                    Text("No external agents registered yet. Open Settings → External Agents to issue a token.")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                } else {
                    ForEach(current.agents) { agent in
                        HStack(spacing: Spacing.s) {
                            StatusGlyph(
                                glyph: TerminalGlyph.bullet,
                                color: agent.isPresent ? Colors.success : Colors.textQuaternary,
                                font: Typography.term2xs)
                            Text(agent.label)
                                .font(Typography.subheadlineMedium)
                                .foregroundStyle(Colors.textPrimary)
                            Spacer()
                            Text(agent.statusText)
                                .font(Typography.caption)
                                .foregroundStyle(agent.isPresent ? Colors.success : Colors.textSecondary)
                        }
                        .padding(.vertical, Spacing.xxs)
                    }
                }
            }
        }
        .cardStyle()
    }

    private func readinessBadge(_ readiness: ExternalAutovisorReadiness) -> some View {
        let isReady = readiness.allowsWrites
        return TerminalStatusBadge(
            glyph: isReady ? TerminalGlyph.done : TerminalGlyph.paused,
            label: readiness.state.displayLabel,
            color: isReady ? Colors.success : Colors.warning,
            bordered: false)
    }

    // MARK: - Offline Waiting Banner

    private func offlineBannerCard(_ banner: ExternalAutovisorOfflineBanner) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                StatusGlyph(glyph: TerminalGlyph.review, color: Colors.warning)
                Text(banner.headline)
                    .font(Typography.subheadlineMedium)
                    .foregroundStyle(Colors.textPrimary)
                Spacer()
            }
            Text(banner.detail)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            HStack(spacing: Spacing.xs) {
                ForEach(banner.waitingTaskIDs, id: \.self) { taskID in
                    Button {
                        onOpenTask(taskID)
                    } label: {
                        Text("Open #\(taskID)")
                            .font(Typography.termXs)
                    }
                    .buttonStyle(.terminalSecondary)
                }
            }
        }
        .padding(Spacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle.squircle(CornerRadius.medium)
                .fill(Colors.warningTint)
        )
        .overlay(
            RoundedRectangle.squircle(CornerRadius.medium)
                .strokeBorder(Colors.warning, lineWidth: 1)
        )
    }

    // MARK: - Agent Tasks

    private func tasksSection(_ tasks: [ExternalAutovisorTaskRowItem], showsAgentTag: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonoLabel(text: "Agent Tasks (\(tasks.count))", rule: true)
            if tasks.isEmpty {
                emptyCard("No tasks created by external agents in this work folder yet.")
            } else {
                VStack(spacing: Spacing.xs) {
                    ForEach(tasks) { item in
                        Button {
                            onOpenTask(item.id)
                        } label: {
                            HStack(spacing: Spacing.s) {
                                Text("#\(item.id)")
                                    .font(Typography.termXs)
                                    .foregroundStyle(Colors.accent)
                                Text(item.title)
                                    .font(Typography.subheadlineMedium)
                                    .foregroundStyle(Colors.textPrimary)
                                    .lineLimit(1)
                                if showsAgentTag {
                                    TerminalStatusBadge.agent(label: item.agentIdentity.label)
                                }
                                Spacer()
                                if item.isWaitingForAnswer {
                                    TerminalStatusBadge(
                                        glyph: TerminalGlyph.review,
                                        label: "\(item.waitingQuestionCount) waiting",
                                        color: Colors.warning,
                                        bordered: false)
                                }
                                Text(item.status.displayLabel(isChatMode: false))
                                    .font(Typography.caption)
                                    .foregroundStyle(Colors.textTertiary)
                            }
                            .padding(Spacing.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle.squircle(CornerRadius.small)
                                    .fill(Colors.surfaceCard)
                            )
                            .overlay(
                                RoundedRectangle.squircle(CornerRadius.small)
                                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Activity

    /// The Watchtower's Recent Activity card, row for row: the shared header, a divider, then
    /// the lines — or one line saying why there are none.
    private func activitySection(_ activity: ExternalAutovisorActivitySelection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonoLabel(text: "Activity (\(activity.items.count))", rule: true)
            VStack(spacing: 0) {
                ActivityFilterBar(
                    options: activity.filterOptions,
                    selection: activity.taskFilter,
                    onSelect: onSelectActivityTaskFilter,
                    isHideDisabled: !activity.canHide,
                    onHide: onHideActivity
                )
                .padding(Spacing.m)

                TerminalDivider()

                if activity.items.isEmpty {
                    Text(activity.emptyText)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                        .padding(Spacing.standard)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(activity.items) { item in
                            ExternalAutovisorActivityRow(
                                item: item,
                                onOpenFullCall: { onOpenFullCall(item) },
                                onOpenTask: onOpenTask)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    .padding(.horizontal, Spacing.s)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .fill(Colors.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
        }
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Colors.textTertiary)
            .padding(Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .fill(Colors.surfaceCard)
            )
    }
}

// MARK: - Activity row

/// One call, one line: `glyph title → result · #N · time`. A tap anywhere on the line opens the
/// call in full when it is on disk (`item.hasFullCall`); only such a line lights on hover, so the
/// highlight says which lines open. A row of its own so hover state is per row and the pane's
/// body does not re-evaluate on every mouse move.
struct ExternalAutovisorActivityRow: View {
    let item: ExternalAutovisorFeedItem
    let onOpenFullCall: @MainActor () -> Void
    let onOpenTask: @MainActor (Int) -> Void

    @State private var isHovered = false

    /// An action by the agent reads in the primary ink; a poll or a read — most of the log —
    /// in the secondary, so the actions stand out of the transcript.
    private var titleColor: Color {
        if item.isError { return Colors.error }
        return item.isAgentAction ? Colors.textPrimary : Colors.textSecondary
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(Self.glyph(for: item.kind))
                .font(Typography.termXs)
                .foregroundStyle(item.isError ? Colors.error : (item.isAgentAction ? Colors.accent : Colors.textQuaternary))
                .accessibilityHidden(true)

            // The title keeps its width; the arguments and the result truncate first — the
            // title says what happened, the rest is detail.
            // Each one-line text carries itself as its tooltip: what truncates can be read. The
            // title's also carries the arguments it narrates only in part.
            Text(item.title)
                .font(item.isAgentAction ? Typography.termXs.weight(.medium) : Typography.termXs)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(item.titleHelpText)

            if let arguments = item.inlineArgumentsText {
                Text(arguments)
                    .font(Typography.termXs)
                    .foregroundStyle(Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(arguments)
            }

            Text("→")
                .font(Typography.termXs)
                .foregroundStyle(Colors.textQuaternary)
            Text(item.resultText)
                .font(Typography.termXs)
                .foregroundStyle(item.isError ? Colors.error : Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(item.resultText)

            Spacer(minLength: Spacing.xs)

            // The trailing facts never shrink: the task link and the time are what a reader
            // scans the column for.
            if let taskID = item.taskID, let badge = item.taskBadgeText {
                Button {
                    onOpenTask(taskID)
                } label: {
                    Text(badge)
                        .font(Typography.termXs)
                        .foregroundStyle(Colors.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Open task \(badge)")
            }

            Text(item.timestampText)
                .font(Typography.term2xs)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Colors.textQuaternary)
        }
        // Padding, hover fill, hit shape and tap on ONE view: the band that lights is the band
        // that opens (CLAUDE.md #12 — a hit area is its cell, not its glyphs). The `#N` button
        // inside keeps its own clicks: a child's gesture wins over its parent's.
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.xs)
        .background(
            RoundedRectangle.squircle(CornerRadius.micro)
                .fill(isHovered && item.hasFullCall ? Colors.surfaceHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if item.hasFullCall { onOpenFullCall() }
        }
        .modifier(OpenableRowAccessibility(
            isOpenable: item.hasFullCall,
            taskID: item.taskID,
            taskBadge: item.taskBadgeText,
            onOpen: onOpenFullCall,
            onOpenTask: onOpenTask))
    }

    /// The row's sigil: what kind of thing the agent did, in the terminal's own vocabulary.
    static func glyph(for kind: ExternalAutovisorFeedItem.Kind) -> String {
        switch kind {
        case .createdTask: "+"
        case .answeredQuestion: TerminalGlyph.prompt
        case .roleReview: TerminalGlyph.done
        case .taskControl: TerminalGlyph.working
        case .messaged: TerminalGlyph.prompt
        case .scheduled: TerminalGlyph.revision
        case .folderContext: TerminalGlyph.revision
        case .waitForEvents: TerminalGlyph.queued
        case .error: TerminalGlyph.failed
        case .other: "$"
        }
    }
}

/// One VoiceOver element per line. A line that opens its call is a button whose default action
/// opens it; the nested `#N` link, merged into the line, comes back as a named action — the
/// shape of `WatchtowerFeatureTipCard`, the other tappable container holding a button.
private struct OpenableRowAccessibility: ViewModifier {
    let isOpenable: Bool
    let taskID: Int?
    let taskBadge: String?
    let onOpen: @MainActor () -> Void
    let onOpenTask: @MainActor (Int) -> Void

    /// Branchless on `isOpenable`, which flips when the row's task is deleted: the line keeps its
    /// identity and only loses the trait, the hint and what its default action does.
    func body(content: Content) -> some View {
        taskAction(on: content.accessibilityElement(children: .combine))
            .accessibilityAddTraits(isOpenable ? .isButton : [])
            .accessibilityHint(Text(isOpenable ? "Opens the full request and response" : ""))
            .accessibilityAction {
                if isOpenable { onOpen() }
            }
    }

    @ViewBuilder
    private func taskAction(on view: some View) -> some View {
        if let taskID, let taskBadge {
            view.accessibilityAction(named: Text("Open task \(taskBadge)")) { onOpenTask(taskID) }
        } else {
            view
        }
    }
}
