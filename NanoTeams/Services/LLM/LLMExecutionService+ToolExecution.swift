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

    /// A call an approval gate refused BEFORE the runtime saw it, paired with the synthetic
    /// result the gate built for it. Carried into `executeToolCalls` for one purpose: to reach
    /// the per-run logs through the same seam as every other non-executed call.
    nonisolated struct GateRefusal: Sendable {
        let call: StepToolCall
        let result: ToolExecutionResult
    }

    /// The one `errorMessage` category every gate refusal is logged under. The envelope in
    /// `resultJSON` says WHICH refusal (`BASH_DENIED`, `COMPUTER_USE_DENIED`, …); this says
    /// only that it never reached a handler — which is what `jq 'select(.errorMessage == …)'`
    /// needs to count them against the executed calls.
    nonisolated static let gateRefusedLogMessage = "approval gate refused"

    /// The refusals the iteration hands to `executeToolCalls`, in emit order. A gate result
    /// that is the unified `cancelled` envelope (a held approval abandoned by Pause / teardown)
    /// is NOT a refusal and is left out — parity with `ToolRuntime.executeAll`, which never
    /// logs a cancellation envelope either. An index with no call behind it is dropped.
    nonisolated static func gateRefusalsToLog(
        resolvedToolCalls: [StepToolCall],
        gateResults: [Int: ToolExecutionResult]
    ) -> [GateRefusal] {
        gateResults.keys.sorted().compactMap { idx in
            guard resolvedToolCalls.indices.contains(idx), let result = gateResults[idx],
                  !result.isCancellationEnvelope
            else { return nil }
            return GateRefusal(call: resolvedToolCalls[idx], result: result)
        }
    }

    /// Executes resolved tool calls (with authorization and identical-write rejection) and
    /// returns results in order matching the input. Tool calls not in `allowedToolNames` are
    /// rejected with a classified unavailability envelope; a second `write_file` with identical
    /// `(path, content)` in the same step is rejected with `identical_write_loop`.
    ///
    /// `gateRefusals` are the calls the approval gates (`gateBashCalls`, `gateComputerUseCalls`)
    /// already refused upstream. They are NOT executed and NOT returned — the iteration merges
    /// their synthetic results back by index — but they ARE mirrored into both per-run logs
    /// here, ahead of the executed batch, with `durationMS == nil`. Until 2026-09-07 they were
    /// simply dropped from `callsToExecute`, and since `ToolRuntime` is the only writer of
    /// `tool_calls.jsonl` and of the network log's `.toolCall` records, a refused `bash` was
    /// invisible to every audit reading either — the validator's pass rate was a ceiling
    /// (KNOWN_ISSUES C2). No default: a caller that has no gate must say so with `[]`.
    ///
    /// The per-batch `runtime.executeAll` dispatch hops onto a detached
    /// cooperative-pool task; pre-flight (authorization / dup-write check)
    /// and post-flight (result interleave) stay on the calling actor —
    /// they only touch in-memory state.
    func executeToolCalls(
        resolvedToolCalls: [StepToolCall],
        gateRefusals: [GateRefusal],
        allowedToolNames: Set<String>,
        phaseWithheldToolNames: Set<String> = [],
        supersededToolNames: Set<String> = [],
        /// MCP tools this step advertised that the live catalogue no longer answers for on the
        /// same terms, split by why — see `MCPResolvedTools.drift(against:)`.
        mcpDrift: MCPToolDrift = .none,
        /// MCP tools the role holds that never reached the schema, because no call of them
        /// could reach a decision in a run with nobody to approve.
        mcpWithheldToolNames: Set<String> = [],
        /// Every MCP tool the LIVE catalogue holds, granted to this role or not — so a call
        /// to someone else's tool is answered "not issued to you", not "no such tool".
        mcpKnownToolNames: Set<String> = [],
        isPlanningPhase: Bool = false,
        runtime: ToolRuntime,
        tracker: ToolCallTracker,
        task: NTMSTask,
        runIndex: Int,
        roleID: String
    ) async -> [ToolExecutionResult] {
        // Everything below — the gate refusals included — is logged only past this guard:
        // with no delegate there is no run to log into, and a refusal is not more real
        // than an executed call. Pinned by `ToolIterationGateLoggingTests`.
        guard let delegate else { return [] }

        let expectedArtifacts = task.runs[runIndex].steps
            .first(where: { $0.id == roleID })?.expectedArtifacts ?? []
        let runsBash = resolvedToolCalls.contains { ToolRegistry.resolveToolName($0.name) == ToolNames.bash }
        let context = ToolExecutionContext(
            workFolderRoot: delegate.workFolderURL ?? Self.noWorkFolderSandboxRoot,
            taskID: task.id,
            runID: task.runs[runIndex].id,
            roleID: roleID,
            expectedArtifacts: expectedArtifacts,
            isPlanningPhase: isPlanningPhase,
            // The same set the batch is authorized against below: the plain ask refuses a
            // questionnaire only when the form is there to receive it.
            questionnaireAvailable: allowedToolNames.contains(ToolNames.askSupervisorForm),
            // Read now, per batch: a server added, switched on or re-pointed since the step
            // began is dialled at once, and this batch's `bash` must already refuse its port.
            // Only for a batch that runs `bash` — nothing else reads it, and the list costs a
            // read of the MCP catalogue and of the interface addresses.
            guardedLoopbackPorts: runsBash
                ? delegate.seatbeltGuardedLoopbackPorts
                : SeatbeltSandbox.effectiveGuardedPorts([]),
            // The sandbox settings too — the switch, the grants, the fallback — so what the
            // person set since the step began governs this batch's command.
            bashSandbox: runsBash ? delegate.bashPolicy.sandbox : BashPolicy.Sandbox()
        )

        var results: [ToolExecutionResult] = []
        var toolsToExecute: [StepToolCall] = []
        var rejectedResults: [Int: ToolExecutionResult] = [:]
        // The same reading the resolver stripped the schema with, so a call the model makes
        // against a withheld family is answered with the reason it was withheld — not with
        // "not available for this role", which is false for a tool the role holds.
        let approval = ToolApprovalAvailability(
            bashMode: delegate.bashPolicy.mode,
            computerUseMode: delegate.computerUsePolicy.mode,
            humanPresent: approvalHumanPresent(
                task: task, supervisorMode: resolveTeam(task: task)?.settings.supervisorMode ?? .manual))
        // Pre-runtime rejections to mirror into BOTH per-run logs (tool_calls.jsonl +
        // network_log.json): these never reach ToolRuntime, so they'd otherwise be
        // invisible in both audits. (call, result, concise reason for `errorMessage`.)
        var rejectedToLog: [(call: StepToolCall, result: ToolExecutionResult, message: String)] =
            gateRefusals.map { ($0.call, $0.result, Self.gateRefusedLogMessage) }

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
                    approval: approval,
                    phaseWithheldToolNames: phaseWithheldToolNames,
                    supersededToolNames: supersededToolNames,
                    mcpDrift: mcpDrift,
                    mcpWithheldToolNames: mcpWithheldToolNames,
                    mcpKnownToolNames: mcpKnownToolNames
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
            return await runtime.executeAll(context: context, toolCalls: toolsToExecute)
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
    /// The other cases distinguish work-folder preconditions that filter tools at
    /// schema-build time, so the rejection envelope can name the actual
    /// blocker instead of falsely blaming role config.
    ///
    /// `unknownToolName` and `notInRoleConfig` were ONE case until 2026-09-11, and
    /// conflating them is an R1.8.5 violation with a measured cost: they have different
    /// repairs. A name that is not a tool at all has no repair in the world — the model
    /// must drop it. A real tool the role was not issued has no repair in the CALL, but
    /// it does have one in the model's own OUTPUT: name the fact you wanted from it as
    /// unverified and carry on. MeditationApp task 48 run 1 is what the merged case cost:
    /// the planner asked for `run_xcodebuild`, was told to "proceed without this step",
    /// and wrote `=== BUILD SUCCESS ===` into the brief 0.4 s later.
    /// `nonisolated` + `CaseIterable` so `PromptFormatConventionsTests` can sweep every
    /// rejection message. Bare, the enum would inherit the app target's `@MainActor`
    /// default isolation and its synthesized `allCases` would be unreachable from a
    /// nonisolated `XCTestCase` (same trap as `AcceptanceService.AcceptRoute`).
    nonisolated enum ToolUnavailabilityReason: CaseIterable {
        /// No tool of this name exists in the application — the model invented it (often
        /// an artifact name, a file name, or a phrase lifted from its own prompt). Nothing
        /// can make the call work, so the repair is to drop the name entirely.
        case unknownToolName
        /// The name IS a registered tool; this role was not issued it. The call cannot be
        /// repaired, but the GAP it leaves can be: say in your own output what you wanted
        /// to learn and that it is unverified.
        case notInRoleConfig
        case workFolderClosed       // default-storage mode, no real project folder
        case gitRepoMissing         // work folder has no `.git` directory
        case visionNotConfigured    // analyze_image without a vision LLM config
        case xcodeSchemeNotSelected // run_xcodebuild/run_xcodetests without a scheme
        case computerUseDisabled    // screen_capture/ui_* with ComputerUsePolicy.mode == .off
        case bashDisabled           // bash/bash_output with BashPolicy.mode == .off
        /// The tool is on and the role holds it, but every call would wait for a human's
        /// approval and this run has none (`ApprovalGatedAvailability` — Manual with no
        /// human, or the computer-use mutating trio under Semi-automatic with no human).
        /// The resolver withheld it from the schema; the model called it anyway. Own
        /// executor code, `approval_unavailable`, because `precondition_failed`'s direction
        /// blames the work folder and offers the escalation channel — both wrong here.
        case approverUnavailable
        /// The role HAS this tool and every work-folder precondition is met —
        /// this ITERATION withheld it because the step is still in its planning
        /// phase. The only reason with a "retry later" contract: every other one
        /// tells the model to stop, which is factually wrong here, since after
        /// recording its plan the model SHOULD repeat the exact same call.
        case withheldUntilPlanRecorded
        /// The role holds this runner and every precondition is met — but an approved
        /// `request_changes` has put THIS role in `.revisionRequested` while its step plays
        /// on, and the target is rewriting the very tree a build would read. Withheld per
        /// ITERATION at the executor, like the planning phase, because the status flips
        /// from inside the role's own tool loop (`holdDownstreamForRevision`) after the
        /// schema was resolved at entry — and the wire must stay byte-identical for the
        /// rest of the step (the catalog is rendered into the prompt, so narrowing the
        /// `tools` array mid-step would re-prefill every remaining request). Own code:
        /// `precondition_failed`'s direction blames the work folder and offers "proceed
        /// without this step" — the permission this whole family exists to withdraw.
        case workSuperseded
        /// The role holds this MCP tool and the step advertised it — but between the step's
        /// entry and this call its connected server changed the tool's description or schema
        /// or dropped it, a person withdrew its approval, the server was removed, or the name
        /// now belongs to another server (`MCPLiveCatalogueIndex.standing(of:)`). Gone for the
        /// rest of the step in every case — also while its server's tool list is being read
        /// again, which is answered from the listing the app last committed. A tool that listing
        /// still approved at the called text is NOT this case — the re-read may find it
        /// unchanged and bring it back within the step — and has its own
        /// (`.mcpToolsBeingReread`). The
        /// SCHEMA still promises it,
        /// deliberately: the tool list is rendered into segment 0 of the prompt and the wire is
        /// append-only, so narrowing it mid-step would re-prefill every remaining request. So
        /// the promise is kept honest here instead — on the one call that hits it — and the
        /// next step resolves against the new catalogue. Own code: `precondition_failed`
        /// blames the work folder, and nothing about this blocker is local.
        case mcpToolChanged
        /// The role holds this MCP tool and the step advertised it, and nothing about the tool
        /// changed — its server has no live session right now: reconnecting after a dropped
        /// session, failing, switched off. Every tool of a server leaves the live catalogue
        /// while it has no session and comes back, at the same hash, when it reconnects — often
        /// seconds later. Until 2026-09-23 this was `.mcpToolChanged`, whose text says the
        /// server changed what the tool does and withholds it for the rest of the step: false
        /// on both counts, and a model believing it abandons a tool that works again a turn
        /// later (R1.8.5). Own code, and one of the two MCP refusals that leave a later call
        /// open (`.mcpToolsBeingReread` is the other).
        case mcpServerNotConnected
        /// The role holds this MCP tool and the step advertised it, and nothing about the tool
        /// changed — its server cannot be used until a person changes its settings: its
        /// credential was refused, its address is one this client will not talk to, it speaks
        /// nothing this client can read (an incompatible server), or a person switched it off.
        /// The connection retries none of them (`MCPServerConnection.recordFailure(_:)`; a
        /// switched-off server has no connection at all), so unlike `.mcpServerNotConnected` no
        /// later call in the step can succeed, and the refusal invites none. Until 2026-09-23 (A2 verification) both states read as
        /// `.mcpServerNotConnected`, whose "call it again later in this step" sent the model
        /// back to a server that would not come back without a person (R1.8.5). Own code,
        /// because the remedy differs from both neighbours: nothing in the call is at fault and
        /// no wait clears it, but a person CAN — so the direction offers the escalation channel.
        case mcpServerNeedsAttention
        /// The role holds this MCP tool and the step advertised it, and nothing says the tool
        /// changed — its server's tool list is being read again: a listing asked after its
        /// `list_changed`, or once its stated catalogue lifetime ran out, failed
        /// (`MCPServerConnection.catalogueUnverified`), and the listing the app last committed
        /// approved the tool at the text the step froze (one it did not is `.mcpToolChanged`
        /// throughout). The connection lists again on its own,
        /// and the first listing that commits brings back, at the same hash and within the
        /// step, every tool it did not change; one it DID change is `.mcpToolChanged` from then
        /// on. Until 2026-09-24 (group C) this state read as `.mcpToolChanged`, whose text
        /// withholds the tool for the remainder of the step — false the moment the re-read
        /// commits, and a model believing it abandons a tool that works again a turn later
        /// (R1.8.5). Own code: the second MCP refusal that leaves a later call open, and the
        /// only one that names the case in which that later call is refused instead.
        case mcpToolsBeingReread

        /// The executor's lowercase error code for this reason — the ONE spelling both
        /// `makeUnavailableToolResult` (which writes it) and `ToolErrorNotePolicy.direction`
        /// (which chooses the remedy by it) read, and what `RuntimePromptRegistry` iterates
        /// so every envelope AND every direction rides the runtime fingerprint. Until the
        /// evening of 2026-09-11 the codes were literals in two switches and in neither
        /// registry loop: the wave's central model-facing rewrite shipped under an
        /// unchanged `runtimePromptVersion` (DEBTS D-B11, closed).
        ///
        /// `notInRoleConfig` keeps the legacy `tool_not_authorized` (regression-pinned by
        /// `RepoBrowserNamespaceRejectionTests` / `ToolErrorGuidanceTests`); the
        /// precondition family shares `precondition_failed`; the three reasons whose
        /// remedy differs from their family's carry their own.
        var errorCode: String {
            switch self {
            case .unknownToolName: return "unknown_tool"
            case .notInRoleConfig: return "tool_not_authorized"
            case .workFolderClosed, .gitRepoMissing, .visionNotConfigured,
                 .xcodeSchemeNotSelected, .computerUseDisabled, .bashDisabled:
                return "precondition_failed"
            case .approverUnavailable: return "approval_unavailable"
            case .withheldUntilPlanRecorded: return "plan_required"
            case .workSuperseded: return "work_superseded"
            case .mcpToolChanged: return "mcp_tool_changed"
            case .mcpServerNotConnected: return "mcp_server_not_connected"
            case .mcpServerNeedsAttention: return "mcp_server_needs_attention"
            case .mcpToolsBeingReread: return "mcp_tools_being_reread"
            }
        }

        /// The reason a call the MCP invoker stopped at dispatch is refused with — the same one
        /// the classifier gives the same fact when the iteration's drift check already saw it.
        init(_ refusal: MCPDispatchRefusal) {
            switch refusal {
            case .toolChanged: self = .mcpToolChanged
            case .serverNotConnected: self = .mcpServerNotConnected
            case .serverNeedsAttention: self = .mcpServerNeedsAttention
            case .toolsBeingReread: self = .mcpToolsBeingReread
            }
        }

        /// What this refusal tells the model to DO — declared by the reason, not inferred
        /// from its wording.
        ///
        /// R1.8.1 asks every refusal to carry a repair. The HANDLER tree's repair is "change
        /// this argument and resend", and `ErrorRepairCensusPinTests.repairVerb` was measured
        /// against exactly that. This family has no argument to change, so running that
        /// predicate here is 60 % noise: of five reds it raises, two are real. A contract the
        /// reason STATES is the derivation that fits — the switch is compiler-exhaustive, so
        /// a twelfth reason cannot join without saying what it asks the model to do, and the
        /// pin then reads the promise rather than guessing at a verb (DEBTS D-B10).
        var disposition: RefusalDisposition {
            switch self {
            case .unknownToolName: return .dropTheName
            case .withheldUntilPlanRecorded: return .retryAfter(ToolNames.updateScratchpad)
            case .mcpServerNotConnected, .mcpToolsBeingReread: return .retryLater
            default: return .terminalCarryForward
            }
        }

        /// The thing that is actually in the way — read by the pin that forbids a DIRECTION
        /// from naming a blocker its reason does not have. Six reasons share
        /// `precondition_failed`, and its one appended direction claimed the work folder set
        /// every one of them; for a session policy (`.computerUseDisabled`, `.bashDisabled`)
        /// that is a false diagnosis, and a false diagnosis sends the model to perturb the
        /// wrong thing (R1.8.5).
        var blocker: Blocker {
            switch self {
            case .unknownToolName, .notInRoleConfig: return .theRoster
            case .workFolderClosed, .gitRepoMissing, .visionNotConfigured,
                 .xcodeSchemeNotSelected:
                return .theWorkFolder
            case .computerUseDisabled, .bashDisabled: return .sessionPolicy
            case .approverUnavailable: return .noHumanInTheRun
            case .withheldUntilPlanRecorded, .workSuperseded: return .thisStepSoFar
            case .mcpToolChanged: return .theServer
            case .mcpServerNotConnected: return .serverConnection
            case .mcpServerNeedsAttention: return .serverSettings
            case .mcpToolsBeingReread: return .serverToolList
            }
        }
    }

    /// What a refusal asks the model to do next. Three contracts, and only one is a retry.
    nonisolated enum RefusalDisposition: Equatable {
        /// Nothing can make the call work and nothing takes its place: whatever it would have
        /// settled stays unknown, and saying so is the only honest way past it.
        case terminalCarryForward
        /// The name is not a tool at all. No variant of it becomes one.
        case dropTheName
        /// The one temporal arm: do the named thing, then repeat the identical call.
        case retryAfter(String)
        /// Nothing the model does clears it, and time may: carry on with what it holds, and the
        /// identical call may be made again later in the step — not straight away, when it
        /// would meet the same state.
        case retryLater

        /// The phrases that SPELL this contract. Closed and short on purpose — widening the
        /// list so a new message passes is how a measured detector goes hollow, which is why
        /// `testTheContractCheckStillRefusesAMessageThatStatesNoContract` plants a wording
        /// that must not pass.
        ///
        /// `proceed without this step` is deliberately ABSENT and separately forbidden: it is
        /// the permission withdrawn on 2026-09-11 after a planner read it as licence to
        /// assert the build result it had just been refused.
        var sanctionedClauses: [String] {
            switch self {
            case .dropTheName:
                return ["is not a tool"]
            case .retryAfter(let tool):
                return ["then call"] + [tool]
            case .retryLater:
                return ["again later in this step"]
            case .terminalCarryForward:
                return [
                    "as unverified",
                    "continue with the tools you hold",
                    "continue without",
                    "Continue without",
                    "Finish this step from what you already have",
                ]
            }
        }
    }

    /// What stands between the model and the call. Named so a shared DIRECTION cannot claim
    /// one blocker on behalf of reasons that have another.
    nonisolated enum Blocker: String, CaseIterable {
        case theRoster
        case theWorkFolder
        case sessionPolicy
        case noHumanInTheRun
        case thisStepSoFar
        /// An external MCP server: it changed what it publishes, or stopped publishing.
        /// Nothing in the work folder, the session or this step is in the way.
        case theServer
        /// An external MCP server's CONNECTION: it has no live session at the moment. Nothing
        /// about the tool changed.
        case serverConnection
        /// An external MCP server's SETTINGS: it cannot be used until a person changes them —
        /// a refused credential, a refused address, an incompatible server, a server switched
        /// off. Nothing about the tool changed, and no wait brings it back.
        case serverSettings
        /// An external MCP server's TOOL LIST: a listing that should have read a change — after
        /// its `list_changed`, or once its stated catalogue lifetime ran out — failed, and the
        /// list is being read again. Nothing about the connection, the settings or the tool is
        /// known to be wrong.
        case serverToolList

        /// Nouns that assert THIS blocker. A direction shared by several reasons may carry
        /// none of them.
        var nouns: [String] {
            switch self {
            case .theRoster: return ["your system prompt", "issued to you"]
            case .theWorkFolder: return ["work folder", ".git directory", "vision model", "Xcode scheme"]
            case .sessionPolicy: return ["turned off for this session", "disabled by policy"]
            case .noHumanInTheRun: return ["approval", "has none"]
            case .thisStepSoFar: return ["plan is recorded", "remainder of this step"]
            case .theServer: return ["its server", "approved"]
            case .serverConnection: return ["not connected"]
            case .serverSettings: return ["its settings"]
            case .serverToolList: return ["being read again"]
            }
        }
    }

    /// The name-shaped split, in ONE place: a canonical name outside a speaker's toolset is
    /// either not a tool at all (`.unknownToolName` — nothing can make the call work) or a
    /// real tool this role was not issued (`.notInRoleConfig` — the gap it leaves is what
    /// gets recorded). `allSchemas` is the one registry both the resolver and the executor
    /// read, so "not in it" is the same fact the schema builder acted on. Read by the
    /// classifier's tail and by `MeetingToolExecutor`, which until the evening of
    /// 2026-09-11 handed every rejected meeting call `.notInRoleConfig` — and so told a
    /// participant that `submit_vote` "did not run and returned nothing".
    /// - Parameter dynamicKnownNames: names that ARE tools without being in
    ///   `ToolHandlerRegistry` — the live MCP catalogue. Without it, every external tool a
    ///   role was not granted reads as `.unknownToolName` ("no variant of this name is a
    ///   tool"), which is false and sends the model to drop a name it could legitimately be
    ///   issued.
    nonisolated static func nameShapedReason(
        canonical: String, dynamicKnownNames: Set<String> = []
    ) -> ToolUnavailabilityReason {
        if ToolHandlerRegistry.schema(named: canonical) != nil { return .notInRoleConfig }
        return dynamicKnownNames.contains(canonical) ? .notInRoleConfig : .unknownToolName
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
        approval: ToolApprovalAvailability,
        phaseWithheldToolNames: Set<String> = [],
        supersededToolNames: Set<String> = [],
        mcpDrift: MCPToolDrift = .none,
        mcpWithheldToolNames: Set<String> = [],
        mcpKnownToolNames: Set<String> = [],
        fileManager: FileManager = .default
    ) -> ToolUnavailabilityReason {
        let registry = ToolHandlerRegistry.self
        // The MCP sets lead, and all five outrank the phase for the same reason the bash
        // and computer-use arms below it do: recording a plan re-enables nothing here. A
        // changed tool needs the server put back the way it was approved, a server between
        // sessions needs to reconnect, a tool list being read again needs the read to
        // succeed, a server waiting for a person needs its settings changed, and a withheld
        // tool needs a person in the run — none is a condition the boundary resolves, so
        // `plan_required`'s "call it again after recording your plan" would name the wrong
        // thing to wait for. The four drift sets are disjoint (one standing per tool), so
        // their order among themselves decides nothing.
        if mcpDrift.changed.contains(toolName) { return .mcpToolChanged }
        if mcpDrift.serverNotConnected.contains(toolName) { return .mcpServerNotConnected }
        if mcpDrift.toolsBeingReread.contains(toolName) { return .mcpToolsBeingReread }
        // Ahead of the approver arm too: a person present to approve could not make this call
        // run either, so "this run has none" would name the wrong thing to fix.
        if mcpDrift.serverNeedsAttention.contains(toolName) { return .mcpServerNeedsAttention }
        if mcpWithheldToolNames.contains(toolName) { return .approverUnavailable }
        // ABOVE the phase check, and the exception proves that check's rule. Everything else in
        // `phaseWithheldToolNames` is withheld by a condition the BOUNDARY resolves, which is
        // what makes `plan_required`'s "call it again after recording your plan" true. A bash
        // mode of `.off` is not such a condition: recording a plan does not re-enable a disabled
        // tool, so the retry it invites is doomed and ends in `bash_denied` one turn later.
        // Name the durable blocker instead.
        if registry.shellTools.contains(toolName) {
            switch approval.bash {
            case .withheld(.switchedOff): return .bashDisabled
            case .withheld(.noApprover): return .approverUnavailable
            case .readOnlyUnattended, .available: break
            }
        }
        // The same durable-blocker precedence for the other approval-gated family: Off and
        // "nobody to approve" both outrank the phase, and under Semi-automatic with no human
        // the mutating trio is withheld while the read-only two are not.
        if registry.computerUseTools.contains(toolName) {
            switch approval.computerUse {
            case .withheld(.switchedOff): return .computerUseDisabled
            case .withheld(.noApprover): return .approverUnavailable
            case .readOnlyUnattended:
                if registry.computerUseMutatingTools.contains(toolName) { return .approverUnavailable }
            case .available: break
            }
        }
        // A superseded role's runners, ahead of the phase: both sets are derived from the
        // already-precondition-filtered tool array, so membership proves every other reason
        // is inapplicable — and of the two, this one is the durable blocker for the rest of
        // the step, while `plan_required` invites a retry that would only land here again.
        if supersededToolNames.contains(toolName) { return .workSuperseded }
        // Checked next, and without an ordering hazard: this set is derived
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
        let tn = ToolNames.self
        if (toolName == tn.runXcodebuild || toolName == tn.runXcodetests)
            && xcodeSchemeKnown
            && (selectedScheme == nil || selectedScheme?.isEmpty == true) {
            return .xcodeSchemeNotSelected
        }
        // Last: split the residue by whether the name is a tool at all
        // (`nameShapedReason`). Nothing above this line can reach a name that is not a
        // tool — every precondition set is derived from the registry — so the order is
        // free of hazard. `toolName` reaches here canonical (`ToolRegistry.resolveToolName`
        // at the call site, which lowercases), so a namespaced, aliased or differently
        // cased emission of a REAL tool resolves before this and is correctly
        // `.notInRoleConfig`, never "no such tool".
        return nameShapedReason(canonical: toolName, dynamicKnownNames: mcpKnownToolNames)
    }

    /// Builds a tool-unavailable error envelope with cause-specific code and
    /// message. `notInRoleConfig` keeps the legacy `tool_not_authorized` code
    /// (regression-pinned by `RepoBrowserNamespaceRejectionTests` /
    /// `ToolErrorGuidanceTests`); precondition cases use `precondition_failed`
    /// with a message that names the missing prerequisite so the LLM stops
    /// retrying instead of looping on "use only tools listed in your prompt".
    /// The envelope shape also bifurcates: `notInRoleConfig` omits the structured
    /// `tool` field (see the body for why); precondition cases keep it.
    ///
    /// The code is `reason.errorCode` — the DIRECTION is chosen by code, not by reason
    /// (`ToolErrorNotePolicy.direction`), which is why `unknownToolName` has its own: under
    /// `tool_not_authorized` it would inherit the sibling's remedy, "record it as
    /// unverified", meaningless for a name that names nothing.
    /// runtime-prompt
    nonisolated static func makeUnavailableToolResult(
        call: StepToolCall,
        canonicalName: String,
        scope: String,
        reason: ToolUnavailabilityReason
    ) -> ToolExecutionResult {
        let errorCode = reason.errorCode
        let msg: String
        switch reason {
        case .unknownToolName:
            msg = "No tool named '\(call.name)' exists in this application. The name is not a tool — check your system prompt's tool list and call one of those instead."
        case .notInRoleConfig:
            // The substring `is not available \(scope)` is load-bearing and pinned
            // (`ToolUnavailabilityClassifierTests`, `RepoBrowserNamespaceRejectionTests`).
            // What follows it changed on 2026-09-11: the old text ended at "use only tools
            // listed in your system prompt", and the direction added "proceed without this
            // step" — which a planner read as permission to assert the missing fact. The
            // tool did not run; the honest remedy is to say so in the output.
            msg = "Tool '\(call.name)' is not available \(scope), so it did not run and returned nothing. Name the fact you wanted from it as unverified in your own output, and continue with the tools you hold."
        case .workFolderClosed:
            // The old text stated the fault and handed the model nothing: the only action it
            // named — "until the user opens a project folder" — belongs to a party the model
            // cannot reach, which is the same shape `.gitRepoMissing`'s comment below rejects
            // for "ask the supervisor" (R3.8.6: prose nobody reads). `default storage` is
            // load-bearing and pinned (`ToolUnavailabilityClassifierTests`).
            msg = "Tool '\(call.name)' requires an opened work folder. This session uses default storage, so no file write, git or xcode tool can run at all — name what you wanted them to settle as unverified in your own output, and continue with the tools you hold."
        case .gitRepoMissing:
            // The envelope states the FACT and the alternative; the escalation channel, if
            // the role holds one, is `ToolErrorNotePolicy.direction`'s to add — it knows the
            // schema, this builder does not, and "ask the supervisor" to a role without
            // `ask_supervisor` is prose nobody reads (R3.8.6).
            msg = "Tool '\(call.name)' requires a git repository. The work folder has no .git directory — skip git operations and record anything you wanted them to settle as unverified."
        case .visionNotConfigured:
            // "proceed without image analysis" was the retired permission still shipping. The
            // 2026-09-11 wave stripped "proceed without this step" from `.notInRoleConfig`
            // because a planner read it as licence to assert the missing fact; vision's whole
            // job is establishing a fact about an image, so the invitation is sharper here
            // than anywhere else. `vision model` is pinned.
            msg = "Tool '\(call.name)' requires a configured vision model. None is configured for this work folder — name what you wanted to learn from the image as unverified in your own output, and continue without it."
        case .xcodeSchemeNotSelected:
            msg = "Tool '\(call.name)' requires a selected Xcode scheme. No scheme is configured for this work folder — record the build or test result you wanted as unverified rather than assuming one."
        case .computerUseDisabled:
            msg = "Tool '\(call.name)' requires Computer Use, which is turned off for this session. Continue without screen control."
        case .bashDisabled:
            // Names the POLICY, not the Settings pane: the model cannot open one. Mirrors the
            // wording rule `BashPermissionService`'s own mode-off denial follows.
            msg = "Tool '\(call.name)' requires the bash tool, which is disabled by policy (execution mode: Off). No command can run in this session — continue without a shell."
        case .approverUnavailable:
            // Own code — the lowercase executor spelling of `ToolErrorCode.approvalUnavailable`,
            // so `ToolErrorNotePolicy.direction` reaches its channel-free arm from both shapes.
            // `precondition_failed` would blame "the work folder" (false: the blocker is the
            // run's lack of a human) and offer `ask_supervisor` (the answerer that cannot
            // approve) — the exact ring KNOWN_ISSUES A15 describes, one envelope to the left.
            msg = ToolHandlerRegistry.shellTools.contains(canonicalName)
                ? "Tool '\(call.name)' is withheld in this run: every command would need a human's approval, and this run has none. Continue without a shell."
                : "Tool '\(call.name)' is withheld in this run: this action would need a human's approval, and this run has none. Continue without it."
        case .workSuperseded:
            msg = "Tool '\(call.name)' is withheld for the remainder of this step: an approved change request is rewriting the tree a build would read, and this step's output will be superseded by your own re-run, which holds the runners again. Finish this step from what you already have, without further builds."
        case .mcpToolsBeingReread:
            // States what holds whichever way the state was reached — the list is being read
            // again, and no call of that server runs until the read succeeds (the route refuses
            // every one while its catalogue is unverified, `MCPClientRegistry.callTool`) — and
            // names no cause: a `list_changed` is the server announcing a change, but a stated
            // catalogue lifetime running out announces nothing, and "its server announced a
            // change" was false for it until C-5 (2026-09-24). Nor does it say the tool changed
            // or what the change is (either would put the server's word in front of the model,
            // the rug pull's own channel). Leaves a later call open, after other work, as
            // `.mcpServerNotConnected` does; and it names the outcome the re-read itself can
            // produce, so a later `mcp_tool_changed` is the promise kept rather than a
            // contradiction (R1.8.5). A person revoking the tool meanwhile refuses it the same
            // way; the text claims no exclusivity, so it stays true then too.
            msg = "Tool '\(call.name)' did not run: the list of tools its server offers is being read again, and none of that server's tools runs until the read succeeds. Nothing in the call is at fault, and it returned nothing. Continue with the tools you hold; if this step still needs it, call it again later in this step, after other work — if the re-read list changed this tool, it will be withheld for the rest of the step instead. Until it answers, treat what it would have settled as unverified."
        case .mcpToolChanged:
            // States the fact and the one honest remedy. No retry is invited: the schema
            // still lists this tool for the rest of the step, so "try again" would be an
            // invitation to loop against a refusal that cannot change until the next step.
            // Nor is the change described — the difference is between two server-authored
            // texts, and putting either in front of the model is the rug pull's own channel.
            //
            // "or its approval was withdrawn" since 2026-09-23: the dispatch check now refuses a
            // call to a tool a person revoked mid-step with this text, and without the clause
            // it blamed the server for a decision the server never made (R1.8.5).
            // "or how it is called" since 2026-10-28: a tool whose schema carries
            // `x-mcp-header` (`callShapeDependsOnEra`), header parameters or not, is refused this
            // way once its server's session speaks another protocol revision than the one the
            // step's calls are assembled for — the tool's text did not change, the shape of a call
            // of it did (`MCPToolCall.era`).
            msg = "Tool '\(call.name)' is withheld for the remainder of this step: since this step was set up, its server changed what this tool does or how it is called, or stopped offering it, or its approval was withdrawn. The call did not run and returned nothing. Name what you wanted it to settle as unverified in your own output, and continue with the tools you hold."
        case .mcpServerNotConnected:
            // States what is known — the server has no session NOW — and nothing it cannot
            // know: it does not say the server is reconnecting, only that it may be, because
            // `.connecting` and a retrying `.failed` both reach this arm and neither promises
            // that the next attempt succeeds (a server switched off reaches
            // `.mcpServerNeedsAttention` instead). One of the two MCP refusals that
            // leave a later call open, and it says when: after other work, not on the next
            // turn, when the same call would meet the same state.
            msg = "Tool '\(call.name)' did not run: its server is not connected right now, and it may be reconnecting. Nothing in the call is at fault, and it returned nothing. Continue with the tools you hold; if this step still needs it, call it again later in this step, after other work, when its server may be back. Until it answers, treat what it would have settled as unverified."
        case .mcpServerNeedsAttention:
            // States what is known — the server cannot be used until a person changes its
            // settings — and invites no retry: nothing retries a refused credential, a refused
            // address, an incompatible server or one a person switched off, so a later call in
            // this step meets the same state. The escalation channel, when the role holds one, rides the direction.
            msg = "Tool '\(call.name)' did not run: its server cannot be used until a person changes its settings in this app. Nothing in the call is at fault, and it returned nothing. Name what you wanted it to settle as unverified in your own output, and continue with the tools you hold."
        case .withheldUntilPlanRecorded:
            // Distinct code so `ToolErrorNotePolicy.direction` can steer toward the
            // retry. `precondition_failed` would tell the model the blocker is
            // the work folder — false, and non-retryable.
            msg = "Tool '\(call.name)' becomes available once your plan is recorded. Call update_scratchpad with your findings and your numbered plan, then call '\(call.name)' again. Only your recorded notes cross into the next phase — file contents you have read do not, so put anything you must reproduce verbatim into the notes before you record them."
        }
        // Omit the structured `tool` field for the genuine-hallucination case:
        // the rejected name is frequently an artifact name (or other non-tool
        // string the model invented, e.g. "Engineering Notes"), and echoing it
        // back as `"tool":"X"` reinforces the wrong premise that X is a callable
        // tool. The precondition reasons keep it — there it names a real blocked
        // tool (the canonical, namespace-stripped name) that downstream tooling
        // relies on (retention pinned by `ToolUnavailabilityClassifierTests`'s
        // `testEnvelope_gitRepoMissing…` `"tool":"git_add"` assertion).
        // Serialized, not concatenated: the hand-rolled version escaped `msg` and not
        // `canonicalName`, and its sibling `makeIdenticalWriteLoopResult` escaped neither.
        // `makeExecutorErrorEnvelope` keeps this shape (the top-level `error` literal the
        // policy's bespoke arms switch on) and makes the escaping total.
        // Both name-shaped reasons omit it, for the same reason and with different force:
        // `unknownToolName` names nothing at all, and `notInRoleConfig` names something
        // this role may not call — in both, a structured `"tool":"X"` frames X as a
        // callable handle it is not. The precondition reasons keep it (there it names a
        // real blocked tool downstream tooling relies on).
        var extra: [String: String] = [:]
        switch reason {
        case .unknownToolName, .notInRoleConfig: break
        default: extra["tool"] = canonicalName
        }
        return ToolExecutionResult.synthetic(
            for: call,
            outputJSON: makeExecutorErrorEnvelope(error: errorCode, message: msg, extra: extra),
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
        // The path the fingerprint matched on — read the way the runtime reads it.
        let parsed = (ToolCallArguments.prepare(rawJSON: call.argumentsJSON, emittedName: call.name)
            .dispatched?.args["path"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        // `"?"` stays the STRUCTURED field's sentinel (its shape is pinned), but it must not
        // reach the MESSAGE: the model reads that as a literal path. `ToolErrorNotePolicy`
        // used to collapse it while restating this sentence, and no longer restates anything.
        let path = parsed ?? "?"
        let target = parsed.map { "'\($0)'" } ?? "the file"
        let msg = "Identical write to \(target) already executed in this step."
        // `path` is model-authored: a `"` or `\` in it used to emit malformed JSON as the
        // answer to the very call the model has to correct.
        return ToolExecutionResult.synthetic(
            for: call,
            outputJSON: makeExecutorErrorEnvelope(
                error: "identical_write_loop", message: msg, extra: ["path": path]),
            isError: true
        )
    }
}
