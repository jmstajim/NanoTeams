import Foundation

/// Categorizes tools for UI display and behavioral grouping.
enum ToolCategory: String, Codable {
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
}

// MARK: - ToolHandlerDependencies

/// Bundle of per-registry state passed to `ToolHandler.makeInstance(dependencies:)`.
/// Each handler picks the fields it needs; there is no runtime cost for unused fields.
struct ToolHandlerDependencies {
    let workFolderRoot: URL
    let resolver: SandboxPathResolver
    let fileManager: FileManager
    let internalDir: URL
}

// MARK: - ToolHandler

/// Self-describing tool: a single type owns its schema, name, category, behavioral
/// flags, and execution logic. Adding a new tool is one conforming type in one file,
/// added to `ToolHandlerRegistry.allTypes` — `buildHandlers` iterates that list
/// automatically via `makeInstance(dependencies:)`.
///
/// - Static metadata (`name`, `schema`, `category`, `excludedInMeetings`,
///   `blockedInDefaultStorage`, `isCacheable`) is available without instantiation,
///   enabling schema lookup before any work folder is opened (bootstrap, settings UI).
/// - Instance `handle(context:args:)` captures per-registry state (sandbox resolver,
///   file manager, work folder root) via `makeInstance`.
protocol ToolHandler {
    static var name: String { get }
    static var schema: ToolSchema { get }
    static var category: ToolCategory { get }

    /// When `true`, the tool is filtered out of meeting turn tool schemas.
    /// Used for signaling and collaboration tools that don't make sense inside meetings.
    static var excludedInMeetings: Bool { get }

    /// When `true`, the tool is blocked (replaced with an error stub) when no real
    /// work folder is open. Used for write/git/xcode tools.
    static var blockedInDefaultStorage: Bool { get }

    /// When `true`, results of this tool can be cached and deduplicated across
    /// tool-loop iterations. Defaults to `true` for `.fileRead` / `.gitRead`
    /// categories (except `git_diff`, which overrides to `false`).
    static var isCacheable: Bool { get }

    /// Factory — constructs an instance bound to a specific work folder. Called
    /// from `ToolHandlerRegistry.buildHandlers`. Handlers ignore the fields they
    /// don't need.
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self

    /// Executes the tool. Errors are caught inside via `ToolErrorHandler.execute`,
    /// so this method is non-throwing by contract.
    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult
}

extension ToolHandler {
    static var excludedInMeetings: Bool { false }
    static var blockedInDefaultStorage: Bool { false }

    /// Default: read-only file/git tools are cacheable; everything else is not.
    /// `GitDiffTool` overrides to `false` because the working tree mutates between reads.
    static var isCacheable: Bool {
        switch category {
        case .fileRead, .gitRead: return true
        default: return false
        }
    }
}
