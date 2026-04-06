import SwiftUI

// MARK: - Prompt Tab

struct RoleEditorPromptTab: View {
    @Binding var editorState: RoleEditorState
    let mode: EditorMode<TeamRoleDefinition>
    let toolDefinitions: [ToolDefinitionRecord]
    let team: Team

    private var currentRoleDefinition: TeamRoleDefinition {
        TeamRoleDefinition(
            id: {
                if case .edit(let role) = mode { return role.id }
                return UUID().uuidString
            }(),
            name: editorState.roleName,
            icon: editorState.roleIcon,
            prompt: editorState.rolePrompt,
            toolIDs: Array(editorState.selectedTools),
            usePlanningPhase: editorState.usePlanningPhase,
            dependencies: RoleDependencies(
                requiredArtifacts: editorState.requiredArtifacts,
                producesArtifacts: editorState.producedArtifacts
            ),
            llmOverride: editorState.llmOverrideEnabled ? LLMOverride(
                baseURLString: editorState.llmBaseURL.isEmpty ? nil : editorState.llmBaseURL,
                modelName: editorState.llmModelName.isEmpty ? nil : editorState.llmModelName
            ) : nil,
            isSystemRole: false,
            systemRoleID: {
                if case .edit(let role) = mode { return role.systemRoleID }
                return nil
            }(),
            iconColor: editorState.roleIconColor,
            iconBackground: editorState.roleIconBackground
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Role Guidance")
                            .font(.headline)
                        Text("This text is injected into the team's system prompt template as **{roleGuidance}**. It defines what this role focuses on, its expertise, and how it should approach tasks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        editorState.showingPromptPreview = true
                    } label: {
                        Label("Preview Full Prompt", systemImage: "eye")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Preview the complete system prompt that the LLM receives, with this guidance inserted into the template")
                }
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.top, Spacing.s)

            TextEditor(text: $editorState.rolePrompt)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(Spacing.s)
                .background(Colors.surfacePrimary)
                
                .padding(.horizontal, Spacing.standard)
                .padding(.bottom, Spacing.s)
        }
        .sheet(isPresented: $editorState.showingPromptPreview) {
            PromptPreviewSheet(
                roleDefinition: currentRoleDefinition,
                toolDefinitions: toolDefinitions,
                team: team
            )
        }
    }
}

#Preview("Role Prompt Editor") {
    @Previewable @State var editorState: RoleEditorState = {
        var s = RoleEditorState()
        s.roleName = "Software Engineer"
        s.rolePrompt = "You are an expert software engineer focused on writing clean, maintainable code.\n\nKey responsibilities:\n- Implement features according to the technical plan\n- Write unit tests for all new code\n- Follow project conventions and best practices"
        return s
    }()

    let role = TeamRoleDefinition(id: "swe", name: "Software Engineer", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies())

    RoleEditorPromptTab(
        editorState: $editorState,
        mode: .edit(role),
        toolDefinitions: [],
        team: Team(name: "Preview Team")
    )
    .frame(width: 600, height: 250)
    .background(Colors.surfacePrimary)
}
