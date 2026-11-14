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
///
/// `team` is the Team Editor's binding (`TeamEditorView.binding(for:)`), rebuilt on every render
/// of the editor; `session` is what the click that opened the sheet captured — the team and the
/// folder lifecycle the person was looking at (`TeamEditSheetRequest`). Save composes the role on
/// `team`, commits it as `session` and closes only once that write landed (`RoleEditorSheet.save`);
/// a refusal — the write failed, or the folder or the edited team changed while the sheet was open
/// — keeps the sheet open with the reason. Cancel and Escape ask before throwing away edits
/// (`EditorSheetClosePolicy`, shared with `ArtifactEditorSheet`). Previews:
/// `RoleEditorSheet+Previews.swift`.
struct RoleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NTMSOrchestrator.self) var store
    @Environment(StoreConfiguration.self) var config
    @Binding var team: Team
    /// The team and folder this sheet saves into, or nowhere.
    let session: TeamEditCommitQueue.Session
    let mode: EditorMode<TeamRoleDefinition>
    let onSave: () -> Void

    // Seeded synchronously at init time via `State(initialValue:)`. The
    // previous `@State editorState = RoleEditorState() + .onAppear { load }`
    // pattern left a one-tick window during which the first body
    // evaluation rendered with the default-empty state. Per CLAUDE.md #26.
    @State private var editorState: RoleEditorState
    /// A Save is waiting for its write: Save and Cancel are off, so Escape does nothing.
    @State private var isSaving = false
    /// Why the last Save did not land — shown in the sheet, which stayed open.
    @State private var saveError: String?
    @State private var isConfirmingDiscard = false

    /// `saveError` is the line the sheet opens with: `nil` wherever a person opens it, since
    /// only a failed Save sets one. The previews pass one, so the refused state can be looked at
    /// without a disk that refuses a write (the `ExternalAgentSheet` precedent).
    init(
        team: Binding<Team>,
        session: TeamEditCommitQueue.Session,
        mode: EditorMode<TeamRoleDefinition>,
        onSave: @escaping () -> Void,
        saveError: String? = nil
    ) {
        self._team = team
        self.session = session
        self.mode = mode
        self.onSave = onSave
        self._saveError = State(initialValue: saveError)
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
    /// Step-execution injections plus the coordinator's meeting-only tool — one list,
    /// because the Tools tab has one "Auto-injected" section and the per-tool hint says
    /// which turn a tool rides.
    private var autoInjectedToolNames: [String] {
        let model = RoleToolBadgePolicy.model(
            role: editorState.provisionalDefinition(mode: mode),
            team: team,
            allTeams: store.workFolder?.teams ?? [],
            storage: .from(orchestratorURL: store.workFolderURL),
            selectedScheme: store.snapshot?.workFolder.settings.selectedScheme,
            isVisionConfigured: store.configuration.isVisionConfigured,
            approval: approvalAvailability,
            autovisorTeamPolicy: store.snapshot.map { AutovisorTeamPolicy(settings: $0.workFolder.settings) }
                ?? .unrestricted,
            mcpGrants: mcpGrants
        )
        return model.autoInjected + model.meetingOnly
    }

    /// Every configured MCP server and what it publishes — read once here and handed to both
    /// the auto-injected list and the Tools tab, so a grant's row and its hint cannot
    /// disagree about whether the server is reachable.
    var mcpGrants: MCPGrantCatalogue { store.mcpServerManager?.grantCatalogue ?? .empty }

    /// The folder-level answer to "would a human be there to approve" — the team's Supervisor
    /// mode against Autovisor supervision of this folder — read with the two execution modes,
    /// so the Tools tab hints and the auto-injected list describe the schema the wire ships.
    private var approvalAvailability: ToolApprovalAvailability {
        ToolApprovalAvailability.forTeam(
            bashMode: store.configuration.bashMode,
            computerUseMode: store.configuration.computerUseMode,
            team: team,
            workFolderSettings: store.snapshot?.workFolder.settings)
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

            if let saveError {
                EditorSheetSaveErrorBanner(message: saveError)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.top, Spacing.s)
            }

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
        // Escape is taken by Cancel's `.cancelAction`; this keeps the sheet's own dismissal
        // out of it while there is something to lose or a write to wait for.
        .interactiveDismissDisabled(isSaving || editorState.hasUnsavedChanges(mode: mode))
        .discardChangesConfirmation(of: "role", isPresented: $isConfirmingDiscard) { dismiss() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Spacing.s) {
            MonoLabel(text: mode.isCreate ? "New Role" : "Edit Role", marker: true)

            Spacer()

            if isSaving {
                SavingIndicator()
            } else if !isValid {
                Text(isEditingSupervisor ? "Name is required" : "Name and prompt are required")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
            }

            Button("Cancel") {
                requestClose()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.terminalSecondary)
            .disabled(isSaving)

            Button("Save") {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.terminalPrimary)
            .disabled(!isValid || isSaving)
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
                approval: approvalAvailability,
                lockedTools: isManagedSingletonRole ? AutovisorConstants.managerMandatoryToolIDs : [],
                restrictToTools: isManagedSingletonRole ? Set(AutovisorConstants.managerDefaultToolIDs) : nil,
                mcpGrants: isManagedSingletonRole ? .empty : mcpGrants
            )
        case .dependencies:
            RoleEditorDependenciesTab(
                editorState: $editorState, isEditingSupervisor: isEditingSupervisor, team: $team, session: session)
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

    /// Save, then close — only once the write landed. Until 2026-11-08 the sheet closed on the
    /// Binding assignment, whose setter merely started a write: a tool ticked here could vanish
    /// with no sign. A refused write keeps the sheet open with the reason and the draft intact.
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        let failure = await Self.save(editorState, mode: mode, session: session, onto: team, through: store.teamEdits)
        isSaving = false
        if let failure {
            saveError = failure
            return
        }
        onSave()
        dismiss()
    }

    /// Cancel and Escape: close at once only when nothing would be lost.
    private func requestClose() {
        switch EditorSheetClosePolicy.onCancel(
            hasUnsavedChanges: editorState.hasUnsavedChanges(mode: mode), isSaving: isSaving
        ) {
        case .close: dismiss()
        case .confirmDiscard: isConfirmingDiscard = true
        case .ignore: break
        }
    }

    /// The Save apart from the view: the draft composed on `team` — the team the sheet's binding
    /// reads now — committed as `session`, and the write that carries it awaited. `nil` when the
    /// role is stored; otherwise why it is not — for the sheet to show while it stays open.
    ///
    /// `session` is asked first: after a folder switch `team` is the next folder's team of the
    /// same id, after an edited-team change another team, and either one composed with this draft
    /// is a write into the wrong place — or, when that team lacks the role, a refusal that blames
    /// a deletion that never happened. Composed on a local copy and handed over ONCE: one staged
    /// value is what the Save waits for (`RoleEditorMutations`).
    static func save(
        _ editorState: RoleEditorState,
        mode: EditorMode<TeamRoleDefinition>,
        session: TeamEditCommitQueue.Session,
        onto team: Team,
        through queue: TeamEditCommitQueue
    ) async -> String? {
        if let refusal = queue.refusal(toSave: session, into: team) { return refusal }
        var newTeam = team
        guard RoleEditorMutations.applySave(to: &newTeam, editorState: editorState, mode: mode) else {
            return "Could not save role — “\(editorState.roleName)” no longer exists in this team. "
                + "It may have been deleted in another view."
        }
        return await queue.commit(newTeam, as: session).failureReason
    }

}
