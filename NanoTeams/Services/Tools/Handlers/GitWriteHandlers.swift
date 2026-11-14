import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - git_add

nonisolated struct GitAddTool: ToolHandler {
    static let name = TN.gitAdd
    static let schema = ToolSchema(
        name: TN.gitAdd,
        description: "Add files to git staging area for commit.",
        parameters: JS.object(
            properties: [
                "paths": JS.array(items: JS.string()),
            ],
            required: ["paths"]
        )
    )
    static let category: ToolCategory = .gitWrite
    static let undeclaredArguments = ToolArgumentVocabulary.aliases(["files", "path", "file"], of: "paths")
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL
    let resolver: SandboxPathResolver

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot, resolver: dependencies.resolver)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // A work folder that IS a credential store (`~/.ssh`, `~/.claude` opened as a
            // project) is no more git's to touch than the file tools' — asked by every git tool,
            // not only by the five that take paths (#382).
            if resolver.hidesRoot { throw SandboxPathError.protectedWorkFolder }
            // `files` / `path` / `file` arrive here as `paths` (`undeclaredArguments`); a bare
            // string coerces to a one-element list.
            let paths = try requiredStringArray(args, "paths")

            // `{"paths": []}` reaches here intact (coerceStringArray keeps an explicitly
            // empty list), and a bare `git add` exits 0 — so the model asked to stage
            // files, staged none, and read ok:true. Same success-envelope-for-a-no-op
            // shape as the git_pull regression fixed 2026-08-07.
            guard !paths.isEmpty else {
                throw ToolArgumentError.invalidValue(
                    key: "paths",
                    detail: "is empty — name at least one file, or \".\" to stage everything.")
            }

            // Absolute and redundant-work-folder-name forms are tolerated, as in the file
            // tools; a path those tools REFUSE is refused here too (#378).
            //
            // The positives are EXPANDED here rather than handed to git with the hidden
            // locations as `:(exclude)` beside them: measured on git 2.54, an exclude next to a
            // directory positive makes `git add` stage NOTHING for some directory names and
            // everything for others, silently, under exit 0 — and the envelope then reported
            // what the caller asked for rather than what git did. Expanding means every path
            // staged is one this tool judged and can name (#378).
            let positives = try resolver.gitPositives(forPaths: paths)
            let found = try Self.filesToStage(
                positives: positives, resolver: resolver, in: workFolderRoot)
            switch found {
            case .gitRefused(let failure):
                if GitErrorClassifier.isNotARepository(stderr: failure) {
                    return GitErrorClassifier.notARepositoryError(toolName: Self.name, args: args)
                }
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed,
                    message: failure.isEmpty
                        ? "git add failed with no output — check that the paths exist inside the work folder."
                        : failure)
            case .found(let files):
                struct AddData: Codable {
                    var staged: [String]
                }
                guard !files.isEmpty else {
                    // A path the caller NAMED that matches nothing is a fault it can repair —
                    // git said so before this tool expanded the positives itself, and the
                    // sentence is the same one. A bare `.` over a clean tree is not: nothing to
                    // stage is the whole truth about it.
                    guard paths.allSatisfy({ $0.trimmingCharacters(in: .whitespaces) == "." })
                    else {
                        return makeErrorResult(
                            toolName: Self.name, args: args,
                            code: .commandFailed,
                            message: "did not match any files that are new, changed or deleted: "
                                + positives.joined(separator: ", ")
                                + ". Check the path with list_files, or pass \".\" to stage the whole work folder.")
                    }
                    return makeSuccessResult(
                        toolName: Self.name, args: args,
                        data: AddData(staged: []),
                        meta: ToolResultMeta(
                            truncated: false,
                            warnings: ["Nothing to stage under \(positives.joined(separator: ", "))"
                                + " — no file there is new, changed or deleted."]))
                }
                var gitArgs = ["add", "--"]
                gitArgs.append(contentsOf: files.map(resolver.gitLiteral))
                let result = try ProcessRunner.runRoleGit(gitArgs, in: workFolderRoot)
                guard result.success else {
                    // No not-a-repository arm here: the expansion above already ran two git
                    // queries successfully, so there IS a repository, and the only thing left
                    // to say is what git said.
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .commandFailed,
                        message: result.stderr.isEmpty
                            ? "git add failed with no output — check that the paths exist inside the work folder."
                            : result.stderr)
                }
                return makeSuccessResult(
                    toolName: Self.name, args: args, data: AddData(staged: files))
            }
        }
    }
}

extension GitAddTool {
    /// Every file under `positives` that `git add` would touch — new, changed or deleted — as
    /// work-folder-relative paths the resolver permits.
    ///
    /// Two queries, because they answer different halves and disagree about their root:
    /// `ls-files --others` prints paths relative to the CWD, `diff --name-only` relative to the
    /// REPOSITORY (measured), so the diff side takes `--relative`. Both are read-only.
    enum StageCandidates {
        case found([String])
        /// git's own first line — the arm `git add` had before, kept so a broken repository
        /// still reports what git said rather than an empty stage.
        case gitRefused(String)
    }

    static func filesToStage(
        positives: [String], resolver: SandboxPathResolver, in root: URL
    ) throws -> StageCandidates {
        var found: Set<String> = []
        for positive in positives {
            let spec = resolver.gitLiteral(positive)
            for query in [
                ["ls-files", "--others", "--exclude-standard", "--", spec],
                ["diff", "--relative", "--name-only", "--", spec],
            ] {
                let result = try ProcessRunner.runRoleGit(query, in: root)
                guard result.success else { return .gitRefused(result.stderr) }
                found.formUnion(
                    result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
                        .map(String.init))
            }
        }
        // Judged one by one, so nothing hidden can ride in on a directory the caller named.
        let permitted = found.filter { relative in
            let path = (root.path as NSString).appendingPathComponent(relative)
            return resolver.permits(canonicalPath: SandboxPathResolver.canonicalPath(path))
        }
        return .found(permitted.sorted())
    }
}

// MARK: - git_commit

nonisolated struct GitCommitTool: ToolHandler {
    static let name = TN.gitCommit
    static let schema = ToolSchema(
        name: TN.gitCommit,
        description: "Commit staged changes.",
        parameters: JS.object(
            properties: [
                "message": JS.string(),
                "amend": JS.boolean(),
            ],
            required: ["message"]
        )
    )
    static let category: ToolCategory = .gitWrite
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL
    let resolver: SandboxPathResolver

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot, resolver: dependencies.resolver)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // A work folder that IS a credential store (`~/.ssh`, `~/.claude` opened as a
            // project) is no more git's to touch than the file tools' — asked by every git tool,
            // not only by the five that take paths (#382).
            if resolver.hidesRoot { throw SandboxPathError.protectedWorkFolder }
            let message = try requiredString(args, "message")
            let amend = optionalBool(args, "amend", default: false)

            var gitArgs = ["commit", "-m", message]
            if amend {
                gitArgs.append("--amend")
            }

            let result = try ProcessRunner.runRoleGit(gitArgs, in: workFolderRoot)

            guard result.success else {
                let errorMsg = result.stderr + result.stdout
                if GitErrorClassifier.isNotARepository(stderr: errorMsg) {
                    return GitErrorClassifier.notARepositoryError(toolName: Self.name, args: args)
                }
                // Git spells the same situation two ways: "nothing to commit" normally,
                // and "nothing added to commit but untracked files present" when the tree
                // holds only untracked files. Matching one left the other as COMMAND_FAILED
                // — two error codes for one failure class, which `ToolErrorNotePolicy.direction`
                // then routes differently.
                if errorMsg.contains("nothing to commit")
                    || errorMsg.contains("nothing added to commit") {
                    // Keep git's actionable half. Collapsing both spellings to a bare
                    // "Nothing to commit" would fix the error CODE and lose the only
                    // sentence that tells the model what to do next.
                    let untrackedOnly = errorMsg.contains("untracked files present")
                        || errorMsg.contains("nothing added to commit")
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .conflict,
                        message: untrackedOnly
                            ? "Nothing to commit — only untracked files are present. Stage them with git_add first."
                            : "Nothing to commit — the working tree is clean. Continue with the next step."
                    )
                }
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed, message: errorMsg
                )
            }

            let hashResult = try ProcessRunner.runRoleGit(["rev-parse", "HEAD"], in: workFolderRoot)
            let hash =
                hashResult.success
                    ? hashResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""

            struct CommitData: Codable {
                var hash: String
                var message: String
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: CommitData(hash: hash, message: message)
            )
        }
    }
}

// MARK: - git_pull

nonisolated struct GitPullTool: ToolHandler {
    static let name = TN.gitPull
    static let schema = ToolSchema(
        name: TN.gitPull,
        description: "Pull from remote.",
        parameters: JS.object(
            properties: [
                "remote": JS.string("Remote name; omit for origin."),
                "branch": JS.string(),
                "rebase": JS.boolean("Rebase instead of merge"),
            ]
        )
    )
    static let category: ToolCategory = .gitWrite
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL
    let resolver: SandboxPathResolver

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot, resolver: dependencies.resolver)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // A work folder that IS a credential store (`~/.ssh`, `~/.claude` opened as a
            // project) is no more git's to touch than the file tools' — asked by every git tool,
            // not only by the five that take paths (#382).
            if resolver.hidesRoot { throw SandboxPathError.protectedWorkFolder }
            let remote = optionalString(args, "remote") ?? "origin"
            let branch = optionalString(args, "branch")
            let rebase = optionalBool(args, "rebase", default: false)

            let checkedRemote = GitErrorClassifier.validatedOperand(
                remote, named: "remote", toolName: Self.name, args: args)
            if let rejection = checkedRemote.rejection { return rejection }
            let checkedBranch = branch.map {
                GitErrorClassifier.validatedOperand($0, named: "branch", toolName: Self.name, args: args)
            }
            if let rejection = checkedBranch?.rejection { return rejection }

            var gitArgs = ["pull"]
            if rebase {
                gitArgs.append("--rebase")
            }
            gitArgs.append(checkedRemote.value)
            if let branch = checkedBranch?.value {
                gitArgs.append(branch)
            }

            let result = try ProcessRunner.runRoleGit(gitArgs, in: workFolderRoot)

            let output = result.stdout + result.stderr

            struct PullData: Codable {
                var success: Bool
                var conflicts: [String]
                var output: String
            }

            // A pull can fail for reasons that are not conflicts — no such remote,
            // no upstream, refusing to merge unrelated histories. Those used to
            // fall through to the success envelope below carrying
            // `success: false`, and the model reads `ok`, not `data.success`, so
            // an unreachable remote looked like a completed pull. Mirrors the
            // guard `git_checkout` / `git_branch` / `git_merge` use.
            //
            // The EXIT STATUS decides, and it is consulted FIRST — the same ordering
            // `git_merge` adopted on 2026-08-08, and for the same reason, which
            // applies here with a wider blast radius. `git pull` merges internally
            // and exits non-zero on a conflict, so a pull that SUCCEEDED cannot be
            // one; but it also prints a DIFFSTAT, i.e. the name of every file the
            // fast-forward touched. Probing that text first meant a clean pull of a
            // commit adding `docs/CONFLICT.md` reported `CONFLICT` and sent the model
            // to resolve conflicts in an already-merged tree. Branch names reach the
            // same text ("Merge branch 'fix-CONFLICT-handling'"), so `git_merge`'s
            // reproducer is reachable here too.
            guard result.success else {
                if output.contains("CONFLICT") || output.contains("Merge conflict") {
                    // The only place the model learns WHICH file to fix — the envelope is
                    // an `ErrorEnvelope` (`data: nil`) and the guidance builder surfaces
                    // only `message`. `GitConflictParser` because `range(of: "in ")` parsed
                    // two of git's five conflict shapes and handed back a branch name, a
                    // SHA, or English prose for the other three.
                    let conflictFiles = GitConflictParser.conflictedPaths(in: output)

                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .conflict,
                        message: GitConflictParser.conflictMessage(paths: conflictFiles),
                        details: ["conflicts": conflictFiles.joined(separator: ", ")]
                    )
                }
                if let classified = GitErrorClassifier.classify(
                    stderr: result.stderr, toolName: Self.name, args: args,
                    subject: "Remote '\(remote)'"
                ) {
                    return classified
                }
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed,
                    message: result.stderr.isEmpty ? output : result.stderr
                )
            }

            // Exit 0 is NOT proof of a merged tree. With `merge.autoStash` /
            // `rebase.autoStash` set, git completes the merge, then conflicts applying the
            // stash, and exits **0** anyway — measured: `Applying autostash resulted in
            // conflicts.`, exit 0, `UU f.txt`, conflict markers written to disk. Reporting
            // `ok: true, conflicts: []` there sends the model to build or edit a file full
            // of markers, and the compiler errors that follow have no explanation in the
            // tool log. The index is the authoritative answer and costs one cheap call;
            // a text probe is not, which is the whole reason the exit status is consulted
            // first above.
            let unmerged = (try? ProcessRunner.runRoleGit(["ls-files", "-u"], in: workFolderRoot))
                .map { GitConflictParser.unmergedPaths(inLsFilesOutput: $0.stdout) } ?? []
            if !unmerged.isEmpty {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .conflict,
                    message: GitConflictParser.conflictMessage(paths: unmerged),
                    details: ["conflicts": unmerged.joined(separator: ", ")]
                )
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: PullData(success: result.success, conflicts: [], output: output)
            )
        }
    }
}

// MARK: - git_stash

nonisolated struct GitStashTool: ToolHandler {
    static let name = TN.gitStash
    static let schema = ToolSchema(
        name: TN.gitStash,
        description: "Stash changes.",
        parameters: JS.object(
            properties: [
                "action": JS.string(
                    "Stash operation to perform.",
                    enumValues: StashAction.allCases.map(\.rawValue)),
                "message": JS.string(),
                "index": JS.integer("0-based index into the stash list."),
                "include_untracked": JS.boolean(),
            ],
            required: ["action"]
        )
    )
    static let category: ToolCategory = .gitWrite
    static let blockedInDefaultStorage = true

    /// The verbs, in the order the schema advertises them — one source for the `enum:` the
    /// model reads, the `requiredEnum` guard and the exhaustive dispatch below.
    enum StashAction: String, CaseIterable {
        case push, pop, apply, list, drop
    }

    let workFolderRoot: URL
    let resolver: SandboxPathResolver

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot, resolver: dependencies.resolver)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // A work folder that IS a credential store (`~/.ssh`, `~/.claude` opened as a
            // project) is no more git's to touch than the file tools' — asked by every git tool,
            // not only by the five that take paths (#382).
            if resolver.hidesRoot { throw SandboxPathError.protectedWorkFolder }
            let action = try requiredEnum(args, "action", as: StashAction.self)
            let message = optionalString(args, "message")
            let index = optionalInt(args, "index")
            let includeUntracked = optionalBool(args, "include_untracked", default: false)

            // Each arm rejects the arguments it does not read (R3.5.2): `message` and
            // `include_untracked` belong to `push`, `index` to the three stash-addressing
            // verbs. Until 2026-09-06 they were silently dropped — `pop` with a `message`
            // reported ok:true for a call that did something other than what it asked.
            let stashIndexVerbs: [StashAction] = [.pop, .apply, .drop]
            if action != .push {
                if let rejected = rejectInapplicable(
                    "message", supplied: message != nil, appliesTo: ["push"],
                    toolName: Self.name, args: args) { return rejected }
                if let rejected = rejectInapplicable(
                    "include_untracked", supplied: args["include_untracked"] != nil, appliesTo: ["push"],
                    toolName: Self.name, args: args) { return rejected }
            }
            if !stashIndexVerbs.contains(action),
               let rejected = rejectInapplicable(
                   "index", supplied: index != nil, appliesTo: stashIndexVerbs.map(\.rawValue),
                   toolName: Self.name, args: args) { return rejected }

            var gitArgs = ["stash"]

            switch action {
            case .push:
                gitArgs.append("push")
                if includeUntracked {
                    gitArgs.append("-u")
                }
                if let message = message {
                    gitArgs.append("-m")
                    gitArgs.append(message)
                }
                // Scoped, like every other git tool: an unscoped `stash push` reaches the whole
                // repository, so it would revert a hidden file NanoTeams itself maintains —
                // an agent token file inside a versioned client folder (#376).
                gitArgs.append("--")
                gitArgs.append(contentsOf: try resolver.gitPathspecs(forPaths: nil))

            case .pop:
                gitArgs.append("pop")
                if let index = index {
                    gitArgs.append("stash@{\(index)}")
                }

            case .apply:
                gitArgs.append("apply")
                if let index = index {
                    gitArgs.append("stash@{\(index)}")
                }

            case .list:
                gitArgs.append("list")

            case .drop:
                gitArgs.append("drop")
                if let index = index {
                    gitArgs.append("stash@{\(index)}")
                }
            }

            let result = try ProcessRunner.runRoleGit(gitArgs, in: workFolderRoot)

            guard result.success else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed, message: result.stderr
                )
            }

            struct StashData: Codable {
                var action: String
                var output: String
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: StashData(action: action.rawValue, output: result.stdout)
            )
        }
    }
}
