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
nonisolated struct WorkFolderState: Codable, Hashable {
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
    /// Task ID of the hidden Autovisor singleton task for this folder, once
    /// created (lazily, when the manager is enabled). Single source of truth for
    /// "which task is the manager" — consumed by sidebar/fallback exclusions and
    /// the supervisor-routing / event-wake self-guards. `nil` = not yet created.
    var autovisorTaskID: Int?
    /// Teams whose bundled-content reconcile was deferred because a role held a
    /// live tool loop. Retried — scoped to just these teams — on the next open
    /// even when `lastAppliedAppVersion` is already current.
    ///
    /// Deliberately decoupled from the watermark. Holding the watermark instead
    /// (the old behaviour) meant one busy team re-ran the FULL reconcile on every
    /// launch, which re-clobbered every OTHER team's system-role prompts,
    /// toolIDs and settings each time — so a user edit died at the next launch
    /// rather than surviving until the next app upgrade.
    var pendingReconcileTeamIDs: [NTMSID]

    init(
        schemaVersion: Int = 8,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now(),
        activeTeamID: NTMSID? = nil,
        activeTaskID: Int? = nil,
        lastAppliedAppVersion: String = "",
        deletedTeamTemplateIDs: [String] = [],
        autovisorTaskID: Int? = nil,
        pendingReconcileTeamIDs: [NTMSID] = []
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
        self.autovisorTaskID = autovisorTaskID
        self.pendingReconcileTeamIDs = pendingReconcileTeamIDs
    }

    // Forward-compatible decoding: any missing field falls back to a sensible
    // default so adding new fields in a future version does not destroy existing
    // user data (see CLAUDE.md Model Conventions #4).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Migrate the version in-memory so a successful legacy decode doesn't
        // re-encode under a stale `schemaVersion` (CLAUDE.md #48). A file written by
        // a newer build (version > 8) keeps its higher version on save.
        let storedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 5
        self.schemaVersion = max(storedVersion, 8)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.activeTeamID = try c.decodeIfPresent(NTMSID.self, forKey: .activeTeamID)
        self.activeTaskID = try c.decodeIfPresent(Int.self, forKey: .activeTaskID)
        self.lastAppliedAppVersion = try c.decodeIfPresent(String.self, forKey: .lastAppliedAppVersion) ?? ""
        self.deletedTeamTemplateIDs = try c.decodeIfPresent([String].self, forKey: .deletedTeamTemplateIDs) ?? []
        self.autovisorTaskID = try c.decodeIfPresent(Int.self, forKey: .autovisorTaskID)
        self.pendingReconcileTeamIDs =
            try c.decodeIfPresent([NTMSID].self, forKey: .pendingReconcileTeamIDs) ?? []
    }
}

// MARK: - ProjectSettings (settings.json)

/// User-configurable project settings.
///
/// Stored in `.nanoteams/internal/settings.json`. Mutates only when the user
/// edits work folder context, contextPrompt, or selectedScheme — never written
/// during task execution.
nonisolated struct ProjectSettings: Codable, Hashable {
    var schemaVersion: Int
    var context: String
    var contextPrompt: String
    var selectedScheme: String?
    // Autovisor (schemaVersion 3). Goal + standing memory + enable flag +
    // activation config for the per-folder automated Supervisor agent. Goal/memory
    // are editable in Settings and written by the manager via `update_scratchpad`
    // (memory write-through). The manager's *schedule* lives on its task's
    // `recurrence`; `activation` carries the event-driven triggers + debounce;
    // `tuning` carries the numeric behaviour caps (throughput + stuck detection).
    var autovisorGoal: String
    var autovisorMemory: String
    var autovisorEnabled: Bool
    var autovisorActivation: AutovisorActivation
    var autovisorTuning: AutovisorTuning
    // Whether the Autovisor may assemble a new team on the fly via
    // `create_managed_task team_id: "generated"`. Additive, tolerant decode (no
    // version bump — same policy as the goal/clip fields below). Default `true`
    // preserves the historical always-on behaviour; an absent key on an existing
    // `settings.json` reads as allowed. Gated at BOTH the schema
    // (`CreateManagedTaskTool.buildSchema`) and runtime (`classifyManagedTeamID`)
    // layers when off.
    var autovisorAllowTeamGeneration: Bool
    // Teams the Autovisor may NOT create tasks on. Additive, tolerant decode (no version
    // bump — same policy as the field above). A BLOCK list, so the default `[]` means
    // "every team allowed", identical to the behaviour before it existed, and a team added
    // later is usable without revisiting Settings. Normalized on decode (sorted + deduped)
    // so a hand-edited file self-heals and a reordering can't spuriously dirty the settings
    // diff. See `AutovisorTeamPolicy` for the predicates and for why stale ids are never
    // pruned.
    // `didSet` (not just the setters + decode) because the whole point of storing a SORTED,
    // deduped array is that `ProjectSettings` is `Hashable` and `mutateWorkFolder` diffs it
    // structurally — two orderings of the same block set must not read as a change. A plain
    // `var` left that guarantee resting on every future writer remembering to normalize;
    // this makes it structural. Does not fire during `init`, so both inits still normalize
    // explicitly.
    var autovisorBlockedTeamIDs: [NTMSID] {
        didSet {
            let normalized = AutovisorTeamPolicy.normalizedBlockList(autovisorBlockedTeamIDs)
            if normalized != autovisorBlockedTeamIDs { autovisorBlockedTeamIDs = normalized }
        }
    }
    // Goal-composer attachments + skill/clip cards (additive, tolerant decode — no
    // version bump, same policy as the agent-instruction fields below). Project-
    // relative paths into the folder-level `.nanoteams/autovisor/attachments/` store
    // (survives manager delete/recreate, like the goal string). Mirrored onto the
    // manager task's `attachmentPaths`/`clippedTexts` by `syncAutovisorGoalToManagerBrief`.
    var autovisorGoalAttachmentPaths: [String]
    var autovisorGoalClips: [String]
    // Agent-instruction overrides (additive, tolerant decode — no version bump).
    // `extra` = user-added files (relative paths within the work folder) that
    // join the auto-discovered set; `excluded` = paths the user X'd out of
    // CONTENT injection (the file stays in the list — demoted to path listing;
    // for a main file the next priority candidate takes over); `injected` =
    // listed files the user promoted INTO content injection from the list.
    var agentInstructionExtraPaths: [String]
    var agentInstructionExcludedPaths: [String]
    var agentInstructionInjectedPaths: [String]

    init(
        schemaVersion: Int = 3,
        context: String = "",
        contextPrompt: String = AppDefaults.workFolderContextPrompt,
        selectedScheme: String? = nil,
        autovisorGoal: String = "",
        autovisorMemory: String = "",
        autovisorEnabled: Bool = false,
        autovisorActivation: AutovisorActivation = .default,
        autovisorTuning: AutovisorTuning = .default,
        autovisorAllowTeamGeneration: Bool = true,
        autovisorBlockedTeamIDs: [NTMSID] = [],
        autovisorGoalAttachmentPaths: [String] = [],
        autovisorGoalClips: [String] = [],
        agentInstructionExtraPaths: [String] = [],
        agentInstructionExcludedPaths: [String] = [],
        agentInstructionInjectedPaths: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.context = context
        self.contextPrompt = contextPrompt
        self.selectedScheme = selectedScheme
        self.autovisorGoal = autovisorGoal
        self.autovisorMemory = autovisorMemory
        self.autovisorEnabled = autovisorEnabled
        self.autovisorActivation = autovisorActivation
        self.autovisorTuning = autovisorTuning
        self.autovisorAllowTeamGeneration = autovisorAllowTeamGeneration
        self.autovisorBlockedTeamIDs = AutovisorTeamPolicy.normalizedBlockList(autovisorBlockedTeamIDs)
        self.autovisorGoalAttachmentPaths = autovisorGoalAttachmentPaths
        self.autovisorGoalClips = autovisorGoalClips
        self.agentInstructionExtraPaths = agentInstructionExtraPaths
        self.agentInstructionExcludedPaths = agentInstructionExcludedPaths
        self.agentInstructionInjectedPaths = agentInstructionInjectedPaths
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case context
        case contextPrompt
        case selectedScheme
        case autovisorGoal
        case autovisorMemory
        case autovisorEnabled
        case autovisorActivation
        case autovisorTuning
        case autovisorAllowTeamGeneration
        case autovisorBlockedTeamIDs
        case autovisorGoalAttachmentPaths
        case autovisorGoalClips
        case agentInstructionExtraPaths
        case agentInstructionExcludedPaths
        case agentInstructionInjectedPaths
        // Legacy keys (schemaVersion 1). Read-only fallback so existing
        // settings.json files continue to load after the rename.
        case legacyDescription = "description"
        case legacyDescriptionPrompt = "descriptionPrompt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        // Migrate to current shape in-memory so the next encode never writes new
        // keys under a stale `schemaVersion`. A file written by a newer build
        // (version > 3) keeps its higher version so a forward-rolled binary doesn't
        // silently downgrade on save (CLAUDE.md #48).
        self.schemaVersion = max(storedVersion, 3)
        self.context = try c.decodeIfPresent(String.self, forKey: .context)
            ?? c.decodeIfPresent(String.self, forKey: .legacyDescription)
            ?? ""
        self.contextPrompt = try c.decodeIfPresent(String.self, forKey: .contextPrompt)
            ?? c.decodeIfPresent(String.self, forKey: .legacyDescriptionPrompt)
            ?? AppDefaults.workFolderContextPrompt
        self.selectedScheme = try c.decodeIfPresent(String.self, forKey: .selectedScheme)
        self.autovisorGoal = try c.decodeIfPresent(String.self, forKey: .autovisorGoal) ?? ""
        self.autovisorMemory = try c.decodeIfPresent(String.self, forKey: .autovisorMemory) ?? ""
        self.autovisorEnabled = try c.decodeIfPresent(Bool.self, forKey: .autovisorEnabled) ?? false
        self.autovisorActivation = try c.decodeIfPresent(AutovisorActivation.self, forKey: .autovisorActivation) ?? .default
        self.autovisorTuning = try c.decodeIfPresent(AutovisorTuning.self, forKey: .autovisorTuning) ?? .default
        self.autovisorAllowTeamGeneration =
            try c.decodeIfPresent(Bool.self, forKey: .autovisorAllowTeamGeneration) ?? true
        // Normalize on the way in: a hand-edited file converges on first load, and two
        // orderings of the same block set can't read as a settings change.
        self.autovisorBlockedTeamIDs = AutovisorTeamPolicy.normalizedBlockList(
            try c.decodeIfPresent([NTMSID].self, forKey: .autovisorBlockedTeamIDs) ?? [])
        self.autovisorGoalAttachmentPaths =
            try c.decodeIfPresent([String].self, forKey: .autovisorGoalAttachmentPaths) ?? []
        self.autovisorGoalClips =
            try c.decodeIfPresent([String].self, forKey: .autovisorGoalClips) ?? []
        self.agentInstructionExtraPaths =
            try c.decodeIfPresent([String].self, forKey: .agentInstructionExtraPaths) ?? []
        self.agentInstructionExcludedPaths =
            try c.decodeIfPresent([String].self, forKey: .agentInstructionExcludedPaths) ?? []
        self.agentInstructionInjectedPaths =
            try c.decodeIfPresent([String].self, forKey: .agentInstructionInjectedPaths) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(context, forKey: .context)
        try c.encode(contextPrompt, forKey: .contextPrompt)
        try c.encodeIfPresent(selectedScheme, forKey: .selectedScheme)
        try c.encode(autovisorGoal, forKey: .autovisorGoal)
        try c.encode(autovisorMemory, forKey: .autovisorMemory)
        try c.encode(autovisorEnabled, forKey: .autovisorEnabled)
        try c.encode(autovisorActivation, forKey: .autovisorActivation)
        try c.encode(autovisorTuning, forKey: .autovisorTuning)
        try c.encode(autovisorAllowTeamGeneration, forKey: .autovisorAllowTeamGeneration)
        try c.encode(autovisorBlockedTeamIDs, forKey: .autovisorBlockedTeamIDs)
        try c.encode(autovisorGoalAttachmentPaths, forKey: .autovisorGoalAttachmentPaths)
        try c.encode(autovisorGoalClips, forKey: .autovisorGoalClips)
        try c.encode(agentInstructionExtraPaths, forKey: .agentInstructionExtraPaths)
        try c.encode(agentInstructionExcludedPaths, forKey: .agentInstructionExcludedPaths)
        try c.encode(agentInstructionInjectedPaths, forKey: .agentInstructionInjectedPaths)
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
nonisolated struct TeamsFile: Codable, Hashable {
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
