import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - run_xcodebuild

nonisolated struct RunXcodebuildTool: ToolHandler {
    static let name = TN.runXcodebuild
    static let schema = ToolSchema(
        name: TN.runXcodebuild,
        description: "Build the Xcode project.",
        parameters: JS.object(properties: [:])
    )
    static let category: ToolCategory = .xcode
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL
    /// No default: see `XcodebuildRunning` for why an inert one cannot exist.
    let runner: any XcodebuildRunning

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot, runner: SystemXcodebuildRunner())
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            switch try XcodeBuildRunner.sweep(
                workFolderRoot: workFolderRoot,
                toolName: Self.name, args: args,
                action: "build",
                timeout: XcodeBuildRunner.buildTimeout,
                runner: runner
            ) {
            case .error(let errorResult):
                return errorResult

            case .swept(let sweep):
                let (data, truncated) = XcodeBuildRunner.aggregateBuild(
                    runs: sweep.runs, workFolderRoot: workFolderRoot,
                    duration: sweep.duration, maxLines: XcodeBuildRunner.defaultMaxLogLines
                )
                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: data,
                    meta: ToolResultMeta(truncated: truncated)
                )
            }
        }
    }
}

// MARK: - run_xcodetests

nonisolated struct RunXcodetestsTool: ToolHandler {
    static let name = TN.runXcodetests
    static let schema = ToolSchema(
        name: TN.runXcodetests,
        description: "Run the Xcode test suite.",
        parameters: JS.object(properties: [:])
    )
    static let category: ToolCategory = .xcode
    static let blockedInDefaultStorage = true

    let workFolderRoot: URL
    /// No default: see `XcodebuildRunning` for why an inert one cannot exist.
    let runner: any XcodebuildRunning

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(workFolderRoot: dependencies.workFolderRoot, runner: SystemXcodebuildRunner())
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            switch try XcodeBuildRunner.sweep(
                workFolderRoot: workFolderRoot,
                toolName: Self.name, args: args,
                action: "test",
                timeout: XcodeBuildRunner.testTimeout,
                runner: runner
            ) {
            case .error(let errorResult):
                return errorResult

            case .swept(let sweep):
                let (data, truncated) = XcodeBuildRunner.aggregateTests(
                    runs: sweep.runs, workFolderRoot: workFolderRoot,
                    duration: sweep.duration, maxLines: XcodeBuildRunner.defaultMaxLogLines
                )
                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: data,
                    meta: ToolResultMeta(truncated: truncated)
                )
            }
        }
    }
}
