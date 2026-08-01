import SwiftUI

// MARK: - Artifact Editor Sheet

/// Sheet for creating/editing team artifacts.
struct ArtifactEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NTMSOrchestrator.self) private var store
    @Binding var team: Team
    let mode: EditorMode<TeamArtifact>
    /// Carries the stored artifact so callers never have to diff the `team`
    /// Binding to discover what changed. `RoleEditorDependenciesTab` used to do
    /// exactly that, and it could not work: `onSave` runs in the same
    /// synchronous turn as the Binding write, whose setter is async, so the
    /// diff always came back empty and the auto-assign never fired.
    let onSave: (TeamArtifact) -> Void

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
                // Mirrors `RoleEditorSheet`: a failed save keeps the sheet open
                // so the user can copy their work out or cancel explicitly,
                // instead of dismissing as if the edit had landed.
                if saveArtifact() { dismiss() }
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
                        .disabled(nameEditingBlocker != nil)
                }

                if let blocker = nameEditingBlocker {
                    Label(blocker.message, systemImage: "lock")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                } else if let conflict = nameConflictMessage {
                    Label(conflict, systemImage: "exclamationmark.triangle")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.warning)
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
                if case .edit = mode {
                    // Keyed on the LIVE edited name, not the captured
                    // `mode` payload: mid-rename the payload still holds the
                    // old name, so the panel would report usage for a name the
                    // user is in the middle of replacing.
                    usageInfo(forArtifactNamed: ArtifactEditorMutations.canonicalName(artifactName))
                } else {
                    Text("Save the artifact to see usage information")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                        .italic()
                }
            }
        }
    }

    private func usageInfo(forArtifactNamed artifactName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Producers
            let producers = team.rolesProducing(artifactName: artifactName)
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
            let consumers = team.rolesRequiring(artifactName: artifactName)
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

    /// Why the name field is read-only, if it is.
    private enum NameEditingBlocker {
        case lock(ArtifactEditorMutations.NameLock)
        case runInFlight

        var message: String {
            switch self {
            case .lock(.reservedSupervisorTask):
                return "“\(SystemTemplates.supervisorTaskArtifactName)” is a reserved name — the engine refers to it directly."
            case .lock(.systemArtifact):
                return "Built-in artifact — the name is managed by the team template. Duplicate it to get a renameable copy."
            case .runInFlight:
                return "A run is in progress on this team. Renaming now would strand the running step on the old artifact name."
            }
        }
    }

    /// `nil` when the name may be edited. Only meaningful in `.edit` — a
    /// newly-created artifact is custom by construction and has no live run
    /// referring to it yet.
    private var nameEditingBlocker: NameEditingBlocker? {
        guard case .edit(let artifact) = mode else { return nil }
        if let lock = ArtifactEditorMutations.nameLock(for: artifact) { return .lock(lock) }
        if store.hasInFlightRun(forTeamID: team.id) { return .runInFlight }
        return nil
    }

    /// Non-nil when the typed name would collide with another artifact.
    ///
    /// Only checked when the name actually CHANGED — mirroring
    /// `ArtifactEditorMutations.applyEdit`, which validates availability only on
    /// a rename. Checking unconditionally would permanently disable Save on a
    /// team that already contains two slug-colliding artifacts, locking the user
    /// out of editing the description of either.
    private var nameConflictMessage: String? {
        let trimmed = ArtifactEditorMutations.canonicalName(artifactName)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != originalArtifactName else { return nil }
        guard !ArtifactEditorMutations.isNameAvailable(
            trimmed, in: team, excludingArtifactID: editingArtifactID
        ) else { return nil }
        return "Another artifact in this team already uses this name."
    }

    private var editingArtifactID: String? {
        if case .edit(let artifact) = mode { return artifact.id }
        return nil
    }

    /// The stored name of the artifact being edited, or `nil` in `.create`
    /// (where every name is a "change" and must be checked).
    private var originalArtifactName: String? {
        guard let editingArtifactID else { return nil }
        return team.artifacts.first { $0.id == editingArtifactID }?.name
    }

    /// Save is gated on a non-empty name AND slug uniqueness. Uniqueness lives
    /// here rather than in an error channel because it is a pre-condition the
    /// user can see and fix, not a mid-air failure — and because
    /// `ArtifactEditorMutations`' `nil` return is reserved for "the row
    /// vanished", mirroring `RoleEditorMutations.applyEdit`.
    private var isValid: Bool {
        !ArtifactEditorMutations.canonicalName(artifactName).isEmpty
            && nameConflictMessage == nil
    }

    // MARK: - Actions

    private func loadArtifact(_ artifact: TeamArtifact) {
        artifactName = artifact.name
        artifactDescription = artifact.description
        artifactIcon = artifact.icon
        artifactMimeType = artifact.mimeType
    }

    /// Returns `true` when the save actually landed.
    ///
    /// Compose every mutation on a local copy and ship it through the `team`
    /// Binding via a SINGLE assignment. Multiple consecutive writes to the
    /// Binding race because `TeamEditorView.binding(for:)` has a captured-value
    /// getter and an async setter — each write re-reads the same pre-edit
    /// snapshot and the last one wins. This method previously issued five, so
    /// only its final `updatedAt` write survived and the rename (plus
    /// description, icon and MIME type) was silently discarded. See
    /// `ArtifactEditorMutations` doc.
    private func saveArtifact() -> Bool {
        var newTeam = team
        let draft = ArtifactEditorMutations.Draft(
            name: artifactName,
            description: artifactDescription,
            icon: artifactIcon,
            mimeType: artifactMimeType
        )

        let saved: TeamArtifact?
        switch mode {
        case .create:
            saved = ArtifactEditorMutations.applyCreate(to: &newTeam, draft: draft)
        case .edit(let artifact):
            saved = ArtifactEditorMutations.applyEdit(
                to: &newTeam,
                existingArtifactID: artifact.id,
                draft: draft
            )
        }

        guard let saved else {
            store.lastErrorMessage =
                "Could not save artifact — “\(ArtifactEditorMutations.canonicalName(artifactName))” could not be applied to this team. It may have been deleted or renamed in another view."
            return false
        }

        team = newTeam
        onSave(saved)
        return true
    }

}

#Preview {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    ArtifactEditorSheet(
        team: .constant(.default),
        mode: .create,
        onSave: { _ in }
    )
    .environment(store)
}
