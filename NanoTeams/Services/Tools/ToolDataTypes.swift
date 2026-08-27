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
    /// `edit_file`'s whitespace-tolerant fallback found `old_text` in several
    /// places once trailing whitespace is ignored, so a single replace would be
    /// a guess. Distinct from `ANCHOR_NOT_FOUND` because the recovery differs:
    /// the anchor is essentially right and needs MORE context lines, not a
    /// character-level correction — the generic anchor guidance would actively
    /// mislead.
    case anchorAmbiguous = "ANCHOR_AMBIGUOUS"
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
    /// `bash` command blocked by the command-permission layer: a deny rule
    /// matched, the Auto judge rejected it, or human approval was required but
    /// unavailable (Manual mode in an autonomous / Autovisor / headless context —
    /// Auto mode runs unattended). Distinct from `COMMAND_FAILED` (the command
    /// ran and exited non-zero) — a denied command never executed. Routed to a
    /// don't-retry guidance via `ToolErrorNotePolicy.direction`'s `bash_denied` case.
    /// (A foreground timeout is surfaced as a success envelope with
    /// `timed_out: true`, not an error code.)
    case bashDenied = "BASH_DENIED"
    /// A computer-use action (`ui_click` / `ui_type` / `ui_key` / `ui_scroll` /
    /// `screen_capture`) was blocked by the computer-use permission layer: mode Off,
    /// a self-guard / allowlist / blocked-pattern deny, out-of-bounds coordinates,
    /// the Auto judge rejected it, or human approval was required but unavailable.
    /// Distinct from `COMMAND_FAILED` (the OS action ran and failed).
    case computerUseDenied = "COMPUTER_USE_DENIED"
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
///
/// This is the per-file record the walk accumulates. What reaches the model is
/// `SkippedFileGroup` — see there for why the two shapes differ.
nonisolated struct SkippedFile: Codable {
    var path: String
    var reason: String
}

/// Skipped files folded by reason, which is the shape the tool envelope carries.
///
/// One entry per file floods the context whenever the cause is per-CLASS rather than
/// per-file: every `.doc` in a tree yields the same "save as .docx" sentence, every
/// mislabeled export the same "not valid RTF", every un-downloaded cloud placeholder the
/// same open error. Forty files then cost forty copies of one fact, which is the same
/// flood that made binaries an aggregate count one field over.
///
/// The fold lives at the ENVELOPE boundary, not in the walk: `SearchExecutorOutput.skipped`
/// stays per-file because that is what actually happened. This is a statement of the same
/// facts sized for a reader.
nonisolated struct SkippedFileGroup: Codable, Equatable {
    var reason: String
    /// How many files hit this reason — the true total, which `paths` may not reach.
    var count: Int
    /// Up to `pathSampleLimit` of them. The cap needs no separate notice: `count` sitting
    /// beside a shorter list says so.
    var paths: [String]

    /// Sample size per group. Enough to recognise the pattern (which folder, which
    /// extension) without restating it.
    static let pathSampleLimit = 5

    /// Folds per-file records by reason, most-common first.
    ///
    /// Ties break on `reason` so the output is a function of the input alone — two runs
    /// over one tree must produce byte-identical envelopes, or the prompt prefix moves for
    /// no reason. Paths keep walk order, which is already sorted.
    static func group(_ skipped: [SkippedFile]) -> [SkippedFileGroup] {
        var order: [String] = []
        var byReason: [String: [String]] = [:]
        for file in skipped {
            if byReason[file.reason] == nil { order.append(file.reason) }
            byReason[file.reason, default: []].append(file.path)
        }
        return order
            .map { reason in
                let paths = byReason[reason] ?? []
                return SkippedFileGroup(
                    reason: reason,
                    count: paths.count,
                    paths: Array(paths.prefix(pathSampleLimit))
                )
            }
            .sorted { ($0.count, $1.reason) > ($1.count, $0.reason) }
    }
}

// MARK: - Git Data Types

nonisolated struct GitPathStatus: Codable {
    var path: String
    var status: String
    /// Set only for a staged rename. Porcelain v1 emits `old.txt -> new.txt` in ONE
    /// field; passing that through verbatim breaks the house rule that every path a
    /// tool reports is usable as a `read_file`/`git_add` argument, so `path` carries
    /// the NEW name and the old one moves here.
    var old_path: String?
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
    /// The key was present but its value could not be interpreted. Distinct
    /// from `missingRequired` so the model is told what's actually wrong —
    /// reporting "Missing" for an argument it just sent sends it hunting for
    /// a phantom omission instead of fixing the type.
    case invalidValue(key: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingRequired(let key):
            "Missing required argument: \(key)"
        case .invalidValue(let key, let detail):
            "Argument '\(key)' \(detail)"
        }
    }
}
