import SwiftUI

// MARK: - Role Editor Sheet

/// Sheet for creating/editing team roles with tabbed sections.
struct RoleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NTMSOrchestrator.self) var store
    @Environment(StoreConfiguration.self) var config
    @Binding var team: Team
    let mode: EditorMode<TeamRoleDefinition>
    let onSave: () -> Void

    @State private var editorState = RoleEditorState()

    /// True if editing the Supervisor role (user-controlled, not LLM-driven)
    private var isEditingSupervisor: Bool {
        if case .edit(let role) = mode {
            return role.isSupervisor
        }
        return false
    }

    /// True if editing the team's Meeting Coordinator — used to show
    /// `conclude_meeting` as auto-injected in the Tools tab.
    private var isEditingMeetingCoordinator: Bool {
        if case .edit(let role) = mode {
            return team.settings.meetingCoordinatorRoleID == role.id
        }
        return false
    }

    /// Sections available for the current role (Supervisor only sees General + Dependencies)
    private var availableSections: [RoleSection] {
        if isEditingSupervisor {
            return [.general, .dependencies]
        }
        return RoleSection.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()

            // Section tabs
            Picker("Section", selection: $editorState.activeSection) {
                ForEach(availableSections) { section in
                    Text(section.label).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.s)

            // Section content
            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer
            footerBar
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 720, idealHeight: 800)
        .onAppear {
            if case .edit(let role) = mode {
                editorState.load(from: role)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text(mode.isCreate ? "New Role" : "Edit Role")
                .font(.title3)
                .fontWeight(.semibold)

            Spacer()
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.m)
    }

    // MARK: - Section Content

    @ViewBuilder
    private var sectionContent: some View {
        switch editorState.activeSection {
        case .general:
            RoleEditorGeneralTab(editorState: $editorState, isEditingSupervisor: isEditingSupervisor)
        case .prompt:
            RoleEditorPromptTab(editorState: $editorState, mode: mode, toolDefinitions: store.toolDefinitions, team: team)
        case .tools:
            RoleEditorToolsTab(editorState: $editorState, isMeetingCoordinator: isEditingMeetingCoordinator)
        case .dependencies:
            RoleEditorDependenciesTab(editorState: $editorState, isEditingSupervisor: isEditingSupervisor, team: $team)
        case .llm:
            RoleEditorLLMTab(editorState: $editorState, llmProvider: config.llmProvider)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if !isValid {
                Text(isEditingSupervisor ? "Name is required" : "Name and prompt are required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Save") {
                saveRole()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!isValid)
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.m)
    }

    // MARK: - Validation

    private var isValid: Bool {
        let nameValid = !editorState.roleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEditingSupervisor { return nameValid }
        return nameValid && !editorState.rolePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func saveRole() {
        // SystemTemplates.supervisorTaskArtifactName can only be produced by the Supervisor role
        let sanitizedProduced = editorState.producedArtifacts.filter { $0 != SystemTemplates.supervisorTaskArtifactName }
        let dependencies = RoleDependencies(
            requiredArtifacts: editorState.requiredArtifacts,
            producesArtifacts: sanitizedProduced
        )

        let llmOverride: LLMOverride? = editorState.llmOverrideEnabled ? LLMOverride(
            baseURLString: editorState.llmBaseURL.isEmpty ? nil : editorState.llmBaseURL,
            modelName: editorState.llmModelName.isEmpty ? nil : editorState.llmModelName,
            maxTokens: editorState.overrideMaxTokens > 0 ? editorState.overrideMaxTokens : nil,
            temperature: editorState.overrideTemperature
        ) : nil

        switch mode {
        case .create:
            let now = MonotonicClock.shared.now()
            let newRole = TeamRoleDefinition(
                id: NTMSID.from(name: "\(team.id):\(editorState.roleName)"),
                name: editorState.roleName,
                icon: editorState.roleIcon,
                prompt: editorState.rolePrompt,
                toolIDs: Array(editorState.selectedTools),
                usePlanningPhase: editorState.usePlanningPhase,
                dependencies: dependencies,
                llmOverride: llmOverride,
                isSystemRole: false,
                systemRoleID: nil,
                iconColor: editorState.roleIconColor,
                iconBackground: editorState.roleIconBackground,
                createdAt: now,
                updatedAt: now
            )
            TeamManagementService.addRole(to: &team, role: newRole)

        case .edit(let role):
            if let index = team.roles.firstIndex(where: { $0.id == role.id }) {
                // Single write — multiple individual assignments would each trigger
                // the Binding setter separately, and the captured-value getter in
                // TeamEditorView.binding(for:) causes later writes to overwrite earlier ones.
                var updated = team.roles[index]
                updated.name = editorState.roleName
                updated.icon = editorState.roleIcon
                updated.iconColor = editorState.roleIconColor
                updated.iconBackground = editorState.roleIconBackground
                if updated.isSupervisor {
                    // Supervisor is user-controlled — lock produced artifact, clear LLM fields
                    updated.dependencies = RoleDependencies(
                        requiredArtifacts: editorState.requiredArtifacts,
                        producesArtifacts: [SystemTemplates.supervisorTaskArtifactName]
                    )
                    updated.prompt = ""
                    updated.toolIDs = []
                    updated.usePlanningPhase = false
                    updated.llmOverride = nil
                } else {
                    updated.dependencies = dependencies
                    updated.prompt = editorState.rolePrompt
                    updated.toolIDs = Array(editorState.selectedTools)
                    updated.usePlanningPhase = editorState.usePlanningPhase
                    updated.llmOverride = llmOverride
                }
                updated.updatedAt = MonotonicClock.shared.now()
                team.roles[index] = updated
            }
        }

        onSave()
    }

}

#Preview {
    RoleEditorSheet(
        team: .constant(.default),
        mode: .create,
        onSave: {}
    )
}
