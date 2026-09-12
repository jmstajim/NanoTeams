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

    /// The gate is taken HERE, around the whole sweep, rather than inside `XcodeBuildRunner`:
    /// `sweep` and `XcodebuildRunning.run` are synchronous by signature, so this `async`
    /// closure is the innermost frame that can suspend. Scheme discovery is inside the
    /// critical section on purpose — `xcodebuild -list` touches the same project state.
    func handle(context: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // A `Result`, not a throw: the queue duration must reach the envelope of a
            // cancelled wait or a failed build too, and `ToolErrorHandler.envelope` is the
            // same ladder `execute` would have applied to a throw.
            let (gated, queued) = await XcodeBuildGate.withExclusiveAccess(
                key: context.stepKey
            ) {
                try XcodeBuildRunner.sweep(
                    workFolderRoot: workFolderRoot,
                    toolName: Self.name, args: args,
                    action: "build",
                    timeout: XcodeBuildRunner.buildTimeout,
                    runner: runner
                )
            }
            let outcome: XcodeBuildRunner.SweepOutcome
            switch gated {
            case .failure(let error):
                return ToolErrorHandler.envelope(for: error, toolName: Self.name, args: args)
                    .withQueuedTime(queued)
            case .success(let swept):
                outcome = swept
            }
            switch outcome {
            case .error(let errorResult):
                return errorResult.withQueuedTime(queued)

            case .swept(let sweep):
                let (data, truncated) = XcodeBuildRunner.aggregateBuild(
                    runs: sweep.runs, workFolderRoot: workFolderRoot,
                    duration: sweep.duration, maxLines: XcodeBuildRunner.defaultMaxLogLines
                )
                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: data,
                    meta: ToolResultMeta(truncated: truncated)
                ).withQueuedTime(queued)
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

    /// Same gate as `run_xcodebuild`, and the same token: a `build` running during a
    /// `test-without-building` kills both, because DerivedData is shared.
    func handle(context: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // A `Result`, not a throw: the queue duration must reach the envelope of a
            // cancelled wait or a failed build too, and `ToolErrorHandler.envelope` is the
            // same ladder `execute` would have applied to a throw.
            let (gated, queued) = await XcodeBuildGate.withExclusiveAccess(
                key: context.stepKey
            ) {
                try XcodeBuildRunner.sweep(
                    workFolderRoot: workFolderRoot,
                    toolName: Self.name, args: args,
                    action: "test",
                    timeout: XcodeBuildRunner.testTimeout,
                    runner: runner
                )
            }
            let outcome: XcodeBuildRunner.SweepOutcome
            switch gated {
            case .failure(let error):
                return ToolErrorHandler.envelope(for: error, toolName: Self.name, args: args)
                    .withQueuedTime(queued)
            case .success(let swept):
                outcome = swept
            }
            switch outcome {
            case .error(let errorResult):
                return errorResult.withQueuedTime(queued)

            case .swept(let sweep):
                let (data, truncated) = XcodeBuildRunner.aggregateTests(
                    runs: sweep.runs, workFolderRoot: workFolderRoot,
                    duration: sweep.duration, maxLines: XcodeBuildRunner.defaultMaxLogLines
                )
                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: data,
                    meta: ToolResultMeta(truncated: truncated)
                ).withQueuedTime(queued)
            }
        }
    }
}
