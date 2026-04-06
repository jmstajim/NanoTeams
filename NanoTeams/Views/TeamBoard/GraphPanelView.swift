import SwiftUI

// MARK: - Graph Panel View

/// Left panel containing team graph and status bar.
struct GraphPanelView: View {
    let task: NTMSTask
    let workFolder: WorkFolderProjection?
    let roleStatuses: [String: RoleExecutionStatus]
    let roleDefinitions: [TeamRoleDefinition]
    let producedArtifacts: Set<String>
    @Binding var selectedRoleID: String?
    var onRestartRole: ((String) -> Void)? = nil
    var onFinishRole: ((String) -> Void)? = nil
    var isChatMode: Bool = false
    var isPaused: Bool = false
    var isEngineRunning: Bool = true
    var meetingParticipants: Set<String> = []
    var isTaskInReview: Bool = false

    private var activeTeam: Team? {
        if let preferredTeamID = task.preferredTeamID,
           let team = workFolder?.teams.first(where: { $0.id == preferredTeamID }) {
            return team
        }
        return workFolder?.activeTeam
    }

    private var activeTeamMembers: Set<String> {
        Set(activeTeam?.roles.map(\.id) ?? Team.default.roles.map(\.id))
    }

    private var nodePositions: [TeamNodePosition] {
        activeTeam?.graphLayout.nodePositions ?? TeamGraphLayout.default.nodePositions
    }

    var body: some View {
        TeamGraphView(
            roleStatuses: roleStatuses,
            roleDefinitions: roleDefinitions,
            nodePositions: nodePositions,
            teamMembers: activeTeamMembers,
            selectedRoleID: $selectedRoleID,
            producedArtifacts: producedArtifacts,
            team: activeTeam,
            onRestartRole: onRestartRole,
            onFinishRole: onFinishRole,
            isChatMode: isChatMode,
            isPaused: isPaused,
            isEngineRunning: isEngineRunning,
            meetingParticipants: meetingParticipants,
            isTaskInReview: isTaskInReview
        )
        .clipped()
        .background(Colors.surfacePrimary)
    }
}

// MARK: - Previews

#Preview("Graph Panel — Idle") {
    @Previewable @State var selectedRoleID: String? = nil
    let team = Team.default
    let wf = WorkFolderProjection(
        state: WorkFolderState(name: "Preview", activeTeamID: team.id),
        settings: .defaults,
        teams: [team]
    )
    GraphPanelView(
        task: NTMSTask(id: 0, title: "Implement sorting", supervisorTask: "Create sorting algorithms"),
        workFolder: wf,
        roleStatuses: [:],
        roleDefinitions: team.roles,
        producedArtifacts: [],
        selectedRoleID: $selectedRoleID
    )
    .frame(width: 500, height: 400)
}

#Preview("Graph Panel — In Progress") {
    @Previewable @State var selectedRoleID: String? = nil
    let team = Team.default
    let wf = WorkFolderProjection(
        state: WorkFolderState(name: "Preview", activeTeamID: team.id),
        settings: .defaults,
        teams: [team]
    )
    GraphPanelView(
        task: NTMSTask(id: 0, title: "Build notification system", supervisorTask: "Real-time alerts"),
        workFolder: wf,
        roleStatuses: [
            team.roles[0].id: .done,
            team.roles[1].id: .done,
            team.roles[2].id: .working,
            team.roles[3].id: .working,
        ],
        roleDefinitions: team.roles,
        producedArtifacts: ["Supervisor Task", "Product Requirements"],
        selectedRoleID: $selectedRoleID,
        isEngineRunning: true
    )
    .frame(width: 500, height: 400)
}
