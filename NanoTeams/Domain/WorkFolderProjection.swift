import Foundation

/// In-memory composite view assembled from `workfolder.json` + `settings.json` + `teams.json`.
///
/// This is what services and views operate on. `NTMSRepository` is the only code
/// that reads/writes the three underlying files — everything else sees a single
/// projection. Mutations made via `NTMSOrchestrator.mutateWorkFolder { proj in ... }`
/// are diff-compared field-by-field so only the changed files are re-written.
///
/// Field layout is designed so that existing view code (`store.workFolder?.teams`,
/// `store.workFolder?.activeTeam`, `store.workFolder?.name`) continues to work
/// without rewrites. The only callsite-level change is that user settings
/// (`context`, `contextPrompt`, `selectedScheme`) are now accessed through
/// the `settings` sub-struct: `store.workFolder?.settings.context`.
nonisolated struct WorkFolderProjection: Hashable {
    var state: WorkFolderState
    var settings: ProjectSettings
    var teams: [Team]

    // MARK: - Identity convenience (read-through to state)

    var id: UUID { state.id }
    var name: String { state.name }

    var activeTeamID: NTMSID? {
        get { state.activeTeamID }
        set { state.activeTeamID = newValue }
    }

    // MARK: - Active team lookup

    /// The currently active team (first team if activeTeamID is nil or not found).
    var activeTeam: Team? {
        if let id = state.activeTeamID {
            return teams.first { $0.id == id }
        }
        return teams.first
    }

    // MARK: - Team Management

    /// Set the active team by ID.
    mutating func setActiveTeam(_ teamID: NTMSID) {
        if teams.contains(where: { $0.id == teamID }) {
            state.activeTeamID = teamID
            state.updatedAt = MonotonicClock.shared.now()
        }
    }

    /// A display name whose derived id is free in this folder.
    ///
    /// A team's id is DERIVED FROM ITS NAME (`NTMSID.from(name:)`), so two teams that share a
    /// name share an id — and the derivation lowercases and strips punctuation, so "My Team",
    /// "MY TEAM" and "My: Team" all derive `my_team` without ever looking alike to the user.
    /// The collision has to be resolved BEFORE the id is derived, which is the rule
    /// `TeamImportExportService.importRole` already states in its own comment ("before
    /// generating ID so ID matches final name") — the team-level doors just never applied it.
    ///
    /// Terminates: each suffix derives a distinct id (digits survive the derivation), so among
    /// any `existingIDs.count + 1` candidates at least one is free.
    nonisolated static func availableTeamName(_ desired: String, existingIDs: Set<NTMSID>) -> String {
        guard existingIDs.contains(NTMSID.from(name: desired)) else { return desired }
        var suffix = 2
        while existingIDs.contains(NTMSID.from(name: "\(desired) \(suffix)")) {
            suffix += 1
        }
        return "\(desired) \(suffix)"
    }

    /// Add a new team, renaming it if its derived id is already taken. Returns the id it was
    /// actually added under — which the caller MUST use to select it, since on a collision the
    /// team's own `id` is no longer the one in the folder.
    ///
    /// Two teams sharing an id is not a cosmetic duplicate. `activeTeam` and every
    /// `teams.first(where:)` resolve the FIRST, so the second is unreachable and every edit
    /// lands on the other copy; `removeTeam` is `removeAll { $0.id == teamID }`, so deleting
    /// one deletes BOTH; a run pinned to that id can resolve the wrong roster; and the team
    /// pickers hand SwiftUI a duplicate `ForEach` id. Reachable in two clicks — "Duplicate"
    /// twice names both copies `<team> Copy`.
    ///
    /// Only a CUSTOM team is renamed. A template team's id is a fixed identity that bootstrap's
    /// missing-template detection, `removeTeam`'s tombstone and "Restore Default Teams" all key
    /// on, so renaming one would make those lookups miss — which is exactly why the custom team
    /// has to yield FIRST, here, while it is still the one being added.
    ///
    /// Hence `lazilyMaterialisedTeamIDs` in the taken set: the Autovisor team and the Generated
    /// placeholder are created on demand (first enable / first "Generate Team..." pick), so they
    /// are absent from `teams` precisely when a custom team could take their id, and both
    /// creators guard on `templateID` — which a custom team does not carry. Reserving them is
    /// the only door at which the conflict is still resolvable.
    @discardableResult
    mutating func addTeam(_ team: Team) -> NTMSID {
        var incoming = team
        let existingIDs = Set(teams.map(\.id))
            .union(TeamTemplateFactory.lazilyMaterialisedTeamIDs)
        if incoming.templateID == nil, existingIDs.contains(incoming.id) {
            incoming.name = Self.availableTeamName(incoming.name, existingIDs: existingIDs)
            incoming.id = NTMSID.from(name: incoming.name)
        }
        teams.append(incoming)
        state.updatedAt = MonotonicClock.shared.now()
        return incoming.id
    }

    /// Remove a team by ID (cannot remove the last team).
    ///
    /// If the team is built from a template (non-nil, non-"generated" `templateID`),
    /// the templateID is appended to `state.deletedTeamTemplateIDs` so subsequent
    /// `migrateIfNeeded` passes won't resurrect it as a "missing bootstrap template".
    mutating func removeTeam(_ teamID: NTMSID) {
        guard teams.count > 1 else { return }
        if let team = teams.first(where: { $0.id == teamID }),
           !team.isGeneratedPlaceholder,
           let tid = team.templateID,
           !state.deletedTeamTemplateIDs.contains(tid)
        {
            state.deletedTeamTemplateIDs.append(tid)
        }
        teams.removeAll { $0.id == teamID }
        if state.activeTeamID == teamID {
            state.activeTeamID = teams.first?.id
        }
        state.updatedAt = MonotonicClock.shared.now()
    }

    /// Update a team by ID.
    mutating func updateTeam(_ team: Team) {
        if let index = teams.firstIndex(where: { $0.id == team.id }) {
            teams[index] = team
            state.updatedAt = MonotonicClock.shared.now()
        }
    }

    /// Get team by ID.
    func team(withID id: NTMSID) -> Team? {
        teams.first { $0.id == id }
    }
}
