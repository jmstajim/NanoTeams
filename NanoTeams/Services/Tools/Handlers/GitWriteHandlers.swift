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
                "paths": JS.array(items: JS.string("Path to add")),
            ],
            required: ["paths"]
        )
    )
    static let category: ToolCategory = .gitWrite
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL
    let resolver: SandboxPathResolver

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot, resolver: dependencies.resolver)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // I4: surface every accepted alias so a model that emits an
            // unrecognized argument shape ({"foos": [...]}) sees the full set of
            // acceptable keys instead of just `paths`. The single-valued aliases
            // ride the same resolver — a bare string coerces to a one-element list.
            let paths = try requiredStringArray(
                args,
                aliases: ["paths", "files", "path", "file"],
                display: "paths (or files / path / file)"
            )

            // `{"paths": []}` reaches here intact (coerceStringArray keeps an explicitly
            // empty list), and a bare `git add` exits 0 — so the model asked to stage
            // files, staged none, and read ok:true. Same success-envelope-for-a-no-op
            // shape as the git_pull regression fixed 2026-08-07.
            guard !paths.isEmpty else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "paths is empty — name at least one file, or \".\" to stage everything."
                )
            }

            // Tolerate absolute + redundant-work-folder-name path forms (globs/pathspec
            // magic pass through untouched) so git_add behaves like the file tools.
            let normalizedPaths = paths.map { resolver.relativizePathspec($0) }
            var gitArgs = ["add"]
            gitArgs.append(contentsOf: normalizedPaths)

            let result = try ProcessRunner.runGit(gitArgs, in: workFolderRoot)

            guard result.success else {
                if GitErrorClassifier.isNotARepository(stderr: result.stderr) {
                    return GitErrorClassifier.notARepositoryError(toolName: Self.name, args: args)
                }
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed,
                    message: result.stderr.isEmpty ? "git add failed" : result.stderr
                )
            }

            struct AddData: Codable {
                var staged: [String]
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: AddData(staged: normalizedPaths)
            )
        }
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
                "message": JS.string("Commit message"),
                "amend": JS.boolean("Amend last commit"),
            ],
            required: ["message"]
        )
    )
    static let category: ToolCategory = .gitWrite
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let message = try requiredString(args, "message")
            let amend = optionalBool(args, "amend", default: false)

            var gitArgs = ["commit", "-m", message]
            if amend {
                gitArgs.append("--amend")
            }

            let result = try ProcessRunner.runGit(gitArgs, in: workFolderRoot)

            guard result.success else {
                let errorMsg = result.stderr + result.stdout
                if GitErrorClassifier.isNotARepository(stderr: errorMsg) {
                    return GitErrorClassifier.notARepositoryError(toolName: Self.name, args: args)
                }
                // Git spells the same situation two ways: "nothing to commit" normally,
                // and "nothing added to commit but untracked files present" when the tree
                // holds only untracked files. Matching one left the other as COMMAND_FAILED
                // — two error codes for one failure class, which `buildToolErrorGuidance`
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
                            : "Nothing to commit — the working tree is clean."
                    )
                }
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed, message: errorMsg
                )
            }

            let hashResult = try ProcessRunner.runGit(["rev-parse", "HEAD"], in: workFolderRoot)
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
                "remote": JS.string("Remote name"),
                "branch": JS.string("Branch name"),
                "rebase": JS.boolean("Rebase instead of merge"),
            ]
        )
    )
    static let category: ToolCategory = .gitWrite
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let remote = optionalString(args, "remote") ?? "origin"
            let branch = optionalString(args, "branch")
            let rebase = optionalBool(args, "rebase", default: false)

            var gitArgs = ["pull"]
            if rebase {
                gitArgs.append("--rebase")
            }
            gitArgs.append(remote)
            if let branch = branch {
                gitArgs.append(branch)
            }

            let result = try ProcessRunner.runGit(gitArgs, in: workFolderRoot)

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
                        message: "Merge conflicts detected",
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
            let unmerged = (try? ProcessRunner.runGit(["ls-files", "-u"], in: workFolderRoot))
                .map { GitConflictParser.unmergedPaths(inLsFilesOutput: $0.stdout) } ?? []
            if !unmerged.isEmpty {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .conflict,
                    message: "Merge conflicts detected",
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
                    enumValues: ["push", "pop", "apply", "list", "drop"]),
                "message": JS.string("Stash message"),
                "index": JS.integer("Stash index"),
                "include_untracked": JS.boolean("Include untracked files"),
            ],
            required: ["action"]
        )
    )
    static let category: ToolCategory = .gitWrite
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let action = try requiredString(args, "action")
            let message = optionalString(args, "message")
            let index = optionalInt(args, "index")
            let includeUntracked = optionalBool(args, "include_untracked", default: false)

            var gitArgs = ["stash"]

            switch action {
            case "push":
                gitArgs.append("push")
                if includeUntracked {
                    gitArgs.append("-u")
                }
                if let message = message {
                    gitArgs.append("-m")
                    gitArgs.append(message)
                }

            case "pop":
                gitArgs.append("pop")
                if let index = index {
                    gitArgs.append("stash@{\(index)}")
                }

            case "apply":
                gitArgs.append("apply")
                if let index = index {
                    gitArgs.append("stash@{\(index)}")
                }

            case "list":
                gitArgs.append("list")

            case "drop":
                gitArgs.append("drop")
                if let index = index {
                    gitArgs.append("stash@{\(index)}")
                }

            default:
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "Invalid action: \(action). Use: push, pop, apply, list, drop"
                )
            }

            let result = try ProcessRunner.runGit(gitArgs, in: workFolderRoot)

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
                data: StashData(action: action, output: result.stdout)
            )
        }
    }
}
