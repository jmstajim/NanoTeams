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
/// edits work folder context, contextPrompt, or selectedScheme — never written
/// during task execution.
struct ProjectSettings: Codable, Hashable {
    var schemaVersion: Int
    var context: String
    var contextPrompt: String
    var selectedScheme: String?

    init(
        schemaVersion: Int = 2,
        context: String = "",
        contextPrompt: String = AppDefaults.workFolderContextPrompt,
        selectedScheme: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.context = context
        self.contextPrompt = contextPrompt
        self.selectedScheme = selectedScheme
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case context
        case contextPrompt
        case selectedScheme
        // Legacy keys (schemaVersion 1). Read-only fallback so existing
        // settings.json files continue to load after the rename.
        case legacyDescription = "description"
        case legacyDescriptionPrompt = "descriptionPrompt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        // Migrate to current shape in-memory so the next encode never writes new
        // keys under a stale `schemaVersion`. Files at v3+ keep their version so
        // a forward-rolled binary doesn't silently downgrade on save.
        self.schemaVersion = max(storedVersion, 2)
        self.context = try c.decodeIfPresent(String.self, forKey: .context)
            ?? c.decodeIfPresent(String.self, forKey: .legacyDescription)
            ?? ""
        self.contextPrompt = try c.decodeIfPresent(String.self, forKey: .contextPrompt)
            ?? c.decodeIfPresent(String.self, forKey: .legacyDescriptionPrompt)
            ?? AppDefaults.workFolderContextPrompt
        self.selectedScheme = try c.decodeIfPresent(String.self, forKey: .selectedScheme)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(context, forKey: .context)
        try c.encode(contextPrompt, forKey: .contextPrompt)
        try c.encodeIfPresent(selectedScheme, forKey: .selectedScheme)
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
