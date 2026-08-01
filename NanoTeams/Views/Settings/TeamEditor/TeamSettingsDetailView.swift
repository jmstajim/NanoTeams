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

    /// Name and description are edited through local drafts and committed on
    /// submit / focus loss, matching what every OTHER field in this view
    /// already does.
    ///
    /// They used to bind straight to `$team.name` / `$team.description`. That
    /// Binding is `TeamEditorView.binding(for:)`, whose setter spawns
    /// `Task { await store.mutateWorkFolder … }` — so every KEYSTROKE queued a
    /// full `teams.json` write, each one carrying the same captured pre-edit
    /// snapshot (the same stale-getter hazard documented on
    /// `ArtifactEditorMutations` / `RoleEditorMutations`).
    @State private var draftName: String = ""
    @State private var draftDescription: String = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case description
    }

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
        // Commit the draft whichever field the user just LEFT — the blur half of
        // the submit/blur pair. `onSubmit` covers Return in the name field;
        // `TextEditor` has no submit, so blur is its only commit point.
        .onChange(of: focusedField) { previous, _ in
            switch previous {
            case .name: commitName()
            case .description: commitDescription()
            case nil: break
            }
        }
        .onDisappear {
            commitName()
            commitDescription()
        }
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
                TextField("Team Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .terminalField()
                    .focused($focusedField, equals: .name)
                    .onSubmit { commitName() }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Description")
                        .font(Typography.subheadline)
                        .foregroundStyle(Colors.textSecondary)
                    TextEditor(text: $draftDescription)
                        .font(Typography.termBase)
                        .frame(minHeight: 60, maxHeight: 120)
                        .borderedTextEditorStyle()
                        .focused($focusedField, equals: .description)
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
        draftName = team.name
        draftDescription = team.description
    }

    /// Single Binding write, and only when the value actually changed — a
    /// no-op commit would still queue a `teams.json` write on every focus
    /// change. Routed through `Team.rename(to:)` so `team.updatedAt` bumps and
    /// `Team.==`'s id+timestamp shortcut doesn't suppress observers.
    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty team name is not a rename the user meant — restore rather
        // than persist a nameless team into the picker.
        guard !trimmed.isEmpty else {
            draftName = team.name
            return
        }
        guard trimmed != team.name else { return }
        var newTeam = team
        newTeam.rename(to: trimmed)
        team = newTeam
        draftName = trimmed
        onSave()
    }

    private func commitDescription() {
        guard draftDescription != team.description else { return }
        var newTeam = team
        newTeam.description = draftDescription
        newTeam.updatedAt = MonotonicClock.shared.now()
        team = newTeam
        onSave()
    }
}

// MARK: - Previews

#Preview("Team Settings") {
    @Previewable @State var team = Team.default
    TeamSettingsDetailView(team: $team, onSave: {})
        .frame(width: 500, height: 600)
}
