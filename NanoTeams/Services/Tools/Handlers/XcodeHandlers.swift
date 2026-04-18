import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - run_xcodebuild

struct RunXcodebuildTool: ToolHandler {
    static let name = TN.runXcodebuild
    static let schema = ToolSchema(
        name: TN.runXcodebuild,
        description: "Run xcodebuild command using project settings.",
        parameters: JS.object(properties: [:])
    )
    static let category: ToolCategory = .xcode
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let xcodeRef = XcodeBuildRunner.findProject(in: workFolderRoot) else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .fileNotFound,
                    message: "No .xcodeproj, .xcworkspace, or Package.swift found in project root.",
                    next: NextHint(
                        suggested_cmd: TN.listFiles,
                        suggested_args: ["path": "."],
                        reason: "Check project structure"
                    )
                )
            }

            let schemesResult = XcodeBuildRunner.resolveSchemes(
                xcodeRef: xcodeRef, workFolderRoot: workFolderRoot,
                toolName: Self.name, args: args
            )
            let schemesToRun: [String]
            switch schemesResult {
            case .schemes(let schemes): schemesToRun = schemes
            case .error(let errorResult): return errorResult
            }

            let action = "build"
            let destination = "platform=macOS"
            let maxLogLines = 30
            let xcodebuildArgsBase = XcodeBuildRunner.buildBaseArgs(
                xcodeRef: xcodeRef, destination: destination, action: action
            )

            var allIssues: [XcodeIssue] = []
            var fullLog = ""
            var success = true
            var exitCode = 0
            var totalDuration: Double = 0
            var errorCount = 0
            var warningCount = 0

            for scheme in schemesToRun {
                var xcodebuildArgs = xcodebuildArgsBase
                XcodeBuildRunner.injectScheme(scheme, into: &xcodebuildArgs, action: action)

                fullLog += fullLog.isEmpty ? "--- Scheme: \(scheme) ---\n" : "\n\n--- Scheme: \(scheme) ---\n"

                let startTime = Date()
                let result = try ProcessRunner.runXcodebuild(xcodebuildArgs, in: workFolderRoot, timeout: 600)
                totalDuration += Date().timeIntervalSince(startTime)

                let output = result.stdout + result.stderr
                fullLog += output

                if !result.success {
                    success = false
                    exitCode = Int(result.exitCode)
                }

                let schemeIssues = XcodeBuildRunner.parseIssues(from: output, workFolderRoot: workFolderRoot)
                allIssues.append(contentsOf: schemeIssues)
                errorCount += schemeIssues.filter { $0.severity == "error" }.count
                warningCount += schemeIssues.filter { $0.severity == "warning" }.count

                if !result.success { break }
            }

            let (truncatedLog, truncated) = XcodeBuildRunner.truncateLog(fullLog, maxLines: maxLogLines)

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: XcodeBuildRunner.BuildResult(
                    success: success,
                    exit_code: exitCode,
                    duration: totalDuration,
                    error_count: errorCount,
                    warning_count: warningCount,
                    issues: allIssues,
                    log: success ? "" : String(truncatedLog.prefix(BuildConstants.maxBuildLogChars))
                ),
                meta: ToolResultMeta(truncated: truncated)
            )
        }
    }
}

// MARK: - run_xcodetests

struct RunXcodetestsTool: ToolHandler {
    static let name = TN.runXcodetests
    static let schema = ToolSchema(
        name: TN.runXcodetests,
        description: "Run tests using xcodebuild using project settings.",
        parameters: JS.object(properties: [:])
    )
    static let category: ToolCategory = .xcode
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let xcodeRef = XcodeBuildRunner.findProject(in: workFolderRoot) else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .fileNotFound,
                    message: "No .xcodeproj, .xcworkspace, or Package.swift found"
                )
            }

            let schemesResult = XcodeBuildRunner.resolveSchemes(
                xcodeRef: xcodeRef, workFolderRoot: workFolderRoot,
                toolName: Self.name, args: args
            )
            let schemesToRun: [String]
            switch schemesResult {
            case .schemes(let schemes): schemesToRun = schemes
            case .error(let errorResult): return errorResult
            }

            let action = "test"
            let destination = "platform=macOS"
            let maxLogLines = 30
            let xcodebuildArgsBase = XcodeBuildRunner.buildBaseArgs(
                xcodeRef: xcodeRef, destination: destination, action: action
            )

            var totalPassed = 0
            var totalFailed = 0
            let totalSkipped = 0
            var allFailures: [[String: String]] = []
            var fullLog = ""
            var success = true
            var exitCode = 0
            var totalDuration: Double = 0

            for scheme in schemesToRun {
                var xcodebuildArgs = xcodebuildArgsBase
                XcodeBuildRunner.injectScheme(scheme, into: &xcodebuildArgs, action: action)

                fullLog += fullLog.isEmpty ? "--- Scheme: \(scheme) ---\n" : "\n\n--- Scheme: \(scheme) ---\n"

                let startTime = Date()
                let result = try ProcessRunner.runXcodebuild(xcodebuildArgs, in: workFolderRoot, timeout: 1200)
                totalDuration += Date().timeIntervalSince(startTime)

                let output = result.stdout + result.stderr
                fullLog += output

                if !result.success {
                    success = false
                    exitCode = Int(result.exitCode)
                }

                let passedPattern = #"Test Case .+ passed"#
                let failedPattern = #"Test Case .+ failed"#

                if let passedRegex = try? NSRegularExpression(pattern: passedPattern) {
                    totalPassed += passedRegex.numberOfMatches(
                        in: output, range: NSRange(output.startIndex..., in: output))
                }
                if let failedRegex = try? NSRegularExpression(pattern: failedPattern) {
                    totalFailed += failedRegex.numberOfMatches(
                        in: output, range: NSRange(output.startIndex..., in: output))
                }

                let failurePattern = #"(.+?):(\d+):\s*error:\s*(.+)"#
                if let failureRegex = try? NSRegularExpression(pattern: failurePattern) {
                    let range = NSRange(output.startIndex..., in: output)
                    failureRegex.enumerateMatches(in: output, options: [], range: range) {
                        match, _, _ in
                        guard let match = match else { return }

                        var failure: [String: String] = [:]
                        failure["scheme"] = scheme

                        if match.range(at: 1).location != NSNotFound,
                            let fileRange = Range(match.range(at: 1), in: output)
                        {
                            var file = String(output[fileRange])
                            if file.hasPrefix(workFolderRoot.path) {
                                file = String(file.dropFirst(workFolderRoot.path.count + 1))
                            }
                            failure["file"] = file
                        }

                        if match.range(at: 2).location != NSNotFound,
                            let lineRange = Range(match.range(at: 2), in: output)
                        {
                            failure["line"] = String(output[lineRange])
                        }

                        if match.range(at: 3).location != NSNotFound,
                            let msgRange = Range(match.range(at: 3), in: output)
                        {
                            failure["message"] = String(output[msgRange])
                        }

                        if !failure.isEmpty {
                            allFailures.append(failure)
                        }
                    }
                }

                if !result.success { break }
            }

            let (truncatedLog, truncated) = XcodeBuildRunner.truncateLog(fullLog, maxLines: maxLogLines)

            let testSuccess = success && totalFailed == 0
            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: XcodeBuildRunner.TestResult(
                    success: testSuccess,
                    exit_code: exitCode,
                    passed: totalPassed,
                    failed: totalFailed,
                    skipped: totalSkipped,
                    duration: totalDuration,
                    failures: allFailures,
                    log: testSuccess ? "" : truncatedLog
                ),
                meta: ToolResultMeta(truncated: truncated)
            )
        }
    }
}
