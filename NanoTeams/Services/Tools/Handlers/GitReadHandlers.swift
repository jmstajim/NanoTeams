import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - git_status

struct GitStatusTool: ToolHandler {
    static let name = TN.gitStatus
    static let schema = ToolSchema(
        name: TN.gitStatus,
        description: "Get git status.",
        parameters: JS.object(properties: [:])
    )
    static let category: ToolCategory = .gitRead
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot)
    }

    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let result = try ProcessRunner.runGit(["status", "--porcelain=v1", "-b"], in: workFolderRoot)

            guard result.success else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed,
                    message: result.stderr.isEmpty ? "git status failed" : result.stderr
                )
            }

            let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            var branch = "HEAD"
            var files: [GitPathStatus] = []

            for line in lines {
                let str = String(line)
                if str.hasPrefix("##") {
                    let branchPart = str.dropFirst(3)
                    if let dotRange = branchPart.range(of: "...") {
                        branch = String(branchPart[..<dotRange.lowerBound])
                    } else {
                        branch = String(branchPart).trimmingCharacters(in: .whitespaces)
                    }
                } else if str.count >= 3 {
                    let indexStatus = String(str.prefix(1))
                    let worktreeStatus = String(str.dropFirst(1).prefix(1))
                    let path = String(str.dropFirst(3))

                    var status = ""
                    if indexStatus != " " && indexStatus != "?" {
                        status += indexStatus
                    }
                    if worktreeStatus != " " {
                        status += worktreeStatus
                    }
                    if indexStatus == "?" {
                        status = "?"
                    }

                    if !path.isEmpty {
                        files.append(GitPathStatus(path: path, status: status))
                    }
                }
            }

            struct StatusData: Codable {
                var branch: String
                var files: [GitPathStatus]
                var clean: Bool
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: StatusData(branch: branch, files: files, clean: files.isEmpty)
            )
        }
    }
}

// MARK: - git_branch_list

struct GitBranchListTool: ToolHandler {
    static let name = TN.gitBranchList
    static let schema = ToolSchema(
        name: TN.gitBranchList,
        description: "List git branches.",
        parameters: JS.object(
            properties: [
                "all": JS.boolean("List all branches including remote")
            ]
        )
    )
    static let category: ToolCategory = .gitRead
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot)
    }

    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let all = optionalBool(args, "all", default: false)

            var gitArgs = ["branch", "-v"]
            if all {
                gitArgs.append("-a")
            }

            let result = try ProcessRunner.runGit(gitArgs, in: workFolderRoot)

            guard result.success else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed, message: result.stderr
                )
            }

            var branches: [BranchInfo] = []
            var currentBranch = ""

            for line in result.stdout.split(separator: "\n") {
                let str = String(line)
                let isCurrent = str.hasPrefix("*")
                var branchLine = isCurrent ? String(str.dropFirst(2)) : String(str.dropFirst(2))
                branchLine = branchLine.trimmingCharacters(in: .whitespaces)

                let parts = branchLine.split(separator: " ", maxSplits: 1)
                guard let name = parts.first else { continue }

                let branchName = String(name)
                let isRemote = branchName.hasPrefix("remotes/")

                let displayName = isRemote ? String(branchName.dropFirst(8)) : branchName

                if isCurrent {
                    currentBranch = displayName
                }

                branches.append(
                    BranchInfo(
                        name: displayName,
                        current: isCurrent,
                        upstream: nil,
                        is_remote: isRemote
                    ))
            }

            struct BranchListData: Codable {
                var branches: [BranchInfo]
                var current: String
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: BranchListData(branches: branches, current: currentBranch)
            )
        }
    }
}

// MARK: - git_log

struct GitLogTool: ToolHandler {
    static let name = TN.gitLog
    static let schema = ToolSchema(
        name: TN.gitLog,
        description: "Show git log.",
        parameters: JS.object(
            properties: [
                "max": JS.integer("Max commits to show"),
                "oneline": JS.boolean("Oneline format"),
                "paths": JS.array(items: JS.string("Filter by paths")),
            ]
        )
    )
    static let category: ToolCategory = .gitRead
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot)
    }

    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let maxCount = optionalInt(args, "max") ?? 20
            let oneline = optionalBool(args, "oneline", default: true)
            let paths = optionalStringArray(args, "paths")

            var gitArgs = ["log", "-\(maxCount)"]

            if oneline {
                gitArgs.append("--oneline")
            } else {
                gitArgs.append("--format=%H|%s|%an|%ai")
            }

            if let paths = paths, !paths.isEmpty {
                gitArgs.append("--")
                gitArgs.append(contentsOf: paths)
            }

            let result = try ProcessRunner.runGit(gitArgs, in: workFolderRoot)

            guard result.success else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed, message: result.stderr
                )
            }

            var commits: [Commit] = []

            for line in result.stdout.split(separator: "\n") {
                let str = String(line)
                if oneline {
                    let parts = str.split(separator: " ", maxSplits: 1)
                    if parts.count >= 1 {
                        let hash = String(parts[0])
                        let message = parts.count > 1 ? String(parts[1]) : ""
                        commits.append(
                            Commit(hash: hash, message: message, author: nil, date: nil))
                    }
                } else {
                    let parts = str.split(separator: "|", maxSplits: 3)
                    if parts.count >= 2 {
                        commits.append(
                            Commit(
                                hash: String(parts[0]),
                                message: String(parts[1]),
                                author: parts.count > 2 ? String(parts[2]) : nil,
                                date: parts.count > 3 ? String(parts[3]) : nil
                            ))
                    }
                }
            }

            struct LogData: Codable {
                var commits: [Commit]
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: LogData(commits: commits)
            )
        }
    }
}

// MARK: - git_diff

struct GitDiffTool: ToolHandler {
    static let name = TN.gitDiff
    static let schema = ToolSchema(
        name: TN.gitDiff,
        description: "Show git diff.",
        parameters: JS.object(
            properties: [
                "cached": JS.boolean("Show staged changes"),
                "paths": JS.array(items: JS.string("Filter by paths")),
                "max_lines": JS.integer("Max lines of diff"),
            ]
        )
    )
    static let category: ToolCategory = .gitRead
    static let blockedInDefaultStorage = true
    /// Working-tree mutations between reads make diff results stale — do not cache.
    static let isCacheable = false

    let workFolderRoot: URL

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot)
    }

    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let cached = optionalBool(args, "cached", default: false)
            let paths = optionalStringArray(args, "paths")
            let maxLines = optionalInt(args, "max_lines") ?? 400

            var gitArgs = ["diff"]
            if cached {
                gitArgs.append("--cached")
            }

            if let paths = paths, !paths.isEmpty {
                gitArgs.append("--")
                gitArgs.append(contentsOf: paths)
            }

            let result = try ProcessRunner.runGit(gitArgs, in: workFolderRoot)

            guard result.success else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .commandFailed, message: result.stderr
                )
            }

            let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            let truncated = lines.count > maxLines
            let outputLines = truncated ? Array(lines.prefix(maxLines)) : lines
            let diff = outputLines.joined(separator: "\n")

            let filesChanged = lines.filter { $0.hasPrefix("diff --git") }.count

            struct DiffData: Codable {
                var diff: String
                var files_changed: Int
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: DiffData(diff: diff, files_changed: filesChanged),
                meta: ToolResultMeta(truncated: truncated)
            )
        }
    }
}
