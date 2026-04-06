import SwiftUI

// MARK: - Artifact Editor Sheet

/// Sheet for creating/editing team artifacts.
struct ArtifactEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var team: Team
    let mode: EditorMode<TeamArtifact>
    let onSave: () -> Void

    @State private var artifactName: String = ""
    @State private var artifactDescription: String = ""
    @State private var artifactIcon: String = "doc.text"
    @State private var artifactMimeType: String = "text/markdown"

    private let mimeTypes = ArtifactConstants.supportedMimeTypes

    var body: some View {
        NavigationStack {
            Form {
                basicInfoSection
                technicalSection
                usagePreviewSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(mode.isCreate ? "New Artifact" : "Edit Artifact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveArtifact()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .onAppear {
            if case .edit(let artifact) = mode {
                loadArtifact(artifact)
            }
        }
    }

    // MARK: - Sections

    private var basicInfoSection: some View {
        Section("Basic Information") {
            HStack(spacing: 8) {
                IconPickerButton(selectedIcon: $artifactIcon)

                TextField("Artifact Name", text: $artifactName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description — included in the system prompt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $artifactDescription)
                    .font(.body)
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Colors.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                            .stroke(Colors.borderSubtle, lineWidth: 1)
                    )
            }

        }
    }

    private var technicalSection: some View {
        Section("Technical") {
            Picker("MIME Type", selection: $artifactMimeType) {
                ForEach(mimeTypes, id: \.self) { mimeType in
                    HStack {
                        Text(mimeTypeLabel(for: mimeType))
                        Spacer()
                        Text(mimeType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(mimeType)
                }
            }
        }
    }

    private var usagePreviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Usage in Team")
                    .font(.subheadline)
                    .fontWeight(.medium)

                if case .edit(let artifact) = mode {
                    usageInfo(for: artifact)
                } else {
                    Text("Save the artifact to see usage information")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
        }
    }

    private func usageInfo(for artifact: TeamArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Producers
            let producers = team.rolesProducing(artifactName: artifact.name)
            if !producers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(Colors.artifact)
                        Text("Produced by:")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    ForEach(producers, id: \.id) { role in
                        Text("• \(role.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
            }

            // Consumers
            let consumers = team.rolesRequiring(artifactName: artifact.name)
            if !consumers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(Colors.info)
                        Text("Required by:")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    ForEach(consumers, id: \.id) { role in
                        Text("• \(role.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
            }

            // Orphaned warning
            if producers.isEmpty && consumers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Colors.warning)
                    Text("This artifact is not used by any roles")
                        .font(.caption)
                        .foregroundStyle(Colors.warning)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        .fill(Colors.warningTint)
                )
            }
        }
    }

    // MARK: - Helpers

    private func mimeTypeLabel(for mimeType: String) -> String {
        ArtifactConstants.mimeTypeDisplayNames[mimeType] ?? mimeType
    }

    private var isValid: Bool {
        !artifactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func loadArtifact(_ artifact: TeamArtifact) {
        artifactName = artifact.name
        artifactDescription = artifact.description
        artifactIcon = artifact.icon
        artifactMimeType = artifact.mimeType
    }

    private func saveArtifact() {
        switch mode {
        case .create:
            let now = MonotonicClock.shared.now()
            let newArtifact = TeamArtifact(
                id: Artifact.slugify(artifactName),
                name: artifactName,
                icon: artifactIcon,
                mimeType: artifactMimeType,
                description: artifactDescription,
                isSystemArtifact: false,
                systemArtifactName: nil,
                createdAt: now,
                updatedAt: now
            )
            TeamManagementService.addArtifact(to: &team, artifact: newArtifact)

        case .edit(let artifact):
            if let index = team.artifacts.firstIndex(where: { $0.id == artifact.id }) {
                team.artifacts[index].name = artifactName
                team.artifacts[index].description = artifactDescription
                team.artifacts[index].icon = artifactIcon
                team.artifacts[index].mimeType = artifactMimeType
                team.artifacts[index].updatedAt = MonotonicClock.shared.now()
            }
        }

        onSave()
    }

}

#Preview {
    ArtifactEditorSheet(
        team: .constant(.default),
        mode: .create,
        onSave: {}
    )
}
