import SwiftUI

// MARK: - Team Settings Detail View

/// View for editing team settings (name, acceptance mode, limits, collaboration).
/// Displayed under the "Settings" tab in TeamEditorView.
struct TeamSettingsDetailView: View {
    @Binding var team: Team
    let onSave: () -> Void

    @State private var acceptanceMode: AcceptanceMode = .afterEachRole
    @State private var acceptanceCheckpoints: Set<String> = []
    @State private var supervisorMode: SupervisorMode = .manual
    @State private var supervisorCanBeInvited: Bool = false
    @State private var limits: TeamLimits = .default

    var body: some View {
        Form {
            generalSection
            acceptanceSection
            supervisorModeSection
            TeamSettingsCollaborationSection(
                team: $team,
                supervisorCanBeInvited: $supervisorCanBeInvited,
                nonSupervisorRoles: nonSupervisorRoles,
                onSave: onSave
            )
            TeamSettingsLimitsSection(limits: $limits)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            loadSettings()
        }
        .onChange(of: team.id) { _, _ in
            loadSettings()
        }
        .onChange(of: team.name) { _, _ in onSave() }
        .onChange(of: team.description) { _, _ in onSave() }
        .onChange(of: acceptanceMode) { _, newValue in
            team.settings.defaultAcceptanceMode = newValue
            onSave()
        }
        .onChange(of: acceptanceCheckpoints) { _, newValue in
            team.settings.acceptanceCheckpoints = newValue
            onSave()
        }
        .onChange(of: supervisorMode) { _, newValue in
            team.settings.supervisorMode = newValue
            onSave()
        }
        .onChange(of: supervisorCanBeInvited) { _, newValue in
            team.settings.supervisorCanBeInvited = newValue
            onSave()
        }
        .onChange(of: limits) { _, newValue in
            team.settings.limits = newValue
            onSave()
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            TextField("Team Name", text: $team.name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $team.description)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .borderedTextEditorStyle()
            }
        } header: {
            Text("General")
        }
    }

    // MARK: - Acceptance

    private var acceptanceSection: some View {
        Section {
            Picker("Mode", selection: $acceptanceMode) {
                ForEach(AcceptanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Text(acceptanceMode.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            if acceptanceMode == .customCheckpoints {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Roles Requiring Approval")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    ForEach(nonSupervisorRoles) { role in
                        Toggle(role.name, isOn: Binding(
                            get: { acceptanceCheckpoints.contains(role.id) },
                            set: { isOn in
                                if isOn {
                                    acceptanceCheckpoints.insert(role.id)
                                } else {
                                    acceptanceCheckpoints.remove(role.id)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.top, Spacing.xs)
            }
        } header: {
            Text("Acceptance & Review")
        } footer: {
            Text("Controls when the Supervisor reviews and approves team output.")
        }
    }

    // MARK: - Supervisor Mode

    private var supervisorModeSection: some View {
        Section {
            Picker("Mode", selection: $supervisorMode) {
                ForEach(SupervisorMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text(supervisorMode.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Ask Supervisor")
        } footer: {
            Text("Controls how the team handles questions to the Supervisor.")
        }
    }

    // MARK: - Helpers

    private var nonSupervisorRoles: [TeamRoleDefinition] {
        team.nonSupervisorRoles
    }

    private func loadSettings() {
        acceptanceMode = team.settings.defaultAcceptanceMode
        acceptanceCheckpoints = team.settings.acceptanceCheckpoints
        supervisorMode = team.settings.supervisorMode
        supervisorCanBeInvited = team.settings.supervisorCanBeInvited
        limits = team.settings.limits
    }
}

// MARK: - Previews

#Preview("Team Settings") {
    @Previewable @State var team = Team.default
    TeamSettingsDetailView(team: $team, onSave: {})
        .frame(width: 500, height: 600)
}
