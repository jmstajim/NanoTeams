import SwiftUI
import UniformTypeIdentifiers

// MARK: - Team Editor Validation (pure, testable)

/// Builds the rows shown in the Team Editor's validation banner. Extracted as a
/// `nonisolated enum` (same testable-namespace style as
/// `RoleEditorSkillsPolicy`) so the combine + severity mapping is
/// unit-testable without rendering the view.
nonisolated enum TeamEditorValidation {

    /// One banner row — structural (missing role / empty name) or delegation
    /// policy. `isError` drives the row icon + color and the banner's overall
    /// tint (any error → error styling, else warning). `id` is assigned at
    /// construction so two issues that resolve to the same text (duplicate role
    /// display names, repeated whitelist ids) stay distinct rows in `ForEach`
    /// instead of colliding under `id: \.self` (CLAUDE.md #22/#23).
    struct Issue: Identifiable {
        let id = UUID()
        let isError: Bool
        let message: String
    }

    /// Combines structural validation (`TeamManagementService.validate` — always
    /// errors) with delegation policy (`TeamValidationService.validateDelegationPolicy`
    /// — severity per `ValidationError.isError`), each rendered via
    /// `displayMessage(in:)`. Dependency/orphan checks are intentionally excluded:
    /// they were never surfaced in this banner and would light up warnings on
    /// otherwise-valid teams.
    /// - Parameter knownSkillIDs: ids the agent-skill scanner discovered. Empty
    ///   means "no catalogue yet" and skips the attached-skill check entirely —
    ///   see `TeamValidationService.validateAttachedSkills`. Defaults to empty so
    ///   existing call sites keep compiling with the check inert.
    static func issues(
        team: Team,
        allTeams: [Team],
        knownSkillIDs: Set<String> = []
    ) -> [Issue] {
        var issues = TeamManagementService.validate(team).map {
            Issue(isError: true, message: $0.localizedDescription)
        }
        issues += TeamValidationService.validateDelegationPolicy(team: team, allTeams: allTeams).map {
            Issue(isError: $0.isError, message: $0.displayMessage(in: team))
        }
        issues += TeamValidationService.validateAttachedSkills(
            team: team, knownSkillIDs: knownSkillIDs
        ).map {
            Issue(isError: $0.isError, message: $0.displayMessage(in: team))
        }
        return issues
    }
}

// MARK: - Team Editor View

/// Main Team Editor with role/artifact management and visual graph.
/// Layout: Team selector at top, graph editor on the left (center), settings tabs on the right.
///
/// Split across extension files:
/// - `TeamEditorView+Actions.swift` — action handlers (save, delete, duplicate, import, export)
/// - `NewTeamSheet.swift` — new team creation sheet + template card
struct TeamEditorView: View {
    @Environment(NTMSOrchestrator.self) var store
    @Environment(DictationService.self) private var dictation

    @State private var selectedTab: EditorTab = .team
    @State private var showingNewTeamSheet = false
    @State private var showingGenerateTeamSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var validationIssues: [TeamEditorValidation.Issue] = []
    @State private var showingImportTeam = false
    @State var importError: ImportExportError? = nil
    @State private var selectedRoleID: String? = nil
    // The team currently *edited* — decoupled from the global `activeTeamID` so
    // selecting the managed singleton (Autovisor) here never becomes the work
    // folder's default team for new tasks. nil → follow the global `activeTeamID`.
    @State var editorSelectedTeamID: NTMSID? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Terminal-style sub-toolbar — replaces the native `.toolbar` block
            // (Pass 29, mirrors the TeamBoard Pass 28 pattern). Per the JSX spec:
            // `▌ TEAM EDITOR  <selector>  ··  <validation>  ⋯`.
            teamEditorTopBar

            // Validation Banner
            if !validationIssues.isEmpty {
                validationBanner
            }

            // Main content: graph left (center), settings right
            if let team = activeTeam {
                HSplitView {
                    // Left: always-visible graph (main area)
                    TeamGraphEditorView(
                        team: binding(for: team),
                        selectedRoleID: $selectedRoleID,
                        onSave: handleSaveTeam
                    )
                    .frame(minWidth: 250, idealWidth: 500)

                    // Right: segmented tabs + tab content
                    VStack(spacing: 0) {
                        // Terminal-idiom tab strip — sharp corners (DS rule:
                        // radius ≤ 4pt) replacing the prior `Capsule` pill.
                        // Mirrors `TerminalSegmentedPicker`'s squared chrome
                        // so RoleEditor and TeamEditor tabs read identically.
                        HStack(spacing: 2) {
                            ForEach(availableTabs) { tab in
                                Button { selectedTab = tab } label: {
                                    Label(tab.label, systemImage: tab.icon)
                                        .labelStyle(.titleOnly)
                                        .font(Typography.termXs.weight(.medium))
                                        .foregroundStyle(selectedTab == tab ? Colors.textOnAccent : Colors.textSecondary)
                                        .padding(.horizontal, Spacing.s)
                                        .padding(.vertical, Spacing.xxs)
                                        .frame(maxWidth: .infinity)
                                        .background(
                                            RoundedRectangle.squircle(CornerRadius.micro)
                                                .fill(selectedTab == tab ? Colors.accent : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
                            }
                        }
                        .padding(Spacing.xxs)
                        .background(Colors.surfaceElevated, in: RoundedRectangle.squircle(CornerRadius.small))
                        .overlay(
                            RoundedRectangle.squircle(CornerRadius.small)
                                .strokeBorder(Colors.borderSubtle, lineWidth: 1)
                        )
                        .padding(.horizontal, Spacing.standard)
                        .padding(.vertical, Spacing.s)

                        tabContent(for: team)
                    }
                    .frame(minWidth: 280, idealWidth: 400, maxWidth: 900)
                }
            } else {
                noTeamView
            }
        }
        .sheet(isPresented: $showingNewTeamSheet) {
            NewTeamSheet(onSave: handleCreateTeam)
        }
        .sheet(isPresented: $showingGenerateTeamSheet) {
            GenerateTeamSheet { taskDescription in
                await handleGenerateTeam(taskDescription: taskDescription)
            }
            // Re-inject — SwiftUI has historically dropped `@Observable`
            // environment values when presenting sheets on macOS.
            .environment(dictation)
        }
        .alert("Delete Team", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                handleDeleteTeam()
            }
        } message: {
            Text("Are you sure you want to delete this team? This action cannot be undone.")
        }
        .alert("Import Error", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {
                importError = nil
            }
        } message: {
            if let error = importError {
                Text(error.localizedDescription)
            }
        }
        .onChange(of: showingImportTeam) { _, isShowing in
            if isShowing {
                handleImportTeam()
                showingImportTeam = false
            }
        }
        .onChange(of: activeTeam?.id) { _, _ in
            // Switching to a team that hides the current tab (e.g. Autovisor hides
            // Artifacts) would otherwise strand the user on an empty pane.
            selectedTab = TeamEditorTabPolicy.clamp(selectedTab, available: availableTabs)
            validateCurrentTeam()
        }
        // `updatedAt` bumps on every role/delegation edit (CLAUDE.md #42), so
        // this re-validates after a save even when the team id is unchanged —
        // delegation fixes/regressions surface in the banner immediately.
        .onChange(of: activeTeam?.updatedAt) { _, _ in
            validateCurrentTeam()
        }
        .onAppear {
            validateCurrentTeam()
            presentPendingNewTeamSheetIfPossible()
        }
        .task {
            // Nothing in the Team Editor triggered a skill scan before this — the
            // catalogue was carried entirely by the work-folder-open and startRun
            // scans, which also left `validateAttachedSkills` (and now the role-list
            // skills badge) blind to skills added since launch. TTL-memoed (5s) and
            // equality-guarded, so re-entering the tab costs nothing.
            await store.refreshAgentSkills()
            // `.onAppear` above ran before the scan resolved.
            validateCurrentTeam()
        }
        // Level trigger. `.onAppear` covers "Settings was closed" and "the tab was
        // switched to Teams" (both mount this view), but NOT "Settings is already open
        // on Teams" — there is no mount, so the appear never re-fires. Observing the
        // latch itself covers that third case, and it is also what retries a request
        // that had to defer because another sheet/alert was up.
        .onChange(of: store.pendingNewTeamSheet) { _, _ in
            presentPendingNewTeamSheetIfPossible()
        }
        // Retry hooks: a deferred request is re-checked as soon as the presentation
        // that blocked it goes away. macOS allows one presentation per window, so
        // without these a request that arrived while, say, the delete confirmation was
        // up would sit armed until the user happened to leave and re-enter the tab.
        .onChange(of: showingNewTeamSheet) { _, isShowing in
            if !isShowing { presentPendingNewTeamSheetIfPossible() }
        }
        .onChange(of: showingGenerateTeamSheet) { _, isShowing in
            if !isShowing { presentPendingNewTeamSheetIfPossible() }
        }
        .onChange(of: showingDeleteConfirmation) { _, isShowing in
            if !isShowing { presentPendingNewTeamSheetIfPossible() }
        }
        .onChange(of: importError == nil) { _, isClear in
            if isClear { presentPendingNewTeamSheetIfPossible() }
        }
    }

    /// Consumes `NTMSOrchestrator.pendingNewTeamSheet` (armed by the QuickCapture
    /// panel's "New Team..." entry) and raises the sheet.
    ///
    /// **Peeks before consuming, and defers rather than clearing.** macOS presents one
    /// sheet/alert per window, so setting `showingNewTeamSheet = true` while another is
    /// up is silently dropped. Consuming first would then destroy the intent with no
    /// retry path — the user's click would vanish, and `showingNewTeamSheet` would be
    /// left `true` against a sheet that never appeared, so a later dismissal could pop
    /// an unrequested one. Leaving the latch armed is recoverable; consuming is not.
    ///
    /// It deliberately does NOT dismiss whatever is already presented. Tearing down the
    /// destructive "Delete Team" confirmation from a background action the user never
    /// associated with it would read as the delete having gone through.
    ///
    /// Presentations owned by descendants (role/artifact editors, the graph's
    /// `.sheet(item:)`) are not observable from here; those defer until the user closes
    /// them and the next `.onAppear` / latch change re-checks. Deferring is the
    /// acceptable failure, losing the request is not.
    private func presentPendingNewTeamSheetIfPossible() {
        guard store.pendingNewTeamSheet else { return }
        guard !showingNewTeamSheet,
              !showingGenerateTeamSheet,
              !showingDeleteConfirmation,
              importError == nil else { return }
        guard store.consumeNewTeamSheetRequest() else { return }
        showingNewTeamSheet = true
    }

    // MARK: - Top Bar

    /// Terminal-style sub-toolbar — the sole navbar for the Team Editor pane
    /// (Pass 29). Replaces the native macOS `.toolbar` block; layout per
    /// `DesignSystemByClaude/ui_kits/desktop/TeamEditor.jsx` lines 408–420.
    @ViewBuilder
    private var teamEditorTopBar: some View {
        TeamEditorTopBar(issues: validationIssues) {
            if let snapshot = store.snapshot {
                // Hide only the Generated Team placeholder from the config list.
                // The Autovisor team IS shown here (protected: non-deletable,
                // non-duplicable) so it can be inspected/configured.
                let selectableTeams = snapshot.workFolder.teams.filter { !$0.isHiddenFromTeamEditor }
                if !selectableTeams.isEmpty {
                    let activeID = activeTeam?.id ?? selectableTeams[0].id
                    let canDuplicate = activeTeam.map { !$0.isManagedSingleton } ?? false
                    let canDelete = activeTeam.map {
                        TeamManagementService.canDeleteTeam(in: snapshot.workFolder, teamID: $0.id)
                    } ?? false
                    TeamSelectorView(
                        teams: selectableTeams,
                        activeTeamID: activeID,
                        canDelete: canDelete,
                        canDuplicate: canDuplicate,
                        onSelect: handleSelectTeam,
                        onAdd: { showingNewTeamSheet = true },
                        onGenerate: { showingGenerateTeamSheet = true },
                        onDuplicate: handleDuplicateTeam,
                        onDelete: { showingDeleteConfirmation = true }
                    )
                }
            }
        } actions: {
            Menu {
                Button {
                    showingImportTeam = true
                } label: {
                    Label("Import Team...", systemImage: "square.and.arrow.down")
                }

                Button {
                    handleExportTeam()
                } label: {
                    Label("Export Team...", systemImage: "square.and.arrow.up")
                }
                .disabled(activeTeam == nil)

                Divider()

                Button {
                    handleResetLayout()
                } label: {
                    Label("Reset Graph Layout", systemImage: "arrow.counterclockwise")
                }

                Divider()

                Button {
                    handleRestoreDefaults()
                } label: {
                    Label("Restore Default Teams", systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .navbarIconCell()
            .help("More actions")
        }
    }

    // MARK: - Validation Banner

    private var validationBanner: some View {
        let hasError = validationIssues.contains(where: \.isError)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(validationIssues) { issue in
                HStack(spacing: Spacing.s) {
                    StatusGlyph(
                        glyph: issue.isError ? TerminalGlyph.failed : TerminalGlyph.review,
                        color: issue.isError ? Colors.error : Colors.warning
                    )
                    Text(issue.message)
                        .font(Typography.termBase)
                        .foregroundStyle(Colors.textPrimary)
                }
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hasError ? Colors.errorTint : Colors.warningTint)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(hasError ? Colors.error : Colors.warning),
            alignment: .bottom
        )
    }

    // MARK: - Tab Content

    /// Inputs for the role-list row badges. Read here — this view already holds the
    /// orchestrator and already reads the skill catalogue for validation — and
    /// handed down as a value so `RoleListView` and its rows stay orchestrator-free.
    private var roleRowBadgeInputs: RoleRowBadgeInputs {
        RoleRowBadgeInputs(
            skillCatalogue: store.roleSkills?.items ?? [],
            allTeams: store.snapshot?.workFolder.teams ?? [],
            storage: .from(orchestratorURL: store.workFolderURL),
            selectedScheme: store.snapshot?.workFolder.settings.selectedScheme,
            isVisionConfigured: store.configuration.isVisionConfigured,
            isComputerUseEnabled: store.configuration.isComputerUseEnabled,
            autovisorTeamPolicy: store.snapshot.map { AutovisorTeamPolicy(settings: $0.workFolder.settings) }
                ?? .unrestricted
        )
    }

    @ViewBuilder
    private func tabContent(for team: Team) -> some View {
        switch selectedTab {
        case .team:
            TeamSettingsDetailView(team: binding(for: team), onSave: handleSaveTeam)
        case .prompts:
            TeamPromptsDetailView(team: binding(for: team), onSave: handleSaveTeam)
        case .roles:
            RoleListView(
                team: binding(for: team),
                onSave: handleSaveTeam,
                badgeInputs: roleRowBadgeInputs
            )
        case .artifacts:
            ArtifactListView(team: binding(for: team), onSave: handleSaveTeam)
        }
    }

    private var noTeamView: some View {
        NTMSEmptyState(
            title: "No Team Selected",
            message: "Create or select a team to configure it",
            systemImage: "person.3",
            action: { showingNewTeamSheet = true },
            actionLabel: "Create Team"
        )
    }

    // MARK: - Helpers

    /// Tabs available for the edited team. The managed singleton (Autovisor) keeps the
    /// Roles tab (read-only — see `RoleListView`) and the Prompts tab (System prompt only —
    /// see `TeamPromptsDetailView`), but hides Artifacts: its single artifact dependency is
    /// structural and editing it would break the manager.
    var availableTabs: [EditorTab] {
        TeamEditorTabPolicy.availableTabs(isManagedSingleton: activeTeam?.isManagedSingleton ?? false)
    }

    var activeTeam: Team? {
        guard let snapshot = store.snapshot else { return nil }
        // Editor-visible teams: only the Generated Team placeholder is hidden.
        // Autovisor shows as a protected entry.
        let selectable = snapshot.workFolder.teams.filter { !$0.isHiddenFromTeamEditor }
        // A local editor selection wins (so picking Autovisor edits it here without
        // touching the global default team); otherwise follow the global activeTeamID.
        if let editorID = editorSelectedTeamID, let team = selectable.first(where: { $0.id == editorID }) {
            return team
        }
        let preferredID = snapshot.workFolder.activeTeamID ?? selectable.first?.id
        return selectable.first { $0.id == preferredID } ?? selectable.first
    }

    func binding(for team: Team) -> Binding<Team> {
        let teamID = team.id  // capture id once — avoids stale reference in set closure
        return Binding(
            get: { team },
            set: { newValue in
                Task {
                    await store.mutateWorkFolder { project in
                        if let index = project.teams.firstIndex(where: { $0.id == teamID }) {
                            project.teams[index] = newValue
                        }
                    }
                }
            }
        )
    }

    func validateCurrentTeam() {
        guard let team = activeTeam else {
            validationIssues = []
            return
        }
        validationIssues = TeamEditorValidation.issues(
            team: team,
            allTeams: store.snapshot?.workFolder.teams ?? [],
            knownSkillIDs: Set(store.roleSkills?.items.map(\.id) ?? [])
        )
    }

}

#Preview {
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var dictation = DictationService()
    TeamEditorView()
        .environment(store)
        .environment(store.configuration)
        .environment(dictation)
        .frame(width: 900, height: 700)
}
