import SwiftUI

// MARK: - Keyboard Shortcuts

extension TeamBoardView {

    var keyboardShortcuts: some View {
        Group {
            // Escape: Deselect role
            Button("") {
                withAnimation {
                    selectedRoleID = nil
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .hidden()

            // ⌘Space: Pause/Resume
            Button("") { togglePauseResume() }
                .keyboardShortcut(.space, modifiers: .command)
                .hidden()

            // ⌘A: Accept work (if selected role needs acceptance)
            Button("") { acceptSelectedRole() }
                .keyboardShortcut("a", modifiers: .command)
                .hidden()

            // Down Arrow: Select next role
            Button("") { selectNextRole() }
                .keyboardShortcut(.downArrow, modifiers: [])
                .hidden()

            // Up Arrow: Select previous role
            Button("") { selectPreviousRole() }
                .keyboardShortcut(.upArrow, modifiers: [])
                .hidden()

            // 1-7: Select role by number
            if !orderedRoleIDs.isEmpty {
                ForEach(Array(1...min(7, orderedRoleIDs.count)), id: \.self) { number in
                    Button("") { selectRoleByNumber(number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
                        .hidden()
                }
            }
        }
    }

    func togglePauseResume() {
        guard let taskID = task?.id else { return }
        let state = engineState.taskEngineStates[taskID] ?? .pending
        Task {
            if state == .running || state == .needsSupervisorInput || state == .needsAcceptance {
                await store.pauseRun(taskID: taskID)
            } else if state == .paused {
                await store.resumeRun(taskID: taskID)
            } else if state == .pending {
                await store.startRun(taskID: taskID)
            }
        }
    }

    func acceptSelectedRole() {
        guard let roleID = selectedRoleID,
              selectedRoleStatus == .needsAcceptance else { return }
        handleAcceptance(roleID: roleID)
    }

    func selectNextRole() {
        guard !orderedRoleIDs.isEmpty else { return }

        if let current = selectedRoleID,
           let currentIndex = orderedRoleIDs.firstIndex(of: current) {
            let nextIndex = (currentIndex + 1) % orderedRoleIDs.count
            selectedRoleID = orderedRoleIDs[nextIndex]
        } else {
            selectedRoleID = orderedRoleIDs.first
        }
    }

    func selectPreviousRole() {
        guard !orderedRoleIDs.isEmpty else { return }

        if let current = selectedRoleID,
           let currentIndex = orderedRoleIDs.firstIndex(of: current) {
            let prevIndex = currentIndex > 0 ? currentIndex - 1 : orderedRoleIDs.count - 1
            selectedRoleID = orderedRoleIDs[prevIndex]
        } else {
            selectedRoleID = orderedRoleIDs.last
        }
    }

    func selectRoleByNumber(_ number: Int) {
        let index = number - 1
        guard index >= 0 && index < orderedRoleIDs.count else { return }
        selectedRoleID = orderedRoleIDs[index]
    }
}
