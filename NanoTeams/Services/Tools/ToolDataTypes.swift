import Foundation

// MARK: - Error Codes (from JSON Schema)

enum ToolErrorCode: String, Codable {
    case invalidArgs = "INVALID_ARGS"
    case fileNotFound = "FILE_NOT_FOUND"
    case notAFile = "NOT_A_FILE"
    case notADirectory = "NOT_A_DIRECTORY"
    case permissionDenied = "PERMISSION_DENIED"
    case rangeOutOfBounds = "RANGE_OUT_OF_BOUNDS"
    case anchorNotFound = "ANCHOR_NOT_FOUND"
    case patchApplyFailed = "PATCH_APPLY_FAILED"
    case conflict = "CONFLICT"
    case commandFailed = "COMMAND_FAILED"
    /// `delegate_to_team` rejected the call due to delegation policy:
    /// not top-level, target not in whitelist, generated-team disabled, depth-cap reached,
    /// chat-mode target, etc. Distinct from `INVALID_ARGS` (malformed args) and
    /// `COMMAND_FAILED` (transient runtime failure during the delegated run).
    case delegationDenied = "DELEGATION_DENIED"
    /// Delegated child task exceeded `DelegationConstants.delegationTimeoutSeconds`
    /// without reaching a terminal state. The child engine has been stopped.
    case delegationTimedOut = "DELEGATION_TIMED_OUT"
    /// Supervisor queued a message for the delegating role while the child was
    /// running, signalling that the delegation should be aborted (e.g. "team
    /// is looping, stop"). The child engine has been stopped; the user's
    /// message text is embedded in `error.message` so the parent role can
    /// re-evaluate on its next tool-loop iteration.
    case delegationInterrupted = "DELEGATION_INTERRUPTED"
    /// The tool call was cancelled before it produced a result. Two sources:
    /// (a) `ToolRuntime.executeAll` saw `Task.isCancelled` between handlers and
    /// emitted a synthetic envelope for the unrun calls; (b) `ProcessRunner.run`
    /// observed `Task.isCancelled` mid-subprocess and SIGTERMed/SIGKILLed the
    /// child, then threw `ProcessRunnerError.cancelled`. Both routes converge
    /// on this code so downstream classifiers see one signal, not "command_failed
    /// that happens to mention 'cancelled'".
    case cancelled = "CANCELLED"
}

// MARK: - Response Envelope Types

nonisolated struct ToolError: Codable {
    var code: String
    var message: String
    var details: [String: String]?
}

nonisolated struct NextHint: Codable {
    var suggested_cmd: String?
    var suggested_args: [String: String]?
    var reason: String?
}

nonisolated struct ToolResultMeta: Codable {
    var truncated: Bool
    var warnings: [String]

    init(truncated: Bool = false, warnings: [String] = []) {
        self.truncated = truncated
        self.warnings = warnings
    }
}

// MARK: - FileSystem Data Types

nonisolated struct Entry: Codable {
    var path: String
    var name: String
    var type: String  // "file" | "dir"
}

nonisolated struct LineRef: Codable {
    var line: Int
    var text: String
}

nonisolated struct SearchMatch: Codable {
    var path: String
    var line: Int
    var text: String
    var context_before: [LineRef]?
    var context_after: [LineRef]?
}

/// A file whose name or relative path matched the search query, independent of
/// content. Surfaced alongside `SearchMatch` so the LLM can find files it
/// already knows the name of in one tool call instead of falling back to
/// `list_files`. `matched_on` lets the LLM see whether the hit was on the
/// basename (stronger signal) or only on a parent directory in the path.
///
/// `matched_on` is a typed enum (encoded as the raw string `"basename"` or
/// `"path"`) so the discriminator can never drift between the matcher and
/// the wire — the only two valid values are spelled exactly once.
nonisolated struct FilenameMatch: Codable, Equatable {
    enum MatchedOn: String, Codable {
        case basename
        case path
    }
    var path: String
    var matched_on: MatchedOn
}

/// A file the search traversal encountered but could not index.
/// Surfaced so the LLM/user can tell "no hits" from "file was unreadable".
nonisolated struct SkippedFile: Codable {
    var path: String
    var reason: String
}

// MARK: - Git Data Types

nonisolated struct GitPathStatus: Codable {
    var path: String
    var status: String
}

nonisolated struct Commit: Codable {
    var hash: String
    var message: String
    var author: String?
    var date: String?
}

nonisolated struct BranchInfo: Codable {
    var name: String
    var current: Bool
    var upstream: String?
    var is_remote: Bool?
}

// MARK: - Xcode Data Types

nonisolated struct XcodeIssue: Codable {
    var file: String?
    var line: Int?
    var column: Int?
    var severity: String?
    var message: String
    var raw: String?
}

nonisolated struct XcodeProjectRef: Codable {
    var kind: String  // "workspace" | "project"
    var path: String
}

// MARK: - Supervisor Data Types

nonisolated struct AskSupervisorData: Codable {
    var question: String
    var status: String
}

// MARK: - Argument Error

enum ToolArgumentError: LocalizedError {
    case missingRequired(String)

    var errorDescription: String? {
        switch self {
        case .missingRequired(let key):
            "Missing required argument: \(key)"
        }
    }
}
