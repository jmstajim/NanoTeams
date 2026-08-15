import Foundation

/// Extension for tool call execution: authorization, identical-write rejection, and runtime dispatch.
extension LLMExecutionService {

    /// Sandbox root used when the delegate has no work folder. Defensive only: `workFolderURL` is
    /// assigned exactly once in production (`openWorkFolder`) and is never set back to nil —
    /// `closeProject()` swaps to default storage through that same call, so it lowers the root
    /// rather than clearing it, and it cancels in-flight executions first. The one real nil window
    /// is before `bootstrapDefaultStorageIfNeeded` on launch, when no snapshot (and therefore no
    /// run) exists for a tool batch to belong to. Treat a hit here as a bug elsewhere, not a
    /// supported mode.
    ///
    /// MUST NOT be `/`: `SandboxPathResolver.isWithin` against `/` is universally true and the
    /// relativization drops a single component, so a `/` root silently turns the sandbox into the
    /// whole filesystem. This points below a non-directory, so the path can never exist — every
    /// resolve stays inside a dead root and every file operation fails not-found (fail closed).
    /// Single consumer, so it lives next to it (Information Expert).
    private static let noWorkFolderSandboxRoot = URL(
        fileURLWithPath: "/dev/null/nanoteams-no-work-folder", isDirectory: true)

    // MARK: - Tool Execution

    /// Executes resolved tool calls (with authorization and identical-write rejection) and
    /// returns results in order matching the input. Tool calls not in `allowedToolNames` are
    /// rejected with a classified unavailability envelope; a second `write_file` with identical
    /// `(path, content)` in the same step is rejected with `identical_write_loop`.
    ///
    /// The per-batch `runtime.executeAll` dispatch hops onto a detached
    /// cooperative-pool task; pre-flight (authorization / dup-write check)
    /// and post-flight (result interleave) stay on the calling actor —
    /// they only touch in-memory state.
    func executeToolCalls(
        resolvedToolCalls: [StepToolCall],
        allowedToolNames: Set<String>,
        phaseWithheldToolNames: Set<String> = [],
        isPlanningPhase: Bool = false,
        runtime: ToolRuntime,
        tracker: ToolCallTracker,
        task: NTMSTask,
        runIndex: Int,
        roleID: String
    ) async -> [ToolExecutionResult] {
        guard let delegate else { return [] }

        let expectedArtifacts = task.runs[runIndex].steps
            .first(where: { $0.id == roleID })?.expectedArtifacts ?? []
        let context = ToolExecutionContext(
            workFolderRoot: delegate.workFolderURL ?? Self.noWorkFolderSandboxRoot,
            taskID: task.id,
            runID: task.runs[runIndex].id,
            roleID: roleID,
            expectedArtifacts: expectedArtifacts,
            isPlanningPhase: isPlanningPhase
        )

        var results: [ToolExecutionResult] = []
        var toolsToExecute: [StepToolCall] = []
        var rejectedResults: [Int: ToolExecutionResult] = [:]
        // Pre-runtime rejections to mirror into BOTH per-run logs (tool_calls.jsonl +
        // network_log.json): these never reach ToolRuntime, so they'd otherwise be
        // invisible in both audits. (call, result, concise reason for `errorMessage`.)
        var rejectedToLog: [(call: StepToolCall, result: ToolExecutionResult, message: String)] = []

        for (idx, call) in resolvedToolCalls.enumerated() {
            // Normalize before authorization; call.name stays as-emitted for display / history.
            let name = ToolRegistry.resolveToolName(call.name)

            // Reject tool calls not in the role's allowed set. The "not allowed"
            // condition has multiple causes (tool truly absent from role config,
            // or filtered out at schema-time by a missing precondition like git
            // repo / vision model / xcode scheme / open work folder). Classify
            // so the LLM gets an actionable error instead of the catch-all
            // "not available for this role" — which is misleading when the
            // role IS configured with the tool but the work folder lacks the
            // precondition.
            if !allowedToolNames.contains(name) {
                // I1: `delegate.workFolderURL == nil` means no work folder open
                // at all — semantically equivalent to default storage for the
                // purpose of this classifier (file writes / git / xcode are
                // all blocked). The bare URL equality below would be false
                // for the `noWorkFolderSandboxRoot` fallback and silently
                // misroute to `gitRepoMissing`.
                let isDefault = delegate.workFolderURL == nil
                    || context.workFolderRoot == NTMSOrchestrator.defaultStorageURL
                // I2: when snapshot is nil (teardown / task-switch race) we
                // can't make claims about the user's scheme setting. Pass
                // `xcodeSchemeKnown: false` so the classifier falls through
                // to `.notInRoleConfig` instead of blaming a setting it
                // can't see.
                let snapshot = delegate.snapshot
                let scheme = snapshot?.workFolder.settings.selectedScheme
                let reason = Self.classifyUnavailability(
                    toolName: name,
                    workFolderRoot: context.workFolderRoot,
                    isDefaultStorage: isDefault,
                    isVisionConfigured: delegate.visionLLMConfig != nil,
                    selectedScheme: scheme,
                    xcodeSchemeKnown: snapshot != nil,
                    isComputerUseEnabled: delegate.computerUsePolicy.isEnabled,
                    isBashEnabled: delegate.bashPolicy.mode != .off,
                    phaseWithheldToolNames: phaseWithheldToolNames
                )
                let rejected = Self.makeUnavailableToolResult(
                    call: call, canonicalName: name, scope: "for this role", reason: reason
                )
                rejectedResults[idx] = rejected
                rejectedToLog.append((call, rejected, "tool not authorized / precondition not met"))
                continue
            }

            // Reject a second `write_file` with identical (path, content) in the same step —
            // the dominant failure mode of smaller models is rewriting the same file in a loop.
            // First call records its fingerprint atomically and proceeds; from #2 we hand back
            // an error envelope without touching disk so the model sees a hard signal in its
            // conversation. `checkAndRecordWrite` fuses the check-then-record sequence inside
            // the tracker so two identical writes in the same batch are guaranteed to trip on
            // the second pass regardless of where the call site puts the `append` below.
            if tracker.checkAndRecordWrite(toolName: call.name, argumentsJSON: call.argumentsJSON) {
                let rejected = Self.makeIdenticalWriteLoopResult(call: call)
                rejectedResults[idx] = rejected
                rejectedToLog.append((call, rejected, "identical write loop"))
                continue
            }

            toolsToExecute.append(call)
        }

        // Off-main dispatch. Captures are Sendable: `ToolRuntime`
        // (`@unchecked Sendable`), `ToolExecutionContext` (value type),
        // `[StepToolCall]` (Codable values).
        let batchTask = Task.detached(priority: .userInitiated) {
            [runtime, context, toolsToExecute, rejectedToLog] in
            // Mirror the pre-runtime rejections into both per-run logs BEFORE the
            // executed batch (which logs its own calls inside `executeOne`). All
            // rejections are grouped first, then executed calls — relative order
            // within each group is preserved, but a rejected call is NOT interleaved
            // back into the model's exact emission position. The runtime owns both
            // shared logger instances → one serial queue each, no race.
            for item in rejectedToLog {
                runtime.logNonExecutedCall(
                    taskID: context.taskID,
                    runID: context.runID,
                    roleID: context.roleID,
                    toolName: item.call.name,
                    argumentsJSON: item.call.argumentsJSON,
                    resultJSON: item.result.outputJSON,
                    errorMessage: item.message
                )
            }
            return runtime.executeAll(context: context, toolCalls: toolsToExecute)
        }
        // The handoff itself needs no guard: this method is actor-isolated, so the write below and
        // any read of it are adjacent statements with no suspension point between them. A guard
        // here used to claim it covered "state entry removed BETWEEN write and check"; that cannot
        // happen, and its predicate reduced to `hadStateAtStart && !hadStateAtStart` — dead. Worse
        // than dead: it told the next reader the orphan window was handled, so nobody checked
        // whether the PAUSE path cancels this batch. It did not (now fixed in
        // `cancelStepExecution`).
        //
        // The real window is the `await` below, and the guard AFTER it is what covers it: a new
        // step may install its own batch while we suspend, so the pointer is cleared only when it
        // still points at OUR task.
        let stepKey = TaskStepKey(taskID: task.id, stepID: roleID)
        executionStates[stepKey]?.currentToolBatchTask = batchTask
        let freshResults = await batchTask.value
        if executionStates[stepKey]?.currentToolBatchTask == batchTask {
            executionStates[stepKey]?.currentToolBatchTask = nil
        }

        var freshIdx = 0
        for (idx, _) in resolvedToolCalls.enumerated() {
            if let rejected = rejectedResults[idx] {
                results.append(rejected)
            } else {
                results.append(freshResults[freshIdx])
                freshIdx += 1
            }
        }

        return results
    }

    // MARK: - Unavailability classification

    /// Why a tool call landed outside the role's allowed set this iteration.
    /// `notInRoleConfig` is the original `tool_not_authorized` case (model
    /// hallucinated a tool the role was never configured with). The other
    /// cases distinguish work-folder preconditions that filter tools at
    /// schema-build time, so the rejection envelope can name the actual
    /// blocker instead of falsely blaming role config.
    /// `nonisolated` + `CaseIterable` so `PromptFormatConventionsTests` can sweep every
    /// rejection message. Bare, the enum would inherit the app target's `@MainActor`
    /// default isolation and its synthesized `allCases` would be unreachable from a
    /// nonisolated `XCTestCase` (same trap as `AcceptanceService.AcceptRoute`).
    nonisolated enum ToolUnavailabilityReason: CaseIterable {
        case notInRoleConfig
        case workFolderClosed       // default-storage mode, no real project folder
        case gitRepoMissing         // work folder has no `.git` directory
        case visionNotConfigured    // analyze_image without a vision LLM config
        case xcodeSchemeNotSelected // run_xcodebuild/run_xcodetests without a scheme
        case computerUseDisabled    // screen_capture/ui_* with ComputerUsePolicy.mode == .off
        case bashDisabled           // bash/bash_output with BashPolicy.mode == .off
        /// The role HAS this tool and every work-folder precondition is met —
        /// this ITERATION withheld it because the step is still in its planning
        /// phase. The only reason with a "retry later" contract: every other one
        /// tells the model to stop, which is factually wrong here, since after
        /// recording its plan the model SHOULD repeat the exact same call.
        case withheldUntilPlanRecorded
    }

    /// Maps a rejected tool name to the most-specific precondition that
    /// could have stripped it from the role's schema. Order matters:
    /// default-storage subsumes git/xcode/write tools, so it's checked
    /// first. Returns `.notInRoleConfig` only when no known precondition
    /// applies (the genuine hallucination case).
    ///
    /// `xcodeSchemeKnown` lets callers pass `false` when the snapshot they
    /// would read `selectedScheme` from is unavailable (teardown / task
    /// switch). The classifier then declines to blame a setting it can't
    /// see and falls through to `.notInRoleConfig`. Callers with a loaded
    /// snapshot pass `true`. (S4 future-proofing also iterates
    /// `ToolHandlerRegistry.visionTools` — currently just `analyze_image`.)
    static func classifyUnavailability(
        toolName: String,
        workFolderRoot: URL,
        isDefaultStorage: Bool,
        isVisionConfigured: Bool,
        selectedScheme: String?,
        xcodeSchemeKnown: Bool = true,
        isComputerUseEnabled: Bool = true,
        isBashEnabled: Bool = true,
        phaseWithheldToolNames: Set<String> = [],
        fileManager: FileManager = .default
    ) -> ToolUnavailabilityReason {
        let registry = ToolHandlerRegistry.self
        // ABOVE the phase check, and the exception proves that check's rule. Everything else in
        // `phaseWithheldToolNames` is withheld by a condition the BOUNDARY resolves, which is
        // what makes `plan_required`'s "call it again after recording your plan" true. A bash
        // mode of `.off` is not such a condition: recording a plan does not re-enable a disabled
        // tool, so the retry it invites is doomed and ends in `bash_denied` one turn later.
        // Name the durable blocker instead.
        if registry.shellTools.contains(toolName) && !isBashEnabled { return .bashDisabled }
        // Checked FIRST among the rest, and without an ordering hazard: this set is derived
        // from the already-precondition-filtered tool array, so membership
        // proves every other reason is inapplicable.
        if phaseWithheldToolNames.contains(toolName) { return .withheldUntilPlanRecorded }
        if isDefaultStorage && registry.defaultStorageBlocked.contains(toolName) {
            return .workFolderClosed
        }
        let gitTools = registry.gitReadTools.union(registry.gitWriteTools)
        if gitTools.contains(toolName)
            && !isGitRepository(at: workFolderRoot, fileManager: fileManager) {
            return .gitRepoMissing
        }
        if registry.visionTools.contains(toolName) && !isVisionConfigured {
            return .visionNotConfigured
        }
        if registry.computerUseTools.contains(toolName) && !isComputerUseEnabled {
            return .computerUseDisabled
        }
        let tn = ToolNames.self
        if (toolName == tn.runXcodebuild || toolName == tn.runXcodetests)
            && xcodeSchemeKnown
            && (selectedScheme == nil || selectedScheme?.isEmpty == true) {
            return .xcodeSchemeNotSelected
        }
        return .notInRoleConfig
    }

    /// Builds a tool-unavailable error envelope with cause-specific code and
    /// message. `notInRoleConfig` keeps the legacy `tool_not_authorized` code
    /// (regression-pinned by `RepoBrowserNamespaceRejectionTests` /
    /// `ToolErrorGuidanceTests`); precondition cases use `precondition_failed`
    /// with a message that names the missing prerequisite so the LLM stops
    /// retrying instead of looping on "use only tools listed in your prompt".
    /// The envelope shape also bifurcates: `notInRoleConfig` omits the structured
    /// `tool` field (see the body for why); precondition cases keep it.
    nonisolated static func makeUnavailableToolResult(
        call: StepToolCall,
        canonicalName: String,
        scope: String,
        reason: ToolUnavailabilityReason
    ) -> ToolExecutionResult {
        let errorCode: String
        let msg: String
        switch reason {
        case .notInRoleConfig:
            errorCode = "tool_not_authorized"
            msg = "Tool '\(call.name)' is not available \(scope). Use only tools listed in your system prompt."
        case .workFolderClosed:
            errorCode = "precondition_failed"
            msg = "Tool '\(call.name)' requires an opened work folder. The current session uses default storage — file writes, git, and xcode tools are unavailable until the user opens a project folder."
        case .gitRepoMissing:
            errorCode = "precondition_failed"
            msg = "Tool '\(call.name)' requires a git repository. The work folder has no .git directory — skip git operations or ask the supervisor whether to initialize one."
        case .visionNotConfigured:
            errorCode = "precondition_failed"
            msg = "Tool '\(call.name)' requires a configured vision model. None is configured for this work folder — ask the supervisor to configure one, or proceed without image analysis."
        case .xcodeSchemeNotSelected:
            errorCode = "precondition_failed"
            msg = "Tool '\(call.name)' requires a selected Xcode scheme. No scheme is configured for this work folder."
        case .computerUseDisabled:
            errorCode = "precondition_failed"
            msg = "Tool '\(call.name)' requires Computer Use, which is turned off for this session. Continue without screen control, or ask the supervisor to enable Computer Use."
        case .bashDisabled:
            errorCode = "precondition_failed"
            // Names the POLICY, not the Settings pane: the model cannot open one. Mirrors the
            // wording rule `BashPermissionService`'s own mode-off denial follows.
            msg = "Tool '\(call.name)' requires the bash tool, which is disabled by policy (execution mode: Off). No command can run in this session — continue without a shell, or ask the supervisor to enable it."
        case .withheldUntilPlanRecorded:
            // Distinct code so `ToolErrorNotePolicy.direction` can steer toward the
            // retry. `precondition_failed` would tell the model the blocker is
            // the work folder — false, and non-retryable.
            errorCode = "plan_required"
            msg = "Tool '\(call.name)' becomes available once your plan is recorded. Call update_scratchpad with your findings and your numbered plan, then call '\(call.name)' again."
        }
        let escapedMsg = msg.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Omit the structured `tool` field for the genuine-hallucination case:
        // the rejected name is frequently an artifact name (or other non-tool
        // string the model invented, e.g. "Engineering Notes"), and echoing it
        // back as `"tool":"X"` reinforces the wrong premise that X is a callable
        // tool. The precondition reasons keep it — there it names a real blocked
        // tool (the canonical, namespace-stripped name) that downstream tooling
        // relies on (retention pinned by `ToolUnavailabilityClassifierTests`'s
        // `testEnvelope_gitRepoMissing…` `"tool":"git_add"` assertion).
        let outputJSON: String
        if case .notInRoleConfig = reason {
            outputJSON = #"{"error":""# + errorCode + #"","message":""# + escapedMsg + #""}"#
        } else {
            outputJSON = #"{"error":""# + errorCode + #"","tool":""# + canonicalName + #"","message":""# + escapedMsg + #""}"#
        }
        return ToolExecutionResult(
            providerID: call.providerID ?? UUID().uuidString,
            toolName: call.name,
            argumentsJSON: call.argumentsJSON,
            outputJSON: outputJSON,
            isError: true
        )
    }

    /// Builds a `tool_not_authorized` error result (delegates to
    /// `makeUnavailableToolResult` with `.notInRoleConfig`). `call.name` is
    /// preserved as-emitted in the message for display; that branch omits the
    /// structured `tool` field, so `canonicalName` is not surfaced in the
    /// envelope here. `scope` disambiguates executor ("for this role") vs
    /// meeting ("in this meeting").
    /// Kept as a thin wrapper for callers that don't need to distinguish
    /// preconditions (notably `MeetingToolExecutor`, which has its own
    /// scope-bound allowedToolNames invariant). New code should prefer
    /// `makeUnavailableToolResult` so the LLM sees the actual cause.
    nonisolated static func makeToolNotAuthorizedResult(
        call: StepToolCall,
        canonicalName: String,
        scope: String
    ) -> ToolExecutionResult {
        makeUnavailableToolResult(
            call: call, canonicalName: canonicalName, scope: scope, reason: .notInRoleConfig
        )
    }

    /// Builds an `identical_write_loop` error result for a duplicate `write_file` with the same
    /// `(path, content)` already attempted in this step. The model sees this in its tool-call
    /// history; recovery guidance lives in the role prompt and the `write_file` schema, not here.
    nonisolated static func makeIdenticalWriteLoopResult(call: StepToolCall) -> ToolExecutionResult {
        let parsed = (ToolCallDataUtils.parseJSON(call.argumentsJSON)?["path"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        // `"?"` stays the STRUCTURED field's sentinel (its shape is pinned), but it must not
        // reach the MESSAGE: the model reads that as a literal path. `ToolErrorNotePolicy`
        // used to collapse it while restating this sentence, and no longer restates anything.
        let path = parsed ?? "?"
        let target = parsed.map { "'\($0)'" } ?? "the file"
        let msg = "Identical write to \(target) already executed in this step."
        return ToolExecutionResult(
            providerID: call.providerID ?? UUID().uuidString,
            toolName: call.name,
            argumentsJSON: call.argumentsJSON,
            outputJSON: #"{"error":"identical_write_loop","path":""# + path + #"","message":""# + msg + #""}"#,
            isError: true
        )
    }
}
