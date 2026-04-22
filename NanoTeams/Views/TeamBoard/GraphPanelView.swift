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
    var onCorrectRole: ((String) -> Void)? = nil
    var onRetryGeneration: (() -> Void)? = nil
    var isChatMode: Bool = false
    var isPaused: Bool = false
    var isEngineRunning: Bool = true
    var meetingParticipants: Set<String> = []
    var isTaskInReview: Bool = false

    private var activeTeam: Team? {
        if let generated = task.generatedTeam {
            return generated
        }
        if let preferredTeamID = task.preferredTeamID,
           let team = workFolder?.teams.first(where: { $0.id == preferredTeamID }) {
            return team
        }
        return workFolder?.activeTeam
    }

    /// True when task uses the "Generated Team" template and no team has been generated yet.
    private var isGenerationPending: Bool {
        guard task.generatedTeam == nil else { return false }
        guard let preferredID = task.preferredTeamID,
              let template = workFolder?.teams.first(where: { $0.id == preferredID })
        else { return false }
        return template.templateID == "generated"
    }

    /// The most recent create_team tool call across the latest run's steps, if any.
    private var generationToolCall: StepToolCall? {
        guard let run = task.runs.last else { return nil }
        for step in run.steps.reversed() {
            if let call = step.toolCalls.last(where: { $0.name == ToolNames.createTeam }) {
                return call
            }
        }
        return nil
    }

    private var generationFailed: Bool {
        isGenerationPending && (generationToolCall?.isError == true)
    }

    private var isGeneratingTeam: Bool {
        isGenerationPending && !generationFailed
    }

    private var generationErrorMessage: String? {
        guard generationFailed,
              let json = generationToolCall?.resultJSON,
              let dict = JSONUtilities.parseJSONDictionary(json),
              let error = dict["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }
        return message
    }

    private var activeTeamMembers: Set<String> {
        Set(activeTeam?.roles.map(\.id) ?? Team.default.roles.map(\.id))
    }

    private var nodePositions: [TeamNodePosition] {
        activeTeam?.graphLayout.nodePositions ?? TeamGraphLayout.default.nodePositions
    }

    var body: some View {
        ZStack {
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
                onCorrectRole: onCorrectRole,
                isChatMode: isChatMode,
                isPaused: isPaused,
                isEngineRunning: isEngineRunning,
                meetingParticipants: meetingParticipants,
                isTaskInReview: isTaskInReview
            )
            .clipped()

            if isGeneratingTeam {
                VStack(spacing: Spacing.m) {
                    NTMSLoader(.large)
                    Text("Generating team…")
                        .font(Typography.captionSemibold)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Colors.surfaceOverlayStrong)
            } else if generationFailed {
                generationFailureOverlay
            }
        }
        .background(Colors.surfacePrimary)
    }

    private var generationFailureOverlay: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Colors.error)
            Text("Team generation failed")
                .font(Typography.subheadlineSemibold)
                .foregroundStyle(Colors.textPrimary)
            if let message = generationErrorMessage {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }
            if let onRetryGeneration {
                Button("Retry", action: onRetryGeneration)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, Spacing.s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Colors.surfaceOverlayStrong)
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
