import Foundation

/// Pure mutation helpers shared by `ArtifactEditorSheet.saveArtifact`.
///
/// Why this exists: the editor sheet receives `team` through a Binding whose
/// getter (`TeamEditorView.binding(for:)`) returns a *captured snapshot* and
/// whose setter spawns an async `mutateWorkFolder` Task. Two consecutive
/// writes through that Binding race — the second write's read-modify-write
/// cycle reads the stale captured snapshot and silently overwrites the
/// first. `saveArtifact` did FIVE such writes (`team.artifacts[i].name`,
/// `.description`, `.icon`, `.mimeType`, `.updatedAt`), so the last one won
/// and it carried only `updatedAt`. Symptom: renaming an artifact appeared to
/// do nothing — and description, icon and MIME type were being dropped too.
///
/// Note that hardening the Binding's getter would NOT have fixed this: all
/// five writes happen in one synchronous turn, before any `Task` body runs,
/// so a store-reading getter still returns the pre-write value.
///
/// Fix: callers compose every mutation on a local `var newTeam = team` and
/// ship the result via a single Binding write (`team = newTeam`). These
/// helpers own the composition — including the artifact-name cascade, which
/// has no counterpart on the role side — so the rules don't drift between
/// create and edit, and they stay covered by `ArtifactEditorMutationsTests`.
///
/// Mirrors `RoleEditorMutations`.
nonisolated enum ArtifactEditorMutations {

    /// The editor-owned fields, as typed by the user.
    struct Draft: Equatable {
        var name: String
        var description: String
        var icon: String
        var mimeType: String

        init(name: String, description: String, icon: String, mimeType: String) {
            self.name = name
            self.description = description
            self.icon = icon
            self.mimeType = mimeType
        }
    }

    /// Why an artifact's name cannot be edited. `nil` = freely renameable.
    enum NameLock: Equatable {
        /// Bundled content. Reconcile owns these names — it re-adds missing
        /// bundled artifacts, prunes orphan system artifacts BY NAME, and
        /// rewrites every system role's `producesArtifacts` from the template
        /// on *every* work-folder open (not just on a version bump). A user
        /// rename would be undone on the next launch and could then be pruned.
        /// Duplicate the artifact instead — that clears `isSystemArtifact`.
        case systemArtifact

        /// `SystemTemplates.supervisorTaskArtifactName` is injected by the
        /// engine as a hardcoded literal, so nothing can follow a rename of it.
        /// Keyed on the NAME, not on `isSystemArtifact`: `Team.duplicate`
        /// clears that flag, so a user-created team's copy is "custom" while
        /// still carrying the reserved name.
        case reservedSupervisorTask
    }

    /// `nil` when the artifact's name may be edited.
    static func nameLock(for artifact: TeamArtifact) -> NameLock? {
        if artifact.name == SystemTemplates.supervisorTaskArtifactName {
            return .reservedSupervisorTask
        }
        if artifact.isSystemArtifact {
            return .systemArtifact
        }
        return nil
    }

    /// The canonical stored form of a typed name.
    ///
    /// Trimming happens on SAVE, not just in the validity check: the sheet used
    /// to validate `trimmed.isEmpty` but persist the raw string, so `"Release
    /// Notes "` desynced the trim-normalizing consumers (e.g.
    /// `Team.supervisorRequiredArtifacts`) from the raw-comparing ones. It is
    /// also a prerequisite for the slug check below being well-defined.
    static func canonicalName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `raw` can be stored without colliding with another artifact.
    ///
    /// Compares SLUGS, not names. `Artifact.slugify` mints the artifact `id`
    /// (`ArtifactEditorSheet` create path) and the on-disk step-artifact
    /// filename (`NTMSRepository+StepArtifacts`), so two names that differ only
    /// by case or punctuation are a genuine id + file collision even though
    /// `==` says they differ — and `Team.addArtifact` appends with no
    /// uniqueness guard while `artifact(withName:)` silently returns `.first`.
    ///
    /// - Parameter excludingArtifactID: the row being edited, so an artifact
    ///   never collides with itself.
    static func isNameAvailable(
        _ raw: String,
        in team: Team,
        excludingArtifactID: String?
    ) -> Bool {
        let slug = Artifact.slugify(canonicalName(raw))
        guard !slug.isEmpty else { return false }
        return !team.artifacts.contains { other in
            other.id != excludingArtifactID && Artifact.slugify(other.name) == slug
        }
    }

    /// Apply the editor's `.edit` save to `team` in one pass.
    ///
    /// Returns the stored artifact, or `nil` when the save cannot be applied —
    /// the row vanished mid-edit (a stale sheet racing `handleDeleteArtifact`),
    /// the name is empty, the name collides with another artifact, or a rename
    /// was attempted on a locked name. On `nil`, `team` is byte-for-byte
    /// untouched and the caller must not assign through the Binding.
    @discardableResult
    static func applyEdit(
        to team: inout Team,
        existingArtifactID: String,
        draft: Draft
    ) -> TeamArtifact? {
        guard let index = team.artifacts.firstIndex(where: { $0.id == existingArtifactID }) else {
            return nil
        }

        let existing = team.artifacts[index]
        // Read the OLD name from the live team, inside the mutation. The two
        // obvious alternatives — `EditorMode.edit(artifact)`'s captured payload
        // and the `.onAppear`-seeded `@State artifactName` — are both snapshots
        // taken outside this frame, and this is the only frame that sees both
        // the current stored name and the new one.
        let oldName = existing.name
        let newName = canonicalName(draft.name)
        guard !newName.isEmpty else { return nil }

        let isRename = newName != oldName
        if isRename {
            guard nameLock(for: existing) == nil else { return nil }
            guard isNameAvailable(newName, in: team, excludingArtifactID: existing.id) else {
                return nil
            }
        }

        var updated = existing
        updated.name = newName
        updated.description = draft.description
        updated.icon = draft.icon
        updated.mimeType = draft.mimeType
        // `id` is deliberately NOT re-derived. It is the stable identity used by
        // list selection, deletion, the `deletedSystemArtifactIDs` tombstones
        // and reconcile's "already present" check — renaming is a display
        // change, exactly as it is for roles (`RoleEditorMutations.applyEdit`
        // never re-derives `role.id` either).

        // Route the splice through `Team.updateArtifact(_:)` — it owns the
        // artifact + team `updatedAt` bumps internally. Without the TEAM bump,
        // `Team.==`'s id+timestamp shortcut (CLAUDE.md #42) treats the team as
        // unchanged and SwiftUI observers up the chain skip re-render, so the
        // list would still show the pre-edit name even with the race gone.
        // The old code bumped only the ARTIFACT's `updatedAt`.
        team.updateArtifact(updated)

        if isRename {
            team.renameArtifactReferences(from: oldName, to: newName)
        }

        return team.artifacts.first { $0.id == existing.id }
    }

    /// Apply the editor's `.create` save to `team` in one pass.
    ///
    /// Returns the stored artifact, or `nil` when the name is empty or collides
    /// with an existing artifact's slug. On `nil`, `team` is untouched.
    @discardableResult
    static func applyCreate(
        to team: inout Team,
        draft: Draft
    ) -> TeamArtifact? {
        let newName = canonicalName(draft.name)
        guard !newName.isEmpty else { return nil }
        guard isNameAvailable(newName, in: team, excludingArtifactID: nil) else { return nil }

        let now = MonotonicClock.shared.now()
        let artifact = TeamArtifact(
            id: Artifact.slugify(newName),
            name: newName,
            icon: draft.icon,
            mimeType: draft.mimeType,
            description: draft.description,
            isSystemArtifact: false,
            systemArtifactName: nil,
            createdAt: now,
            updatedAt: now
        )
        team.addArtifact(artifact)
        return artifact
    }
}
