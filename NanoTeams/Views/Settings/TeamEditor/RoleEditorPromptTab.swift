import SwiftUI

// MARK: - Prompt Tab

struct RoleEditorPromptTab: View {
    @Binding var editorState: RoleEditorState
    let mode: EditorMode<TeamRoleDefinition>
    let team: Team

    @Environment(NTMSOrchestrator.self) private var store

    /// The role as the editor currently has it — what "Preview Full Prompt"
    /// renders, so it must reflect EVERY field that reaches the prompt.
    ///
    /// Built by mutating the edited role rather than by enumerating fields into
    /// the memberwise init. The enumerate-fields shape silently dropped whatever
    /// it forgot — it was missing both delegation fields (so the preview omitted
    /// the auto-injected 4-tool delegation pack) and `provider:` on the LLM
    /// override. Mutating a copy also means a field added later shows up in the
    /// preview with no edit here. Same lesson as `Team.duplicate`.
    private var currentRoleDefinition: TeamRoleDefinition {
        editorState.provisionalDefinition(mode: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        MonoLabel(text: "Role Guidance", marker: true)
                        Text("This text is injected into the team's system prompt template as **{roleGuidance}**. It defines what this role focuses on, its expertise, and how it should approach tasks.")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textSecondary)
                    }

                    Spacer()

                    Button {
                        editorState.showingPromptPreview = true
                    } label: {
                        Label("Preview Full Prompt", systemImage: "eye")
                            .font(Typography.caption)
                    }
                    .buttonStyle(.terminalSecondary)
                    .controlSize(.small)
                    .help("Preview the complete system prompt that the LLM receives, with this guidance inserted into the template")
                }
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.top, Spacing.s)

            HStack(alignment: .top, spacing: Spacing.xs) {
                PromptMarker()
                TextEditor(text: $editorState.rolePrompt)
                    .font(Typography.termBase)
                    .scrollContentBackground(.hidden)
            }
            .padding(Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.surfacePrimary)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.small)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
            .padding(.horizontal, Spacing.standard)
            .padding(.bottom, Spacing.s)
        }
        .sheet(isPresented: $editorState.showingPromptPreview) {
            PromptPreviewSheet(
                roleDefinition: currentRoleDefinition,
                team: team,
                workFolder: store.snapshot?.projection
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
        team: Team(name: "Preview Team")
    )
    .frame(width: 600, height: 250)
    .background(Colors.surfacePrimary)
    .environment(NTMSOrchestrator(repository: NTMSRepository()))
}
