import Foundation

/// The human's choice on an MCP approval card. `.alwaysAllow` is offered only when the
/// server's approval mode is not Manual and the step is not mid-planning — the two cases where
/// a standing grant either contradicts the mode or would take effect after a boundary that
/// discards the transcript it was made in.
nonisolated enum MCPApprovalChoice: Hashable { case allow, deny, alwaysAllow }

extension NTMSOrchestrator {

    // MARK: - The hooks the gate publishes through

    /// `LLMStateDelegate`: the gate began holding one call. Publish it so the activity feed
    /// renders the card.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func mcpApprovalDidBegin(_ request: MCPApprovalRequest) {
        mcpApprovalRequests[TaskStepKey(taskID: request.taskID, stepID: request.stepID)] = request
    }

    /// `LLMStateDelegate`: the gate stopped holding a call (decided or cancelled). Clears the
    /// card ONLY if it is the SAME hold instance — `createdAt`, not the bare call key — so a
    /// late end from a cancelled-then-re-prompted hold of the same call cannot wipe the
    /// freshly-republished card and wedge the step.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func mcpApprovalDidEnd(taskID: Int, stepID: String, callKey: String, createdAt: Date) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if let request = mcpApprovalRequests[key],
           request.callKey == callKey, request.createdAt == createdAt {
            mcpApprovalRequests[key] = nil
        }
    }

    /// `LLMStateDelegate`: drop every published card on full execution teardown. Task ids are
    /// reused across folders, so a card that outlived its run would render under a
    /// same-numbered task in the next one.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func clearAllMCPApprovalRequests() {
        mcpApprovalRequests.removeAll()
    }

    // MARK: - The buttons

    /// Resolves a HELD MCP call DIRECTLY, bypassing the model: on `.allow` the call goes out
    /// and the model gets the server's real answer; on `.deny` it gets a refusal.
    ///
    /// `.alwaysAllow` records the standing grant FIRST and only then releases the call — as an
    /// allow, which is all the call is — so the grant is on disk before anything can act on the
    /// approval. The write is bound to the hash on the card, `MCPApprovalRequest.pinHash`, and
    /// to the server's live terms: `MCPServerConnection.setAlwaysAllow` refuses it for a
    /// connection stopped, a mode that allows no standing grant, or a text that moved. A refused
    /// grant is simply not recorded: this call still runs, because the person did approve it,
    /// and the next one asks again — the honest outcome when the terms they read are no longer
    /// the server's.
    func resolveMCPApproval(
        taskID: Int, stepID: String, callKey: String, choice: MCPApprovalChoice
    ) async {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard let request = mcpApprovalRequests[key], request.callKey == callKey else { return }

        let decision: MCPApprovalDecision
        switch choice {
        case .allow: decision = .allow
        case .deny: decision = .deny
        case .alwaysAllow:
            recordAlwaysAllow(for: request)
            decision = .allow
        }
        llmExecutionService.resolveMCPApproval(
            taskID: taskID, stepID: stepID, callKey: callKey, decision: decision)
    }

    /// Writes the standing grant through the server's own connection, which owns the trust
    /// store's view of that server — or records nothing: when there is no such connection any
    /// more (the server was switched off or removed while the card was on screen); when the
    /// tool is no longer in the snapshot, which is what catches a connection stopped while the
    /// card was up — a stopped connection of a switched-on server reads `.connecting`, and only
    /// a connected server's tools are in the snapshot; or when the connection refuses the write
    /// — a mode that allows no grant, a text that moved, and, behind the snapshot, its own
    /// `.connectionStopped`. Nothing reads which: the call is released as an allow either way.
    private func recordAlwaysAllow(for request: MCPApprovalRequest) {
        guard let manager = mcpServerManager,
              let connection = manager.connections.first(where: { $0.config.slug.rawValue == request.serverSlug })
        else { return }
        // The SERVER's own name for the tool, recovered from the entry the card was built
        // from: the pin is keyed by it, because the model-facing fold is lossy and two of a
        // server's tools can fold to one name.
        guard let entry = manager.snapshot.entry(named: request.toolName) else { return }
        _ = try? connection.setAlwaysAllow(
            tool: entry.descriptor.originalName, allowed: true, expectedHash: request.pinHash)
    }

    /// Evaluates a held MCP approval call through `MCPJudgeService` as a read-only advisor
    /// ("Ask AI") without resolving or withdrawing the held call.
    func requestMCPJudgeAdvice(
        taskID: Int,
        stepID: String,
        callKey: String? = nil,
        client: (any LLMClient)? = nil
    ) async -> MCPJudgeService.Decision? {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard let request = mcpApprovalRequests[key] else { return nil }
        if let callKey, request.callKey != callKey { return nil }

        let strictness = mcpServerManager?.connections
            .first(where: { $0.config.slug.rawValue == request.serverSlug })?
            .config.judgeStrictness ?? .standard
        let stepConfig = configuration.globalLLMConfig
        let override = configuration.mcpJudgeLLMOverride
        await llmExecutionService.noteInterleavingCall(
            label: "mcp advice",
            config: JudgeConfig.forVerdict(stepConfig, override: override))
        let ruling = await MCPJudgeService.judge(
            call: MCPJudgeCall(request: request),
            strictness: strictness,
            config: stepConfig,
            override: override,
            client: client ?? llmExecutionService.clientFactory(),
            logger: nil)
        return ruling.decision
    }
}
