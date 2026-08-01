import Foundation

/// The tool set a role actually ships to the model for **step execution**.
///
/// `LLMExecutionService.resolveToolSchemas` is only the FIRST of three
/// production stages — `filterForDefaultStorage` strips 18 tools when no real
/// work folder is open, and `filterForGitAvailability` strips all 11 git tools
/// when `<root>/.git` is absent. Reading stage 1 alone and calling it "the
/// effective set" overstates by up to 29 tools, so every surface that wants to
/// *report* what a role gets composes all three here rather than re-spelling
/// the chain (the runtime call site, the wire preview, and the role-list badge
/// all did their own composition or none at all before this type existed).
///
/// Deliberately NOT modelled: the meeting-turn narrowing
/// (`MeetingCoordinator.filterMeetingTools`) and the planning-phase narrowing
/// (`PlanningPhasePolicy.planningToolNames`). A role with a planning phase has
/// two different effective sets across one step's lifetime, so a single number
/// can't describe both — surfaces naming this set should say "step execution".
nonisolated enum EffectiveToolset {

    /// Two-way state encoding "where the project lives" for the tool-resolution
    /// pipeline. Replaces the previous `(workFolderRoot: URL?, isDefaultStorage:
    /// Bool)` pair which encoded 4 combinations for 2 valid states (two of which
    /// silently lied about the project's git status / write permissions).
    ///
    /// - `.defaultStorage`: no real folder selected — the orchestrator routes
    ///   writes to its internal default-storage directory, so write / git /
    ///   xcode tools get stripped via `filterForDefaultStorage`.
    /// - `.realFolder(root:)`: a user-chosen project folder. Git tools survive
    ///   iff `root/.git` exists (checked by `filterForGitAvailability`).
    enum Storage: Hashable, Sendable {
        case defaultStorage
        case realFolder(root: URL)

        /// Bridge from the orchestrator's `workFolderURL` state. `nil` URL or
        /// a URL equal to `NTMSOrchestrator.defaultStorageURL` collapse to
        /// `.defaultStorage`. Centralizes the rule that previously lived
        /// inline in both `PromptPreviewSheet` and `TemplatePreviewSheet`.
        @MainActor
        static func from(orchestratorURL: URL?) -> Storage {
            guard let url = orchestratorURL, url != NTMSOrchestrator.defaultStorageURL else {
                return .defaultStorage
            }
            return .realFolder(root: url)
        }
    }

    /// Full three-stage resolution, entered with the role DEFINITION so the
    /// lossy `Role → findRole` round-trip is skipped entirely (see the
    /// `resolveToolSchemas(forDefinition:…)` doc comment).
    static func resolve(
        role: TeamRoleDefinition,
        team: Team?,
        allTeams: [Team],
        storage: Storage,
        selectedScheme: String?,
        isVisionConfigured: Bool,
        isComputerUseEnabled: Bool,
        autovisorAllowTeamGeneration: Bool,
        fileManager: FileManager = .default
    ) -> [ToolSchema] {
        let stage1 = LLMExecutionService.resolveToolSchemas(
            forDefinition: role,
            team: team,
            allTeams: allTeams,
            selectedScheme: selectedScheme,
            isVisionConfigured: isVisionConfigured,
            isComputerUseEnabled: isComputerUseEnabled,
            autovisorAllowTeamGeneration: autovisorAllowTeamGeneration
        )
        return applyStorageFilters(stage1, storage: storage, fileManager: fileManager)
    }

    /// Stages 2–3 on their own, for callers that must produce stage 1 themselves
    /// — the runtime goes through the *instance* `toolSchemas(…)` shim because
    /// that one also reports orphan meeting coordinators, a side effect the pure
    /// static deliberately doesn't carry.
    static func applyStorageFilters(
        _ tools: [ToolSchema],
        storage: Storage,
        fileManager: FileManager = .default
    ) -> [ToolSchema] {
        switch storage {
        case .defaultStorage:
            return LLMExecutionService.filterForDefaultStorage(tools, isDefaultStorage: true)
        case .realFolder(let root):
            let filtered = LLMExecutionService.filterForDefaultStorage(tools, isDefaultStorage: false)
            return LLMExecutionService.filterForGitAvailability(
                filtered, workFolderRoot: root, fileManager: fileManager)
        }
    }
}
