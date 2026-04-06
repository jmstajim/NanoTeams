import Foundation

/// Single source of truth for all built-in tools.
///
/// Each handler type declares its own schema, category, and behavioral flags
/// (`excludedInMeetings`, `blockedInDefaultStorage`, `isCacheable`). Schema/metadata
/// queries iterate `allTypes` statically. Runtime dispatch uses `buildHandlers(...)`
/// which drives the same `allTypes` list via `makeInstance(dependencies:)` — adding
/// a new tool is one append to `allTypes` and one conforming struct.
enum ToolHandlerRegistry {

    // MARK: - All Built-in Handlers (single source of truth)

    /// Every built-in tool type, in display order. Add a new tool by appending here
    /// and creating a conforming `ToolHandler` struct — no other edits required.
    static let allTypes: [any ToolHandler.Type] = [
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

    /// Read-only tools whose results can be cached across tool-loop iterations.
    /// Metadata-driven — `GitDiffTool` overrides `isCacheable` to `false`, so no
    /// hardcoded subtraction is needed here.
    static let cacheableTools: Set<String> =
        Set(allTypes.filter { $0.isCacheable }.map { $0.name })

    /// Tool names in a given category. Stable, single source of truth.
    static func names(in category: ToolCategory) -> Set<String> {
        Set(allTypes.filter { $0.category == category }.map { $0.name })
    }

    /// Read-only file system tools: `read_file`, `read_lines`, `list_files`, `search`.
    static var fileReadTools: Set<String> { names(in: .fileRead) }

    /// Mutating file system tools: `write_file`, `edit_file`, `delete_file`.
    static var fileWriteTools: Set<String> { names(in: .fileWrite) }

    /// All file system tools (read + write).
    static var allFileTools: Set<String> { fileReadTools.union(fileWriteTools) }

    /// Read-only Git tools: `git_status`, `git_log`, `git_diff`, `git_branch_list`.
    static var gitReadTools: Set<String> { names(in: .gitRead) }

    /// Mutating Git tools (add/commit/pull/stash/checkout/merge/branch).
    static var gitWriteTools: Set<String> { names(in: .gitWrite) }

    /// Xcode build/test tools.
    static var xcodeTools: Set<String> { names(in: .xcode) }

    /// Vision analysis tools.
    static var visionTools: Set<String> { names(in: .vision) }

    // MARK: - Handler Instance Construction

    /// Builds instance handlers bound to a specific work folder by iterating
    /// `allTypes` and calling each type's `makeInstance(dependencies:)`. In default
    /// storage mode, `blockedInDefaultStorage` handlers are filtered out — `Tools.swift`
    /// registers error stubs for them separately.
    static func buildHandlers(
        workFolderRoot: URL,
        isDefaultStorage: Bool,
        fileManager: FileManager = .default
    ) -> [any ToolHandler] {
        let internalDir = NTMSPaths(workFolderRoot: workFolderRoot).internalDir
        let resolver = SandboxPathResolver(workFolderRoot: workFolderRoot, internalDir: internalDir)
        let deps = ToolHandlerDependencies(
            workFolderRoot: workFolderRoot,
            resolver: resolver,
            fileManager: fileManager,
            internalDir: internalDir
        )

        return allTypes.compactMap { type -> (any ToolHandler)? in
            if isDefaultStorage && type.blockedInDefaultStorage { return nil }
            return type.makeInstance(dependencies: deps)
        }
    }
}
