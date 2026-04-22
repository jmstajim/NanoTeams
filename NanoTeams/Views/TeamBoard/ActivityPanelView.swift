import SwiftUI

// MARK: - Activity Panel View

/// Right panel containing role context banner (when selected) and unified activity feed.
/// Replaces ChatPanelView by eliminating nested tabs and consolidating controls.
struct ActivityPanelView: View {
    let run: Run?
    let roleDefinitions: [TeamRoleDefinition]
    @Binding var selectedRoleID: String?
    let supervisorReviewArtifacts: [String]
    let producedArtifacts: Set<String>
    let isFinalReviewStage: Bool
    var isChatMode: Bool = false
    let isReadOnly: Bool
    var onReviewTask: (() -> Void)? = nil
    let onRequestChanges: (String, String) -> Void
    var onRestartRole: ((String, String) -> Void)? = nil
    var onCorrectRole: ((String, String) -> Void)? = nil
    var isPaused: Bool = false
    var meetingParticipants: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if let roleID = selectedRoleID {
                RoleContextBanner(
                    roleID: roleID,
                    run: run,
                    roleDefinitions: roleDefinitions,
                    isInMeeting: meetingParticipants.contains(roleID),
                    isPaused: isPaused,
                    onDeselect: {
                        selectedRoleID = nil
                    },
                    onRestart: isReadOnly ? nil : onRestartRole,
                    onCorrect: isReadOnly ? nil : onCorrectRole,
                    isReadOnly: isReadOnly
                )
                Divider()
            }

            TeamActivityFeedView(
                run: run,
                roleDefinitions: roleDefinitions,
                supervisorReviewArtifacts: supervisorReviewArtifacts,
                producedArtifacts: producedArtifacts,
                isFinalReviewStage: isFinalReviewStage,
                isChatMode: isChatMode,
                isReadOnly: isReadOnly,
                filterRoleID: selectedRoleID,
                onSelectRole: { roleID in
                    selectedRoleID = roleID
                },
                onReviewTask: onReviewTask,
                onRequestChanges: onRequestChanges
            )
        }
        .clipped()
    }
}

// MARK: - Previews

#Preview("Activity Panel — No Role Selected") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var selectedRoleID: String? = nil
    ActivityPanelView(
        run: nil,
        roleDefinitions: Team.default.roles,
        selectedRoleID: $selectedRoleID,
        supervisorReviewArtifacts: [],
        producedArtifacts: [],
        isFinalReviewStage: false,
        isReadOnly: false,
        onRequestChanges: { _, _ in }
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .frame(width: 500, height: 600)
}

#Preview("Activity Panel — Role Selected") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var selectedRoleID: String? = Team.default.roles.first(where: { !$0.isSupervisor })?.id
    let team = Team.default
    ActivityPanelView(
        run: Run(id: 0, roleStatuses: [team.roles[1].id: .working]),
        roleDefinitions: team.roles,
        selectedRoleID: $selectedRoleID,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task"],
        isFinalReviewStage: false,
        isReadOnly: false,
        onRequestChanges: { _, _ in }
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .frame(width: 500, height: 600)
}
