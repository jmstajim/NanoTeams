import SwiftUI
import UniformTypeIdentifiers

// MARK: - Team Editor View

/// Main Team Editor with role/artifact management and visual graph.
/// Layout: Team selector at top, graph editor on the left (center), settings tabs on the right.
///
/// Split across extension files:
/// - `TeamEditorView+Actions.swift` — action handlers (save, delete, duplicate, import, export)
/// - `NewTeamSheet.swift` — new team creation sheet + template card
struct TeamEditorView: View {
    @Environment(NTMSOrchestrator.self) var store

    @State private var selectedTab: EditorTab = .team
    @State private var showingNewTeamSheet = false
    @State private var showingGenerateTeamSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var validationErrors: [TeamValidationError] = []
    @State private var showingImportTeam = false
    @State var importError: ImportExportError? = nil
    @State private var selectedRoleID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Validation Banner
            if !validationErrors.isEmpty {
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
                            ForEach(EditorTab.allCases) { tab in
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
                if let snapshot = store.snapshot,
                   !snapshot.workFolder.teams.isEmpty {
                    let activeID = snapshot.workFolder.activeTeamID ?? snapshot.workFolder.teams[0].id
                    TeamSelectorView(
                        teams: snapshot.workFolder.teams,
                        activeTeamID: activeID,
                        onSelect: handleSelectTeam,
                        onAdd: { showingNewTeamSheet = true },
                        onGenerate: { showingGenerateTeamSheet = true },
                        onDuplicate: handleDuplicateTeam,
                        onDelete: { showingDeleteConfirmation = true }
                    )
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
            validateCurrentTeam()
        }
        .onAppear {
            validateCurrentTeam()
        }
    }

    // MARK: - Validation Banner

    private var validationBanner: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(validationErrors, id: \.self) { error in
                HStack(spacing: Spacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Colors.warning)
                    Text(error.localizedDescription)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Colors.warningTint)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Colors.warning),
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

    var activeTeam: Team? {
        guard let snapshot = store.snapshot else { return nil }
        let activeID = snapshot.workFolder.activeTeamID ?? snapshot.workFolder.teams.first?.id
        return snapshot.workFolder.teams.first { $0.id == activeID }
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
            validationErrors = []
            return
        }
        validationErrors = TeamManagementService.validate(team)
    }

    // MARK: - Supporting Types

    enum EditorTab: String, CaseIterable, Identifiable, Hashable {
        case team
        case prompts
        case roles
        case artifacts

        var id: String { rawValue }

        private static let metadata: [EditorTab: (label: String, icon: String)] = [
            .team:      ("Settings",  "gearshape"),
            .prompts:   ("Prompts",   "text.bubble"),
            .roles:     ("Roles",     "person.text.rectangle"),
            .artifacts: ("Artifacts", "doc.text"),
        ]

        var label: String { Self.metadata[self]!.label }
        var icon: String { Self.metadata[self]!.icon }
    }
}

#Preview {
    TeamEditorView()
        .frame(width: 900, height: 700)
}
