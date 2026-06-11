import SwiftUI
import UniformTypeIdentifiers

// MARK: - Team Editor Validation (pure, testable)

/// Builds the rows shown in the Team Editor's validation banner. Extracted as a
/// `nonisolated enum` (same testable-namespace style as
/// `RoleEditorConcludeMeetingPredicate`) so the combine + severity mapping is
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
    static func issues(team: Team, allTeams: [Team]) -> [Issue] {
        var issues = TeamManagementService.validate(team).map {
            Issue(isError: true, message: $0.localizedDescription)
        }
        issues += TeamValidationService.validateDelegationPolicy(team: team, allTeams: allTeams).map {
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
                        HStack(spacing: Spacing.xs) {
                            ForEach(availableTabs) { tab in
                                Button { selectedTab = tab } label: {
                                    Label(tab.label, systemImage: tab.icon)
                                        .labelStyle(.titleOnly)
                                        .font(Typography.captionSemibold)
                                        .foregroundStyle(selectedTab == tab ? Colors.surfaceBackground : .secondary)
                                        .padding(.horizontal, Spacing.m)
                                        .padding(.vertical, Spacing.xs)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(selectedTab == tab ? Colors.accent : Colors.surfaceElevated)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
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
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
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
            }

            ToolbarItemGroup(placement: .primaryAction) {
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
                    Image(systemName: "ellipsis.circle")
                }
                .help("More actions")
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
        }
    }

    // MARK: - Validation Banner

    private var validationBanner: some View {
        let hasError = validationIssues.contains(where: \.isError)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(validationIssues) { issue in
                HStack(spacing: Spacing.s) {
                    Image(systemName: issue.isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.isError ? Colors.error : Colors.warning)
                    Text(issue.message)
                        .font(.callout)
                        .foregroundStyle(.primary)
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

    @ViewBuilder
    private func tabContent(for team: Team) -> some View {
        switch selectedTab {
        case .team:
            TeamSettingsDetailView(team: binding(for: team), onSave: handleSaveTeam)
        case .prompts:
            TeamPromptsDetailView(team: binding(for: team), onSave: handleSaveTeam)
        case .roles:
            RoleListView(team: binding(for: team), onSave: handleSaveTeam)
        case .artifacts:
            ArtifactListView(team: binding(for: team), onSave: handleSaveTeam)
        }
    }

    private var noTeamView: some View {
        ContentUnavailableView {
            Label("No Team Selected", systemImage: "person.3")
        } description: {
            Text("Create or select a team to configure it")
        } actions: {
            Button("Create Team") {
                showingNewTeamSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            allTeams: store.snapshot?.workFolder.teams ?? []
        )
    }

}

#Preview {
    TeamEditorView()
        .frame(width: 900, height: 700)
}
