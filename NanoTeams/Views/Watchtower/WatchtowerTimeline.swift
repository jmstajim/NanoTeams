import SwiftUI

/// The per-body-pass watch key for the timeline memo: a store WRITE counter plus the
/// two view-local filters. Deliberately a named `Equatable` struct rather than a tuple
/// — `onChange(of:)` needs `Equatable`, and a named type is where the reason the key
/// is CHEAP (and therefore over-fires) can live next to the fields.
private struct TimelineWatchKey: Equatable {
    let storeWrites: Int
    let taskFilter: Int?
    let clearedUpTo: Date?
}

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

    /// The `inputsVersion` the cached timeline was built from, so the fold that
    /// used to run per body pass now runs once per store write — see
    /// `timelineWatchKey`.
    @State private var builtInputsVersion: Int?

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
        .onChange(of: timelineWatchKey) { _, _ in rebuildEvents() }
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

    /// What this view evaluates on EVERY body pass: two view-local filters and a
    /// store WRITE counter. All three are O(1) to read and to compare.
    ///
    /// `timelineInputsVersion` below is the real question — "did anything the builder
    /// reads move" — and answering it is Theta(runs x steps) with three `String`
    /// hashes per step. It used to sit here, in the `onChange` KEY, which SwiftUI
    /// evaluates on every pass whether or not the handler fires (CLAUDE.md #113), on
    /// the app's launch destination and default detail pane, whose body observes
    /// `store.activeTask` and therefore re-evaluates on every `mutateTask`
    /// (DEBTS D-26, recorded as the a6 axis's one `verdict: defect`).
    ///
    /// The split keeps BOTH properties. `storeWriteRevision` over-fires by
    /// construction — it counts writes, not changes — so the handler runs more often
    /// than the timeline changes; `rebuildEvents` then pays the exact fold ONCE and
    /// returns early when it matches. Net: O(1) per body pass, one fold per store
    /// write, one rebuild per real change. A cheaper KEY that tried to answer the
    /// real question directly would risk the one failure a memo must never have —
    /// a key that fails to move when the built timeline would differ — which is what
    /// `WatchtowerTimelineInputsVersionTests` exists to prevent, field by field.
    private var timelineWatchKey: TimelineWatchKey {
        TimelineWatchKey(
            storeWrites: store.storeWriteRevision,
            taskFilter: selectedTaskFilter,
            clearedUpTo: clearedUpToDate
        )
    }

    /// The exact change-detector `buildTimeline` needs, evaluated once per store
    /// write from `rebuildEvents` rather than once per body pass.
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
        // The fold the `onChange` key used to carry. Paid here, once per store write,
        // and it is what makes the over-firing watch key harmless.
        let version = timelineInputsVersion
        guard version != builtInputsVersion else { return }
        builtInputsVersion = version

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
    @Previewable @State var previewStore = PreviewStore.make()
    WatchtowerTimeline(onTaskSelect: { _ in }, clearedUpToDate: .constant(nil))
        .environment(previewStore)
        .frame(width: 500, height: 600)
}
