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

    var body: some View {
        VStack(spacing: 0) {
            // Filter header
            filterHeader
                .padding(Spacing.m)

            Divider()

            // Timeline content
            if filteredEvents.isEmpty {
                emptyState
            } else {
                timelineContent
            }
        }
        .background(Colors.surfaceOverlay)
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
                        .foregroundStyle(.secondary)

                    Text(filterLabel)
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        .fill(Colors.surfaceCard)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            Spacer()

            // Clear button - hides displayed events without deleting data
            ClearTimelineButton(isDisabled: filteredEvents.isEmpty) {
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
                ForEach(Array(filteredEvents.prefix(visibleCount))) { event in
                    WatchtowerTimelineItem(
                        event: event,
                        onTap: { onTaskSelect(event.taskID) }
                    )
                }

                // Show more button
                if filteredEvents.count > visibleCount {
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
                Text("Show more (\(filteredEvents.count - visibleCount) remaining)")
                    .font(.subheadline)
                    .foregroundStyle(Colors.accent)
                Spacer()
            }
            .padding(Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
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
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text("No activity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

    private var filteredEvents: [TimelineEvent] {
        let roles = store.activeTask.map { store.resolvedTeam(for: $0).roles } ?? []
        return WatchtowerTimelineBuilder.buildTimeline(
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
                .font(.caption)
                .foregroundStyle(isHovered ? .primary : .secondary)
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
