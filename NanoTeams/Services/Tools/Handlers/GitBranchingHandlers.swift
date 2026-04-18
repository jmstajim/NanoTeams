import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - Git Error Classifier (shared helper)

enum GitErrorClassifier {
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

    /// True when stderr indicates the working folder isn't a git repo. Anchored
    /// on git's canonical prefix `fatal: not a git repository` to avoid
    /// false-positives if a user commit message happens to contain the phrase
    /// — `git_commit` passes stdout through the classifier too.
    static func isNotARepository(stderr: String) -> Bool {
        stderr.contains("fatal: not a git repository")
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

struct GitCheckoutTool: ToolHandler {
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

            let currentResult = try ProcessRunner.runGit(["branch", "--show-current"], in: workFolderRoot)
            let previousBranch = currentResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            var gitArgs = ["checkout"]
            if create {
                gitArgs.append("-b")
            }
            gitArgs.append(branch)
            if let from = from, create {
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

struct GitMergeTool: ToolHandler {
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

            let output = result.stdout + result.stderr
            let hasConflicts = output.contains("CONFLICT") || output.contains("Merge conflict")

            if hasConflicts {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .conflict, message: "Merge conflicts detected"
                )
            }

            struct MergeData: Codable {
                var success: Bool
                var merged_branch: String
                var conflicts: [String]
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: MergeData(success: result.success, merged_branch: branch, conflicts: [])
            )
        }
    }
}

// MARK: - git_branch

struct GitBranchTool: ToolHandler {
    static let name = TN.gitBranch
    static let schema = ToolSchema(
        name: TN.gitBranch,
        description: "Manage branches.",
        parameters: JS.object(
            properties: [
                "action": JS.string(
                    "Action: create, delete, rename",
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

            switch action {
            case "create":
                gitArgs.append(name)
                if let from = from {
                    gitArgs.append(from)
                }

            case "delete":
                gitArgs.append(force ? "-D" : "-d")
                gitArgs.append(name)

            case "rename":
                guard let newName = newName else {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .invalidArgs, message: "new_name is required for rename action"
                    )
                }
                gitArgs.append("-m")
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
}
