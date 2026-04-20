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

    var body: some View {
        ToolSelectionView(
            selectedTools: $editorState.selectedTools,
            producedArtifacts: editorState.producedArtifacts,
            isNonProducingNonObserver: isNonProducingNonObserver,
            isMeetingCoordinator: isMeetingCoordinator,
            isVisionConfigured: config.isVisionConfigured
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
