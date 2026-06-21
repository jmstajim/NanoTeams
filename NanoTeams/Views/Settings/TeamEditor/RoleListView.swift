import SwiftUI
import UniformTypeIdentifiers

// MARK: - Role List View

/// List of roles in a team with search, add/edit/delete, and double-click to edit.
struct RoleListView: View {
    @Binding var team: Team
    let onSave: () -> Void

    @State var selectedRoleID: String? = nil
    @State private var showingAddRole = false
    @State private var showingEditRole: TeamRoleDefinition? = nil
    @State var showingDeleteConfirmation: TeamRoleDefinition? = nil
    @State var importError: ImportExportError? = nil
    @State private var searchText: String = ""

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
            RoleListItemView(role: role)

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

            // Name + summary
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(role.name)
                    .font(Typography.subheadlineSemibold)
                    .foregroundStyle(Colors.textPrimary)
                    .lineLimit(1)

                summaryLine
            }

            Spacer(minLength: 0)

            // Right-side badges
            if !role.isSupervisor {
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

                    if !role.toolIDs.isEmpty {
                        Label("\(role.toolIDs.count)", systemImage: "wrench")
                            .font(Typography.term2xs.weight(.medium))
                            .foregroundStyle(Colors.textTertiary)
                            .help("\(role.toolIDs.count) tools available")
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
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
