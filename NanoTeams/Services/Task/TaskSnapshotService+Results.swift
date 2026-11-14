import Foundation

/// The values `task_changes` gets from the snapshot store, and the refusals it can give.
extension TaskSnapshotService {
    struct ChangedFile: Codable, Equatable, Sendable {
        var path: String
        var change_type: String
        var old_path: String?
        /// `true` on a file of the current page whose diff git calls binary; absent otherwise.
        var binary: Bool?
        /// `not_utf8` on a file of the current page whose diff is not valid UTF-8; absent otherwise.
        var encoding: String?

        init(path: String, change_type: String, old_path: String? = nil, binary: Bool? = nil, encoding: String? = nil) {
            self.path = path
            self.change_type = change_type
            self.old_path = old_path
            self.binary = binary
            self.encoding = encoding
        }
    }

    struct TaskChangesResult: Codable, Equatable, Sendable {
        var folder_id: String
        var task_id: Int
        var round: Int
        var files: [ChangedFile]
        var diff: String
        var page: Int
        var total_pages: Int
        var has_more: Bool
        var not_tracked: [NotTrackedPath]
        /// What of the snapshot store was put back while the round was open (S1), by fixed
        /// labels — a `meta.warnings` line, never on the wire (`CodingKeys`).
        var store_repairs: [String] = []
        /// The page's diff file by file, raw — what the presentation layer sanitizes and
        /// attributes warnings to. Never on the wire (`CodingKeys`).
        var page_diffs: [PageFileDiff] = []

        enum CodingKeys: String, CodingKey {
            case folder_id, task_id, round, files, diff, page, total_pages, has_more, not_tracked
        }

        init(
            folder_id: String,
            task_id: Int,
            round: Int,
            files: [ChangedFile],
            diff: String,
            page: Int,
            total_pages: Int,
            has_more: Bool,
            not_tracked: [NotTrackedPath] = [],
            store_repairs: [String] = [],
            page_diffs: [PageFileDiff] = []
        ) {
            self.folder_id = folder_id
            self.task_id = task_id
            self.round = round
            self.files = files
            self.diff = diff
            self.page = page
            self.total_pages = total_pages
            self.has_more = has_more
            self.not_tracked = not_tracked
            self.store_repairs = store_repairs
            self.page_diffs = page_diffs
        }
    }

    /// A path the snapshot reports but cannot stage, and why — `embedded_repository` for a
    /// nested repository or submodule (§8: listed, never compared), `hidden_by_round_rules`
    /// for a file ignore rules written during the round would hide and that could not be
    /// staged even so.
    struct NotTrackedPath: Codable, Equatable, Sendable {
        var path: String
        var reason: String

        static let embeddedRepository = "embedded_repository"
        static let hiddenByRoundRules = "hidden_by_round_rules"
    }
}

/// The refusals `task_changes` writes for the agent — one builder each, called by the code that
/// refuses and rendered by `RuntimePromptRegistry`. Until 2026-11-12 (F6 T3) the registry rendered
/// a hand-written copy of each (`TaskSnapshotService.RefusalSample`) that production never read,
/// so rewording a real refusal moved no fingerprint.
nonisolated enum TaskChangesRefusal {
    /// Whether `filePath` is no relative path inside the folder: a traversal, an absolute path, a
    /// backslash or a NUL. One rule for the two places that refuse it — `diffChanges`, and
    /// `task_changes` before it calls `diffChanges`, where the call's own round is in hand.
    static func refuses(filePath: String) -> Bool {
        filePath.contains("..") || filePath.hasPrefix("/") || filePath.contains("\\") || filePath.contains("\0")
    }

    /// runtime-prompt
    static func invalidFilePath(_ path: String) -> String {
        "Invalid file_path: '\(path)'. Relative path without traversal expected."
    }

    /// runtime-prompt
    static let invalidPage = "page must be positive integer >= 1."

    /// runtime-prompt
    static let invalidPageSize = "page_size must be positive integer >= 1."

    /// runtime-prompt
    static let invalidRoundArgument = "Invalid parameter 'round': must be positive integer >= 1."

    /// runtime-prompt
    static let invalidPageArgument = "Invalid parameter 'page': must be positive integer >= 1."

    /// runtime-prompt
    static func protectedWorkFolder(_ path: String) -> String {
        "Protected work folder: \(path)"
    }

    /// runtime-prompt
    static func snapshotsUnavailable(taskID: Int) -> String {
        "Snapshots unavailable for task \(taskID)."
    }

    /// runtime-prompt
    static func roundDoesNotExist(round: Int, taskID: Int) -> String {
        "Round \(round) does not exist for task \(taskID)."
    }
}
