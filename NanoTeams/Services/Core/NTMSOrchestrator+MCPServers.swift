import Foundation

/// The orchestrator's MCP surface: build the manager, point it at the open folder, and take it
/// down on the four paths that end a folder's life.
extension NTMSOrchestrator {

    /// Builds the manager once, on the first folder open.
    ///
    /// **Not gated on `hasRealWorkFolder`.** A chat-mode team in default storage is a normal
    /// way to use this app, and an MCP server is just as useful there. What a missing folder
    /// costs is the per-folder opt-out file and the frame log — both of which degrade to
    /// "everything the catalogue allows" and "no log", neither of which is a reason to
    /// withhold the feature.
    ///
    /// Built AFTER `apply(snapshot)` so the folder is known, and BEFORE `refreshAgentSkills`
    /// so the first step of a run already sees the catalogue.
    func setUpMCPServerManager() async {
        if mcpServerManager == nil {
            mcpServerManager = MCPServerManager(
                catalogueStore: mcpCatalogueStore, environment: mcpEnvironment)
        }
        await mcpServerManager?.setWorkFolder(paths: workFolderURL.map { NTMSPaths(workFolderRoot: $0) })
    }

    /// Stops every connection. Called from a folder switch, a reset, a close, and from quit.
    func tearDownMCPServerManager(budget: TimeInterval = MCPConstants.shutdownBudget) async {
        await mcpServerManager?.shutdown(budget: budget)
    }

    /// What a step freezes at entry. `.empty` when no manager exists, which is what makes a
    /// prompt built without MCP byte-identical to one built before this feature existed.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var mcpTools: MCPToolsSnapshot? {
        mcpServerManager?.snapshot
    }

    /// The single shutdown step the termination delegate runs.
    ///
    /// All three branches run in PARALLEL, and the parallelism is the point: the delegate has
    /// about five seconds in total, the search index write can use most of them on a large
    /// folder, and running the MCP client or hosted MCP server teardown after it would leave
    /// sessions and `wait_for_events` connections hanging for however long the index took.
    /// None of the three can fail the others — all are best-effort by construction.
    func shutdownForTermination() async {
        externalAutovisorReadinessSignal.wakeAll(reason: .shuttingDown)
        async let searchIndex: Void = tearDownSearchIndexCoordinator()
        async let mcp: Void = tearDownMCPServerManager(budget: MCPConstants.shutdownBudget)
        async let hostedMCP: Void = AppTerminationDelegate.run(
            { [weak self] in await self?.shutdownHostedMCPForTermination() },
            budget: AppTerminationDelegate.hostedMCPShutdownBudget
        )
        _ = await (searchIndex, mcp, hostedMCP)
        // The activity log writes on its own queue; whatever it still holds — a summary line,
        // a full call — reaches the disk before the process does not. LAST, not first: the waits
        // woken above, and the calls the hosted server's teardown ends, record their rows while
        // this function is suspended in the await.
        externalActivityLog.flush()
    }
}
