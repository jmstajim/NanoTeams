import Foundation

/// Actor managing isolated git snapshot storage in `<workFolder>/.nanoteams/internal/snapshots.git`.
/// Captures work folder changes per task and round without touching user repository state.
actor TaskSnapshotService: TaskSnapshotProtocol {
    typealias SnapshotPhase = TaskSnapshotPhase

    let fileManager = FileManager.default
    let home: URL?

    /// Where the person's `core.excludesFile` comes from: their own git config, read on first
    /// use, or given — so a test does not read the developer's real `~/.gitconfig` (N11).
    enum GlobalExcludesSource: Sendable {
        case personsGitConfig
        case given(String?)
    }
    let globalExcludesSource: GlobalExcludesSource
    /// The person's excludes file once read; `.some(nil)` when they have none.
    var personsGlobalExcludesFile: String??
    /// Per store path, the config `initializeStore` writes there — the reference (S1).
    var referenceConfigs: [String: Data] = [:]
    /// Which git runs the store, and how long a command whose cost does NOT grow with the work
    /// tree may take (`SnapshotGitInvocation`).
    let gitInvocation: SnapshotGitInvocation
    nonisolated private static let folderLocks = AsyncKeyedLock()

    /// `home` is the person's home: what the sandbox hides and where their git config is.
    init(home: URL? = nil, gitInvocation: SnapshotGitInvocation = .system) {
        self.home = home
        self.globalExcludesSource = .personsGitConfig
        self.gitInvocation = gitInvocation
    }

    init(home: URL? = nil, globalExcludesFile: String?, gitInvocation: SnapshotGitInvocation = .system) {
        self.home = home
        self.globalExcludesSource = .given(globalExcludesFile)
        self.gitInvocation = gitInvocation
    }

    /// Removes the `*.lock` files a git of this process left in the store — safe because the
    /// folder lock is held and `runAsync` returns only after its child exits, and because no other
    /// NanoTeams process has the folder open (`WorkFolderInstanceLock`, D-M18 N17) — which a
    /// snapshot asks before it sweeps (`withFolderLock`'s `folderStillHeld`, D-M18 R8). What neither
    /// lock covers: a git child of a NanoTeams that has since exited — the instance lock went with
    /// its process, the child did not. Only where git keeps locks: the store's own
    /// files, `refs/` (recursively), `objects/info/`, `objects/pack/`. Until 2026-11-12 the sweep
    /// walked the whole store, every loose object included, on every acquisition of the lock —
    /// synchronously, on the actor every folder's snapshots share (N14). Off the actor now.
    @concurrent
    nonisolated static func removeStaleLocks(in gitDir: URL) async {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: gitDir.path) else { return }
        func sweep(_ directory: URL, recursive: Bool) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names {
                let url = directory.appendingPathComponent(name)
                let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
                if type == .typeDirectory {
                    if recursive { sweep(url, recursive: true) }
                } else if name.hasSuffix(".lock") {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
        sweep(gitDir, recursive: false)
        sweep(gitDir.appendingPathComponent("refs", isDirectory: true), recursive: true)
        sweep(gitDir.appendingPathComponent("objects/info", isDirectory: true), recursive: false)
        sweep(gitDir.appendingPathComponent("objects/pack", isDirectory: true), recursive: false)
    }

    /// The scratch stores `referenceConfig` makes beside the real one and deletes when done
    /// (`snapshots-reference-<uuid>.git`, S1) — the ones a crash or a kill between the two left
    /// behind. Every scratch store is made and removed inside this lock, and no other NanoTeams
    /// process has the folder open, so any found here is an orphan (F6 C / D-M18 N17, 2026-11-12).
    /// Off the actor, like the lock sweep.
    @concurrent
    nonisolated static func removeOrphanedReferenceStores(in internalDir: URL) async {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: internalDir.path) else { return }
        for name in names where name.hasPrefix(referenceStorePrefix) && name.hasSuffix(".git") {
            try? fileManager.removeItem(at: internalDir.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// The name every scratch store begins with — `referenceConfig` makes them, the sweep finds them.
    nonisolated static let referenceStorePrefix = "snapshots-reference-"

    /// Runs `operation` alone on the folder's store, after holding an existing store to its
    /// reference (`restoreStore`, S1). `operation` gets what that check put back.
    ///
    /// `folderStillHeld` is asked once the in-process lock is this call's — after a wait that can
    /// outlast a folder switch — and before the sweeps below. Both sweeps are safe only while this
    /// process holds the folder (`WorkFolderInstanceLock`): after it let the folder go, another
    /// NanoTeams may have opened it and be using a scratch store or a git lock there (D-M18 R8).
    func withFolderLock<T: Sendable>(
        workFolder: URL,
        folderStillHeld: @Sendable () -> Bool = { true },
        _ operation: (_ storeRepairs: [String]) async throws -> T
    ) async throws -> T {
        let canonicalPath = workFolder.standardizedFileURL.resolvingSymlinksInPath().path
        await Self.folderLocks.acquire(key: canonicalPath)
        defer {
            Self.folderLocks.release(key: canonicalPath)
        }
        guard folderStillHeld() else { throw Self.folderNotHeldError }

        let gitDir = NTMSPaths(workFolderRoot: workFolder).snapshotsGitDir
        await Self.removeStaleLocks(in: gitDir)
        await Self.removeOrphanedReferenceStores(in: gitDir.deletingLastPathComponent())
        var repairs: [String] = []
        if fileManager.fileExists(atPath: gitDir.appendingPathComponent("HEAD").path) {
            repairs = try await restoreStore(gitDir: gitDir, workFolder: workFolder)
            await recordStoreRepairs(repairs, gitDir: gitDir, workFolder: workFolder)
        }

        return try await operation(repairs)
    }

    /// Ensures the private snapshots bare git repository is initialized with proper exclusions and config.
    func ensureRepositoryInitialized(in workFolder: URL) async throws -> (gitDir: URL, env: [String: String]) {
        let resolver = SandboxPathResolver(workFolderRoot: workFolder, home: home)
        if resolver.hidesRoot {
            throw ExternalAutovisorError(TaskChangesRefusal.protectedWorkFolder(workFolder.path), code: .permissionDenied)
        }

        let snapshotPaths = NTMSPaths(workFolderRoot: workFolder)
        let internalDir = snapshotPaths.internalDir
        let gitDir = snapshotPaths.snapshotsGitDir

        let headFile = gitDir.appendingPathComponent("HEAD")
        if !fileManager.fileExists(atPath: headFile.path) {
            try fileManager.createDirectory(at: internalDir, withIntermediateDirectories: true, attributes: NTMSRepository.internalDirAttributes)
            try? fileManager.setAttributes(NTMSRepository.internalDirAttributes, ofItemAtPath: internalDir.path)
            try await initializeStore(at: gitDir, workFolder: workFolder)
        }

        syncExcludes(in: workFolder, gitDir: gitDir)

        let env: [String: String] = [
            "GIT_INDEX_FILE": gitDir.appendingPathComponent("index").path,
            "GIT_AUTHOR_NAME": "NanoTeams",
            "GIT_AUTHOR_EMAIL": "snapshots@nanoteams.internal",
            "GIT_COMMITTER_NAME": "NanoTeams",
            "GIT_COMMITTER_EMAIL": "snapshots@nanoteams.internal"
        ]

        return (gitDir, env)
    }

    /// What a snapshot of a folder this process no longer holds ends with (`withFolderLock`).
    nonisolated static let folderNotHeldError = ExternalAutovisorError(
        "The work folder is no longer open in this NanoTeams.", code: .folderChanged,
        next: ExternalNextCall.folderChanged.hint())

    /// Captures a snapshot for a task, run, and round at a specific phase (`.start`, `.review`, etc.).
    func takeSnapshot(
        workFolder: URL, taskID: Int, runID: Int, round: Int, phase: SnapshotPhase,
        folderStillHeld: @escaping @Sendable () -> Bool
    ) async throws {
        try await withFolderLock(workFolder: workFolder, folderStillHeld: folderStillHeld) { storeRepairs in
            let resolver = SandboxPathResolver(workFolderRoot: workFolder, home: home)
            if resolver.hidesRoot {
                throw ExternalAutovisorError(TaskChangesRefusal.protectedWorkFolder(workFolder.path), code: .permissionDenied)
            }

            let (gitDir, _) = try await ensureRepositoryInitialized(in: workFolder)

            let startRef = "refs/nanoteams/\(taskID)/\(runID)/\(round)/start"
            let roundRules = phase == .start
                ? nil
                : await loadRoundRules(taskID: taskID, runID: runID, round: round, workFolder: workFolder, gitDir: gitDir)
            let staged = try await stageTree(
                workFolder: workFolder, gitDir: gitDir, resolver: resolver,
                roundRules: roundRules, startRef: roundRules == nil ? nil : startRef)
            if phase == .start {
                try await storeRoundRules(
                    staged.currentRules, taskID: taskID, runID: runID, round: round,
                    workFolder: workFolder, gitDir: gitDir)
            }
            let treeSHA = staged.tree

            var message = "task \(taskID) run \(runID) round \(round) \(phase.rawValue)"
            let trailers = [Self.notShownTrailerLine(staged.notShown), Self.storeRepairedTrailerLine(storeRepairs)]
                .compactMap { $0 } + ["\(Self.snapshotMomentTrailer)\(Self.snapshotMomentMilliseconds())"]
            message += "\n\n" + trailers.joined(separator: "\n")
            let commitRes = try await runPrivateGit(
                ["--git-dir=\(gitDir.path)", "commit-tree", treeSHA, "-m", message],
                in: workFolder,
                gitDir: gitDir
            )
            if commitRes.exitCode != 0 {
                throw ExternalAutovisorError("Snapshot commit-tree failed: \(commitRes.stderr)", code: .commandFailed)
            }
            let commitSHA = commitRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            let refName = "refs/nanoteams/\(taskID)/\(runID)/\(round)/\(phase.rawValue)"
            let updateRes = try await runPrivateGit(
                ["--git-dir=\(gitDir.path)", "update-ref", refName, commitSHA],
                in: workFolder,
                gitDir: gitDir
            )
            if updateRes.exitCode != 0 {
                throw ExternalAutovisorError("Snapshot update-ref failed: \(updateRes.stderr)", code: .commandFailed)
            }
        }
    }
}
