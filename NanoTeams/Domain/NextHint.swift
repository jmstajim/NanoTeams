import Foundation

/// The machine-copyable half of a tool envelope: the call to make NEXT, with its
/// arguments already filled in.
///
/// The prose in `error.message` says what went wrong; this says what to do about it
/// in a shape the model can copy rather than re-derive. `read_file`'s over-cap
/// rejection is the reference use — it hands back `read_lines` with the path and a
/// concrete range, so the recovery costs the model no reasoning at all.
///
/// **Why this lives in `Domain/` and not beside the envelope helpers that emit it.**
/// It is a pure Foundation value type by construction, and the layering rule for this
/// project is that `Domain/` holds exactly those. Its old home in
/// `Services/Tools/ToolDataTypes.swift` made it unreachable from Domain without
/// inverting the dependency direction, and that had a measured cost rather than a
/// theoretical one: `AutovisorStatus.acceptRejectionAdvice` had to return a bare
/// `String` and say so in its own doc comment ("returning a `NextHint` here would make
/// `AutovisorStatus` the first Domain type to reference one from `Services/Tools`"),
/// which left the whole collaboration path — every `manage_role` / `control_task`
/// rejection the Autovisor makes — emitting an envelope whose `next` slot existed and
/// was always empty. Observed 2026-08-11: a manager facing a Review task tried
/// `accept` on a `.done` role, got the bare fact, and stalled.
///
/// Snake_case property names are the WIRE contract (the envelope is serialized
/// verbatim by `JSONCoderFactory.makeWireEncoder`), not a style lapse — they match
/// `suggested_cmd` / `suggested_args` as the model reads them.
nonisolated struct NextHint: Codable, Hashable {
    var suggested_cmd: String?
    var suggested_args: [String: String]?
    var reason: String?
}

// MARK: - The two repairs every path-taking tool hands back

nonisolated extension NextHint {
    /// "Look at what IS there": `list_files` on the directory that should have held `path`.
    /// The repair for every not-found path — `read_file`, `read_lines`, `edit_file`. A
    /// top-level path has no parent component; `.` names the work folder root, which is what
    /// `list_files` expects (an empty path is not a listing).
    static func listingParent(of path: String) -> NextHint {
        let parent = (path as NSString).deletingLastPathComponent
        return NextHint(
            suggested_cmd: ToolNames.listFiles,
            suggested_args: ["path": parent.isEmpty ? "." : parent],
            reason: "Check available files"
        )
    }

    /// "It is a directory — here is what is inside": `list_files` on `path` itself. The
    /// repair for every tool handed a directory where it needed a file.
    static func listing(_ path: String) -> NextHint {
        NextHint(
            suggested_cmd: ToolNames.listFiles,
            suggested_args: ["path": path],
            reason: "List directory contents"
        )
    }
}
