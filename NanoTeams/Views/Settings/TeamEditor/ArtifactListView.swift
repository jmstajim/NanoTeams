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
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Colors.accent)
                        .frame(width: 28, height: 28)
                        .background(Colors.accentTint, in: Circle())
                        .contentShape(Circle())
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
                onSave: handleSaveArtifact
            )
        }
        .sheet(item: $showingEditArtifact) { artifact in
            ArtifactEditorSheet(
                team: $team,
                mode: .edit(artifact),
                onSave: handleSaveArtifact
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
        ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Artifact List

    private var artifactList: some View {
        List(selection: $selectedArtifactID) {
            ForEach(filteredArtifacts) { artifact in
                ArtifactListItemView(artifact: artifact, team: team)
                    .contentShape(Rectangle())
                    .tag(artifact.id)
                    .onTapGesture(count: 2) {
                        showingEditArtifact = artifact
                    }
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
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

}

// MARK: - Artifact List Item View

/// Compact artifact list item showing icon, name, MIME type, and role connections.
private struct ArtifactListItemView: View {
    let artifact: TeamArtifact
    let team: Team

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 36

    var body: some View {
        HStack(spacing: Spacing.m) {
            // Artifact icon
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Colors.accentTint)
                    .frame(width: iconSize, height: iconSize)

                Image(systemName: artifact.icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Colors.accent)
            }

            // Name + details
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(artifact.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                // Role connections summary
                if !roleConnectionSummary.isEmpty {
                    Text(roleConnectionSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // MIME type label
            Text(artifact.mimeType)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
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
