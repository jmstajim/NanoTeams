import Foundation

/// Thread-safe boolean gate consulted by `HostedMCPListener` on its background queue to return
/// `503 Service Unavailable` (`Retry-After: 1`) while a work-folder transition is in flight
/// over an existing committed folder generation (§7.1).
nonisolated final class HostedMCPTransitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func setActive(_ value: Bool) {
        lock.lock()
        active = value
        lock.unlock()
    }
}

/// Lifecycle and agent management integration for the hosted External Agents MCP server (§6, §7.1).
extension NTMSOrchestrator {

    /// Synchronizes `hostedMCPTransitionGate` with the folder-open generation counters:
    /// active (`503 Retry-After: 1`) whenever a folder was previously committed
    /// (`committedWorkFolderGeneration > 0`) and a newer transition has started
    /// (`committedWorkFolderGeneration != workFolderOpenGeneration`) (§7.1).
    func updateHostedMCPTransitionGate() {
        hostedMCPTransitionGate.setActive(
            committedWorkFolderGeneration > 0
                && committedWorkFolderGeneration != workFolderOpenGeneration
        )
    }

    /// Resolves the port the hosted MCP server should bind to, honoring `NANOTEAMS_MCP_PORT`
    /// when valid (`1024...65535`) and otherwise `configuration.externalAgentsPort`.
    var effectiveHostedMCPPort: UInt16 {
        HostedMCPEnvironment.resolveServerPort(
            environment: hostedMCPEnvironment.processEnvironment(),
            configuredPort: configuration.externalAgentsPort
        )
    }

    /// Active bound port of the hosted MCP server when `.listening(let port)`, or `nil` when stopped.
    var activeHostedMCPServerPort: UInt16? {
        if case .listening(let port) = hostedMCPListenerState {
            return port
        }
        return hostedMCPListener?.boundPort
    }

    /// The External Agents port a role's `bash` may neither connect to nor listen on
    /// (`SeatbeltSandbox.guardedExternalAgentsPorts`, §10.2.3): the port the server uses or would
    /// use, External Agents on OR off. Until 2026-11-08 this was `nil` with the switch off, and a
    /// role could listen on the port while the server was down and collect the bearer of every
    /// client that connects over HTTP (#375). While a stop is still settling, the port the
    /// listener holds.
    var seatbeltHostedMCPPort: UInt16? {
        if !configuration.externalAgentsEnabled, pendingHostedMCPLifecycleTask == nil,
           let bound = activeHostedMCPServerPort {
            return bound
        }
        return effectiveHostedMCPPort
    }

    /// Every loopback port a role's `bash` may neither connect to nor listen on — the External
    /// Agents ports, and the ports of the MCP and LLM servers on this machine — read per tool
    /// batch into `ToolExecutionContext.guardedLoopbackPorts` (§10.2.3, #375).
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var seatbeltGuardedLoopbackPorts: [UInt16] {
        SeatbeltSandbox.guardedLoopbackPorts(
            externalAgentsPort: seatbeltHostedMCPPort,
            mcpServerPorts: seatbeltMCPServerPorts,
            llmServerPorts: seatbeltLLMServerPorts)
    }

    /// The ports of the configured MCP servers on this machine (`SeatbeltSandbox.mcpServerPorts(of:)`).
    /// NanoTeams is the CLIENT there and sends each server's bearer on every redial, so the reason
    /// is #375's in the other direction. Every configured server counts, switched on or off and
    /// allowed in this folder or not.
    ///
    /// Read from the catalogue ON DISK as well as from the manager — without moving a file that
    /// does not decode, and with the list moved aside still counted
    /// (`MCPServerCatalogueStore.serversForPortReservation`). The manager is built by the
    /// first folder open, last (`setUpMCPServerManager`), after `apply(snapshot)` has made the
    /// window live and the scheduler and the Autovisor pass can already start a step — and until
    /// 2026-11-08 a step started in that window guarded no MCP port at all. The manager's reading
    /// counts too: what it still dials while a closing connection finishes, or before it re-reads
    /// an edit (`MCPServerManager.configuredServers`).
    var seatbeltMCPServerPorts: [UInt16] {
        SeatbeltSandbox.mcpServerPorts(
            of: mcpCatalogueStore.serversForPortReservation() + (mcpServerManager?.configuredServers ?? []))
    }

    /// The ports of the LLM servers on this machine NanoTeams may send a prompt to
    /// (`SeatbeltSandbox.llmServerPorts(of:)`): every base URL a setting names, switched on or not
    /// (`StoreConfiguration.llmServerBaseURLStrings`), and every role's own override — in the open
    /// folder's teams and in the generated rosters of the tasks in memory, which a delegated child
    /// or a generated team runs on (the same rosters `referencedModelSites(base:)` walks).
    var seatbeltLLMServerPorts: [UInt16] {
        var urls = configuration.llmServerBaseURLStrings
        let generated = [activeTask?.generatedTeam] + (snapshot?.loadedTasks.values.map(\.generatedTeam) ?? [])
        let roles = (snapshot?.projection.teams.flatMap(\.roles) ?? [])
            + generated.flatMap { $0?.roles ?? [] }
        urls += roles.compactMap { $0.llmOverride?.baseURLString }
        return SeatbeltSandbox.llmServerPorts(of: urls)
    }

    func handleHostedMCPAgentInvalidated(_ agentID: UUID) {
        hostedMCPListener?.cancelConnections(forAgent: agentID)
        autovisorEventFeed.cancelWaiters(forAgentID: agentID)
        hostedMCPAgentsRevision &+= 1
    }

    /// Evaluates active `BashSecurityWarning` items for the current folder's driver and External Agents state (§10.2.4).
    var activeBashSecurityWarnings: [BashSecurityWarning] {
        let driver = snapshot?.workFolder.settings.autovisorDriver ?? .builtInModel
        return BashSecurityWarning.evaluate(
            policy: configuration.bashPolicy,
            driver: driver,
            externalAgentsEnabled: configuration.externalAgentsEnabled
        )
    }

    /// Returns `true` when `agentID` has a `wait_for_events` call in progress in the open folder —
    /// for the whole call, between the bridges a wake drops and the next one it parks on
    /// (`AutovisorEventFeed.hasWaitInProgress(forAgentID:)`, §6).
    func hasActiveHostedMCPWait(forAgent agentID: UUID) -> Bool {
        autovisorEventFeed.hasWaitInProgress(forAgentID: agentID)
    }

    /// Evaluates whether `agentID` is currently present (seen within `windowSeconds` or holding an active `wait_for_events`, §6).
    func isHostedMCPAgentPresent(
        _ agentID: UUID,
        windowSeconds: TimeInterval = HostedMCPConstants.presenceConnectedWindowSeconds
    ) -> Bool {
        hostedMCPAgentStore.isAgentPresent(
            agentID: agentID,
            hasActiveWait: hasActiveHostedMCPWait(forAgent: agentID),
            windowSeconds: windowSeconds
        )
    }

    // MARK: - Issuing, reissuing and revoking agent tokens (#375)

    /// Where token files go: the person's own `~/.config` in the app, a temporary folder in
    /// every test (`HostedMCPEnvironment.clientHomeDirectory`).
    var hostedMCPClientTokenFile: HostedMCPClientTokenFile {
        HostedMCPClientTokenFile(home: hostedMCPEnvironment.clientHomeDirectory())
    }

    /// Adds an agent and hands its token over: written to its token file for the bridge, and on
    /// the sheet once for a client that sends it in a header. A file that cannot be written does
    /// not undo the agent — the token on the sheet still connects a header-sending client — it
    /// is reported (`Delivery.notWritten`), and a reissue writes the file again. Until
    /// 2026-11-09 the add was undone for the two clients that read a file, since for them the
    /// token was not shown at all.
    func addHostedMCPAgent(label: String) throws -> HostedMCPTokenHandoff {
        handOver(try hostedMCPAgentStore.createAgent(label: label))
    }

    /// Reissues one agent's token and hands the new one over the same way.
    func reissueHostedMCPAgentToken(agentID: UUID) throws -> HostedMCPTokenHandoff {
        handOver(try hostedMCPAgentStore.rotateToken(agentID: agentID))
    }

    /// Reissues every registered agent's token (D11 action on `portInUse`) and returns both
    /// halves: what was issued, each handed over, and the agents whose rotation failed. Not
    /// `@discardableResult` — an issued token dropped on the floor is an agent cut off.
    func rotateAllHostedMCPAgentTokens() -> HostedMCPBulkRotation {
        HostedMCPBulkRotation.rotate(hostedMCPAgentStore.listAgents()) { agentID in
            handOver(try hostedMCPAgentStore.rotateToken(agentID: agentID))
        }
    }

    /// The person's switch on the agent's row: whether `agentID` may replace the open folder's
    /// Work Folder Context through the hosted server. Throws when `agents.json` cannot be
    /// written — the switch then shows what is stored, not what was asked.
    func setHostedMCPAgentMayReplaceWorkFolderContext(_ allowed: Bool, agentID: UUID) throws {
        try hostedMCPAgentStore.setMayReplaceWorkFolderContext(allowed, agentID: agentID)
    }

    /// Whether the agent of an external call may replace the Work Folder Context, read from the
    /// store at the moment of the call — a switch flipped while the agent is connected applies to
    /// its next call, and a record that is gone (the agent revoked mid-call) allows nothing.
    func externalAgentMayReplaceWorkFolderContext(_ agent: AgentIdentity) -> Bool {
        hostedMCPAgentStore.agent(id: agent.id)?.mayReplaceWorkFolderContext ?? false
    }

    /// Revokes `agentID` and removes its token file. Returns a line for the person when
    /// something was left behind — a verifier the Keychain kept, a file that would not go.
    func revokeHostedMCPAgent(agentID: UUID) throws -> String? {
        let record = hostedMCPAgentStore.listAgents().first { $0.id == agentID }
        var leftBehind: [String] = []
        if let warning = try hostedMCPAgentStore.revokeAgent(agentID: agentID).warning {
            leftBehind.append(warning)
        }
        if let record {
            do {
                try hostedMCPClientTokenFile.remove(shortID: record.shortID)
            } catch {
                let reason = (error as? HostedMCPClientTokenFileError)?.message ?? "Could not remove its token file."
                leftBehind.append("Agent revoked, but its token file is still there. \(reason)")
            }
        }
        return leftBehind.isEmpty ? nil : leftBehind.joined(separator: " ")
    }

    /// An issued token, written to its file. The issue has already happened, so a file that
    /// cannot be written is reported, not thrown — the token stays on the sheet.
    private func handOver(_ issued: HostedMCPIssuedAgent) -> HostedMCPTokenHandoff {
        let file = hostedMCPClientTokenFile
        do {
            let url = try file.write(token: issued.token, shortID: issued.record.shortID)
            return HostedMCPTokenHandoff(agent: issued, delivery: .written(url))
        } catch {
            let url = HostedMCPClientTokenFile.location(shortID: issued.record.shortID, home: file.home)
                ?? HostedMCPClientTokenFile.folder(home: file.home)
            let reason = (error as? HostedMCPClientTokenFileError)?.message ?? "Could not write the token file."
            return HostedMCPTokenHandoff(agent: issued, delivery: .notWritten(url, reason: reason))
        }
    }

    /// Starts (or restarts on a new port) the hosted loopback MCP listener.
    @discardableResult
    func startHostedMCPServer(port explicitPort: UInt16? = nil) async throws -> UInt16 {
        let targetPort = explicitPort ?? effectiveHostedMCPPort
        if let existing = hostedMCPListener,
           case .listening(let bound) = existing.state,
           targetPort != 0,
           bound == targetPort {
            hostedMCPListenerState = .listening(port: bound)
            return bound
        }

        if let existing = hostedMCPListener {
            await existing.stop()
            hostedMCPListener = nil
        }

        hostedMCPListenerState = .starting
        hostedMCPLastErrorMessage = nil

        let toolHost = HostedMCPToolHost(orchestrator: self)
        let dispatcher = HostedMCPDispatcher(
            toolExecutor: toolHost,
            agentTextVersion: RuntimePromptFingerprint.externalAgent
        )
        // A role's background command launched before this port was reserved could be
        // listening on it — on the other address family, or before the bind below — and would
        // answer every client that connects over HTTP with its bearer. Stopped first, and the
        // port reserved for every later command (`LoopbackPortReservations.reserve`).
        if targetPort != 0 {
            LoopbackPortReservations.shared.reserve([targetPort])
        }
        let gate = hostedMCPTransitionGate
        let listener = HostedMCPListener(
            agentStore: hostedMCPAgentStore,
            dispatcher: dispatcher,
            frameLog: hostedMCPFrameLog,
            isFolderTransitionGateActive: { gate.isActive }
        )
        do {
            let bound = try await listener.start(port: targetPort)
            // The port the system picked for port 0 is known only now; reserved like any other.
            LoopbackPortReservations.shared.reserve([bound])
            hostedMCPListener = listener
            hostedMCPListenerState = .listening(port: bound)
            MCPEndpointPolicy.setConfiguredHostedServerPort(bound)
            autovisorEventFeed.bumpEpochForServerEnable()
            return bound
        } catch {
            let listenerError = (error as? HostedMCPListenerError) ?? .bindFailed("listener_start_failed")
            hostedMCPListener = nil
            hostedMCPListenerState = .failed(listenerError)
            hostedMCPLastErrorMessage = listenerError.message
            lastErrorMessage = listenerError.message
            throw listenerError
        }
    }

    /// Stops the hosted loopback MCP listener and wakes any active `wait_for_events` calls.
    func stopHostedMCPServer() async {
        let existing = hostedMCPListener
        hostedMCPListener = nil
        hostedMCPListenerState = .stopped
        guard let existing else { return }
        externalAutovisorReadinessSignal.wakeAll(reason: .autovisorDisabled)
        autovisorEventFeed.handleReadinessWake(.autovisorDisabled)
        await existing.stop()
    }

    /// Serialized reconciliation triggered when `configuration.externalAgentsEnabled` or
    /// `configuration.externalAgentsPort` changes.
    func reconcileHostedMCPServerFromConfiguration() {
        let previousTask = pendingHostedMCPLifecycleTask
        let task = Task { @MainActor [weak self] in
            _ = await previousTask?.value
            guard let self else { return }
            if self.configuration.externalAgentsEnabled {
                _ = try? await self.startHostedMCPServer()
            } else {
                await self.stopHostedMCPServer()
            }
        }
        pendingHostedMCPLifecycleTask = task
    }

    /// Fast bounded teardown called from `AppTerminationDelegate.shutdownForTermination` (§7.1):
    /// wakes all `wait_for_events` waiters with `shutting_down`, flushes pending `lastSeenAt`
    /// timestamps, and stops the dual-stack listeners and active connections.
    func shutdownHostedMCPForTermination() async {
        pendingHostedMCPLifecycleTask?.cancel()
        pendingHostedMCPLifecycleTask = nil
        externalAutovisorReadinessSignal.wakeAll(reason: .shuttingDown)
        autovisorEventFeed.handleReadinessWake(.shuttingDown)
        try? hostedMCPAgentStore.flushPendingLastSeenWrites()
        if let listener = hostedMCPListener {
            hostedMCPListener = nil
            hostedMCPListenerState = .stopped
            await listener.stop()
        } else {
            hostedMCPListenerState = .stopped
        }
    }
}
