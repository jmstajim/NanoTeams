import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - Git Error Classifier (shared helper)

nonisolated enum GitErrorClassifier {
    static func classify(
        stderr: String, toolName: String, args: [String: Any], subject: String
    ) -> ToolExecutionResult? {
        if isNotARepository(stderr: stderr) {
            return notARepositoryError(toolName: toolName, args: args)
        }
        if stderr.contains("already exists") {
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .conflict, message: "\(subject) already exists"
            )
        }
        if stderr.contains("not found") || stderr.contains("did not match") {
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .fileNotFound, message: "\(subject) not found"
            )
        }
        if stderr.contains("CONFLICT") || stderr.contains("Merge conflict") {
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .conflict, message: "Merge conflicts detected"
            )
        }
        return nil
    }

    /// True when stderr indicates the working folder isn't a git repo.
    ///
    /// **git has TWO spellings for this, and `git diff` uses the second one.** Every other
    /// command says `fatal: not a git repository (or any of the parent directories): .git`;
    /// `diff` says `warning: Not a git repository. Use --no-index to compare two paths
    /// outside a working tree` — different severity word, different capitalisation, exit 128
    /// all the same. Matching only the first spelling made `git_diff` the one read tool that
    /// did NOT hand the model the skip-git guidance in a non-git folder: it fell through to
    /// the generic arm and returned git's own advice to pass `--no-index`, an argument the
    /// tool does not have. That reads to a model as a fixable argument error, so it retries —
    /// exactly the loop `notARepositoryError` was written to end (run EA190834).
    ///
    /// Still anchored on a git DIAGNOSTIC PREFIX rather than the bare phrase, because
    /// `git_commit` passes stdout through this classifier too and a commit message could
    /// otherwise mention "not a git repository" and be misread as one.
    static func isNotARepository(stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("fatal: not a git repository")
            || lower.contains("warning: not a git repository")
    }

    /// Helpful error envelope for non-git folders. Tells the model to skip git operations
    /// and continue with the actual work.
    static func notARepositoryError(toolName: String, args: [String: Any]) -> ToolExecutionResult {
        makeErrorResult(
            toolName: toolName, args: args,
            code: .commandFailed,
            message: "This work folder is not a git repository. Skip all git_* tools for this run — this folder isn't under version control. Continue with file edits, builds, and tests; submit your deliverables when done."
        )
    }
}

// MARK: - git_checkout

nonisolated struct GitCheckoutTool: ToolHandler {
    static let name = TN.gitCheckout
    static let schema = ToolSchema(
        name: TN.gitCheckout,
        description: "Checkout a branch or commit.",
        parameters: JS.object(
            properties: [
                "branch": JS.string("Branch or commit to checkout"),
                "create": JS.boolean("Create new branch"),
                "from": JS.string("Start point for new branch"),
            ],
            required: ["branch"]
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
            let branch = try requiredString(args, "branch")
            let create = optionalBool(args, "create", default: false)
            let from = optionalString(args, "from")

            // `from` is a START POINT, which only exists for a branch being created —
            // `git checkout <branch> <start>` means nothing. It used to be dropped SILENTLY,
            // so `git_checkout(branch: "main", from: "v1.0")` reported success while checking
            // out plain `main`: the model asked to land on a specific commit, was told it had,
            // and every later read described a tree it never selected. An argument accepted and
            // ignored is the mirror of advertise-then-reject — say so instead.
            if from != nil, !create {
                return makeErrorResult(
                    toolName: Self.name, args: args, code: .invalidArgs,
                    message: "`from` is a start point for a NEW branch and applies only with "
                        + "`create: true`. To move onto an existing commit or branch, pass it as "
                        + "`branch` instead."
                )
            }

            let currentResult = try ProcessRunner.runGit(["branch", "--show-current"], in: workFolderRoot)
            let previousBranch = currentResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            var gitArgs = ["checkout"]
            if create {
                gitArgs.append("-b")
            }
            gitArgs.append(branch)
            if let from {
                gitArgs.append(from)
            }

            let result = try ProcessRunner.runGit(gitArgs, in: workFolderRoot)

            guard result.success else {
                if let classified = GitErrorClassifier.classify(
                    stderr: result.stderr, toolName: Self.name, args: args,
                    subject: "Branch '\(branch)'"
                ) {
                    return classified
                }
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed, message: result.stderr
                )
            }

            struct CheckoutData: Codable {
                var branch: String
                var previous: String
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: CheckoutData(branch: branch, previous: previousBranch)
            )
        }
    }
}

// MARK: - git_merge

nonisolated struct GitMergeTool: ToolHandler {
    static let name = TN.gitMerge
    static let schema = ToolSchema(
        name: TN.gitMerge,
        description: "Merge a branch.",
        parameters: JS.object(
            properties: [
                "branch": JS.string("Branch to merge"),
                "no_ff": JS.boolean("No fast-forward"),
                "squash": JS.boolean("Squash merge"),
            ],
            required: ["branch"]
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
            let branch = try requiredString(args, "branch")
            let noFf = optionalBool(args, "no_ff", default: false)
            let squash = optionalBool(args, "squash", default: false)

            var gitArgs = ["merge"]
            if noFf {
                gitArgs.append("--no-ff")
            }
            if squash {
                gitArgs.append("--squash")
            }
            gitArgs.append(branch)

            let result = try ProcessRunner.runGit(gitArgs, in: workFolderRoot)

            // The EXIT STATUS decides, and it is consulted first. `git merge` exits non-zero on
            // a conflict, so a merge that SUCCEEDED cannot be one no matter what its output
            // happened to contain — and its output contains whatever the branch is called.
            // Probing the text first meant merging a branch named e.g. `fix-CONFLICT-handling`
            // could report `CONFLICT` for a merge that landed cleanly, leaving the model to
            // "resolve" conflicts that do not exist. Only once git has said it failed is the
            // text worth reading, and then only to tell a conflict from every other failure.
            //
            // Same reasoning as `GitErrorClassifier.isNotARepository`, which is deliberately
            // anchored so a path containing its marker text can't trigger it.
            guard result.success else {
                let output = result.stdout + result.stderr
                if output.contains("CONFLICT") || output.contains("Merge conflict") {
                    // Name the files, like `git_pull` does. Without `details.conflicts`
                    // this arm told the model "Merge conflicts detected" and nothing
                    // else — the error envelope carries no `data`, and the guidance
                    // builder's default arm reads only `message`, so a merge conflict
                    // arrived with no way to find out where it was.
                    let conflictFiles = GitConflictParser.conflictedPaths(in: output)
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .conflict, message: "Merge conflicts detected",
                        details: conflictFiles.isEmpty
                            ? [:] : ["conflicts": conflictFiles.joined(separator: ", ")]
                    )
                }
                // Every OTHER git failure — an unknown branch, a detached HEAD, an
                // unborn ref — used to fall through to the success envelope below
                // carrying `success: false`. The model's signal is `ok`, so
                // `{"ok":true,"data":{"success":false}}` reads as "the merge worked".
                // Same guard the siblings in this file (`git_checkout`, `git_branch`)
                // have always had; `git_merge` was the one that skipped it.
                if let classified = GitErrorClassifier.classify(
                    stderr: result.stderr, toolName: Self.name, args: args,
                    subject: "Branch '\(branch)'"
                ) {
                    return classified
                }
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed,
                    message: result.stderr.isEmpty ? output : result.stderr
                )
            }

            struct MergeData: Codable {
                var success: Bool
                var merged_branch: String
                var conflicts: [String]
            }

            // Exit 0 is not proof of a merged tree — `merge.autoStash` completes the merge,
            // conflicts applying the stash, and still exits 0 (measured on `git_pull`, which
            // merges the same way). The index is authoritative; a text probe is not.
            let unmerged = (try? ProcessRunner.runGit(["ls-files", "-u"], in: workFolderRoot))
                .map { GitConflictParser.unmergedPaths(inLsFilesOutput: $0.stdout) } ?? []
            if !unmerged.isEmpty {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .conflict, message: "Merge conflicts detected",
                    details: ["conflicts": unmerged.joined(separator: ", ")]
                )
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: MergeData(success: result.success, merged_branch: branch, conflicts: [])
            )
        }
    }
}

// MARK: - git_branch

nonisolated struct GitBranchTool: ToolHandler {
    static let name = TN.gitBranch
    static let schema = ToolSchema(
        name: TN.gitBranch,
        description: "Manage branches.",
        parameters: JS.object(
            properties: [
                "action": JS.string(
                    "Branch operation to perform.",
                    enumValues: ["create", "delete", "rename"]),
                "name": JS.string("Branch name"),
                "from": JS.string("Start point"),
                "new_name": JS.string("New name for rename"),
                "force": JS.boolean("Force action"),
            ],
            required: ["action", "name"]
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
            let name = try requiredString(args, "name")
            let from = optionalString(args, "from")
            let newName = optionalString(args, "new_name")
            let force = optionalBool(args, "force", default: false)

            var gitArgs = ["branch"]

            // Three verbs share one argument set, and until 2026-08-10 only ONE of the
            // four arguments was honoured by every verb it reaches.
            //
            // `force` is meaningful for all three — measured against git: `git branch feat`
            // over an existing branch is `fatal: a branch named 'feat' already exists`
            // (exit 128) while `--force` succeeds, and `-m old feat` fails identically
            // while `-M` succeeds. Only `delete` consulted it. So git handed the model the
            // exact remedy in its own error text, the model set `force: true`, and the
            // argument was dropped — producing a byte-identical failure on every retry,
            // with the loop detector's "change your arguments" advice pointing at an
            // argument that had already been changed.
            //
            // `from` and `new_name` each apply to exactly one verb, and were read and
            // silently discarded by the other two. That is the defect `git_checkout`
            // above already refuses to ship, in the same file, in the same words: an
            // argument accepted and ignored is the mirror of advertise-then-reject.
            // Rejections live inside each arm so the invalid-action guard below still
            // wins for a verb that is not a verb at all.
            switch action {
            case "create":
                if let rejection = rejectInapplicable("new_name", newName, appliesTo: "rename", args: args) {
                    return rejection
                }
                if force {
                    gitArgs.append("--force")
                }
                gitArgs.append(name)
                if let from = from {
                    gitArgs.append(from)
                }

            case "delete":
                if let rejection = rejectInapplicable("from", from, appliesTo: "create", args: args) {
                    return rejection
                }
                if let rejection = rejectInapplicable("new_name", newName, appliesTo: "rename", args: args) {
                    return rejection
                }
                gitArgs.append(force ? "-D" : "-d")
                gitArgs.append(name)

            case "rename":
                if let rejection = rejectInapplicable("from", from, appliesTo: "create", args: args) {
                    return rejection
                }
                guard let newName = newName else {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .invalidArgs, message: "new_name is required for rename action"
                    )
                }
                gitArgs.append(force ? "-M" : "-m")
                gitArgs.append(name)
                gitArgs.append(newName)

            default:
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "Invalid action: \(action). Use: create, delete, rename"
                )
            }

            let result = try ProcessRunner.runGit(gitArgs, in: workFolderRoot)

            guard result.success else {
                if let classified = GitErrorClassifier.classify(
                    stderr: result.stderr, toolName: Self.name, args: args,
                    subject: "Branch '\(name)'"
                ) {
                    return classified
                }
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed, message: result.stderr
                )
            }

            struct BranchData: Codable {
                var action: String
                var name: String
                var new_name: String?
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: BranchData(action: action, name: name, new_name: newName)
            )
        }
    }

    /// `nil` when the argument was not supplied; an `invalidArgs` envelope naming the one
    /// action it belongs to otherwise. Says which verb to use rather than only which one
    /// not to, so the correction is a single edit — the shape `git_checkout`'s own
    /// `from`-rejection settled on.
    private func rejectInapplicable(
        _ argument: String, _ value: String?, appliesTo action: String, args: [String: Any]
    ) -> ToolExecutionResult? {
        guard value != nil else { return nil }
        return makeErrorResult(
            toolName: Self.name, args: args, code: .invalidArgs,
            message: "`\(argument)` applies only with `action: \"\(action)\"`. "
                + "It was ignored here, so this call would not have done what it asked for."
        )
    }
}
