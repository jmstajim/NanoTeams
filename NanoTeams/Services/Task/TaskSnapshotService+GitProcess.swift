import Foundation

/// How the snapshot store's git is RUN: the options every call carries and the environment it
/// starts with (S1, S10 of the F6 acceptance, 2026-11-12). The store's own files — config,
/// `info/`, alternates, hooks — are `TaskSnapshotService+StoreIntegrity.swift`.
///
/// Together the two make git run on a configuration NanoTeams wrote, so what a snapshot stores
/// is the bytes on disk. Live finding (AgentCheck, task 14): a `[filter] clean` planted in
/// `snapshots.git/config` and a `.gitattributes` in the work tree made `add -A` run the filter
/// and store an 8-byte file as the empty blob `e69de29`.
/// The git a snapshot store runs, and the time limit of a command whose cost does not grow with
/// the work tree. `.system` is `/usr/bin/git` with the 60 s every git call of the app has; a
/// test gives another executable (a wrapper that stalls one subcommand) or a shorter limit.
nonisolated struct SnapshotGitInvocation: Sendable, Equatable {
    var executable: String
    var timeLimit: TimeInterval

    static let system = SnapshotGitInvocation(executable: "/usr/bin/git", timeLimit: 60)
}

extension TaskSnapshotService {

    /// The empty tree — what `GIT_ATTR_SOURCE` names, so git reads attributes from a tree that
    /// has none instead of from the work tree.
    nonisolated static let emptyTreeID = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// `PATH` of a snapshot git process: the system's own directories, never the app's.
    nonisolated static let snapshotGitSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The WHOLE environment of a snapshot git process (S10). Nothing comes from the app's
    /// environment: until 2026-11-12 the process inherited it and each `GIT_*` was blanked to
    /// "" — which for git is not absence (`GIT_WORK_TREE=""` refuses `init --bare`, an empty
    /// `GIT_OBJECT_DIRECTORY` breaks every call), and `XDG_CONFIG_HOME` / `HOME` passed through.
    ///
    /// Attributes, and why two mechanisms: `GIT_ATTR_SOURCE` = the empty tree makes git ≥ 2.40
    /// read no `.gitattributes` of the work tree or index at all — whatever attribute a later
    /// git adds; `GIT_ATTR_NOSYSTEM` drops the system file, `core.attributesFile=/dev/null`
    /// (`hardeningFlags`) the person's. Older git ignores the variable, and macOS 15 with
    /// Xcode 16 ships git 2.39 — there the `info/attributes` NanoTeams writes holds
    /// (`attributesOverride`): it outranks every `.gitattributes` and resets each attribute
    /// that changes the bytes `add` stores or the diff the agent reads. `add` has no
    /// `--no-filters` (only `hash-object` does), and a filter needs a driver from config,
    /// which the store's reference config and this environment never carry — but `ident`,
    /// `text` / `eol` and `working-tree-encoding` need none.
    nonisolated static func snapshotGitEnvironment(indexFile: String?) -> [String: String] {
        var env: [String: String] = [
            "PATH": snapshotGitSearchPath,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_ATTR_SOURCE": emptyTreeID,
            "GIT_AUTHOR_NAME": "NanoTeams",
            "GIT_AUTHOR_EMAIL": "snapshots@nanoteams.internal",
            "GIT_COMMITTER_NAME": "NanoTeams",
            "GIT_COMMITTER_EMAIL": "snapshots@nanoteams.internal",
        ]
        if let indexFile {
            env["GIT_INDEX_FILE"] = indexFile
        }
        return env
    }

    /// The `-c` options every snapshot call carries: no hook, no fsmonitor, no submodule
    /// recursion, no attributes file, no CRLF conversion, and the person's excludes file by
    /// path — `/dev/null` when they have none, so git's XDG default is never read behind it.
    nonisolated static func hardeningFlags(excludesFile: String?) -> [String] {
        [
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "submodule.recurse=false",
            "-c", "diff.ignoreSubmodules=all",
            "-c", "core.sharedRepository=0600",
            "-c", "core.attributesFile=/dev/null",
            "-c", "core.autocrlf=false",
            "-c", "core.excludesFile=\(excludesFile ?? "/dev/null")",
        ]
    }

    /// The one runner of the snapshot store's git: hardened options, the environment above.
    @discardableResult
    func runPrivateGit(
        _ arguments: [String],
        in directory: URL,
        gitDir: URL?,
        isDiff: Bool = false
    ) async throws -> ProcessRunner.RawResult {
        let excludesFile = await globalExcludesFile()
        return try await runSnapshotGit(
            arguments, in: directory, gitDir: gitDir, isDiff: isDiff, excludesFile: excludesFile)
    }

    func runSnapshotGit(
        _ arguments: [String],
        in directory: URL,
        gitDir: URL?,
        isDiff: Bool = false,
        excludesFile: String?
    ) async throws -> ProcessRunner.RawResult {
        var fullArgs: [String] = []
        var remainingArgs = arguments
        if let first = remainingArgs.first, first.hasPrefix("--git-dir=") {
            fullArgs.append(first)
            remainingArgs.removeFirst()
        }
        fullArgs.append(contentsOf: Self.hardeningFlags(excludesFile: excludesFile))

        if isDiff, let diffIdx = remainingArgs.firstIndex(of: "diff") {
            remainingArgs.insert(contentsOf: ["--no-ext-diff", "--no-textconv", "--ignore-submodules=all"], at: diffIdx + 1)
        }
        fullArgs.append(contentsOf: remainingArgs)

        let env = Self.snapshotGitEnvironment(indexFile: gitDir?.appendingPathComponent("index").path)
        return try await ProcessRunner.runAsync(
            executable: gitInvocation.executable,
            arguments: fullArgs,
            currentDirectory: directory,
            environment: env,
            inheritsEnvironment: false,
            timeout: Self.timeLimit(forSnapshotGit: fullArgs, perCommand: gitInvocation.timeLimit) ?? .infinity)
    }

    /// The subcommands whose cost grows with the work tree or the store: they run to their end,
    /// bounded only by cancellation (N1 of the F6 acceptance, 2026-11-12). Until then each carried
    /// the 60 s every git call has, so a cold `add -A` of a large folder without ignore rules was
    /// SIGTERMed — then SIGKILLed — on every attempt, git dropped `index.lock` with the index
    /// unwritten, and the folder never got a start snapshot; `gc --prune=now` after a task's
    /// removal never finished on a large store. A snapshot's wait is bounded where it is waited
    /// for (`TaskSnapshotConstants.captureWaitBudget`), not by killing the work.
    nonisolated static let subcommandsWithoutTimeLimit: Set<String> = [
        "add", "rm", "ls-files", "write-tree", "diff-index", "check-ignore", "gc",
    ]

    /// The time limit of a snapshot git call: `nil` for a subcommand in
    /// `subcommandsWithoutTimeLimit`, `perCommand` for every other.
    nonisolated static func timeLimit(forSnapshotGit arguments: [String], perCommand: TimeInterval) -> TimeInterval? {
        guard let subcommand = gitSubcommand(arguments) else { return perCommand }
        return subcommandsWithoutTimeLimit.contains(subcommand) ? nil : perCommand
    }

    /// The first argument that is neither a global option nor the value of `-c`.
    nonisolated static func gitSubcommand(_ arguments: [String]) -> String? {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "-c" || argument == "-C" {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            return argument
        }
        return nil
    }

    // MARK: - The person's excludes file

    /// The excludes file every snapshot applies as the person's own git would — given, or read
    /// once from their git config (`GlobalExcludesSource`).
    func globalExcludesFile() async -> String? {
        switch globalExcludesSource {
        case .given(let path):
            return path
        case .personsGitConfig:
            if let resolved = personsGlobalExcludesFile { return resolved }
            let path = await readPersonsGlobalExcludesFile()
            personsGlobalExcludesFile = .some(path)
            return path
        }
    }

    /// `core.excludesFile` from the person's global config, read BY PATH through the runner
    /// above — `~/.gitconfig`, which wins, then `~/.config/git/config` — or git's default
    /// `~/.config/git/ignore` when it exists. Until 2026-11-12 this was a synchronous
    /// `git config --global` that inherited the app's environment from a cwd a role could
    /// write to — the one git call that went around the runner (S10).
    private func readPersonsGlobalExcludesFile() async -> String? {
        let personHome = home ?? fileManager.homeDirectoryForCurrentUser
        let configs = [
            personHome.appendingPathComponent(".gitconfig"),
            personHome.appendingPathComponent(".config/git/config"),
        ]
        for config in configs where fileManager.fileExists(atPath: config.path) {
            guard let res = try? await runSnapshotGit(
                ["config", "--file", config.path, "--includes", "--get", "core.excludesfile"],
                in: URL(fileURLWithPath: "/", isDirectory: true), gitDir: nil, excludesFile: nil),
                res.exitCode == 0
            else { continue }
            let value = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if value == "~" { return personHome.path }
            if value.hasPrefix("~/") {
                return personHome.appendingPathComponent(String(value.dropFirst(2))).path
            }
            return (value as NSString).expandingTildeInPath
        }
        let fallback = personHome.appendingPathComponent(".config/git/ignore")
        return fileManager.fileExists(atPath: fallback.path) ? fallback.path : nil
    }
}
