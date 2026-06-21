import SwiftUI

// MARK: - Pure predicate: will conclude_meeting be auto-injected?

/// Pure-logic backing for the Tools-tab "auto-injected" badge on
/// `conclude_meeting`. Must mirror `LLMExecutionService+ToolResolution.swift`
/// step 6 exactly:
///   - Coordinator mode (`designatedCoordinatorID` set & live): only the
///     matching role gets `conclude_meeting`.
///   - Auto mode (`designatedCoordinatorID == nil` OR orphan-normalized to
///     nil): every role with `request_team_meeting` in its **live** tool
///     selection gets it (since the meeting initiator becomes the effective
///     coordinator).
enum RoleEditorConcludeMeetingPredicate {

    /// Inner predicate — assumes `designatedCoordinatorID` has already been
    /// orphan-normalized by the caller. Driven by `liveSelectedTools` so the
    /// badge tracks in-flight tool toggles, not the persisted snapshot.
    static func evaluate(
        roleID: String,
        liveSelectedTools: Set<String>,
        designatedCoordinatorID: String?
    ) -> Bool {
        guard liveSelectedTools.contains(ToolNames.requestTeamMeeting) else { return false }
        return designatedCoordinatorID == nil || designatedCoordinatorID == roleID
    }

    /// Editor-context entry point — wires `editorState.selectedTools` (live)
    /// + team-side designated coordinator (orphan-normalized) into the inner
    /// predicate. Returns `false` for create-mode (no concrete role yet),
    /// for the Supervisor role (Supervisor is the user, never receives
    /// auto-injected LLM tools), and falls through to `evaluate` otherwise.
    ///
    /// Extracting this as a static helper (vs. inlining in the View's
    /// computed property) makes the wiring regression-testable: a misroute
    /// to `role.toolIDs` (stale snapshot — the round-1 review I1 bug) or
    /// missing Supervisor guard (round-3 review CR.2) is caught by
    /// `RoleEditorConcludeMeetingPredicateTests`'s wiring tests.
    static func fromEditorContext(
        mode: EditorMode<TeamRoleDefinition>,
        editorState: RoleEditorState,
        team: Team
    ) -> Bool {
        guard case .edit(let role) = mode else { return false }
        guard !role.isSupervisor else { return false }
        let normalizedCoordID = DesignatedCoordinatorResolver.normalize(
            storedID: team.settings.meetingCoordinatorRoleID,
            // Supervisor is structurally not a valid coordinator — filter
            // it out so a stored Supervisor ID self-heals to Auto-mode
            // exactly the same way the picker (which only offers
            // non-Supervisor roles) presents it.
            availableIDs: team.roles.filter { !$0.isSupervisor }.map(\.id)
        )
        return evaluate(
            roleID: role.id,
            liveSelectedTools: editorState.selectedTools,
            designatedCoordinatorID: normalizedCoordID
        )
    }
}

// MARK: - Role Editor Section Policy (pure, testable)

/// Pure policy for which editor sections a role exposes and whether it auto-injects
/// `ask_supervisor`. Extracted so the managed-singleton (Autovisor) restrictions are
/// unit-tested without a SwiftUI host. See `RoleEditorSectionPolicyTests`.
nonisolated enum RoleEditorSectionPolicy {

    /// - Supervisor: General + Dependencies only (user-controlled, not LLM-driven).
    /// - Managed singleton (Autovisor) manager: Prompt + Tools only (identity,
    ///   dependencies, delegation are structural/template-owned).
    /// - Any other non-Supervisor role: the full set.
    static func availableSections(isSupervisor: Bool, isManagedSingleton: Bool) -> [RoleSection] {
        if isSupervisor { return [.general, .dependencies] }
        if isManagedSingleton { return [.prompt, .tools] }
        return RoleSection.allCases
    }

    /// The section the editor opens on: the default when it's available, otherwise the
    /// first available (e.g. the manager's default `.general` isn't offered → opens `.prompt`).
    static func initialSection(defaultSection: RoleSection, available: [RoleSection]) -> RoleSection {
        available.contains(defaultSection) ? defaultSection : (available.first ?? defaultSection)
    }

    /// Whether `ask_supervisor` is actually auto-injected at runtime for this role.
    /// False for the Autovisor manager — it IS the top Supervisor (runtime excludes it),
    /// so the editor must not show it as auto-injected.
    static func injectsAskSupervisor(isManagedSingleton: Bool) -> Bool {
        !isManagedSingleton
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

    /// True if this role will get `conclude_meeting` auto-injected at runtime
    /// — used to show the tool with an "auto-injected" badge in the Tools tab.
    /// All wiring lives in `RoleEditorConcludeMeetingPredicate.fromEditorContext`
    /// (testable), this property is a thin pass-through.
    private var willAutoInjectConcludeMeeting: Bool {
        RoleEditorConcludeMeetingPredicate.fromEditorContext(
            mode: mode, editorState: editorState, team: team
        )
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
                isMeetingCoordinator: willAutoInjectConcludeMeeting,
                lockedTools: isManagedSingletonRole ? AutovisorConstants.managerMandatoryToolIDs : [],
                restrictToTools: isManagedSingletonRole ? Set(AutovisorConstants.managerDefaultToolIDs) : nil,
                // The Autovisor manager IS the top Supervisor — runtime never injects
                // ask_supervisor for it, so the editor must not show it as auto-injected.
                injectsAskSupervisor: RoleEditorSectionPolicy.injectsAskSupervisor(
                    isManagedSingleton: isManagedSingletonRole
                )
            )
        case .dependencies:
            RoleEditorDependenciesTab(editorState: $editorState, isEditingSupervisor: isEditingSupervisor, team: $team)
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
