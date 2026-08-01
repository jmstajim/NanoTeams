import SwiftUI
import UniformTypeIdentifiers

// MARK: - Artifact List View

/// List of artifacts in a team with search, add/edit/delete, and double-click to edit.
struct ArtifactListView: View {
    @Binding var team: Team
    let onSave: () -> Void

    @State var selectedArtifactID: String? = nil
    @State private var showingAddArtifact = false
    @State private var showingEditArtifact: TeamArtifact? = nil
    @State var showingDeleteConfirmation: TeamArtifact? = nil
    @State var importError: ImportExportError? = nil
    @State private var searchText: String = ""

    private var filteredArtifacts: [TeamArtifact] {
        if searchText.isEmpty {
            return team.artifacts
        }
        let query = searchText.lowercased()
        return team.artifacts.filter { artifact in
            artifact.name.lowercased().contains(query) ||
            artifact.description.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: search + add
            HStack(spacing: Spacing.s) {
                SearchFieldView(placeholder: "Filter artifacts...", text: $searchText)

                // Add artifact button
                Button {
                    showingAddArtifact = true
                } label: {
                    Image(systemName: "plus")
                        .font(Typography.termBase.weight(.bold))
                        .foregroundStyle(Colors.accent)
                        .frame(width: 28, height: 28)
                        .background(Colors.accentTint, in: RoundedRectangle.squircle(CornerRadius.small))
                        .contentShape(RoundedRectangle.squircle(CornerRadius.small))
                }
                .buttonStyle(.plain)
                .help("Add artifact")
                .accessibilityLabel("Add artifact")

                // More actions menu
                Menu {
                    Button {
                        showingAddArtifact = true
                    } label: {
                        Label("New Artifact", systemImage: "plus")
                    }

                    Button {
                        handleImportArtifact()
                    } label: {
                        Label("Import Artifact...", systemImage: "square.and.arrow.down")
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
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)

            // Content
            if team.artifacts.isEmpty {
                emptyState
            } else if filteredArtifacts.isEmpty {
                noResultsState
            } else {
                artifactList
            }
        }
        .sheet(isPresented: $showingAddArtifact) {
            ArtifactEditorSheet(
                team: $team,
                mode: .create,
                onSave: { _ in handleSaveArtifact() }
            )
        }
        .sheet(item: $showingEditArtifact) { artifact in
            ArtifactEditorSheet(
                team: $team,
                mode: .edit(artifact),
                onSave: { _ in handleSaveArtifact() }
            )
        }
        .alert("Delete Artifact", isPresented: Binding(
            get: { showingDeleteConfirmation != nil },
            set: { if !$0 { showingDeleteConfirmation = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                showingDeleteConfirmation = nil
            }
            Button("Delete", role: .destructive) {
                if let artifact = showingDeleteConfirmation {
                    handleDeleteArtifact(artifact)
                }
            }
        } message: {
            if let artifact = showingDeleteConfirmation {
                Text("Are you sure you want to delete '\(artifact.name)'? Roles depending on this artifact will need to be updated.")
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
            title: "No Artifacts",
            icon: "doc.text",
            description: "Add artifacts to define the deliverables produced by roles",
            actionTitle: "Add First Artifact",
            onAction: { showingAddArtifact = true }
        )
    }

    private var noResultsState: some View {
        NTMSSearchEmptyState(searchText: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Artifact List

    private var artifactList: some View {
        // Custom LazyVStack instead of the native `List(selection:)` — DS
        // requires `Colors.accentTint` selection + `CornerRadius.small`
        // corners; List's system-tint wash + rounded-pill selection clash
        // with the palette. See sibling refactor in `RoleListView.roleList`.
        ScrollView {
            LazyVStack(spacing: Spacing.xxs) {
                ForEach(filteredArtifacts) { artifact in
                    SelectableArtifactRow(
                        artifact: artifact,
                        team: team,
                        isSelected: selectedArtifactID == artifact.id,
                        onSelect: { selectedArtifactID = artifact.id },
                        onEdit: { showingEditArtifact = artifact }
                    )
                    .accessibilityAction(named: "Edit") {
                        showingEditArtifact = artifact
                    }
                    .contextMenu {
                        Button {
                            showingEditArtifact = artifact
                        } label: {
                            Label("Edit...", systemImage: "pencil")
                        }

                        Button {
                            handleDuplicateArtifact(artifact)
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }

                        Divider()

                        Button {
                            handleExportArtifact(artifact)
                        } label: {
                            Label("Export Artifact...", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showingDeleteConfirmation = artifact
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
        }
    }

}

// MARK: - Selectable Artifact Row

/// DS-styled wrapper around `ArtifactListItemView` — see
/// `SelectableRoleRow` for rationale.
private struct SelectableArtifactRow: View {
    let artifact: TeamArtifact
    let team: Team
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    @State private var isHovered = false

    private var rowBackground: Color {
        if isSelected { return Colors.accentTint }
        if isHovered { return Colors.surfaceHover }
        return .clear
    }

    var body: some View {
        ArtifactListItemView(artifact: artifact, team: team)
            .padding(.horizontal, Spacing.s)
            .background(rowBackground, in: RoundedRectangle.squircle(CornerRadius.small))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            // Higher-count gesture first so SwiftUI gives double-tap priority.
            .onTapGesture(count: 2) { onEdit() }
            .onTapGesture { onSelect() }
    }
}

// MARK: - Artifact List Item View

/// Compact artifact list item showing icon, name, MIME type, and role connections.
private struct ArtifactListItemView: View {
    let artifact: TeamArtifact
    let team: Team

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 28
    @ScaledMetric(relativeTo: .caption2) private var glyphSize: CGFloat = 10

    var body: some View {
        HStack(spacing: Spacing.m) {
            // Artifact icon — bare glyph, matching `RoleListItemView`.
            Image(systemName: artifact.icon)
                .font(.system(size: glyphSize + 6, weight: .semibold))
                .foregroundStyle(Colors.accent)
                .frame(width: iconSize, height: iconSize)

            // Name + details
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(artifact.name)
                    .font(Typography.subheadlineSemibold)
                    .foregroundStyle(Colors.textPrimary)
                    .lineLimit(1)

                // Role connections summary
                if !roleConnectionSummary.isEmpty {
                    Text(roleConnectionSummary)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // MIME type label
            Text(artifact.mimeType)
                .font(Typography.term2xs)
                .foregroundStyle(Colors.textTertiary)
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Helpers

    private var roleConnectionSummary: String {
        let producers = team.rolesProducing(artifactName: artifact.name)
        let consumers = team.rolesRequiring(artifactName: artifact.name)

        var parts: [String] = []
        if let producer = producers.first {
            parts.append(producer.name)
        }
        if !consumers.isEmpty {
            let names = consumers.prefix(2).map(\.name).joined(separator: ", ")
            let suffix = consumers.count > 2 ? " +\(consumers.count - 2)" : ""
            parts.append(names + suffix)
        }
        return parts.joined(separator: " \u{2192} ")
    }
}

#Preview {
    ArtifactListView(
        team: .constant(.default),
        onSave: {}
    )
    .frame(width: 600, height: 800)
}
