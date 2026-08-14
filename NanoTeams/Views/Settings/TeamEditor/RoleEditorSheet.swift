import SwiftUI

// MARK: - Role Editor Section Policy (pure, testable)

/// Pure policy for which editor sections a role exposes. Extracted so the
/// managed-singleton (Autovisor) restrictions are unit-tested without a SwiftUI
/// host. See `RoleEditorSectionPolicyTests`.
///
/// The Tools tab's "auto-injected" list used to be answered here too, by a
/// `conclude_meeting` predicate and an `ask_supervisor` flag that each restated a
/// rule owned by `LLMExecutionService+ToolResolution`. Both are gone: the sheet now
/// asks the resolver itself (`RoleEditorSheet.autoInjectedToolNames`), so the editor
/// cannot claim an injection the runtime won't perform.
nonisolated enum RoleEditorSectionPolicy {

    /// - Supervisor: General + Dependencies only (user-controlled, not LLM-driven —
    ///   it has no system prompt, so `.skills` would have nowhere to land).
    /// - Managed singleton (Autovisor) manager: Prompt + Tools + Skills. Identity,
    ///   dependencies and delegation are structural/template-owned, but the
    ///   manager runs a step template like any other role, and
    ///   `syncAutovisorTeamToTemplate` touches only `icon`/`toolIDs` — so
    ///   attachments survive every open.
    /// - Any other non-Supervisor role: the full set.
    static func availableSections(isSupervisor: Bool, isManagedSingleton: Bool) -> [RoleSection] {
        if isSupervisor { return [.general, .dependencies] }
        if isManagedSingleton { return [.prompt, .tools, .skills] }
        return RoleSection.allCases
    }

    /// The section the editor opens on: the default when it's available, otherwise the
    /// first available (e.g. the manager's default `.general` isn't offered → opens `.prompt`).
    static func initialSection(defaultSection: RoleSection, available: [RoleSection]) -> RoleSection {
        available.contains(defaultSection) ? defaultSection : (available.first ?? defaultSection)
    }

}

// MARK: - Role Editor Sheet

/// Sheet for creating/editing team roles with tabbed sections.
struct RoleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NTMSOrchestrator.self) var store
    @Environment(StoreConfiguration.self) var config
    @Binding var team: Team
    let mode: EditorMode<TeamRoleDefinition>
    let onSave: () -> Void

    // Seeded synchronously at init time via `State(initialValue:)`. The
    // previous `@State editorState = RoleEditorState() + .onAppear { load }`
    // pattern left a one-tick window during which the first body
    // evaluation rendered with the default-empty state. Per CLAUDE.md #26.
    @State private var editorState: RoleEditorState

    init(team: Binding<Team>, mode: EditorMode<TeamRoleDefinition>, onSave: @escaping () -> Void) {
        self._team = team
        self.mode = mode
        self.onSave = onSave
        var initialState: RoleEditorState
        if case .edit(let role) = mode {
            initialState = RoleEditorState.loaded(from: role)
            // Open on a section that's actually available (e.g. the managed singleton's
            // default `.general` isn't offered → open `.prompt`), never an absent tab.
            initialState.activeSection = RoleEditorSectionPolicy.initialSection(
                defaultSection: initialState.activeSection,
                available: RoleEditorSectionPolicy.availableSections(
                    isSupervisor: role.isSupervisor,
                    isManagedSingleton: team.wrappedValue.isManagedSingleton
                )
            )
        } else {
            initialState = RoleEditorState()
        }
        self._editorState = State(initialValue: initialState)
    }

    /// True if editing the Supervisor role (user-controlled, not LLM-driven)
    private var isEditingSupervisor: Bool {
        if case .edit(let role) = mode {
            return role.isSupervisor
        }
        return false
    }

    /// True when editing the managed singleton's (Autovisor's) Manager role — its
    /// tool policy is locked-mandatory + restricted-optional (see `AutovisorConstants`).
    private var isManagedSingletonRole: Bool {
        team.isManagedSingleton && !isEditingSupervisor
    }

    /// Tools the runtime will add on top of the user's selection, for the Tools
    /// tab's "Auto-injected" list.
    ///
    /// Asks the real resolver against the LIVE draft (`provisionalDefinition`), so
    /// the list tracks in-flight toggles AND can never advertise an injection the
    /// runtime declines — the delegation pack is withheld when every whitelisted
    /// team has been deleted or turned chat-mode, and `ask_supervisor` is stripped
    /// for the Autovisor manager, neither of which the editor's own booleans knew.
    private var autoInjectedToolNames: [String] {
        RoleToolBadgePolicy.model(
            role: editorState.provisionalDefinition(mode: mode),
            team: team,
            allTeams: store.workFolder?.teams ?? [],
            storage: .from(orchestratorURL: store.workFolderURL),
            selectedScheme: store.snapshot?.workFolder.settings.selectedScheme,
            isVisionConfigured: store.configuration.isVisionConfigured,
            isComputerUseEnabled: store.configuration.isComputerUseEnabled,
            autovisorTeamPolicy: store.snapshot.map { AutovisorTeamPolicy(settings: $0.workFolder.settings) }
                ?? .unrestricted
        ).autoInjected
    }

    /// Sections available for the current role:
    /// - Supervisor: General + Dependencies only.
    /// - Any non-Supervisor: full set including Delegation. Peer-status no
    ///   longer gates the tab — the save handler clears `reportsTo` when the
    ///   user enables delegation, so any non-Supervisor role can become a
    ///   delegator from this surface.
    private var availableSections: [RoleSection] {
        RoleEditorSectionPolicy.availableSections(
            isSupervisor: isEditingSupervisor,
            isManagedSingleton: team.isManagedSingleton
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header (with Cancel/Save actions)
            headerBar

            TerminalDivider()

            // Section tabs
            TerminalSegmentedPicker(
                selection: $editorState.activeSection,
                options: availableSections.map { (value: $0, label: $0.label) }
            )
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.s)

            // Section content
            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 720, idealHeight: 800)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Spacing.s) {
            MonoLabel(text: mode.isCreate ? "New Role" : "Edit Role", marker: true)

            Spacer()

            if !isValid {
                Text(isEditingSupervisor ? "Name is required" : "Name and prompt are required")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
            }

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.terminalSecondary)

            Button("Save") {
                if saveRole() { dismiss() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.terminalPrimary)
            .disabled(!isValid)
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
            RoleEditorPromptTab(editorState: $editorState, mode: mode, team: team)
        case .tools:
            RoleEditorToolsTab(
                editorState: $editorState,
                autoInjectedTools: autoInjectedToolNames,
                lockedTools: isManagedSingletonRole ? AutovisorConstants.managerMandatoryToolIDs : [],
                restrictToTools: isManagedSingletonRole ? Set(AutovisorConstants.managerDefaultToolIDs) : nil
            )
        case .dependencies:
            RoleEditorDependenciesTab(editorState: $editorState, isEditingSupervisor: isEditingSupervisor, team: $team)
        case .skills:
            RoleEditorSkillsTab(editorState: $editorState)
        case .llm:
            RoleEditorLLMTab(
                editorState: $editorState,
                llmProvider: config.llmProvider,
                onTokenSaveError: { error in
                    store.lastErrorMessage = "Could not save API token: \(error.localizedDescription)"
                },
                onTokenLoadError: { error in
                    store.lastErrorMessage = "Could not read saved API token: \(error.localizedDescription)"
                }
            )
        case .delegation:
            RoleEditorDelegationTab(
                editorState: $editorState,
                team: team,
                allTeams: store.workFolder?.teams ?? []
            )
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        let nameValid = !editorState.roleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEditingSupervisor { return nameValid }
        return nameValid && !editorState.rolePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    /// Returns `true` when the save actually landed. `false` means the role
    /// disappeared mid-edit (e.g. concurrent `handleDeleteRole` from another
    /// view); the caller must keep the sheet open so the user can copy out
    /// their work or cancel explicitly, instead of silently dismissing as if
    /// nothing happened.
    private func saveRole() -> Bool {
        // Compose every mutation on a local copy and ship it through the
        // `team` Binding via a single assignment. Multiple consecutive writes
        // to the Binding race because `TeamEditorView.binding(for:)` has a
        // captured-value getter — the second write reads the stale snapshot
        // and silently overwrites the first. See `RoleEditorMutations` doc.
        var newTeam = team
        switch mode {
        case .create:
            _ = RoleEditorMutations.applyCreate(
                to: &newTeam,
                editorState: editorState,
                teamID: newTeam.id
            )
            team = newTeam
        case .edit(let role):
            guard RoleEditorMutations.applyEdit(
                to: &newTeam,
                editorState: editorState,
                existingRoleID: role.id
            ) else {
                store.lastErrorMessage = "Could not save role — “\(editorState.roleName)” no longer exists in this team. It may have been deleted in another view."
                return false
            }
            team = newTeam
        }
        onSave()
        return true
    }

}

#Preview {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    RoleEditorSheet(
        team: .constant(.default),
        mode: .create,
        onSave: {}
    )
    .environment(store)
    .environment(store.configuration)
}
