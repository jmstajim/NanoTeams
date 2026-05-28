import SwiftUI

// MARK: - Tools Tab

struct RoleEditorToolsTab: View {
    @Binding var editorState: RoleEditorState
    let isMeetingCoordinator: Bool
    @Environment(StoreConfiguration.self) private var config

    private var isNonProducingNonObserver: Bool {
        // Mirrors TeamRoleDefinition.shouldAutoInjectAskSupervisor
        editorState.producedArtifacts.isEmpty && !editorState.requiredArtifacts.isEmpty
    }

    /// Mirrors `TeamRoleDefinition.hasDelegationConfigured` for the in-flight editor
    /// state — drives the Auto-injected delegation rows in `ToolSelectionView`.
    private var canDelegate: Bool {
        !editorState.selectedDelegationTeamIDs.isEmpty
            || editorState.allowDelegationToGeneratedTeams
    }

    /// Hint text describing the delegation configuration. Surfaces target count
    /// + generated-permission so the user can see at a glance what the LLM will
    /// be allowed to do.
    private var delegationHint: String {
        let teamCount = editorState.selectedDelegationTeamIDs.count
        let teamPart: String? = {
            switch teamCount {
            case 0: return nil
            case 1: return "1 team"
            default: return "\(teamCount) teams"
            }
        }()
        let genPart: String? = editorState.allowDelegationToGeneratedTeams ? "generated" : nil
        return [teamPart, genPart].compactMap { $0 }.joined(separator: " + ")
    }

    var body: some View {
        ToolSelectionView(
            selectedTools: $editorState.selectedTools,
            producedArtifacts: editorState.producedArtifacts,
            isNonProducingNonObserver: isNonProducingNonObserver,
            isMeetingCoordinator: isMeetingCoordinator,
            isVisionConfigured: config.isVisionConfigured,
            canDelegate: canDelegate,
            delegationHint: delegationHint
        )
    }
}

#Preview("Role Tools Tab") {
    @Previewable @State var editorState: RoleEditorState = {
        var s = RoleEditorState()
        s.selectedTools = ["read_file", "write_file", "edit_file", "git_status", "git_diff"]
        s.producedArtifacts = ["Engineering Notes"]
        return s
    }()

    RoleEditorToolsTab(editorState: $editorState, isMeetingCoordinator: false)
        .environment(StoreConfiguration())
        .frame(width: 500, height: 500)
        .background(Colors.surfacePrimary)
}
