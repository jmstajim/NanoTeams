import AppKit
import SwiftUI

// MARK: - Top-Bar Action Components

/// Action-button vars composed into the `TeamBoardTopBar`'s right cluster
/// (Pass 28 dropped the native `.toolbar` block — the in-view TopBar is now
/// the sole navbar). Each returns a `Button` / `Menu` with `Label("name",
/// systemImage: "…")`; the TopBar forces `.labelStyle(.iconOnly)` and the
/// flat `NavbarIconButtonStyle` via the env at its actions slot.
extension TeamBoardView {

    var graphToggleButton: some View {
        Button {
            withAnimation {
                isGraphPanelVisible.toggle()
            }
        } label: {
            Label(
                isGraphPanelVisible ? "Hide Graph" : "Show Graph",
                systemImage: "sidebar.trailing"
            )
        }
    }

    /// "Run now" — Autovisor board only. Renders in the TopBar's right cluster
    /// as a bracketed `[ ▷ Run now ]` button — the only action that keeps its
    /// label. Uses `.terminalSecondary` to override the cluster's env-level
    /// `.navbarIcon` style, which would otherwise clamp the label to a 28×28pt
    /// cell and truncate the text.
    ///
    /// `force: true` — an explicit human restart supersedes ANY engine state,
    /// including a live `.running` pass. Deliberately always enabled and never
    /// confirmed: the reported symptom was a silent no-op while the manager was
    /// mid-pass, and a disabled state or a confirm sheet just re-earns it.
    ///
    /// No `autovisorEnabled` check here, but NOT because the board implies enabled —
    /// it does not. `MainLayoutView.autovisorDetail` gates on
    /// `!autovisorShowsSetupPane`, yet `detailView`'s `.task` branch renders this
    /// same board with no Autovisor gate, and `setAutovisorEnabled(false)` keeps
    /// `autovisorTaskID` — so ⌘3 / the command palette reach it with the feature
    /// OFF once the manager is the active task. The gate lives in
    /// `startAutovisorPass` instead (one seam, every entry point, mirroring
    /// `fireRecurrence`'s zombie guard), which refuses and says why.
    @ViewBuilder
    var autovisorRunNowButton: some View {
        if isAutovisorBoard, !isHistoricalRun, let task {
            Button {
                Task { await store.startAutovisorPass(taskID: task.id, force: true) }
            } label: {
                Label("Run now", systemImage: "play")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.terminalSecondary)
            .controlSize(.small)
            .fixedSize()
            .help("Restart the Autovisor review pass now — abandons a pass in progress")
        }
    }

    @ViewBuilder
    var acceptTaskButton: some View {
        if !isHistoricalRun,
           let task,
           task.isReadyForFinalAcceptance {
            if resolvedTeam.requiresSupervisorFinalReview {
                Button {
                    isShowingFinalReviewSheet = true
                } label: {
                    Label("Review Task", systemImage: "eye.circle")
                        .foregroundStyle(Colors.purple)
                }
                .help("Open Supervisor Final Review")
            } else {
                Button {
                    Task { _ = await store.closeTask(taskID: task.id) }
                } label: {
                    Label("Accept Task", systemImage: "checkmark.circle")
                        .foregroundStyle(Colors.purple)
                }
                .help("Accept completed task and mark as Done")
            }
        }
    }

    @ViewBuilder
    var automationButton: some View {
        if !isHistoricalRun, let task {
            let isActive = (task.recurrence?.isEnabled == true) || (task.runTimeoutSeconds != nil)
            Button {
                isShowingAutomationSheet = true
            } label: {
                Label("Automation", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(isActive ? Colors.accent : Colors.textPrimary)
            }
            .help(automationHelpText(for: task))
        }
    }

    private func automationHelpText(for task: NTMSTask) -> String {
        var parts: [String] = []
        if let recurrence = task.recurrence, recurrence.isEnabled {
            parts.append("Repeat: \(recurrence.rule.summary)")
        }
        if let timeout = task.runTimeoutSeconds {
            parts.append("Timeout: \(Int((timeout / 60).rounded())) min")
        }
        return parts.isEmpty
            ? "Automation — repeat this task on a schedule or limit how long a run may take"
            : parts.joined(separator: " · ")
    }

    /// Team picker — re-exposes `store.switchTeam(to:)` (its only UI caller, the
    /// activity-feed `teamHeaderMenu`, was removed in the navbar redesign). A
    /// live, non-Autovisor, non-managed-singleton task with ≥2 selectable teams
    /// can be re-run on a different team; the switch pauses the run, syncs role
    /// statuses, and prunes steps to the new roster (`TeamSwitchPlanner`).
    /// Pure gate for whether the "Switch Team" menu should appear: a live
    /// (non-historical), non-Autovisor, non-managed-singleton task with at least
    /// two selectable teams (switching to a different team needs an alternative).
    /// Extracted so the branch coverage is unit-testable.
    nonisolated static func shouldOfferTeamSwitch(
        isAutovisorBoard: Bool,
        isHistoricalRun: Bool,
        activeTeamIsManagedSingleton: Bool,
        selectableTeamCount: Int
    ) -> Bool {
        !isAutovisorBoard
            && !isHistoricalRun
            && !activeTeamIsManagedSingleton
            && selectableTeamCount > 1
    }

    @ViewBuilder
    private var switchTeamMenu: some View {
        let teams = (store.snapshot?.workFolder.teams ?? []).filter { !$0.isHiddenFromPickers }
        if Self.shouldOfferTeamSwitch(
            isAutovisorBoard: isAutovisorBoard,
            isHistoricalRun: isHistoricalRun,
            activeTeamIsManagedSingleton: resolvedTeam.isManagedSingleton,
            selectableTeamCount: teams.count
        ) {
            Menu {
                ForEach(teams) { team in
                    Button {
                        Task { await store.switchTeam(to: team.id) }
                    } label: {
                        let title = "\(team.name) (\(team.memberCount) members)"
                        if team.id == resolvedTeam.id {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            } label: {
                Label("Switch Team", systemImage: "person.2.badge.gearshape")
            }

            Divider()
        }
    }

    var moreActionsMenu: some View {
        Menu {
            // New Run — always available, pauses current run first.
            // Hidden on the Autovisor board: its "Run now" toolbar button replaces
            // it (plain startRun no-ops on a parked manager).
            if let task, !isAutovisorBoard {
                Button {
                    Task {
                        let taskState = engineState.taskEngineStates[task.id]
                        if taskState == .running || taskState == .needsSupervisorInput || taskState == .needsAcceptance {
                            await store.pauseRun(taskID: task.id)
                        }
                        await store.startRun(taskID: task.id)
                    }
                } label: {
                    Label("New Run", systemImage: "arrow.counterclockwise")
                }
                .disabled(isHistoricalRun)

                Divider()
            }

            switchTeamMenu

            // Run history submenu
            Menu {
                if let task = task, !task.runs.isEmpty {
                    ForEach(task.runs.reversed()) { run in
                        let status = run.derivedStatus()
                        let isActive = run.id == activeRun?.id
                        let timeStr = run.createdAt.formatted(date: .omitted, time: .shortened)

                        let timedOutSuffix = run.timedOutAt != nil ? " (timed out)" : ""
                        Button {
                            store.selectedRunID = run.id
                        } label: {
                            Label {
                                Text("Run — \(status.displayLabel)\(timedOutSuffix) — \(timeStr)")
                            } icon: {
                                Image(systemName: isActive ? "checkmark.circle" : status.systemImageName)
                            }
                        }
                    }
                } else {
                    Text("No runs yet")
                        .foregroundStyle(Colors.textSecondary)
                }
            } label: {
                Label("Run History", systemImage: "clock.arrow.circlepath")
            }

            Divider()

            Button {
                guard let taskID = task?.id, let runID = displayedRun?.id else { return }
                guard let url = store.conversationLogURL(taskID: taskID, runID: runID) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Conversation Log", systemImage: "text.bubble")
            }
            .disabled(!(task.flatMap { t in displayedRun.map { store.conversationLogExists(taskID: t.id, runID: $0.id) } } ?? false))

            Button {
                guard let taskID = task?.id, let runID = displayedRun?.id else { return }
                guard let url = store.networkLogURL(taskID: taskID, runID: runID) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Network Log", systemImage: "network")
            }
            .disabled(!(task.flatMap { t in displayedRun.map { store.networkLogExists(taskID: t.id, runID: $0.id) } } ?? false))

            if let task, !task.attachmentPaths.isEmpty {
                Divider()

                Button {
                    store.revealTaskAttachments(task)
                } label: {
                    Label("Source Files", systemImage: "paperclip")
                }
            }

            if let task, task.generatedTeam != nil {
                Divider()

                Button {
                    Task { await store.saveGeneratedTeam(taskID: task.id) }
                } label: {
                    Label("Save Team...", systemImage: "square.and.arrow.down")
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .navbarIconCell()
    }
}
