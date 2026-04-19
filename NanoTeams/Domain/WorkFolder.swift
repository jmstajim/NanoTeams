import Foundation

// MARK: - WorkFolderState (workfolder.json)

/// Persisted runtime state for a work folder: identity + active pointers.
///
/// Stored in `.nanoteams/internal/workfolder.json`. This file is small (<500 B)
/// and gets written on every task switch / active team change. Team configuration,
/// user settings, and other large data live in sibling files:
/// - `settings.json` → `ProjectSettings`
/// - `teams.json` → `TeamsFile`
///
/// Services and views never read this type directly; they operate on
/// `WorkFolderProjection`, an in-memory composite assembled by `NTMSRepository`.
struct WorkFolderState: Codable, Hashable {
    var schemaVersion: Int
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var activeTeamID: NTMSID?
    var activeTaskID: Int?
    /// App version (CFBundleShortVersionString) at the time this folder was last
    /// reconciled against bundled content. Empty string means reconcile has never
    /// run for this folder. Compared to current app version to decide if
    /// `applyBundledContentUpdates` should execute on open.
    var lastAppliedAppVersion: String
    /// Template IDs that the user explicitly deleted. Prevents bootstrap from
    /// re-adding these on next open and prevents version-bump reconcile from
    /// resurrecting them. Cleared by "Restore Default Teams".
    var deletedTeamTemplateIDs: [String]

    init(
        schemaVersion: Int = 6,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now(),
        activeTeamID: NTMSID? = nil,
        activeTaskID: Int? = nil,
        lastAppliedAppVersion: String = "",
        deletedTeamTemplateIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.activeTeamID = activeTeamID
        self.activeTaskID = activeTaskID
        self.lastAppliedAppVersion = lastAppliedAppVersion
        self.deletedTeamTemplateIDs = deletedTeamTemplateIDs
    }

    // Forward-compatible decoding: any missing field falls back to a sensible
    // default so adding new fields in a future version does not destroy existing
    // user data (see CLAUDE.md Model Conventions #4).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 5
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.activeTeamID = try c.decodeIfPresent(NTMSID.self, forKey: .activeTeamID)
        self.activeTaskID = try c.decodeIfPresent(Int.self, forKey: .activeTaskID)
        self.lastAppliedAppVersion = try c.decodeIfPresent(String.self, forKey: .lastAppliedAppVersion) ?? ""
        self.deletedTeamTemplateIDs = try c.decodeIfPresent([String].self, forKey: .deletedTeamTemplateIDs) ?? []
    }
}

// MARK: - ProjectSettings (settings.json)

/// User-configurable project settings.
///
/// Stored in `.nanoteams/internal/settings.json`. Mutates only when the user
/// edits project description, descriptionPrompt, or selectedScheme — never
/// written during task execution.
struct ProjectSettings: Codable, Hashable {
    var schemaVersion: Int
    var description: String
    var descriptionPrompt: String
    var selectedScheme: String?

    init(
        schemaVersion: Int = 1,
        description: String = "",
        descriptionPrompt: String = AppDefaults.workFolderDescriptionPrompt,
        selectedScheme: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.description = description
        self.descriptionPrompt = descriptionPrompt
        self.selectedScheme = selectedScheme
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.descriptionPrompt = try c.decodeIfPresent(String.self, forKey: .descriptionPrompt)
            ?? AppDefaults.workFolderDescriptionPrompt
        self.selectedScheme = try c.decodeIfPresent(String.self, forKey: .selectedScheme)
    }

    static let defaults = ProjectSettings()
}

// MARK: - TeamsFile (teams.json)

/// Team configurations for a work folder.
///
/// Stored in `.nanoteams/internal/teams.json`. This is the largest file on disk
/// (~100 KB for a full FAANG-style team set) — splitting it out keeps git diffs
/// clean (editing one role only touches teams.json) and makes per-team inspection
/// easier.
struct TeamsFile: Codable, Hashable {
    var schemaVersion: Int
    var teams: [Team]

    init(schemaVersion: Int = 1, teams: [Team]) {
        self.schemaVersion = schemaVersion
        self.teams = teams
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.teams = try c.decodeIfPresent([Team].self, forKey: .teams) ?? []
    }
}
