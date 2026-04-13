import AppKit
import SwiftUI

// MARK: - Toolbar Components

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

    @ViewBuilder
    var playPauseButton: some View {
        if !isHistoricalRun, let task {
            let taskState = engineState.taskEngineStates[task.id]
            if taskState == .running || taskState == .needsSupervisorInput || taskState == .needsAcceptance {
                Button {
                    Task { await store.pauseRun(taskID: task.id) }
                } label: {
                    Label("Pause Run", systemImage: "pause.fill")
                        .foregroundStyle(Colors.warning)
                }
            } else if taskState == .paused {
                Button {
                    Task { await store.resumeRun(taskID: task.id) }
                } label: {
                    Label("Resume Run", systemImage: "play.fill")
                        .foregroundStyle(Colors.success)
                }
            } else if taskState == .pending || taskState == nil {
                Button {
                    Task { await store.startRun(taskID: task.id) }
                } label: {
                    Label("Start Run", systemImage: "play.fill")
                        .foregroundStyle(Colors.success)
                }
            }
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
                    Label("Review Task", systemImage: "eye.circle.fill")
                        .foregroundStyle(Colors.purple)
                }
                .help("Open Supervisor Final Review")
            } else {
                Button {
                    Task { _ = await store.closeTask(taskID: task.id) }
                } label: {
                    Label("Accept Task", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Colors.purple)
                }
                .help("Accept completed task and mark as Done")
            }
        }
    }

    var moreActionsMenu: some View {
        Menu {
            // New Run — always available, pauses current run first
            if let task {
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

            // Run history submenu
            Menu {
                if let task = task, !task.runs.isEmpty {
                    ForEach(task.runs.reversed()) { run in
                        let status = run.derivedStatus()
                        let isActive = run.id == activeRun?.id
                        let timeStr = run.createdAt.formatted(date: .omitted, time: .shortened)

                        Button {
                            store.selectedRunID = run.id
                        } label: {
                            Label {
                                Text("Run — \(status.displayLabel) — \(timeStr)")
                            } icon: {
                                Image(systemName: isActive ? "checkmark.circle.fill" : status.systemImageName)
                            }
                        }
                    }
                } else {
                    Text("No runs yet")
                        .foregroundStyle(.secondary)
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
            Label("More", systemImage: "ellipsis.circle")
        }
    }
}
