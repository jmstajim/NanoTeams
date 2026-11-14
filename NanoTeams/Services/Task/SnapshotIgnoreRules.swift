import Foundation

/// The ignore rules a round of snapshots STARTED under, kept for the rest of the round
/// (F6 «missed» and N18, 2026-11-12).
///
/// Snapshots obey the same ignore rules as the person's git — and the reviewed role can write
/// those rules: a `.gitignore` naming its new file and itself made both invisible to
/// `task_changes`, and a tracked file it then ignored was reported deleted with its old
/// content. So the start snapshot records the rules, and every later snapshot of the round —
/// and the live diff — stages under THEM: a rule written during the round hides no file until
/// the next round starts, and a rule removed during it exposes nothing the person ignored. The
/// edited `.gitignore` is an ordinary change of the round. A directory the round created that
/// such a rule hides is reported rather than read, and new files it hides are staged within a
/// limit (`TaskSnapshotService.RoundHiddenStagingLimit`).
///
/// The person's `core.excludesFile` is not part of the record: it lives outside the work folder,
/// where a role does not write, and stays the live file.
nonisolated struct SnapshotIgnoreRules: Codable, Equatable, Sendable {
    /// Every per-directory `.gitignore` in the work tree (outside `.git`, `.nanoteams` and
    /// embedded repositories), by work-folder-relative path, as bytes.
    var ignoreFiles: [String: Data]
    /// What `snapshots.git/info/exclude` holds: the internal-directory lines, the work folder's
    /// own `info/exclude` and the rules of an enclosing repository (N19).
    var mirroredExcludes: Data

    init(ignoreFiles: [String: Data], mirroredExcludes: Data) {
        self.ignoreFiles = ignoreFiles
        self.mirroredExcludes = mirroredExcludes
    }

    /// The ref the rules of one round are stored under — a blob, outside `refs/nanoteams/`, so
    /// the round and run listings never read it as a phase.
    static func refName(taskID: Int, runID: Int, round: Int) -> String {
        "\(refPrefix(taskID: taskID))\(runID)/\(round)"
    }

    static func refPrefix(taskID: Int) -> String {
        "refs/nanoteams-rules/\(taskID)/"
    }
}
