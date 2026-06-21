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
        ScrollView {
            VStack(spacing: Spacing.xl) {
                generalSection
                // The managed singleton (Autovisor) hides settings it can't honor:
                // acceptance/supervisor-mode are forced for the autonomous chat-mode
                // manager (changing them breaks it), and collaboration/limits are
                // meaningless for its single management role.
                if !team.isManagedSingleton {
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
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
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
        SettingsCard(header: "General", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                TextField("Team Name", text: $team.name)
                    .textFieldStyle(.plain)
                    .terminalField()

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Description")
                        .font(Typography.subheadline)
                        .foregroundStyle(Colors.textSecondary)
                    TextEditor(text: $team.description)
                        .font(Typography.termBase)
                        .frame(minHeight: 60, maxHeight: 120)
                        .borderedTextEditorStyle()
                }
            }
        }
    }

    // MARK: - Acceptance

    private var acceptanceSection: some View {
        SettingsCard(
            header: "Acceptance & Review",
            systemImage: "checkmark.seal",
            footer: "Controls when the Supervisor reviews and approves team output."
        ) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text("Mode")
                    Spacer()
                    TerminalPicker(
                        selection: $acceptanceMode,
                        options: AcceptanceMode.allCases.map { (value: $0, label: $0.displayName) }
                    )
                }

                Text(acceptanceMode.description)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)

                if acceptanceMode == .customCheckpoints {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Roles Requiring Approval")
                            .font(Typography.subheadlineMedium)

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
                            .toggleStyle(.terminal)
                        }
                    }
                    .padding(.top, Spacing.xs)
                }
            }
        }
    }

    // MARK: - Supervisor Mode

    private var supervisorModeSection: some View {
        SettingsCard(
            header: "Ask Supervisor",
            systemImage: "person.fill.questionmark",
            footer: "Controls how the team handles questions to the Supervisor."
        ) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text("Mode")
                    Spacer()
                    TerminalSegmentedPicker(
                        selection: $supervisorMode,
                        options: SupervisorMode.allCases.map { (value: $0, label: $0.displayName) }
                    )
                }
                Text(supervisorMode.description)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
            }
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
