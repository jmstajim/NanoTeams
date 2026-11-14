import Foundation

/// The snapshot refs of a task: listing, resolving the latest run and round, and removal.
extension TaskSnapshotService {

    /// Lists all refs currently recorded for a task.
    func listTaskRefs(workFolder: URL, taskID: Int) async throws -> [String] {
        let gitDir = NTMSPaths(workFolderRoot: workFolder).snapshotsGitDir
        guard fileManager.fileExists(atPath: gitDir.appendingPathComponent("HEAD").path) else {
            return []
        }

        let prefix = "refs/nanoteams/\(taskID)/"
        let res = try await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "for-each-ref", "--format=%(refname)", prefix],
            in: workFolder,
            gitDir: gitDir
        )
        return res.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Deletes all refs recorded for a task and triggers automated git garbage collection.
    func cleanupTask(workFolder: URL, taskID: Int) async throws {
        try await withFolderLock(workFolder: workFolder) { _ in
            let gitDir = NTMSPaths(workFolderRoot: workFolder).snapshotsGitDir
            guard fileManager.fileExists(atPath: gitDir.appendingPathComponent("HEAD").path) else {
                return
            }

            await deleteRoundRules(taskID: taskID, workFolder: workFolder, gitDir: gitDir)
            let refs = try await listTaskRefs(workFolder: workFolder, taskID: taskID)
            guard !refs.isEmpty else { return }

            for ref in refs {
                _ = try? await runPrivateGit(
                    ["--git-dir=\(gitDir.path)", "update-ref", "-d", ref],
                    in: workFolder,
                    gitDir: gitDir
                )
            }

            _ = try? await runPrivateGit(
                ["--git-dir=\(gitDir.path)", "-c", "gc.autoDetach=false", "gc", "--prune=now"],
                in: workFolder,
                gitDir: gitDir
            )
        }
    }

    /// The refs of one task, by run and round: `refs/nanoteams/<task>/<run>/<round>/<phase>`.
    /// Runs are numbered from 0, as `RunService` numbers them; a ref of any other shape is not
    /// read (the run-less `refs/nanoteams/<task>/<round>/<phase>` of an unreleased build before
    /// F2 is gone — N13 of the F6 acceptance).
    struct TaskRefIndex: Equatable, Sendable {
        /// run → round → the phases recorded for it.
        var phases: [Int: [Int: Set<SnapshotPhase>]] = [:]

        init(refs: [String], taskID: Int) {
            let prefix = "refs/nanoteams/\(taskID)/"
            for ref in refs where ref.hasPrefix(prefix) {
                let parts = ref.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 3,
                      let run = Int(parts[0]), run >= 0,
                      let round = Int(parts[1]), round >= 1,
                      let phase = SnapshotPhase(rawValue: String(parts[2]))
                else { continue }
                phases[run, default: [:]][round, default: []].insert(phase)
            }
        }

        var latestRunID: Int? { phases.keys.max() }

        func latestRound(ofRun runID: Int) -> Int? { phases[runID]?.keys.max() }

        func recordedPhases(run runID: Int, round: Int) -> Set<SnapshotPhase> {
            phases[runID]?[round] ?? []
        }
    }

    func taskRefIndex(gitDir: URL, taskID: Int, workFolder: URL) async throws -> TaskRefIndex {
        let res = try await runPrivateGit(
            ["--git-dir=\(gitDir.path)", "for-each-ref", "--format=%(refname)", "refs/nanoteams/\(taskID)/"],
            in: workFolder,
            gitDir: gitDir
        )
        if res.exitCode != 0 {
            throw ExternalAutovisorError("Snapshot ref listing failed: \(res.stderr)", code: .commandFailed)
        }
        return TaskRefIndex(refs: res.stdout.split(separator: "\n").map(String.init), taskID: taskID)
    }

    /// The end of a round that has ended: of the end snapshots recorded for it, the one taken
    /// LAST (N7 of the F6 acceptance, 2026-11-12). Until then the first of a fixed list of phases
    /// won — `review`, then `failure`, `restart`, … — so a round that went on after an
    /// intermediate acceptance, or after `stop` and `resume`, kept reading against the tree of
    /// its first `review`, and a later `failure` lost to an earlier `review`. `nil` when the
    /// round has no end snapshot.
    func latestEndRef(
        taskID: Int, runID: Int, round: Int, recorded: Set<SnapshotPhase>, workFolder: URL, gitDir: URL
    ) async -> String? {
        var latest: (ref: String, moment: Int64)?
        for phase in SnapshotPhase.endPhases where recorded.contains(phase) {
            let ref = Self.refName(taskID: taskID, runID: runID, round: round, phase: phase)
            let moment = await commitRecord(ref, workFolder: workFolder, gitDir: gitDir).time ?? Int64.min
            if latest == nil || moment > latest!.moment {
                latest = (ref, moment)
            }
        }
        return latest?.ref
    }

    nonisolated static func refName(taskID: Int, runID: Int, round: Int, phase: SnapshotPhase) -> String {
        "refs/nanoteams/\(taskID)/\(runID)/\(round)/\(phase.rawValue)"
    }
}
