import Foundation

/// What a snapshot pays for the files that only ignore rules WRITTEN DURING the round hide (F6
/// «missed», review of 2026-11-12) — the policy alone, without git; `restoreRoundRules` applies
/// it. The ordinary first round of a project writes `.gitignore` with `node_modules/` and runs
/// `npm install`; forcing all of that into the private repository made the snapshot, the store
/// and the `task_changes` pages grow with whatever the role chose to ignore.
extension TaskSnapshotService {

    /// How much a snapshot stages of the files that ONLY rules written during the round hide and
    /// that the round's start did not hold — the files a role made and then ignored itself.
    /// Past either limit the rest goes to `not_tracked` (`hidden_by_round_rules`) unstaged: the
    /// agent still sees each one exists and what hides it, and the cost of a snapshot stays that
    /// of an ordinary change, whatever the role chose to ignore.
    nonisolated struct RoundHiddenStagingLimit: Sendable, Equatable {
        /// Files per snapshot. A role ignores single files by hand — `.env`, a log, a local
        /// config — a handful per round; 200 is far above that, and far below what a dependency
        /// or build tree holds (thousands to tens of thousands), which arrives as a directory
        /// and is not counted here anyway. It is also 40 pages of `task_changes` at its default
        /// page size of 5 — already more than an agent reads.
        var files: Int
        /// Bytes per snapshot, summed. 5 MB keeps a hidden lock file or log readable (a
        /// `package-lock.json` is commonly 0.5–2 MB) and keeps a model, an archive or a database
        /// dump (tens of MB and up) out of the private repository. Git stores a blob once, so a
        /// file re-staged by every phase of the round costs this once, not once per snapshot.
        var bytes: Int
        /// Skipped files listed one by one; past this the list names their nearest
        /// directories instead (`./` for the work folder itself), so `not_tracked` stays a list
        /// an agent can read when a role ignores thousands of files in place (`*.log`).
        var listedSkippedFiles: Int

        static let standard = RoundHiddenStagingLimit(files: 200, bytes: 5 * 1024 * 1024, listedSkippedFiles: 200)
    }

    /// Which of `files` a snapshot stages: in path order, until staging the next would pass
    /// either limit — then that one and every later one is skipped.
    nonisolated static func planRoundHiddenStaging(
        _ files: [(path: String, size: Int)], limit: RoundHiddenStagingLimit
    ) -> (stage: [String], skipped: [String]) {
        let ordered = files.sorted { $0.path < $1.path }
        var stage: [String] = []
        var bytes = 0
        for (index, file) in ordered.enumerated() {
            if stage.count >= limit.files || bytes + file.size > limit.bytes {
                return (stage, ordered[index...].map(\.path))
            }
            stage.append(file.path)
            bytes += file.size
        }
        return (stage, [])
    }

    /// The skipped files as `not_tracked` names them: each one, or — past the list limit — the
    /// directories that hold them, with a trailing `/`.
    nonisolated static func listedSkippedPaths(_ paths: [String], limit: RoundHiddenStagingLimit) -> [String] {
        guard paths.count > limit.listedSkippedFiles else { return paths }
        let directories = paths.map { path -> String in
            guard let slash = path.lastIndex(of: "/") else { return "./" }
            return String(path[...slash])
        }
        return Set(directories).sorted()
    }
}
