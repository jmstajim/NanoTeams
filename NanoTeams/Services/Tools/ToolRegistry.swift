import Foundation

struct ToolExecutionContext: Hashable {
    var workFolderRoot: URL
    var taskID: Int
    var runID: Int
    var roleID: String
}

/// Out-of-band signal from a tool handler indicating special processing is needed.
/// Each case carries only the data relevant to that specific tool type.
enum ToolSignal: Hashable {
    case supervisorQuestion(String)
    case teammateConsultation(id: String, question: String, context: String?)
    case teamMeeting(topic: String, participants: [String], context: String?)
    case changeRequest(targetRole: String, changes: String, reasoning: String)
    case artifact(name: String, content: String, format: String?)
    case visionAnalysis(imagePath: String, prompt: String)
    case teamCreation(config: GeneratedTeamConfig)
    case expandedSearch(ExpandedSearchPayload)
}

/// Payload for a `expand: true` call on `SearchTool`. Threaded through
/// `ToolSignal.expandedSearch` so the processor gets every argument the handler
/// parsed, without 8 positional fields on the enum case. `mode` is stored as
/// the strongly-typed enum so the processor doesn't re-parse a raw string.
///
/// Invariants enforced by the throwing init:
/// - `query` must be non-empty after trimming (empty queries would reach the
///   executor and never match anything — the LLM gets nothing back and
///   can't tell why).
/// - Numeric fields (`maxResults`, context lines, `maxMatchLines`) are
///   clamped to sane ranges so a misbehaving LLM that emits `Int.max` or
///   negative values can't crash the executor budget math.
/// - `paths` is normalized: empty arrays collapse to `nil` so consumers
///   don't have to branch on both "unset" and "set but empty".
struct ExpandedSearchPayload: Hashable {
    let query: String
    let mode: SearchMode
    let paths: [String]?
    let fileGlob: String?
    let contextBefore: Int
    let contextAfter: Int
    let maxResults: Int
    let maxMatchLines: Int

    /// Upper bound on `maxResults` — the LLM shouldn't need more; the round-
    /// robin fan-out budget math stays sane; memory stays bounded.
    static let maxAllowedResults = 1000
    /// Upper bound on `contextBefore`/`contextAfter` — a handful of lines
    /// either side is all any sensible review flow needs; wider only bloats
    /// the envelope.
    static let maxAllowedContextLines = 100
    /// Upper bound on `maxMatchLines` — protects the truncation accounting
    /// from overflow.
    static let maxAllowedMatchLines = 100_000

    enum ValidationError: Error, Equatable {
        case emptyQuery
    }

    init(
        query: String,
        mode: SearchMode,
        paths: [String]?,
        fileGlob: String?,
        contextBefore: Int,
        contextAfter: Int,
        maxResults: Int,
        maxMatchLines: Int
    ) throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.emptyQuery }
        self.query = query  // preserve original casing/spacing for display
        self.mode = mode
        // Normalize empty arrays to nil so the consumer switches on one
        // shape, not two.
        if let paths, !paths.isEmpty {
            self.paths = paths
        } else {
            self.paths = nil
        }
        self.fileGlob = fileGlob
        self.contextBefore = max(0, min(contextBefore, Self.maxAllowedContextLines))
        self.contextAfter = max(0, min(contextAfter, Self.maxAllowedContextLines))
        self.maxResults = max(1, min(maxResults, Self.maxAllowedResults))
        self.maxMatchLines = max(1, min(maxMatchLines, Self.maxAllowedMatchLines))
    }
}

struct ToolExecutionResult: Hashable {
    var providerID: String?     // OpenAI tool_call_id for conversation continuity
    var toolName: String
    var argumentsJSON: String
    var outputJSON: String
    var isError: Bool
    var signal: ToolSignal?

    init(
        toolName: String,
        argumentsJSON: String,
        outputJSON: String,
        isError: Bool,
        signal: ToolSignal? = nil
    ) {
        self.providerID = nil
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.outputJSON = outputJSON
        self.isError = isError
        self.signal = signal
    }

    init(
        providerID: String?,
        toolName: String,
        argumentsJSON: String,
        outputJSON: String,
        isError: Bool,
        signal: ToolSignal? = nil
    ) {
        self.providerID = providerID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.outputJSON = outputJSON
        self.isError = isError
        self.signal = signal
    }
}

final class ToolRegistry {
    typealias ToolHandler = (_ context: ToolExecutionContext, _ args: [String: Any]) throws ->
        ToolExecutionResult

    private var handlers: [String: ToolHandler] = [:]
    private var aliases: [String: String] = [:]

    /// Common tool name aliases that LLMs hallucinate.
    /// Maps alternate name → canonical registered name.
    static let defaultAliases: [String: String] = {
        typealias TN = ToolNames
        return [
            "grep": TN.search,
            "find": TN.search,
            "cat": TN.readFile,
            "read": TN.readFile,
            "print_tree": TN.listFiles,
            "tree": TN.listFiles,
            "ls": TN.listFiles,
            "list_directory": TN.listFiles,
            "create_file": TN.writeFile,
            "touch": TN.writeFile,
            "rm": TN.deleteFile,
            "remove": TN.deleteFile,
            "exec": TN.runXcodebuild,
            "build": TN.runXcodebuild,
            "test": TN.runXcodetests,
            "submit_artifact": TN.createArtifact,
            "save_artifact": TN.createArtifact,
            "creat_artifact": TN.createArtifact,
            "describe_image": TN.analyzeImage,
            "vision": TN.analyzeImage,
        ]
    }()

    /// Provider / training-set prefixes some models prepend to tool names.
    /// Known examples: `openai/gpt-oss-*` emits `functions.*` (Harmony protocol)
    /// and `repo_browser.*` (reflecting Anthropic's Code-Execution tool namespace
    /// that leaked into training data). Stripped before alias lookup and dispatch.
    static let knownToolNamePrefixes: [String] = ["repo_browser.", "functions."]

    /// Canonicalize a raw tool name emitted by an LLM: trim whitespace, strip a
    /// known provider prefix (`repo_browser.`, `functions.`), then apply the
    /// common-hallucination alias map. Apply at every dispatch boundary so
    /// name resolution is consistent.
    static func resolveToolName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        for prefix in knownToolNamePrefixes where lower.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return defaultAliases[name.lowercased()] ?? name
    }

    /// List of all registered tool names
    var registeredToolNames: [String] {
        Array(handlers.keys)
    }

    func register(name: String, handler: @escaping ToolHandler) {
        handlers[name.lowercased()] = handler
    }

    /// Register an alias so that `alias` resolves to the handler for `canonicalName`.
    func registerAlias(_ alias: String, for canonicalName: String) {
        aliases[alias.lowercased()] = canonicalName.lowercased()
    }

    /// Returns the canonical tool name, resolving aliases.
    func canonicalName(for name: String) -> String {
        let lower = name.lowercased()
        return aliases[lower] ?? lower
    }

    func handler(for name: String) -> ToolHandler? {
        let resolved = canonicalName(for: name)
        return handlers[resolved]
    }
    nonisolated deinit {}
}
