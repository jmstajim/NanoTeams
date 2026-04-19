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
/// (`description`, `descriptionPrompt`, `selectedScheme`) are now accessed through
/// the `settings` sub-struct: `store.workFolder?.settings.description`.
struct WorkFolderProjection: Hashable {
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

    /// Add a new team.
    mutating func addTeam(_ team: Team) {
        teams.append(team)
        state.updatedAt = MonotonicClock.shared.now()
    }

    /// Remove a team by ID (cannot remove the last team).
    ///
    /// If the team is built from a template (non-nil, non-"generated" `templateID`),
    /// the templateID is appended to `state.deletedTeamTemplateIDs` so subsequent
    /// `migrateIfNeeded` passes won't resurrect it as a "missing bootstrap template".
    mutating func removeTeam(_ teamID: NTMSID) {
        guard teams.count > 1 else { return }
        if let team = teams.first(where: { $0.id == teamID }),
           let tid = team.templateID,
           tid != "generated",
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
