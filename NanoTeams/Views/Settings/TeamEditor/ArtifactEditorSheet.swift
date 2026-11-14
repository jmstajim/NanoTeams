import SwiftUI

// MARK: - Artifact Editor Sheet

/// Sheet for creating/editing team artifacts.
///
/// The same Save and close as `RoleEditorSheet`: `team` is the Team Editor's binding, rebuilt on
/// every render; `session` is what the click that opened the sheet captured
/// (`TeamEditSheetRequest`). Save composes the artifact on `team`, commits it as `session` and
/// closes only once that write landed; a refusal keeps the sheet open with the reason, and
/// `onSave` — which `RoleEditorDependenciesTab` answers by adding the artifact to the role's
/// draft — is called only for an artifact that is stored. Cancel and Escape ask before throwing
/// away edits (`EditorSheetClosePolicy`). Previews: `ArtifactEditorSheet+Previews.swift`.
struct ArtifactEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NTMSOrchestrator.self) private var store
    @Binding var team: Team
    /// The team and folder this sheet saves into, or nowhere.
    let session: TeamEditCommitQueue.Session
    let mode: EditorMode<TeamArtifact>
    /// Carries the stored artifact so callers never have to diff the `team`
    /// Binding to discover what changed. `RoleEditorDependenciesTab` used to do
    /// exactly that, and it could not work while the Binding's setter was an
    /// async `Task` fired in the same turn as `onSave`: the diff always came
    /// back empty and the auto-assign never fired. Called only once the
    /// artifact's write landed.
    let onSave: (TeamArtifact) -> Void

    /// Seeded at init (CLAUDE.md #26): the `.onAppear` load this replaced left the first render
    /// on the empty form, which the unsaved-changes check would have read as an edit.
    @State private var draft: ArtifactEditorMutations.Draft
    /// A Save is waiting for its write: Save and Cancel are off, so Escape does nothing.
    @State private var isSaving = false
    /// Why the last Save did not land — shown in the sheet, which stayed open.
    @State private var saveError: String?
    @State private var isConfirmingDiscard = false

    private let mimeTypes = ArtifactConstants.supportedMimeTypes

    /// What the static Save answers: the stored artifact, or why there is none.
    enum SaveOutcome: Equatable {
        case saved(TeamArtifact)
        case refused(String)
    }

    /// `saveError` is the line the sheet opens with — `nil` wherever a person opens it; the
    /// previews pass one, as `RoleEditorSheet`'s do.
    init(
        team: Binding<Team>,
        session: TeamEditCommitQueue.Session,
        mode: EditorMode<TeamArtifact>,
        onSave: @escaping (TeamArtifact) -> Void,
        saveError: String? = nil
    ) {
        self._team = team
        self.session = session
        self.mode = mode
        self.onSave = onSave
        self._draft = State(initialValue: ArtifactEditorMutations.openingDraft(for: mode))
        self._saveError = State(initialValue: saveError)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            TerminalDivider()

            if let saveError {
                // On the content's own fill, so the banner reads as the top of the form rather
                // than a band of the header.
                EditorSheetSaveErrorBanner(message: saveError)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.top, Spacing.s)
                    .frame(maxWidth: .infinity)
                    .background(Colors.surfacePrimary)
            }

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
        // Escape is taken by Cancel's `.cancelAction`; this keeps the sheet's own dismissal
        // out of it while there is something to lose or a write to wait for.
        .interactiveDismissDisabled(isSaving || ArtifactEditorMutations.hasUnsavedChanges(draft, mode: mode))
        .discardChangesConfirmation(of: "artifact", isPresented: $isConfirmingDiscard) { dismiss() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Spacing.s) {
            MonoLabel(text: mode.isCreate ? "New Artifact" : "Edit Artifact", marker: true)

            Spacer()

            if isSaving {
                SavingIndicator()
            }

            Button("Cancel") {
                requestClose()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.terminalSecondary)
            .disabled(isSaving)

            Button("Save") {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.terminalPrimary)
            .disabled(!isValid || isSaving)
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.m)
    }

    // MARK: - Sections

    private var basicInfoSection: some View {
        SettingsCard(header: "Basic Information") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: 8) {
                    IconPickerButton(selectedIcon: $draft.icon)

                    TextField("Artifact Name", text: $draft.name)
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

                    TextEditor(text: $draft.description)
                        .font(Typography.termBase)
                        .frame(minHeight: 200)
                        .inputSurface(.editor)
                }
            }
        }
    }

    private var technicalSection: some View {
        SettingsCard(header: "Technical") {
            HStack {
                Text("MIME Type")
                Spacer()
                TerminalPicker(
                    selection: $draft.mimeType,
                    options: mimeTypes.map { (value: $0, label: "\(mimeTypeLabel(for: $0))  ·  \($0)") }
                )
            }
        }
    }

    private var usagePreviewSection: some View {
        SettingsCard(header: "Usage in Team") {
            VStack(alignment: .leading, spacing: 12) {
                if case .edit = mode {
                    // Keyed on the LIVE edited name, not the captured
                    // `mode` payload: mid-rename the payload still holds the
                    // old name, so the panel would report usage for a name the
                    // user is in the middle of replacing.
                    usageInfo(forArtifactNamed: ArtifactEditorMutations.canonicalName(draft.name))
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
        let trimmed = ArtifactEditorMutations.canonicalName(draft.name)
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
        !ArtifactEditorMutations.canonicalName(draft.name).isEmpty
            && nameConflictMessage == nil
    }

    // MARK: - Actions

    /// Save, then close — only once the write landed, and only then is `onSave` told which
    /// artifact is stored. Until 2026-11-08 this sheet closed on the Binding assignment, whose
    /// setter merely started a write, and Cancel and Escape closed without asking: an artifact
    /// created from the Role Editor's Dependencies tab was added to the role's draft even when its
    /// write was refused, and the role then saved depending on an artifact that did not exist.
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        let outcome = await Self.save(draft, mode: mode, session: session, onto: team, through: store.teamEdits)
        isSaving = false
        switch outcome {
        case .refused(let reason):
            saveError = reason
        case .saved(let artifact):
            onSave(artifact)
            dismiss()
        }
    }

    /// Cancel and Escape: close at once only when nothing would be lost.
    private func requestClose() {
        switch EditorSheetClosePolicy.onCancel(
            hasUnsavedChanges: ArtifactEditorMutations.hasUnsavedChanges(draft, mode: mode), isSaving: isSaving
        ) {
        case .close: dismiss()
        case .confirmDiscard: isConfirmingDiscard = true
        case .ignore: break
        }
    }

    /// The Save apart from the view, as `RoleEditorSheet.save`: `session` asked first, the
    /// artifact composed on `team` — the team the sheet's binding reads now — and committed as
    /// `session`, the write that carries it awaited.
    ///
    /// Compose every mutation on a local copy and ship it via a SINGLE commit. This Save once
    /// issued five writes through a binding whose getter returned the captured pre-edit team, so
    /// only its final `updatedAt` write survived and the rename (plus description, icon and MIME
    /// type) was silently discarded. See `ArtifactEditorMutations` doc.
    static func save(
        _ draft: ArtifactEditorMutations.Draft,
        mode: EditorMode<TeamArtifact>,
        session: TeamEditCommitQueue.Session,
        onto team: Team,
        through queue: TeamEditCommitQueue
    ) async -> SaveOutcome {
        if let refusal = queue.refusal(toSave: session, into: team) { return .refused(refusal) }
        var newTeam = team
        let saved: TeamArtifact?
        switch mode {
        case .create:
            saved = ArtifactEditorMutations.applyCreate(to: &newTeam, draft: draft)
        case .edit(let artifact):
            saved = ArtifactEditorMutations.applyEdit(to: &newTeam, existingArtifactID: artifact.id, draft: draft)
        }
        guard let saved else {
            return .refused(
                "Could not save artifact — “\(ArtifactEditorMutations.canonicalName(draft.name))” could not be "
                    + "applied to this team. It may have been deleted or renamed in another view.")
        }
        if let reason = await queue.commit(newTeam, as: session).failureReason { return .refused(reason) }
        return .saved(saved)
    }

}
