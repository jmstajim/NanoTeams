import Foundation

/// Categorizes tools for UI display and behavioral grouping.
nonisolated enum ToolCategory: String, Codable {
    case fileRead
    case fileWrite
    case gitRead
    case gitWrite
    case xcode
    case supervisor
    case memory
    case collaboration
    case artifact
    case vision
    case delegation
    case shell
    case computerUse
}

// MARK: - ToolHandlerDependencies

/// Bundle of per-registry state passed to `ToolHandler.makeInstance(dependencies:)`.
/// Each handler picks the fields it needs; there is no runtime cost for unused fields.
nonisolated struct ToolHandlerDependencies {
    let workFolderRoot: URL
    let resolver: SandboxPathResolver
    let fileManager: FileManager
    let internalDir: URL
    /// When `true`, `SearchTool` treats a missing `exploratory` argument as
    /// `true`. User preference, surfaced from `StoreConfiguration` at
    /// registry-build time.
    let searchExploratoryByDefault: Bool
    /// Hard line limit enforced by `read_file`. User preference, surfaced from
    /// `StoreConfiguration` at registry-build time.
    let readFileMaxLines: Int
    /// Default `max_results` for `search` when the LLM omits the argument.
    /// User preference, surfaced from `StoreConfiguration` at registry-build time.
    let searchMaxResults: Int
    /// Default `context_before` for `search` when the LLM omits the argument.
    let searchContextBefore: Int
    /// Default `context_after` for `search` when the LLM omits the argument.
    let searchContextAfter: Int
    /// Whether `bash` confines commands in a macOS Seatbelt sandbox. From the
    /// user's `BashPolicy`, surfaced at registry-build time.
    let bashSandboxEnabled: Bool
    /// Per-folder read/write grants for the `bash` Seatbelt sandbox. From the
    /// user's `BashPolicy`, surfaced at registry-build time.
    let bashSandboxPermissions: BashSandboxPermissions
    /// Whether `bash` may retry unsandboxed if the Seatbelt wrapper fails to launch.
    let bashAllowUnsandboxedFallback: Bool

    init(
        workFolderRoot: URL,
        resolver: SandboxPathResolver,
        fileManager: FileManager,
        internalDir: URL,
        searchExploratoryByDefault: Bool,
        readFileMaxLines: Int,
        searchMaxResults: Int,
        searchContextBefore: Int,
        searchContextAfter: Int,
        bashSandboxEnabled: Bool = BashConstants.defaultSandboxEnabled,
        bashSandboxPermissions: BashSandboxPermissions = BashSandboxPermissions(),
        bashAllowUnsandboxedFallback: Bool = false
    ) {
        self.workFolderRoot = workFolderRoot
        self.resolver = resolver
        self.fileManager = fileManager
        self.internalDir = internalDir
        self.searchExploratoryByDefault = searchExploratoryByDefault
        self.readFileMaxLines = readFileMaxLines
        self.searchMaxResults = searchMaxResults
        self.searchContextBefore = searchContextBefore
        self.searchContextAfter = searchContextAfter
        self.bashSandboxEnabled = bashSandboxEnabled
        self.bashSandboxPermissions = bashSandboxPermissions
        self.bashAllowUnsandboxedFallback = bashAllowUnsandboxedFallback
    }
}

// MARK: - ToolHandler

/// Self-describing tool: a single type owns its schema, name, category, behavioral
/// flags, and execution logic. Adding a new tool is one conforming type in one file,
/// added to `ToolHandlerRegistry.allTypes` — `buildHandlers` iterates that list
/// automatically via `makeInstance(dependencies:)`.
///
/// - Static metadata (`name`, `schema`, `category`, `excludedInMeetings`,
///   `blockedInDefaultStorage`) is available without instantiation,
///   enabling schema lookup before any work folder is opened (bootstrap, settings UI).
/// - Instance `handle(context:args:)` captures per-registry state (sandbox resolver,
///   file manager, work folder root) via `makeInstance`.
nonisolated protocol ToolHandler {
    static var name: String { get }
    static var schema: ToolSchema { get }
    static var category: ToolCategory { get }

    /// When `true`, the tool is filtered out of meeting turn tool schemas.
    /// Used for signaling and collaboration tools that don't make sense inside meetings.
    static var excludedInMeetings: Bool { get }

    /// When `true`, the tool is blocked (replaced with an error stub) when no real
    /// work folder is open. Used for write/git/xcode tools.
    static var blockedInDefaultStorage: Bool { get }

    /// When `true`, the tool is never included in any role's tool schema offered to
    /// the LLM. Used by tools that are invoked through a dedicated control flow
    /// (e.g. `create_team`, called via `TeamGenerationService` rather than the runtime).
    static var availableToRoles: Bool { get }

    /// Factory — constructs an instance bound to a specific work folder. Called
    /// from `ToolHandlerRegistry.buildHandlers`. Handlers ignore the fields they
    /// don't need.
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self

    /// Executes the tool. Errors are caught inside via `ToolErrorHandler.execute`,
    /// so this method is non-throwing by contract.
    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult
}

nonisolated extension ToolHandler {
    static var excludedInMeetings: Bool { false }
    static var blockedInDefaultStorage: Bool { false }
    static var availableToRoles: Bool { true }
}
