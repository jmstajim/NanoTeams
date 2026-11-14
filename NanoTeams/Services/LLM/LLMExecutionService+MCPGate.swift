import Foundation

// MARK: - MCP approval types

/// A human's verdict on one MCP tool call, as the GATE reads it — plus the case where there is
/// no verdict at all.
///
/// "Always allow" is not a verdict of its own here: to the call it is an allow, and the standing
/// grant it also asks for is the orchestrator's write to the trust file
/// (`NTMSOrchestrator.resolveMCPApproval`), recorded — or refused, and then simply not recorded
/// — before the call is released. Until 2026-10-28 the gate was handed a fourth case,
/// `.alwaysAllow`, that it read exactly like `.allow` and that nothing else read, while the
/// orchestrator "downgraded" a refused grant to a plain allow: a distinction nothing could tell
/// apart.
nonisolated enum MCPApprovalDecision: Hashable {
    case allow
    case deny
    /// The hold ended WITHOUT a human answer: Pause, work-folder switch, or teardown
    /// cancelled the step task. Fail-safe is unchanged — the call still does not go out — but
    /// the outcome is not a refusal, and the model must not be told it was one. The same
    /// distinction `BashApprovalDecision.cancelled` exists for (CLAUDE.md #152), and it
    /// matters more here: this envelope is persisted into the step's conversation, so a
    /// `.deny` written for a decision nobody made would still be telling the model on resume
    /// that a person had refused the call.
    case cancelled
}

// MARK: - The gate

extension LLMExecutionService {

    /// Pre-pass over a turn's resolved tool calls that decides, for each MCP call, whether it
    /// may go out to the server. Returns a sparse map `index → synthetic result` for the
    /// calls it intercepts; indices NOT present pass through to `executeToolCalls`.
    ///
    /// **The decision is made outside the model and it cannot be talked into changing.** The
    /// model chose the tool and wrote the arguments; everything after that is
    /// `MCPPermissionService`'s answer and, where that answer is "ask", a person's. Nothing in a
    /// tool description, a server's annotations or a previous tool result reaches this
    /// function except as the inputs it already distrusts.
    ///
    /// **Two catalogues, one question each.** The TEXT is the step's frozen copy (`mcpTools`)
    /// — what the model read and called against. The POLICY is the live catalogue's, re-read
    /// for every call and so again after every held card: a person who withdraws "Always
    /// allow", switches the server to Manual or un-marks it trusted mid-step has decided about
    /// the NEXT call, not the next step. Until 2026-09-23 the gate decided from the frozen
    /// entry alone, and none of the three reached a running step (F20). The schema stays
    /// frozen: nothing read here reaches the prompt.
    ///
    /// **Every call of a tool the step shipped leaves with a decision.** Past this gate the
    /// invoker checks only that the server has a route and that the route carries the called
    /// text — never the approval mode — so a call waved through here unexamined would go out
    /// under no policy. Until the A2 review of 2026-09-23 a tool missing from the live
    /// catalogue was passed on, on the assumption that the route and the catalogue agree; a
    /// listing on a failed session could open a route the catalogue did not show.
    ///
    /// Resolution per call — first where the tool stands in the live catalogue
    /// (`MCPLiveCatalogueIndex.standing(of:)`, the rule the iteration's drift check reads),
    /// then deny > ask > allow, applied inside `MCPPermissionService`:
    /// - not published → refused here, with the refusal the drift check would have given it,
    ///   and no card: the tool left the catalogue after the iteration began, so there is no
    ///   current policy to ask a person under. `mcp_server_not_connected` when its server is
    ///   between sessions, `mcp_server_needs_attention` when its server waits for a person to
    ///   change its settings (a refused credential or address, an incompatible server, a server
    ///   switched off), `mcp_tools_being_reread` when its server's tool list is being read again
    ///   after a listing failed and the listing it last committed approved the tool at the
    ///   frozen text — read FIRST, since nothing then says which text an entry it still shows
    ///   would run; any other tool of that server is `mcp_tool_changed`, the verdict already
    ///   committed — and `mcp_tool_changed` when it is gone for the step —
    ///   withdrawn, no longer approved, its server removed, or its name now another server's;
    /// - `.deny` → the live pin is at another hash than the text the model called against: the
    ///   server rewrote the tool after the drift check, while the model was generating or an
    ///   earlier card was held. Refused as `mcp_tool_changed` — the refusal the next iteration
    ///   would give it — and never put in front of a person, whose card would show a text the
    ///   model did not call;
    /// - `.allow` → pass through (the call runs, and the invoker checks the text once more);
    /// - `.ask` → first the preflight (`MCPDynamicTool.preflight`): a call the send path
    ///   refuses before anything leaves — the document not a JSON object, an argument the
    ///   runtime's type gate refuses, a header parameter no header can carry — is passed on, with
    ///   no card and WHOEVER is present, to that refusal, which the runtime or the tool gives it:
    ///   the model reads what is wrong with its arguments, not that nobody can approve a call that
    ///   could never be sent;
    /// - `.ask`, a call that would be sent, with a human present → the call is HELD and the gate
    ///   AWAITS the decision in-loop; the model is never asked to re-issue. Allow → runs; Always
    ///   → runs and the grant is recorded; Deny → `MCP_DENIED`; `.cancelled` → the shared
    ///   cancellation envelope. A card shows the call the preflight assembled — what the server
    ///   will receive;
    /// - `.ask`, a call that would be sent, with no human → `APPROVAL_UNAVAILABLE`. Reachable in
    ///   production for a tool the resolver shipped, i.e. one `runsUnattended` said could clear
    ///   the policy — so arriving here means the policy was tightened, or the catalogue moved,
    ///   under the step.
    func gateMCPCalls(
        resolvedToolCalls: [StepToolCall],
        allowedToolNames: Set<String>,
        mcpTools: MCPResolvedTools,
        isPlanningPhase: Bool = false,
        stepID: String,
        taskID: Int,
        supervisorMode: SupervisorMode,
        task: NTMSTask,
        client: any LLMClient = LLMClientRouter(),
        config: LLMConfig = LLMConfig(),
        networkLogger: NetworkLogger? = nil
    ) async -> [Int: ToolExecutionResult] {
        // Cheap exit: nothing to gate unless this step ships MCP tools and the turn calls one.
        guard !mcpTools.shipped.isEmpty,
              resolvedToolCalls.contains(where: { MCPToolNaming.isMCPName(ToolRegistry.resolveToolName($0.name)) })
        else { return [:] }

        let humanPresent = approvalHumanPresent(task: task, supervisorMode: supervisorMode)
        let calledAgainst = mcpTools.shippedByName
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        var live = MCPLiveCatalogue()
        var synthetic: [Int: ToolExecutionResult] = [:]

        for (idx, call) in resolvedToolCalls.enumerated() {
            let name = ToolRegistry.resolveToolName(call.name)
            guard MCPToolNaming.isMCPName(name) else { continue }
            // A name the step did not ship — withheld, drifted, or another role's — belongs
            // to the executor's classifier, which has the facts to say WHICH of those it is.
            // Gating it here would answer with an approval verdict for a call that was never
            // going to run.
            guard allowedToolNames.contains(name), let called = calledAgainst[name] else { continue }
            // Per call, not per batch: the previous iteration of this loop may have awaited a
            // card for minutes. Costs one integer comparison unless the manager rebuilt.
            switch live.refreshed(from: delegate?.mcpTools).standing(of: called) {
            case .refused(let refusal):
                synthetic[idx] = Self.makeUnavailableToolResult(
                    call: call, canonicalName: name, scope: "for this role",
                    reason: ToolUnavailabilityReason(refusal))
            case .published(let current):
                let priorServerNames = priorContactedMCPServerNames(
                    for: stepKey, excluding: current.serverID)
                let intercepted = await decideMCPCall(
                    call, name: name, calledAgainst: called, current: current,
                    priorServerNames: priorServerNames,
                    humanPresent: humanPresent, isPlanningPhase: isPlanningPhase,
                    stepID: stepID, taskID: taskID,
                    client: client, config: config, networkLogger: networkLogger)
                synthetic[idx] = intercepted
                if intercepted == nil,
                   case .sends = MCPDynamicTool.preflight(
                       argumentsJSON: call.argumentsJSON, toolName: name, entry: called)
                {
                    noteMCPServerContacted(
                        stepKey: stepKey,
                        serverID: current.serverID,
                        serverDisplayName: current.serverDisplayName)
                }
            }
        }

        return synthetic
    }

    /// Sorted display names of other MCP servers already contacted during `stepKey`.
    func priorContactedMCPServerNames(
        for stepKey: TaskStepKey, excluding serverID: UUID
    ) -> [String] {
        let map = executionStates[stepKey]?.mcpServersContactedInStep
            ?? mcpServersContactedByStep[stepKey]
            ?? [:]
        return map
            .filter { $0.key != serverID }
            .map(\.value)
            .sorted()
    }

    /// Records that `stepKey` has allowed a call through to `serverID`.
    func noteMCPServerContacted(
        stepKey: TaskStepKey, serverID: UUID, serverDisplayName: String
    ) {
        if executionStates[stepKey] != nil {
            executionStates[stepKey]?.mcpServersContactedInStep[serverID] = serverDisplayName
        } else {
            mcpServersContactedByStep[stepKey, default: [:]][serverID] = serverDisplayName
        }
    }

    /// One call its server still publishes, under the policy as it stands now. `nil` when the
    /// call may go out.
    private func decideMCPCall(
        _ call: StepToolCall,
        name: String,
        calledAgainst called: MCPToolsSnapshot.Entry,
        current: MCPToolsSnapshot.Entry,
        priorServerNames: [String],
        humanPresent: Bool,
        isPlanningPhase: Bool,
        stepID: String,
        taskID: Int,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger?
    ) async -> ToolExecutionResult? {
        switch Self.mcpDecision(
            calledAgainst: called, current: current, priorServerNames: priorServerNames)
        {
        case .allow:
            return nil
        case .deny:
            // The one deny the policy can reach with a pin in hand is step 0's: the text
            // moved. Not `MCP_DENIED`, whose direction says a person reviewed the call and
            // declined — nobody did.
            return Self.makeUnavailableToolResult(
                call: call, canonicalName: name, scope: "for this role", reason: .mcpToolChanged)
        case .ask(let reason):
            return await resolveMCPAsk(
                reason: reason, call: call, name: name, calledAgainst: called, current: current,
                priorServerNames: priorServerNames,
                humanPresent: humanPresent, isPlanningPhase: isPlanningPhase,
                stepID: stepID, taskID: taskID,
                client: client, config: config, networkLogger: networkLogger)
        }
    }

    /// The policy's answer for one call. The TEXT is the one the model called against
    /// (`called`, the step's frozen entry); everything a person can change without the text
    /// changing — the standing grant, the mode, the trust mark — is the live catalogue's
    /// (`current`). A live pin at another hash than the called text is exactly what step 0 of
    /// `MCPPermissionService.evaluate` denies, which is what makes that arm reachable: it was
    /// dead while the pin and the hash were rebuilt from the same frozen value.
    nonisolated static func mcpDecision(
        calledAgainst called: MCPToolsSnapshot.Entry,
        current: MCPToolsSnapshot.Entry,
        priorServerNames: [String] = []
    ) -> MCPPermissionDecision {
        MCPPermissionService.evaluate(
            approvalMode: current.approvalMode,
            serverTrusted: current.serverTrusted,
            annotations: called.descriptor.annotations,
            pin: MCPToolPin(
                toolName: current.descriptor.originalName,
                hash: current.descriptor.pinHash,
                approvedAt: Date(timeIntervalSince1970: 0),
                alwaysAllow: current.alwaysAllowed),
            liveHash: called.descriptor.pinHash,
            priorServerNames: priorServerNames,
            targetServerName: current.serverDisplayName)
    }

    /// The `.ask` arm: held for a person when one is present, refused as unapprovable when not —
    /// for a call that would be sent. `nil` when the call may go out, or goes on to its own
    /// refusal. The card describes the tool from the LIVE entry — the server as it stands now —
    /// whose text is the one the model called against, or the policy would have denied it one
    /// step earlier.
    ///
    /// Whether a call meets a person — or the absence of one — at all, and what its arguments box
    /// shows, is ONE preflight (`MCPDynamicTool.preflight`) over the entry the step REGISTERED
    /// (`called`, the frozen one the runtime type-checks against and `handle` coerces with, and
    /// whose era the call is split for), run FIRST. A call it refuses — the document not an
    /// object, an argument of the wrong type, a header parameter no header can carry — is passed
    /// on to that refusal instead of a card or an `APPROVAL_UNAVAILABLE`: nothing leaves either
    /// way, a person's Allow would release only the refusal, and with nobody present the model
    /// would be told no one can approve a call it has to fix instead. Until 2026-10-28 the gate
    /// read only the first of those, held a card for the rest, showed the document as written
    /// rather than the call the server would receive, and asked about presence
    /// first.
    private func resolveMCPAsk(
        reason: String,
        call: StepToolCall,
        name: String,
        calledAgainst called: MCPToolsSnapshot.Entry,
        current: MCPToolsSnapshot.Entry,
        priorServerNames: [String],
        humanPresent: Bool,
        isPlanningPhase: Bool,
        stepID: String,
        taskID: Int,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger?
    ) async -> ToolExecutionResult? {
        guard case .sends(let outgoing) = MCPDynamicTool.preflight(
            argumentsJSON: call.argumentsJSON, toolName: name, entry: called)
        else { return nil }
        if current.approvalMode == .auto {
            let judgeCall = MCPJudgeCall(
                entry: current, outgoing: outgoing, priorServerNames: priorServerNames)
            let override = delegate?.mcpJudgeOverride
            let ruling = await askApprovalJudge(
                label: "mcp judge",
                config: JudgeConfig.forVerdict(config, override: override)
            ) {
                await MCPJudgeService.judge(
                    call: judgeCall,
                    strictness: current.judgeStrictness,
                    config: config,
                    override: override,
                    client: client,
                    logger: networkLogger)
            }
            switch ruling {
            case .cancelled:
                return makeCancelledResult(for: call)
            case .decided(let verdict) where verdict.allowed:
                return nil
            case .decided(let verdict) where JudgeFailClosedReason.isFailClosed(verdict.reason):
                return makeMCPJudgeUnavailableResult(call: call, reason: verdict.reason)
            case .decided(let verdict):
                return makeMCPDeniedResult(
                    call: call,
                    reason: MCPJudgeService.deniedEnvelopeMessage(reason: verdict.reason))
            }
        }
        guard humanPresent else {
            // Nobody decided, so not a denial: `ToolErrorNotePolicy`'s
            // `approval_unavailable` arm adds the don't-retry half WITHOUT an escalation
            // channel, because the channel a role holds reaches the same answerer that cannot
            // approve (KNOWN_ISSUES A15). Third person: the reader is the model.
            return makeApprovalUnavailableResult(call: call, reason: Self.mcpNoApproverMessage(reason: reason))
        }
        let held = await awaitMCPApproval(
            taskID: taskID, stepID: stepID, call: call, entry: current, outgoing: outgoing,
            // A standing grant takes effect AFTER the planning boundary, under the full
            // toolset, with no further review — and it is created inside the transcript the
            // boundary then discards. The same rule the bash gate states for its own Always
            // button, and for the same reason. A cross-server hold also suppresses the
            // standing grant: the hold is about the step's prior server contact, not the tool.
            offerAlways: current.approvalMode.allowsStandingGrants
                && !isPlanningPhase
                && priorServerNames.isEmpty,
            priorServerNames: priorServerNames)
        switch held {
        case .allow:
            return nil
        case .deny:
            // Third person, because the reader is the MODEL: "you" everywhere else in this
            // tree means the model itself, so "You declined" would tell it that it refused the
            // call it had just asked to make. Terse on purpose — the alternative arrives one
            // turn later from `ToolErrorNotePolicy`.
            return makeMCPDeniedResult(call: call, reason: "The Supervisor declined this call.")
        case .cancelled:
            return makeCancelledResult(for: call)
        }
    }

    // MARK: - Synthetic result builders

    /// The no-human arm's sentence around the policy's reason (`MCPPermissionService`, which
    /// says what the server STATED and what is only treated so). One composer, so the registry
    /// row renders the sentence the model reads rather than a copy of it.
    nonisolated static func mcpNoApproverMessage(reason: String) -> String {
        "This call needs a person's approval (\(reason)), and this run has none. "
            + "Nothing inside the run can approve it — take a different step."
    }

    func makeMCPDeniedResult(call: StepToolCall, reason: String) -> ToolExecutionResult {
        ToolExecutionResult.synthetic(
            for: call,
            outputJSON: makeErrorEnvelope(code: .mcpDenied, message: reason),
            isError: true)
    }

    func makeMCPJudgeUnavailableResult(call: StepToolCall, reason: String) -> ToolExecutionResult {
        ToolExecutionResult.synthetic(
            for: call,
            outputJSON: makeErrorEnvelope(code: .mcpJudgeUnavailable, message: reason),
            isError: true)
    }
}

// MARK: - The live catalogue, as the gate reads it

/// The live catalogue, re-read for every call of a batch and re-indexed only when the manager
/// rebuilt it — so N calls cost N integer comparisons, not N scans of the catalogue
/// (`MCPToolsSnapshot.entry(named:)` is linear). `nil` (no manager) reads as empty: nothing is
/// published and no server is configured, so every call is refused as changed.
private struct MCPLiveCatalogue {
    private var index: MCPLiveCatalogueIndex?

    mutating func refreshed(from snapshot: MCPToolsSnapshot?) -> MCPLiveCatalogueIndex {
        let snapshot = snapshot ?? .empty
        if let index, index.revision == snapshot.revision { return index }
        let rebuilt = MCPLiveCatalogueIndex(snapshot)
        index = rebuilt
        return rebuilt
    }
}
