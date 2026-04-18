import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - git_add

struct GitAddTool: ToolHandler {
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

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let paths: [String]
            if let p = try? requiredStringArray(args, "paths") {
                paths = p
            } else if let single = optionalString(args, "path") {
                paths = [single]
            } else {
                throw ToolArgumentError.missingRequired("paths")
            }

            var gitArgs = ["add"]
            gitArgs.append(contentsOf: paths)

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
                data: AddData(staged: paths)
            )
        }
    }
}

// MARK: - git_commit

struct GitCommitTool: ToolHandler {
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
                if errorMsg.contains("nothing to commit") {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .conflict, message: "Nothing to commit"
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

struct GitPullTool: ToolHandler {
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
            let hasConflicts = output.contains("CONFLICT") || output.contains("Merge conflict")

            struct PullData: Codable {
                var success: Bool
                var conflicts: [String]
                var output: String
            }

            if hasConflicts {
                let conflictFiles =
                    output
                    .components(separatedBy: .newlines)
                    .filter { $0.contains("CONFLICT") }
                    .compactMap { line -> String? in
                        if let range = line.range(of: "in ") {
                            return String(line[range.upperBound...]).trimmingCharacters(
                                in: .whitespaces)
                        }
                        return nil
                    }

                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .conflict,
                    message: "Merge conflicts detected",
                    details: ["conflicts": conflictFiles.joined(separator: ", ")]
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

struct GitStashTool: ToolHandler {
    static let name = TN.gitStash
    static let schema = ToolSchema(
        name: TN.gitStash,
        description: "Stash changes.",
        parameters: JS.object(
            properties: [
                "action": JS.string(
                    "Action: push, pop, apply, list, drop",
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
