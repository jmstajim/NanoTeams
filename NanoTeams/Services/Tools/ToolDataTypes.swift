import Foundation

// MARK: - Error Codes (from JSON Schema)

enum ToolErrorCode: String, Codable, CaseIterable {
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
    /// A subprocess passed its deadline and was SIGTERMed — `ProcessRunnerError.timeout`.
    /// Split out of `COMMAND_FAILED` because the recovery is the opposite one: a
    /// command that ran and exited non-zero needs different ARGUMENTS, a command
    /// that never finished may just need a narrower scope or one more attempt.
    /// The `_TIMED_OUT` suffix is load-bearing — `ToolErrorNotePolicy.direction`
    /// routes on it (alongside `DELEGATION_TIMED_OUT`) to "may be transient — retry
    /// once", so naming this `TIMED_OUT` would silently fall to the generic arm.
    case commandTimedOut = "COMMAND_TIMED_OUT"
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
    /// The tool call was cancelled before it produced a result. Three sources:
    /// (a) `ToolRuntime.executeAll` saw `Task.isCancelled` between handlers and
    /// emitted a synthetic envelope for the unrun calls; (b) `ProcessRunner.run`
    /// observed `Task.isCancelled` mid-subprocess and SIGTERMed/SIGKILLed the
    /// child, then threw `ProcessRunnerError.cancelled`; (c) the `bash` /
    /// computer-use approval gates held a call for a human and the hold was
    /// ABANDONED — Pause, work-folder switch, teardown — rather than answered.
    /// All three routes converge on this code so downstream classifiers see one
    /// signal, not "command_failed that happens to mention 'cancelled'".
    ///
    /// (c) is the reason this code is not merely cosmetic next to `BASH_DENIED`:
    /// the gate's envelope is persisted into the step's conversation, and the
    /// step re-runs on resume — so mislabelling an abandoned hold as a denial
    /// left the model permanently told the Supervisor had refused a command they
    /// were never asked about, under a don't-retry direction (2026-08-30).
    case cancelled = "CANCELLED"
    /// `bash` command blocked by the command-permission layer because a DECISION was
    /// made against it: a deny rule matched, the Auto judge rejected it, or the
    /// Supervisor answered Deny on a held command. Distinct from `COMMAND_FAILED` (the
    /// command ran and exited non-zero) — a denied command never executed — from
    /// `CANCELLED`, which is the same held command with NO answer, and from
    /// `APPROVAL_UNAVAILABLE`, where nobody COULD answer. Routed to a don't-retry
    /// guidance via `ToolErrorNotePolicy.direction`'s `bash_denied` case.
    /// (A foreground timeout is surfaced as a success envelope with
    /// `timed_out: true`, not an error code.)
    case bashDenied = "BASH_DENIED"
    /// A computer-use action (`ui_click` / `ui_type` / `ui_key` / `ui_scroll` /
    /// `screen_capture`) was blocked by the computer-use permission layer because a
    /// decision was made against it: mode Off, a self-guard / allowlist /
    /// blocked-pattern deny, out-of-bounds coordinates, the Auto judge rejected it, or
    /// the Supervisor answered Deny. Distinct from `COMMAND_FAILED` (the OS action ran
    /// and failed), from `CANCELLED` (an abandoned hold — see there) and from
    /// `APPROVAL_UNAVAILABLE` (nobody could answer).
    case computerUseDenied = "COMPUTER_USE_DENIED"
    /// An action that needs a human's approval — a non-read-only `bash` command, a
    /// computer-use click / type / key — in a run that HAS no human to give it
    /// (`ApprovalPresence`: autonomous team, Autovisor supervision, headless). Not a
    /// decision: nobody said no, nobody could say yes, and nothing inside the run
    /// changes that — so, unlike the two `*_DENIED` codes, the direction the model gets
    /// (`ToolErrorNotePolicy`) and the loop nudges name NO escalation channel: the
    /// channel a role holds (`ask_supervisor`) reaches the same answerer that cannot
    /// approve. Until 2026-09-07 this shipped as `BASH_DENIED` with a text asking the
    /// supervisor to "allow unattended command approval" — a setting that never existed.
    /// The families' MODE, not this code, is what a resolver reads: a family every action
    /// of which would land here is withheld from the schema before the model can call it
    /// (`ApprovalGatedAvailability`).
    case approvalUnavailable = "APPROVAL_UNAVAILABLE"
    /// A plain `ask_supervisor` carrying the questionnaire's shape — several questions, or
    /// one with its options enumerated (`SupervisorQuestionShape`) — while `ask_supervisor_form`
    /// is in the batch's schema. An ERROR, not a park: nothing was asked and the Supervisor is
    /// not waiting, so the model can send the form in one more call. Emitted only when the form
    /// is available (`ToolExecutionContext.questionnaireAvailable`); a role with the plain ask
    /// alone keeps the numbered list. `ToolErrorNotePolicy` appends no direction — the
    /// envelope's `next` names the form and the `questions` entry per question (2026-09-11).
    case questionnaireRequired = "QUESTIONNAIRE_REQUIRED"
}

// MARK: - Response Envelope Types

nonisolated struct ToolError: Codable {
    var code: String
    var message: String
    var details: [String: String]?
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

/// One line as the `search` envelope carries it: the pair `[76, "text"]`.
///
/// Positional rather than keyed. `LineRef`'s `{"line":76,"text":"…"}` spends 16 bytes of key
/// text on every line, and one measured page (65 hits over 17 files, context ±1/2) carried 260
/// of them — 40% of `data.matches` was JSON punctuation restating the same two field names.
/// The pair says the same two facts in the same order to a reader that has just read `"lines"`.
///
/// The number stays an `Int` and never moves inside the string (CLAUDE.md #315). `edit_file`
/// repairs a pasted `76│` / `76|` / `76⇥` prefix and NOT a `76: ` one
/// (`FileWriteHandlers.lineNumberPrefixPattern`),
/// and `read_lines` coerces `start_line` from the value it is given — `coerceInt("76: ")` is nil,
/// which `end_line` then reads as "to EOF" under a success envelope. `list_files` refused a
/// marker inside the path string for the same reason: the model copies these tokens verbatim
/// into the next call.
nonisolated struct SearchLine: Codable, Equatable {
    var number: Int
    var text: String

    init(number: Int, text: String) {
        self.number = number
        self.text = text
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        number = try container.decode(Int.self)
        text = try container.decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(number)
        try container.encode(text)
    }
}

/// Content matches folded by FILE, which is the shape the tool envelope carries.
///
/// One record per hit repeats the path on every hit and the `{line,text}` key pair again on
/// every context line: on the measured page above the path was written 48 times for 17 files
/// and the array cost 22 226 of the envelope's 22 807 bytes. Folded, the same facts are 45%
/// smaller with context and 27% smaller at the default context of 0 — and a tool result lives
/// in the append-only wire until a compaction epoch, so that is paid on every subsequent
/// request of the step rather than once.
///
/// Encoded keys sort to `file`, `hits`, `lines` (the wire encoder uses `.sortedKeys`), i.e. the
/// identifier first and the scalars before the array. With 200 lines from one file the path
/// would otherwise sit thousands of bytes below its own content.
///
/// The fold lives at the ENVELOPE boundary, exactly like `SkippedFileGroup` (CLAUDE.md #314):
/// `SearchExecutorOutput.matches` stays per-hit because that is what the scan produced, and the
/// exploratory envelope keeps the per-hit shape — there the round-robin order across expanded
/// terms is the only ranking signal the model sees, and folding by file destroys it.
nonisolated struct SearchFileGroup: Codable, Equatable {
    var file: String
    /// Which numbers in `lines` actually matched the query; the rest is requested context.
    ///
    /// A separate array rather than a flag on the line, because one line can be a hit AND the
    /// context of a neighbouring hit. Merging the windows is what makes the fold lossless, and
    /// it is only lossless if the hit label survives the merge.
    var hits: [Int]
    /// Every line this file contributes — hits and context together, merged by number and
    /// ordered ascending. Overlapping context windows collapse to one entry per line.
    var lines: [SearchLine]

    /// Folds per-hit matches by file, in first-appearance (walk) order.
    ///
    /// Deterministic by construction — file order is the walk's, line order is numeric — because
    /// two runs of one query must produce byte-identical envelopes or the prompt prefix moves and
    /// the server pays a full re-prefill (~4300–6100 ms against ~350 warm). `SkippedFileGroup.group`
    /// states the same requirement for the same reason.
    static func group(_ matches: [SearchMatch]) -> [SearchFileGroup] {
        var order: [String] = []
        var byFile: [String: Accumulator] = [:]
        for match in matches {
            if byFile[match.path] == nil {
                order.append(match.path)
                byFile[match.path] = Accumulator()
            }
            byFile[match.path]?.absorb(match)
        }
        return order.compactMap { path in
            byFile[path].map {
                SearchFileGroup(file: path, hits: $0.hits.sorted(), lines: $0.orderedLines())
            }
        }
    }

    /// Per-file merge state. Text keyed by line number so overlapping context windows collapse;
    /// hit numbers kept in their own set so a line that is both keeps its label.
    private struct Accumulator {
        var text: [Int: String] = [:]
        var hits: Set<Int> = []

        mutating func absorb(_ match: SearchMatch) {
            for ref in (match.context_before ?? []) + (match.context_after ?? []) {
                // Context only fills gaps: a hit's own text is the authority for its line.
                if text[ref.line] == nil { text[ref.line] = ref.text }
            }
            text[match.line] = match.text
            hits.insert(match.line)
        }

        func orderedLines() -> [SearchLine] {
            text.keys.sorted().map { SearchLine(number: $0, text: text[$0] ?? "") }
        }
    }
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

nonisolated struct AskSupervisorFormData: Codable {
    var headline: String
    var questions: Int
    var status: String
}

// MARK: - Argument Error

/// The two ways an argument can be unusable, and the ONE wording for each.
///
/// Both cases state a FACT and stop there. The repair imperative ("fix the
/// arguments and retry", plus the tool's whole required list) is appended once,
/// centrally, by `ToolErrorNotePolicy.direction`'s `INVALID_ARGS` arm — putting
/// it here too would print the same instruction twice on the wire, which is the
/// duplication that type exists to remove. What the policy CANNOT supply is
/// per-argument: which key, what shape it must have, and what shape actually
/// arrived. That is this type's whole job.
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

    /// Names the JSON type a value actually arrived as, for an `invalidValue`
    /// detail: "must be an integer; received a string" beats "must be an
    /// integer" because the model can see its own mistake instead of re-reading
    /// a constraint it believed it had met.
    ///
    /// The `NSNumber` arm must run before any `Bool`/`Int` cast: JSON `true`
    /// bridges to an `NSNumber` that satisfies `as? Bool` AND `as? Int`, so only
    /// the CoreFoundation type id separates "a boolean" from "a number"
    /// (the same bridging `optionalInt` relies on to read `true` as 1).
    static func jsonTypeName(of value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "a boolean" : "a number"
        case is String:
            return "a string"
        case is [Any]:
            return "an array"
        case is [String: Any]:
            return "an object"
        default:
            return "an unsupported value"
        }
    }
}
