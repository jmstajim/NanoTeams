import SwiftUI
import UniformTypeIdentifiers

// MARK: - Row Badge Inputs

/// Everything the row badges need that lives outside the team itself. Threaded
/// from `TeamEditorView` (which already holds the orchestrator) instead of read
/// from `@Environment` here, so this view and its rows stay orchestrator-free:
/// the `#Preview` keeps working without injecting a store, and no row subscribes
/// to the high-churn `snapshot`.
struct RoleRowBadgeInputs: Equatable {
    var skillCatalogue: [AgentSkillsSnapshot.Item] = []
    var allTeams: [Team] = []
    var storage: EffectiveToolset.Storage = .defaultStorage
    var selectedScheme: String? = nil
    var isVisionConfigured: Bool = false
    var isComputerUseEnabled: Bool = false
    var autovisorTeamPolicy: AutovisorTeamPolicy = .unrestricted
}

/// Precomputed badge models for one role. Handed to the row as a plain value so
/// the row never resolves anything itself — `SelectableRoleRow` owns a hover
/// `@State`, so its body (and the row's) re-runs on every pointer enter/exit.
struct RoleRowBadges: Equatable {
    var tools: RoleToolBadgePolicy.Model?
    var skills: RoleEditorSkillsPolicy.Badge?
}

// MARK: - Role List View

/// List of roles in a team with search, add/edit/delete, and double-click to edit.
struct RoleListView: View {
    @Binding var team: Team
    let onSave: () -> Void
    /// Defaults render the list with no badges — keeps the `#Preview` and any
    /// future host compiling without threading orchestrator state.
    var badgeInputs: RoleRowBadgeInputs = .init()

    @State var selectedRoleID: String? = nil
    @State private var showingAddRole = false
    @State private var showingEditRole: TeamRoleDefinition? = nil
    @State var showingDeleteConfirmation: TeamRoleDefinition? = nil
    @State var importError: ImportExportError? = nil
    @State private var searchText: String = ""
    /// Keyed by `TeamRoleDefinition.id`. Recomputed in `.task(id:)` rather than in
    /// `body` — the house rule stated at `PromptPreviewSheet.swift:10-12`.
    @State private var badges: [String: RoleRowBadges] = [:]

    /// The managed singleton (Autovisor) is inspect-only: its roles are template-owned
    /// (toolset/icon revert on open) and structural, so adding / deleting / editing them
    /// is useless or breaks the manager. The list still shows the roles; only mutation is removed.
    private var isReadOnly: Bool {
        team.isManagedSingleton
    }

    private var filteredRoles: [TeamRoleDefinition] {
        if searchText.isEmpty {
            return team.roles
        }
        let query = searchText.lowercased()
        return team.roles.filter { role in
            role.name.lowercased().contains(query) ||
            role.dependencies.producesArtifacts.joined(separator: " ").lowercased().contains(query) ||
            role.dependencies.requiredArtifacts.joined(separator: " ").lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: search + add
            HStack(spacing: Spacing.s) {
                SearchFieldView(placeholder: "Filter roles...", text: $searchText)

                if !isReadOnly {
                    // Add role button
                    Button {
                        showingAddRole = true
                    } label: {
                        Image(systemName: "plus")
                            .font(Typography.termBase.weight(.bold))
                            .foregroundStyle(Colors.accent)
                            .frame(width: 28, height: 28)
                            .background(Colors.accentTint, in: RoundedRectangle.squircle(CornerRadius.small))
                            .contentShape(RoundedRectangle.squircle(CornerRadius.small))
                    }
                    .buttonStyle(.plain)
                    .help("Add role")
                    .accessibilityLabel("Add role")

                    // More actions menu
                    Menu {
                        Button {
                            showingAddRole = true
                        } label: {
                            Label("New Role", systemImage: "plus")
                        }

                        Button {
                            handleImportRole()
                        } label: {
                            Label("Import Role...", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(Typography.subheadlineMedium)
                            .foregroundStyle(Colors.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)

            // Content
            if team.roles.isEmpty {
                emptyState
            } else if filteredRoles.isEmpty {
                noResultsState
            } else {
                roleList
            }
        }
        .sheet(isPresented: $showingAddRole) {
            RoleEditorSheet(
                team: $team,
                mode: .create,
                onSave: handleSaveRole
            )
        }
        .sheet(item: $showingEditRole) { role in
            RoleEditorSheet(
                team: $team,
                mode: .edit(role),
                onSave: handleSaveRole
            )
        }
        .alert("Delete Role", isPresented: Binding(
            get: { showingDeleteConfirmation != nil },
            set: { if !$0 { showingDeleteConfirmation = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                showingDeleteConfirmation = nil
            }
            Button("Delete", role: .destructive) {
                if let role = showingDeleteConfirmation {
                    handleDeleteRole(role)
                }
            }
        } message: {
            if let role = showingDeleteConfirmation {
                Text("Are you sure you want to delete '\(role.name)'? This action cannot be undone.")
            }
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
        .task(id: badgeFingerprint) {
            badges = computeBadges()
        }
    }

    // MARK: - Row Badges

    /// Recomputation key. Deliberately NOT `team` — `Team.==` is `id + updatedAt`
    /// (CLAUDE.md #42) and `handleImportRole` appends a role through
    /// `TeamImportExportService` without bumping `updatedAt`, so an imported role
    /// would never get a badge. Built from the fields resolution actually reads.
    private struct BadgeFingerprint: Equatable {
        let inputs: RoleRowBadgeInputs
        let templateID: String?
        let settings: TeamSettings
        let roleSignatures: [String]
    }

    private var badgeFingerprint: BadgeFingerprint {
        BadgeFingerprint(
            inputs: badgeInputs,
            templateID: team.templateID,
            settings: team.settings,
            roleSignatures: team.roles.map(RoleToolBadgePolicy.resolutionSignature(for:))
        )
    }

    /// Stays on the main actor: `ToolDefinitionRegistry` is `@unchecked Sendable`
    /// with unsynchronized storage whose only writer is `@MainActor`, so reading it
    /// here is same-actor and safe — moving this off would break that incidentally.
    private func computeBadges() -> [String: RoleRowBadges] {
        var result: [String: RoleRowBadges] = [:]
        // Supervisor is the human — no tools, no system prompt, and the row hides
        // the whole cluster for it.
        for role in team.roles where !role.isSupervisor {
            result[role.id] = RoleRowBadges(
                tools: RoleToolBadgePolicy.model(
                    role: role,
                    team: team,
                    allTeams: badgeInputs.allTeams,
                    storage: badgeInputs.storage,
                    selectedScheme: badgeInputs.selectedScheme,
                    isVisionConfigured: badgeInputs.isVisionConfigured,
                    isComputerUseEnabled: badgeInputs.isComputerUseEnabled,
                    autovisorTeamPolicy: badgeInputs.autovisorTeamPolicy
                ),
                skills: RoleEditorSkillsPolicy.badge(
                    attachedIDs: role.attachedSkillIDs,
                    catalogue: badgeInputs.skillCatalogue
                )
            )
        }
        return result
    }

    // MARK: - Empty State

    private var emptyState: some View {
        TeamEditorEmptyStateView(
            title: "No Roles",
            icon: "person.text.rectangle",
            description: "Add roles to define the team's workflow",
            actionTitle: "Add First Role",
            onAction: { showingAddRole = true }
        )
    }

    private var noResultsState: some View {
        NTMSSearchEmptyState(searchText: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Role List

    /// Roles currently visible on the graph
    private var onGraphRoles: [TeamRoleDefinition] {
        filteredRoles.filter { !team.graphLayout.hiddenRoleIDs.contains($0.id) }
    }

    /// Roles hidden from the graph
    private var offGraphRoles: [TeamRoleDefinition] {
        filteredRoles.filter { team.graphLayout.hiddenRoleIDs.contains($0.id) }
    }

    private var roleList: some View {
        // Custom LazyVStack instead of the native `List(selection:)` —
        // List's selection wash is a saturated system tint that clashes with
        // the lavender DS palette, and its row corners are not the near-sharp
        // 2pt squircles the DS calls for. Owning the rendering ourselves lets
        // selection/hover backgrounds use `Colors.accentTint`/`surfaceHover`
        // (Color Rule #2: no `.opacity()` on DS colors) and corners use
        // `CornerRadius.small` (Color Rule #7).
        ScrollView {
            LazyVStack(spacing: Spacing.xxs) {
                ForEach(onGraphRoles) { role in
                    roleRow(for: role)
                }

                if !offGraphRoles.isEmpty {
                    HStack {
                        MonoLabel(text: "Off-Graph")
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.s)
                    .padding(.top, Spacing.s)

                    ForEach(offGraphRoles) { role in
                        roleRow(for: role, showAddToGraph: true)
                    }
                }
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
        }
    }

    @ViewBuilder
    private func roleRow(for role: TeamRoleDefinition, showAddToGraph: Bool = false) -> some View {
        SelectableRoleRow(
            role: role,
            badges: badges[role.id],
            isSelected: selectedRoleID == role.id,
            showAddToGraph: showAddToGraph,
            isReadOnly: isReadOnly,
            onSelect: { selectedRoleID = role.id },
            onEdit: { showingEditRole = role },
            onAddToGraph: { handleAddToGraph(role) }
        )
        .accessibilityAction(named: "Edit") {
            showingEditRole = role
        }
        .contextMenu {
            // Editing is always allowed (read-only Autovisor opens a restricted editor —
            // Prompt + Tools only). Structural actions (Duplicate / Delete) are hidden.
            Button {
                showingEditRole = role
            } label: {
                Label("Edit...", systemImage: "pencil")
            }

            if !isReadOnly {
                Button {
                    handleDuplicateRole(role)
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                .disabled(role.isSupervisor)
            }

            Divider()

            Button {
                handleExportRole(role)
            } label: {
                Label("Export Role...", systemImage: "square.and.arrow.up")
            }

            if !isReadOnly {
                Divider()

                Button(role: .destructive) {
                    showingDeleteConfirmation = role
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(team.roles.count <= 1 || role.isSupervisor)
            }
        }
    }

}

// MARK: - Selectable Role Row

/// DS-styled wrapper around `RoleListItemView`: owns the selection/hover
/// background (so the wash matches `Colors.accentTint` / `surfaceHover`),
/// near-sharp `CornerRadius.small` corners, and tap routing (single =
/// select, double = edit). Replaces the native `List(selection:)` row whose
/// system-tint selection clashed with the DS palette.
private struct SelectableRoleRow: View {
    let role: TeamRoleDefinition
    let badges: RoleRowBadges?
    let isSelected: Bool
    let showAddToGraph: Bool
    let isReadOnly: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onAddToGraph: () -> Void

    @State private var isHovered = false

    private var rowBackground: Color {
        if isSelected { return Colors.accentTint }
        if isHovered { return Colors.surfaceHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: 0) {
            RoleListItemView(role: role, badges: badges)

            if showAddToGraph && !isReadOnly {
                Button {
                    onAddToGraph()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(Typography.termXl)
                        .foregroundStyle(Colors.accent)
                }
                .padding(.leading, Spacing.s)
                .buttonStyle(.plain)
                .help("Add \(role.name) to graph")
            }
        }
        .padding(.horizontal, Spacing.s)
        .background(rowBackground, in: RoundedRectangle.squircle(CornerRadius.small))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Higher-count gesture must come first so SwiftUI gives the double-tap
        // priority and only falls through to single-tap after the disambig delay.
        .onTapGesture(count: 2) { onEdit() }
        .onTapGesture { onSelect() }
    }
}

// MARK: - Role List Item View

/// Compact role list item showing name, key badges, and a summary line.
private struct RoleListItemView: View {
    let role: TeamRoleDefinition
    let badges: RoleRowBadges?

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 28
    @ScaledMetric(relativeTo: .caption2) private var badgeIconSize: CGFloat = 10

    var body: some View {
        HStack(spacing: Spacing.m) {
            // Role icon — bare glyph tinted with what used to be the
            // squircle background. Matches `ActivityFeedRoleAvatar`.
            Image(systemName: role.icon)
                .font(.system(size: badgeIconSize + 6, weight: .semibold))
                .foregroundStyle(role.resolvedIconBackground)
                .frame(width: avatarSize, height: avatarSize)

            // Name + badges on the title line, summary underneath. The badges sit
            // INSIDE the VStack so they align with the name rather than floating
            // between the two lines. That needs the VStack to claim the full width
            // (`maxWidth: .infinity`) and the outer `Spacer` to be gone — otherwise
            // the outer spacer eats the slack and the inner one right-aligns
            // against a content-width container, parking the badges next to the name.
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.s) {
                    Text(role.name)
                        .font(Typography.subheadlineSemibold)
                        .foregroundStyle(Colors.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: Spacing.s)

                    if !role.isSupervisor {
                        badgeCluster
                    }
                }

                summaryLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var badgeCluster: some View {
        HStack(spacing: Spacing.s) {
            if role.usePlanningPhase {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: badgeIconSize))
                    .foregroundStyle(Colors.purple)
                    .help("Uses planning phase")
            }

            if role.llmOverride != nil {
                Image(systemName: "cpu")
                    .font(.system(size: badgeIconSize))
                    .foregroundStyle(Colors.info)
                    .help("Custom LLM configuration")
            }

            // Effective step-execution set, not `toolIDs.count`: the runtime both
            // auto-injects (create_artifact / ask_supervisor / conclude_meeting /
            // the delegation pack) and withholds (no vision model, no Xcode scheme,
            // computer use off, no git repo, no work folder).
            if let tools = badges?.tools, !tools.isSilent {
                Label("\(tools.count)", systemImage: "wrench")
                    .font(Typography.term2xs.weight(.medium))
                    .foregroundStyle(tools.needsAttention ? Colors.warning : Colors.textTertiary)
                    .help(RoleToolBadgePolicy.tooltip(tools))
                    .accessibilityLabel("\(tools.count) tools ship for step execution")
            }

            // `scroll` — a rolled instruction sheet, which is literally what an
            // attached skill is: a `SKILL.md` body spliced into the system prompt.
            // Picked because it reads as clearly NOT a tool next to `wrench`, and
            // because it is the rare knowledge-ish symbol absent from
            // `IconPickerButton.icons` — anything in that catalogue can appear as
            // the role's own avatar 300pt to the left in this very row.
            if let skills = badges?.skills {
                Label("\(skills.count)", systemImage: "scroll")
                    .font(Typography.term2xs.weight(.medium))
                    .foregroundStyle(skills.danglingCount > 0 ? Colors.warning : Colors.textTertiary)
                    .help(RoleEditorSkillsPolicy.badgeTooltip(skills))
                    .accessibilityLabel("\(skills.count) agent skills attached")
            }
        }
        // Badges never compress: a long role name must truncate (it already has
        // `lineLimit(1)`) rather than the counts losing a digit. Same reason
        // `TerminalStatusBadge` pins its own size.
        .fixedSize()
    }

    @ViewBuilder
    private var summaryLine: some View {
        let parts = role.artifactSummary
        if !parts.isEmpty {
            Text(parts)
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
        }
    }

}

#Preview {
    RoleListView(
        team: .constant(.default),
        onSave: {}
    )
    .frame(width: 600, height: 800)
}
