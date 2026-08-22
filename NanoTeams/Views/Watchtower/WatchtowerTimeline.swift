import SwiftUI

// MARK: - Watchtower Timeline

/// Right column of watchtower showing chronological activity from all tasks
struct WatchtowerTimeline: View {
    @Environment(NTMSOrchestrator.self) var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onTaskSelect: (Int) -> Void

    @State private var selectedTaskFilter: Int? = nil
    @State private var visibleCount: Int = 30
    @Binding var clearedUpToDate: Date?

    /// The built timeline, refreshed only when `WatchtowerTimelineBuilder.inputsVersion`
    /// moves. Memoized rather than computed: `body` references it five times, this
    /// pane is the Watchtower's default detail, and every reference used to walk
    /// every run and step of the task, allocate an event per step, sort, and filter
    /// twice — on every `mutateTask`.
    @State private var cachedEvents: [TimelineEvent] = []

    var body: some View {
        VStack(spacing: 0) {
            // Filter header
            filterHeader
                .padding(Spacing.m)

            TerminalDivider()

            // Timeline content
            if cachedEvents.isEmpty {
                emptyState
            } else {
                timelineContent
            }
        }
        .background(Colors.surfaceOverlay)
        .onAppear { rebuildEvents() }
        .onChange(of: timelineInputsVersion) { _, _ in rebuildEvents() }
    }

    // MARK: - Components

    private var filterHeader: some View {
        HStack {
            Menu {
                Button("All tasks & chats") {
                    selectedTaskFilter = nil
                }

                if !availableTasks.isEmpty {
                    Divider()
                    ForEach(availableTasks, id: \.id) { task in
                        Button(task.title) {
                            selectedTaskFilter = task.id
                        }
                    }
                }
            } label: {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(Colors.textSecondary)

                    Text(filterLabel)
                        .font(Typography.termBase)
                        .foregroundStyle(Colors.textPrimary)

                    Image(systemName: "chevron.down")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(Colors.surfaceCard)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            Spacer()

            // Clear button - hides displayed events without deleting data
            ClearTimelineButton(isDisabled: cachedEvents.isEmpty) {
                clearedUpToDate = MonotonicClock.shared.now()
            }
        }
    }

    private var filterLabel: String {
        if let taskID = selectedTaskFilter,
           let task = availableTasks.first(where: { $0.id == taskID }) {
            return task.title
        }
        return "All tasks & chats"
    }

    private var timelineContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(cachedEvents.prefix(visibleCount))) { event in
                    WatchtowerTimelineItem(
                        event: event,
                        onTap: { onTaskSelect(event.taskID) }
                    )
                }

                // Show more button
                if cachedEvents.count > visibleCount {
                    showMoreButton
                }
            }
            .padding(Spacing.m)
        }
    }

    private var showMoreButton: some View {
        Button {
            withAnimation(reduceMotion ? .none : Animations.spring) {
                visibleCount += 30
            }
        } label: {
            HStack {
                Spacer()
                Text("Show more (\(cachedEvents.count - visibleCount) remaining)")
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.accent)
                Spacer()
            }
            .padding(Spacing.m)
            .background(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .fill(Colors.accentTint)
            )
        }
        .buttonStyle(.plain)
        .padding(.top, Spacing.s)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            VStack(spacing: Spacing.m) {
                Image(systemName: "clock")
                    .font(.largeTitle)
                    .foregroundStyle(Colors.textTertiary)
                    .accessibilityHidden(true)

                Text("No activity")
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private var availableTasks: [NTMSTask] {
        if let activeTask = store.activeTask {
            return [activeTask]
        }
        return []
    }

    /// Cheap fold over everything `buildTimeline` reads — the only thing this
    /// view evaluates per body pass now.
    private var timelineInputsVersion: Int {
        let team = store.activeTask.map { store.resolvedTeam(for: $0) }
        return WatchtowerTimelineBuilder.inputsVersion(
            task: store.activeTask,
            teamID: team?.id,
            teamUpdatedAt: team?.updatedAt,
            taskFilter: selectedTaskFilter,
            clearedUpTo: clearedUpToDate
        )
    }

    private func rebuildEvents() {
        let roles = store.activeTask.map { store.resolvedTeam(for: $0).roles } ?? []
        cachedEvents = WatchtowerTimelineBuilder.buildTimeline(
            task: store.activeTask,
            roleDefinitions: roles,
            taskFilter: selectedTaskFilter,
            clearedUpTo: clearedUpToDate
        )
    }
}

// MARK: - Clear Timeline Button

private struct ClearTimelineButton: View {
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye.slash")
                .font(Typography.caption)
                .foregroundStyle(isHovered ? Colors.textPrimary : Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Hide timeline events")
        .accessibilityLabel("Hide timeline events")
        .disabled(isDisabled)
        .trackHover($isHovered)
    }
}

// MARK: - Preview

#Preview {
    WatchtowerTimeline(onTaskSelect: { _ in }, clearedUpToDate: .constant(nil))
        .environment(NTMSOrchestrator(repository: NTMSRepository()))
        .frame(width: 500, height: 600)
}
