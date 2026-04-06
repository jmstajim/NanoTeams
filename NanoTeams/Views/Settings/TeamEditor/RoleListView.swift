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

                // Add role button
                Button {
                    showingAddRole = true
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Colors.accent)
                        .frame(width: 28, height: 28)
                        .background(Colors.accentTint, in: Circle())
                        .contentShape(Circle())
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
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
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
        ContentUnavailableView.search(text: searchText)
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
        List(selection: $selectedRoleID) {
            ForEach(onGraphRoles) { role in
                roleRow(for: role)
            }

            if !offGraphRoles.isEmpty {
                Section {
                    ForEach(offGraphRoles) { role in
                        roleRow(for: role, showAddToGraph: true)
                    }
                } header: {
                    Text("Off-Graph")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func roleRow(for role: TeamRoleDefinition, showAddToGraph: Bool = false) -> some View {
        HStack(spacing: 0) {
            RoleListItemView(role: role)

            if showAddToGraph {
                Button {
                    handleAddToGraph(role)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Colors.accent)
                }
                .padding(.leading, Spacing.s)
                .buttonStyle(.plain)
                .help("Add \(role.name) to graph")
            }
        }
        .contentShape(Rectangle())
        .tag(role.id)
        .onTapGesture(count: 2) {
            showingEditRole = role
        }
        .accessibilityAction(named: "Edit") {
            showingEditRole = role
        }
        .contextMenu {
            Button {
                showingEditRole = role
            } label: {
                Label("Edit...", systemImage: "pencil")
            }

            Button {
                handleDuplicateRole(role)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            .disabled(role.isSupervisor)

            Divider()

            Button {
                handleExportRole(role)
            } label: {
                Label("Export Role...", systemImage: "square.and.arrow.up")
            }

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

// MARK: - Role List Item View

/// Compact role list item showing name, key badges, and a summary line.
private struct RoleListItemView: View {
    let role: TeamRoleDefinition

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36
    @ScaledMetric(relativeTo: .caption2) private var badgeIconSize: CGFloat = 10

    var body: some View {
        HStack(spacing: Spacing.m) {
            // Role icon
            ZStack {
                Circle()
                    .fill(role.resolvedIconBackground)
                    .frame(width: avatarSize, height: avatarSize)

                Image(systemName: role.icon)
                    .font(.system(size: badgeIconSize + 4, weight: .semibold))
                    .foregroundStyle(role.resolvedIconColor)
            }

            // Name + summary
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(role.name)
                    .font(.subheadline.weight(.semibold))
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
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
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
                .font(.caption)
                .foregroundStyle(.tertiary)
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
