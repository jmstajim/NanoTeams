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
        VStack(spacing: 0) {
            headerBar

            TerminalDivider()

            ScrollView {
                VStack(spacing: Spacing.xl) {
                    basicInfoSection
                    technicalSection
                    usagePreviewSection
                }
                .padding(Spacing.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Colors.surfacePrimary)
        }
        .frame(minWidth: 600, minHeight: 500)
        .onAppear {
            if case .edit(let artifact) = mode {
                loadArtifact(artifact)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Spacing.s) {
            MonoLabel(text: mode.isCreate ? "New Artifact" : "Edit Artifact", marker: true)

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.terminalSecondary)

            Button("Save") {
                saveArtifact()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.terminalPrimary)
            .disabled(!isValid)
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.m)
    }

    // MARK: - Sections

    private var basicInfoSection: some View {
        SettingsCard(header: "Basic Information", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: 8) {
                    IconPickerButton(selectedIcon: $artifactIcon)

                    TextField("Artifact Name", text: $artifactName)
                        .textFieldStyle(.plain)
                        .terminalField()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Description — included in the system prompt")
                        .font(Typography.subheadline)
                        .foregroundStyle(Colors.textSecondary)

                    TextEditor(text: $artifactDescription)
                        .font(Typography.termBase)
                        .frame(minHeight: 200)
                        .borderedTextEditorStyle()
                }
            }
        }
    }

    private var technicalSection: some View {
        SettingsCard(header: "Technical", systemImage: "wrench.and.screwdriver") {
            HStack {
                Text("MIME Type")
                Spacer()
                TerminalPicker(
                    selection: $artifactMimeType,
                    options: mimeTypes.map { (value: $0, label: "\(mimeTypeLabel(for: $0))  ·  \($0)") }
                )
            }
        }
    }

    private var usagePreviewSection: some View {
        SettingsCard(header: "Usage in Team", systemImage: "arrow.triangle.swap") {
            VStack(alignment: .leading, spacing: 12) {
                if case .edit(let artifact) = mode {
                    usageInfo(for: artifact)
                } else {
                    Text("Save the artifact to see usage information")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
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
                        Image(systemName: "arrow.up.circle")
                            .foregroundStyle(Colors.artifact)
                        Text("Produced by:")
                            .font(Typography.captionSemibold)
                    }
                    ForEach(producers, id: \.id) { role in
                        Text("• \(role.name)")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textSecondary)
                            .padding(.leading, 20)
                    }
                }
            }

            // Consumers
            let consumers = team.rolesRequiring(artifactName: artifact.name)
            if !consumers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(Colors.info)
                        Text("Required by:")
                            .font(Typography.captionSemibold)
                    }
                    ForEach(consumers, id: \.id) { role in
                        Text("• \(role.name)")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textSecondary)
                            .padding(.leading, 20)
                    }
                }
            }

            // Orphaned warning
            if producers.isEmpty && consumers.isEmpty {
                HStack(spacing: 6) {
                    StatusGlyph(glyph: TerminalGlyph.review, color: Colors.warning)
                    Text("This artifact is not used by any roles")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.warning)
                }
                .padding(Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
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
