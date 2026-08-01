import SwiftUI

// MARK: - Tools Tab

struct RoleEditorToolsTab: View {
    @Binding var editorState: RoleEditorState
    /// Tools the runtime adds on top of the user's selection, resolved once by
    /// `RoleEditorSheet` against the live draft. Replaces the booleans this tab used
    /// to derive itself (`isNonProducingNonObserver` / `isMeetingCoordinator` /
    /// `canDelegate` / `injectsAskSupervisor`) — each was a local restatement of a
    /// rule that lives in `LLMExecutionService+ToolResolution`, free to drift from it.
    let autoInjectedTools: [String]
    /// Mandatory tools shown as locked/Required (Autovisor manager). Default empty.
    var lockedTools: [String] = []
    /// When non-nil, only these tools are offered as toggles (Autovisor manager).
    var restrictToTools: Set<String>? = nil
    @Environment(StoreConfiguration.self) private var config

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
            isVisionConfigured: config.isVisionConfigured,
            isComputerUseEnabled: config.isComputerUseEnabled,
            autoInjectedTools: autoInjectedTools,
            delegationHint: delegationHint,
            lockedTools: lockedTools,
            restrictToTools: restrictToTools
        )
        .onAppear {
            // Safety: ensure the mandatory tools are always selected (persisted to
            // toolIDs) even if a stale team somehow lacked one — they're locked in the UI.
            editorState.selectedTools.formUnion(lockedTools)
        }
    }
}

#Preview("Role Tools Tab") {
    @Previewable @State var editorState: RoleEditorState = {
        var s = RoleEditorState()
        s.selectedTools = ["read_file", "write_file", "edit_file", "git_status", "git_diff"]
        s.producedArtifacts = ["Engineering Notes"]
        return s
    }()

    RoleEditorToolsTab(editorState: $editorState, autoInjectedTools: [ToolNames.createArtifact])
        .environment(StoreConfiguration())
        .frame(width: 500, height: 500)
        .background(Colors.surfacePrimary)
}
