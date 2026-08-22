import Foundation

/// Single source of truth for all built-in tools.
///
/// Each handler type declares its own schema, category, and behavioral flags
/// (`excludedInMeetings`, `blockedInDefaultStorage`). Schema/metadata
/// queries iterate `allTypes` statically. Runtime dispatch uses `buildHandlers(...)`
/// which drives the same `allTypes` list via `makeInstance(dependencies:)` — adding
/// a new tool is one append to `allTypes` and one conforming struct.
nonisolated enum ToolHandlerRegistry {

    // MARK: - All Built-in Handlers (single source of truth)

    /// Every built-in tool type, in display order. Add a new tool by appending here
    /// and creating a conforming `ToolHandler` struct — no other edits required.
    nonisolated(unsafe) static let allTypes: [any ToolHandler.Type] = [
        // File read (always available)
        ReadFileTool.self,
        ReadLinesTool.self,
        ListFilesTool.self,
        SearchTool.self,

        // File write (blocked in default storage)
        WriteFileTool.self,
        EditFileTool.self,
        DeleteFileTool.self,

        // Git read (blocked in default storage)
        GitStatusTool.self,
        GitBranchListTool.self,
        GitLogTool.self,
        GitDiffTool.self,

        // Git write (blocked in default storage)
        GitAddTool.self,
        GitCommitTool.self,
        GitPullTool.self,
        GitStashTool.self,

        // Git branching (blocked in default storage)
        GitCheckoutTool.self,
        GitMergeTool.self,
        GitBranchTool.self,

        // Xcode (blocked in default storage)
        RunXcodebuildTool.self,
        RunXcodetestsTool.self,

        // Supervisor
        AskSupervisorTool.self,

        // Memory
        UpdateScratchpadTool.self,

        // Collaboration
        AskTeammateTool.self,
        RequestTeamMeetingTool.self,
        ConcludeMeetingTool.self,
        RequestChangesTool.self,

        // Artifact
        CreateArtifactTool.self,

        // Vision
        AnalyzeImageTool.self,

        // Team
        CreateTeamTool.self,

        // Delegation
        DelegateToTeamTool.self,
        CancelDelegationTool.self,
        ResumeDelegationTool.self,
        ForwardToTeamTool.self,

        // Autovisor (management tools — only in the hidden Manager role's toolset)
        ListTasksTool.self,
        TaskStatusTool.self,
        CreateManagedTaskTool.self,
        ControlTaskTool.self,
        ManageRoleTool.self,
        AnswerTaskQuestionTool.self,
        MessageTaskTool.self,
        ScheduleTaskTool.self,
        SetWorkFolderContextTool.self,
        WaitForEventsTool.self,

        // Shell (blocked in default storage, excluded in meetings, default-on for
        // the code-writing roles + opt-in for others, gated by the bash-permission layer)
        BashTool.self,
        BashOutputTool.self,

        // Computer Use (excluded in meetings, NOT blocked in default storage — controls the
        // screen, not the work folder; default-OFF for every role; gated by the
        // computer-use permission layer)
        ScreenCaptureTool.self,
        UIClickTool.self,
        UITypeTool.self,
        UIKeyTool.self,
        UIScrollTool.self,
    ]

    // MARK: - Schema & Metadata Queries (cached)

    /// All tool schemas in display order. Available without a work folder.
    static let allSchemas: [ToolSchema] = allTypes.map { $0.schema }

    /// Tools that must be filtered out of meeting turn schemas.
    static let meetingExcluded: Set<String> =
        Set(allTypes.filter { $0.excludedInMeetings }.map { $0.name })

    /// Tools that are replaced with an error stub when no real work folder is open.
    static let defaultStorageBlocked: Set<String> =
        Set(allTypes.filter { $0.blockedInDefaultStorage }.map { $0.name })

    /// Tools that must NEVER be offered to a team role's LLM schema. Used by control-flow
    /// tools (e.g. `create_team`) that have a dedicated invocation path outside the runtime.
    static let unavailableToRoles: Set<String> =
        Set(allTypes.filter { !$0.availableToRoles }.map { $0.name })

    /// Tool names that must NEVER appear in stored `TeamRoleDefinition.toolIDs`.
    /// The 4 live delegation tools auto-inject from settings
    /// (`allowedDelegationTeamIDs` / `allowDelegationToGeneratedTeams`) in
    /// `LLMExecutionService+ToolResolution`; the legacy `"list_teams"` literal
    /// is the removed discovery tool (catalog now embedded inline in
    /// `delegate_to_team`'s description). Used by `RoleEditorMutations` at
    /// save time and by `NTMSRepository.normalizeDelegationToolset` at load
    /// time — single source of truth keeps the two enforcement points in sync.
    static let delegationToolsExcludedFromToolIDs: Set<String> = [
        ToolNames.delegateToTeam,
        ToolNames.cancelDelegation,
        ToolNames.resumeDelegation,
        ToolNames.forwardToTeam,
        "list_teams",
    ]

    /// Tool names in a given category. Stable, single source of truth.
    ///
    /// Each derived set below is `static let`, not a computed `static var`: `allTypes` is
    /// a compile-time list of ~60 metatypes, so a computed getter rebuilt the whole Set on
    /// EVERY access — and the accesses are per tool call (`LLMExecutionService+ToolExecution`)
    /// and per role row per body pass (`RoleToolBadgePolicy`, `ToolSelectionView`). Their
    /// siblings above (`allSchemas`, `meetingExcluded`, `defaultStorageBlocked`,
    /// `unavailableToRoles`) were already `static let`; the memoization had simply been
    /// applied to one half of the family (CLAUDE.md #51/#52).
    static func names(in category: ToolCategory) -> Set<String> {
        Set(allTypes.filter { $0.category == category }.map { $0.name })
    }

    /// Read-only file system tools: `read_file`, `read_lines`, `list_files`, `search`.
    static let fileReadTools: Set<String> = names(in: .fileRead)

    /// Mutating file system tools: `write_file`, `edit_file`, `delete_file`.
    static let fileWriteTools: Set<String> = names(in: .fileWrite)

    /// All file system tools (read + write).
    static let allFileTools: Set<String> = fileReadTools.union(fileWriteTools)

    /// Tools that only OBSERVE the work folder: file reads plus git reads.
    ///
    /// Derived from `ToolCategory` rather than listed, so a read-only tool
    /// added later joins automatically (same contract as `defaultStorageBlocked`).
    /// Consumed by `PlanningPhasePolicy` to build the planning toolset.
    ///
    /// Still excludes `.shell`, but the reason is narrow: membership here is a property of
    /// the TOOL, decided without ever seeing a command, and `bash` writes or does not
    /// depending on the command string. It is NOT a claim that `bash` is unfit for the
    /// planning phase — `PlanningPhasePolicy` admits it separately and makes it read-only by
    /// KERNEL (a Seatbelt profile with every write scope off), a guarantee this static,
    /// command-blind set cannot express. Do not "fix" the asymmetry by adding `.shell` here:
    /// membership must stay phase-independent, or the next consumer of this set inherits a
    /// promise that only the planning phase's per-call narrowing keeps.
    static let readOnlyTools: Set<String> = fileReadTools.union(gitReadTools)

    /// Read-only Git tools: `git_status`, `git_log`, `git_diff`, `git_branch_list`.
    static let gitReadTools: Set<String> = names(in: .gitRead)

    /// Mutating Git tools (add/commit/pull/stash/checkout/merge/branch).
    static let gitWriteTools: Set<String> = names(in: .gitWrite)

    /// Xcode build/test tools.
    static let xcodeTools: Set<String> = names(in: .xcode)

    /// Vision analysis tools.
    static let visionTools: Set<String> = names(in: .vision)

    /// Shell-command tools (`bash` + `bash_output`). Excluded from meetings, but — unlike
    /// write/git/xcode tools — usable with no work folder open (sandboxed to the
    /// Application Support root).
    static let shellTools: Set<String> = names(in: .shell)

    /// Computer-use tools (`screen_capture` + `ui_click`/`ui_type`/`ui_key`/`ui_scroll`).
    /// Stripped from every role's LLM schema when `ComputerUsePolicy.mode == .off`.
    static let computerUseTools: Set<String> = names(in: .computerUse)

    // MARK: - Handler Instance Construction

    /// Builds instance handlers bound to a specific work folder by iterating
    /// `allTypes` and calling each type's `makeInstance(dependencies:)`. In default
    /// storage mode, `blockedInDefaultStorage` handlers are filtered out — `Tools.swift`
    /// registers error stubs for them separately.
    static func buildHandlers(
        workFolderRoot: URL,
        isDefaultStorage: Bool,
        searchExploratoryByDefault: Bool = false,
        readFileMaxLines: Int = AppDefaults.readFileMaxLines,
        searchMaxResults: Int = AppDefaults.searchMaxResults,
        searchContextBefore: Int = AppDefaults.searchContextBefore,
        searchContextAfter: Int = AppDefaults.searchContextAfter,
        bashSandboxEnabled: Bool = BashConstants.defaultSandboxEnabled,
        bashSandboxPermissions: BashSandboxPermissions = BashSandboxPermissions(),
        bashAllowUnsandboxedFallback: Bool = false,
        fileManager: FileManager = .default
    ) -> [any ToolHandler] {
        let internalDir = NTMSPaths(workFolderRoot: workFolderRoot).internalDir
        let resolver = SandboxPathResolver(workFolderRoot: workFolderRoot, internalDir: internalDir)
        let deps = ToolHandlerDependencies(
            workFolderRoot: workFolderRoot,
            resolver: resolver,
            fileManager: fileManager,
            internalDir: internalDir,
            searchExploratoryByDefault: searchExploratoryByDefault,
            readFileMaxLines: readFileMaxLines,
            searchMaxResults: searchMaxResults,
            searchContextBefore: searchContextBefore,
            searchContextAfter: searchContextAfter,
            bashSandboxEnabled: bashSandboxEnabled,
            bashSandboxPermissions: bashSandboxPermissions,
            bashAllowUnsandboxedFallback: bashAllowUnsandboxedFallback
        )

        return allTypes.compactMap { type -> (any ToolHandler)? in
            if isDefaultStorage && type.blockedInDefaultStorage { return nil }
            return type.makeInstance(dependencies: deps)
        }
    }
}
