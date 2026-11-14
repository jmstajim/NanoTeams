import Foundation
import Observation

/// Every configured server, and the one snapshot a step reads.
///
/// **What it owns and what it deliberately does not.** It owns which servers exist, which are
/// running, and the frozen catalogue a step takes at entry. It owns no policy: whether a call
/// may run is `MCPPermissionService`'s, and what a tool's schema looks like is the
/// projection's. That split is why the snapshot can be built without asking anything, and why
/// this type has no opinion about tools it has never seen.
///
/// **Not gated on a real work folder.** A chat-mode team in default storage is a normal way to
/// use this app, and an MCP server is just as useful there. The per-folder opt-outs are read
/// when a folder is open and default to "everything the catalogue allows" when one is not.
@MainActor
@Observable
final class MCPServerManager {

    private(set) var connections: [MCPServerConnection] = []
    /// What a step freezes. Rebuilt whenever a connection's catalogue or status moves.
    private(set) var snapshot: MCPToolsSnapshot = .empty
    /// Approved MCP prompts across connected, enabled servers — consumed by the `/` skills picker.
    private(set) var promptsSnapshot: MCPPromptsSnapshot = .empty
    /// What the role editor reads: every CONFIGURED server and everything it publishes,
    /// including the servers that are switched off and the tools awaiting review — neither of
    /// which the snapshot can carry, because the snapshot holds only what ships.
    private(set) var grantCatalogue: MCPGrantCatalogue = .empty
    /// Surfaced by the Settings row when the catalogue file could not be written.
    private(set) var lastError: String?

    private let catalogueStore: MCPServerCatalogueStore
    private let trustStore: MCPTrustStore
    private let environment: MCPEnvironment
    /// Every write an edit of the server list makes, in its order.
    private let saver: MCPServerSaveCoordinator
    let registry = MCPClientRegistry()
    private var folderOverrides: MCPFolderOverridesStore?
    private var workFolderPaths: NTMSPaths?
    private var revision = 0
    private var staleSweep: Task<Void, Never>?

    /// What the catalogue, this folder's opt-outs and the Keychain said at the last read —
    /// taken when they can change (an edit, a removal and a folder opt-out read at once, and
    /// every reload — which each of them and a folder switch runs — reads again) and held. `serverRows` is read several times per Settings body, and
    /// the body re-evaluates on every status change of every connection: until 2026-09-23
    /// each read decoded `servers.json` and `mcp_folder.json` and queried the Keychain once per
    /// declared secret (F55).
    private var configured: [MCPServerConfig] = []
    private var folderRules: MCPFolderOverrides = .empty
    /// Per server, which of its Keychain accounts hold a value (`MCPSecretStore.storedKeys`) —
    /// what "Needs a token" is derived from, and what the editor offers to keep.
    private var storedSecrets: [UUID: Set<String>] = [:]

    /// The last turn of the chain; the next one runs after it. Three kinds of work take a turn:
    /// every reload, a save that RE-POINTS a server (`save`), and the launch sweep of orphaned
    /// secrets (`sweepOrphanedSecretsOnce`). `reload` suspends in the stops it makes, and while
    /// one is suspended the connection it is stopping already reads stopped: a second reload
    /// deciding THEN would build that server's replacement at once, and the new session would
    /// dial while the old one's close — a legacy server's `DELETE` — was still in flight.
    /// Chained, the second decides after the first's stops have returned. A re-point takes a
    /// turn for the same reason: while it waits for the old address's close, a reload deciding
    /// from the still-old list would build the address the person is moving away from again.
    /// (That two overlapping reloads leave no orphan in `connections` (F10) is carried by each
    /// reload's own re-reading after its stops; the chain is what keeps the two sessions apart.)
    private var reloading: Task<Void, Never>?
    /// Every close the manager began that nobody has yet seen return — an edit's
    /// (`applyWrittenEdit`), a re-point's withdrawal, a reload's own pass, a shutdown's. Each is
    /// a connection's stop task, which ends only once every close that connection made has
    /// (`MCPServerConnection.beginStop`). A close leaves only AFTER it returned
    /// (`awaitClosing`), whoever awaited it, so this list is where every close still running
    /// can be found — including one of a connection no longer in `connections`, which only a
    /// shutdown drops before its close returns. A reload awaits every one before it builds
    /// anything, so no replacement dials while the session it replaces is still closing,
    /// whoever stopped it; a shutdown awaits every one before it returns.
    private var closing: [Task<Void, Never>] = []
    /// Bumped by `shutdown`. A reload ASKED FOR before it — running or still queued — commits
    /// nothing after it.
    private var epoch = 0
    /// Set by `shutdown`, cleared by the next `setWorkFolder` — and by nothing else: nothing is
    /// running and nothing will until a folder is served again, so no server reads `.connecting`
    /// (`status(of:connection:)`), and a reload asked meanwhile — a switch flipped, a server
    /// saved or removed on the Settings page — re-reads the list and builds no connection
    /// (`performReload`). Until 2026-10-28 any reload cleared it, and a flip on the page of a
    /// manager whose folder had failed to open started every server against the folder the app
    /// had left.
    private var isShutDown = false
    /// Whether the launch sweep of orphaned secrets is still owed: set from the environment
    /// (`MCPEnvironment.sweepsOrphanedSecrets`, the app's `.live` only), cleared the moment it is
    /// asked for — so it is asked once per manager, whatever it then finds.
    private var owesSecretSweep: Bool

    init(
        catalogueStore: MCPServerCatalogueStore,
        environment: MCPEnvironment,
        trustStore: MCPTrustStore? = nil
    ) {
        self.catalogueStore = catalogueStore
        self.environment = environment
        let trustStore = trustStore ?? MCPTrustStore(directory: environment.trustDirectory)
        self.trustStore = trustStore
        self.saver = MCPServerSaveCoordinator(
            catalogueStore: catalogueStore, trustStore: trustStore,
            secrets: MCPSecretStore(storage: environment.secretStorage))
        self.owesSecretSweep = environment.sweepsOrphanedSecrets
    }

    // MARK: - Lifecycle

    /// Points the manager at a work folder — or at none. Re-read on every folder open, because
    /// which servers a folder allows is the folder's business. The first one, for a manager the
    /// app built, also sweeps the secrets no server reads (`sweepOrphanedSecretsOnce`).
    ///
    /// The one call that ends a shutdown: serving a folder — or, for a chat in default storage,
    /// serving none — is what runs servers again. Its own reload, and any reload asked after it,
    /// builds connections; a reload that a shutdown overtook still commits nothing (`epoch`).
    /// A connection bound to another folder — its frame log is that folder's — is not kept: the
    /// reload replaces it (`connectionsToStop()`).
    func setWorkFolder(paths: NTMSPaths?) async {
        workFolderPaths = paths
        folderOverrides = paths.map { MCPFolderOverridesStore(paths: $0) }
        isShutDown = false
        await reload()
        await sweepOrphanedSecretsOnce()
    }

    /// Rebuilds the connection set from the catalogue on disk. Servers that are still
    /// configured and still enabled keep their live connection; everything else is stopped.
    ///
    /// One at a time: a reload waits for the one before it — its stops included — so each
    /// decides from the state the last one left, and no replacement dials beside the connection
    /// it replaces.
    ///
    /// A reload belongs to the manager as it stood when it was ASKED for: a `shutdown` after
    /// that — a folder switch, a quit — ends it, even one still queued behind another. Until
    /// the second review of group C (2026-09-23) the shutdown counter was read when a reload
    /// STARTED, and a reload queued before a shutdown started after it and built the folder it
    /// had left — at quit, sessions nothing would ever close.
    func reload() async {
        let epoch = self.epoch
        let previous = reloading
        let turn = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performReload(askedIn: epoch)
        }
        reloading = turn
        await turn.value
    }

    private func performReload(askedIn epoch: Int) async {
        guard epoch == self.epoch else { return }
        // Shut down and no folder served since: the list is read — the rows show what an edit
        // wrote — and nothing is built. The edit applies when the next folder opens.
        guard !isShutDown else {
            readCatalogue()
            rebuildSnapshot()
            return
        }
        // Every await of the reload is here, before the decision: what the catalogue no longer
        // runs as it is — switched off, removed, its terms edited, or failed and edited (see
        // `MCPServerConnection.adopt(_:)`) — is stopped first, and its close awaited, so a
        // replacement never runs beside the connection it replaces. All at once: each stop's
        // synchronous half — the route withdrawn, the status set — happens in this turn, and
        // the closes run side by side, so N legacy `DELETE`s cost one budget, not N (until the
        // second review of group C, 2026-09-23, they were awaited one after another, and every
        // later edit queued behind all of them).
        //
        // Then read again, and stop again whatever THAT reading no longer runs, until a reading
        // finds nothing to stop and nothing is still closing: an edit that lands while the
        // closes are awaited writes its file and stops what it retires at once
        // (`applyWrittenEdit`), and only its own reload waits its turn. Until the review of
        // 2026-09-23 the decision stopped such a connection AFTER starting its replacement, so
        // the two sessions overlapped.
        while true {
            readCatalogue()
            beginStopping(connectionsToStop())
            guard !closing.isEmpty else { break }
            await awaitClosing()
            guard epoch == self.epoch else { return }
        }

        // The decision, from the reading that found nothing to stop, with no await after it:
        // every running connection is runnable as it is — the last pass took each one's policy
        // edit in place — and each server gets exactly one connection.
        var runningByID: [UUID: MCPServerConnection] = [:]
        for connection in connections where !connection.isStopped && runningByID[connection.config.id] == nil {
            runningByID[connection.config.id] = connection
        }
        var kept: [MCPServerConnection] = []
        for config in runnableConfigs() {
            if let existing = runningByID[config.id] {
                kept.append(existing)
            } else {
                // An edit to what the session was BUILT from is a new connection, not a
                // mutated one: the URL, the credentials, the timeouts and the slug are all baked
                // into the transport, the client or the tool names
                // (`MCPServerConfig.ConnectionTerms`). So is any edit to a connection that has
                // failed.
                kept.append(makeConnection(config))
            }
        }
        connections = kept
        // What is about to dial for the first time — a server added, switched on, re-pointed or
        // rebuilt — may be on this machine, and a role's background command launched before its
        // port was reserved could be listening there and take the bearer of the first request:
        // stopped first, and the port reserved for every later command
        // (`LoopbackPortReservations.reserve`). Synchronous, before `start()`.
        let dialling = kept.filter(\.isStopped)
        LoopbackPortReservations.shared.reserve(
            Set(SeatbeltSandbox.mcpServerPorts(of: dialling.map(\.config))))
        for connection in dialling { connection.start() }
        rebuildSnapshot()
        startStaleSweepIfNeeded()
    }

    /// Stops each connection now — its route withdrawn and its status set in this turn — and
    /// keeps its close in `closing` until someone has seen it return.
    private func beginStopping(
        _ stale: [MCPServerConnection], budget: TimeInterval = MCPConstants.shutdownBudget
    ) {
        for connection in stale { closing.append(connection.beginStop(budget: budget)) }
    }

    /// Awaits every close in `closing` NOW, then drops the ones it awaited — never one begun
    /// meanwhile, which the next caller awaits. Until the fifth pass of group D's review
    /// (2026-09-24) a reload emptied the list BEFORE awaiting it, and a shutdown awaited none of
    /// it: a close a reload was waiting for, or one an earlier shutdown had begun, was nowhere a
    /// later shutdown could find it.
    private func awaitClosing() async {
        let pending = closing
        guard !pending.isEmpty else { return }
        for close in pending { await close.value }
        let returned = Set(pending)
        closing.removeAll { returned.contains($0) }
    }

    /// Runs `work` in the reload chain's order: after every turn asked before it, and before any
    /// asked after it. While it runs no reload decides, so none builds a connection — which is
    /// what lets a re-point stop the old address and write with nothing dialling it again in
    /// between, and the launch sweep decide from a list no turn is halfway through changing.
    private func inReloadTurn<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = reloading
        let turn = Task { @MainActor in
            await previous?.value
            return await work()
        }
        reloading = Task { @MainActor in _ = await turn.value }
        return await turn.value
    }

    /// Stops the server's live connection — its route withdrawn in this turn — and awaits every
    /// close still pending before returning (`awaitClosing`): every close any stop handed back,
    /// and with each every close that connection ever made — its own, its lifecycle's (a lost
    /// session's, an abandoned attempt's), every restart's, a press a second press superseded
    /// included, and an earlier stop's (`MCPServerConnection.beginStop`). Nothing built for the
    /// server's old terms can build a request after this.
    private func withdrawConnection(of serverID: UUID) async {
        beginStopping(connections.filter { $0.config.id == serverID && !$0.isStopped })
        rebuildSnapshot()
        await awaitClosing()
    }

    /// What an edit just written to disk changes, applied at once, before its reload queues
    /// behind whatever reload is in flight: the reading re-taken, every connection the edit
    /// retires stopped — a removed or switched-off server's route withdrawn — and every policy
    /// edit adopted, then the snapshot rebuilt from it. A running step's calls read their
    /// policy from the snapshot and reach a server through its route; until the second review
    /// of group C (2026-09-23) both waited for the reload, which waited behind the stops before
    /// it, and a person who switched a server to Manual or removed it saw its calls run
    /// unattended for as long as other servers took to close.
    private func applyWrittenEdit() {
        readCatalogue()
        beginStopping(connectionsToStop())
        rebuildSnapshot()
    }

    /// Every running connection this reading does not run as it is. A policy edit — the
    /// approval mode, the trust mark, the name — is taken in place (`adopt`): it is read per
    /// call, and rebuilding the session for it would kill the server's in-flight calls and show
    /// every running step its tools as drifted.
    ///
    /// The folder a connection serves is part of what it is, like its transport: its frame log is
    /// bound to that folder when it is built (`makeLog(for:)`). So a connection whose log is not
    /// the one the folder served NOW would get is stopped, and the reload builds its successor —
    /// the sequential way, after the close returned, as for a changed transport. Until 2026-10-28
    /// a folder switch kept every connection whose terms were unchanged, and for the rest
    /// of the session it wrote its frames under the folder the app had left — which is what an
    /// open superseded after its read (`NTMSOrchestrator.openWorkFolder`) could leave behind.
    private func connectionsToStop() -> [MCPServerConnection] {
        let runnable = Dictionary(runnableConfigs().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return connections.filter { connection in
            guard !connection.isStopped else { return false }
            guard let config = runnable[connection.config.id] else { return true }
            guard connection.log?.logURL == logURL(for: config) else { return true }
            return !connection.adopt(config)
        }
    }

    /// Re-reads everything `reload` and the rows depend on — together, so the rows never show
    /// one reading's servers beside another's secrets.
    private func readCatalogue() {
        configured = catalogueStore.servers
        folderRules = folderOverrides?.load() ?? .empty
        let secrets = MCPSecretStore(storage: environment.secretStorage)
        storedSecrets = Dictionary(
            configured.map { ($0.id, secrets.storedKeys(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Switched on app-wide and allowed in this folder, in catalogue order — the first row for
    /// an id, as everywhere else a config is looked up, so no server is run twice.
    private func runnableConfigs() -> [MCPServerConfig] {
        var seen = Set<UUID>()
        return configured.filter { isSwitchedOn($0) && seen.insert($0.id).inserted }
    }

    private func isSwitchedOn(_ config: MCPServerConfig) -> Bool {
        config.isEnabled && folderRules.allows(config.id)
    }

    /// One server's standing, as the list and the snapshot both read it.
    ///
    /// `.connecting` means a lifecycle is about to run: a server switched on whose connection
    /// is between lifecycles — stopped on its way to being replaced, not yet built — reads it.
    /// `.disabled` is everything that will NOT run until something changes: a person's switch,
    /// or a manager that is shut down with no reload after it (a folder that failed to open,
    /// the app quitting). The gate and the drift check read `.disabled` as a server that waits
    /// for a person, and `.connecting` as one to try again later (`MCPLiveCatalogueIndex`); a
    /// status that said `.disabled` for a restart invited a later call to a server a person had
    /// switched off, and one that said `.connecting` after a shutdown promised a connection
    /// nothing would make (second review of group C, 2026-09-23).
    private func status(of config: MCPServerConfig, connection: MCPServerConnection?) -> MCPServerStatus {
        guard isSwitchedOn(config), !isShutDown else { return .disabled }
        guard let connection, connection.status != .disabled else { return .connecting }
        return connection.status
    }

    /// One server's standing for a PERSON (`MCPServerStanding`) — computed here and nowhere else,
    /// because this is the one type that holds every fact it reads: the switch, this folder's
    /// rule, the Keychain's answer, whether the manager is shut down, and the connection. The
    /// Settings row and the grant catalogue's server both carry it, so the list, the page, the
    /// role editor's section header and a held grant's hint cannot read one server two ways —
    /// which they did until 2026-10-28, the editor reading `.disabled` as "Off" whatever had
    /// switched the server off.
    private func standing(of config: MCPServerConfig, connection: MCPServerConnection?) -> MCPServerStanding {
        .of(isSwitchedOn: config.isEnabled,
            isAllowedInThisFolder: folderRules.allows(config.id),
            hasRequiredSecrets: config.hasRequiredSecrets(among: storedSecretKeys(of: config.id)),
            isShutDown: isShutDown,
            status: status(of: config, connection: connection))
    }

    private func makeConnection(_ config: MCPServerConfig) -> MCPServerConnection {
        MCPServerConnection(
            config: config,
            environment: environment,
            trustStore: trustStore,
            registry: registry,
            log: makeLog(for: config),
            onChange: { [weak self] in self?.rebuildSnapshot() })
    }

    private func makeLog(for config: MCPServerConfig) -> MCPRPCLog? {
        guard let url = logURL(for: config) else { return nil }
        let storage = environment.secretStorage
        return MCPRPCLog(
            logURL: url,
            credentials: { MCPRedaction.Credentials.sent(to: config, storage: storage) })
    }

    /// Where a connection built for `config` now writes its frames: under the folder served, when
    /// there is one and the environment logs at all. The one spelling `makeLog(for:)` builds from
    /// and `connectionsToStop()` compares a running connection's log against.
    private func logURL(for config: MCPServerConfig) -> URL? {
        guard environment.writesRPCLog, let paths = workFolderPaths else { return nil }
        return paths.mcpRPCLogJSONL(slug: config.slug)
    }

    /// Stops everything. Called on a folder switch, a reset, and at quit — where the budget
    /// is what the termination delegate can spare.
    ///
    /// Every server at once, under the one budget: a legacy server's close can spend all of it
    /// on its `DELETE`, and until 2026-09-23 the servers were stopped one after another, so three
    /// that hung took three budgets and the termination delegate's five seconds ran out before
    /// the last one was told (F16). Each stop begins in this turn; the awaits only join them.
    ///
    /// Returns only once every close any path began has returned — at quit, the app may exit
    /// the moment this does, and a close is a request built through the authorizer. It awaits
    /// `closing`, which holds its own stops and every earlier one no one has seen return: an
    /// edit's or a re-point's (their connection still listed, stopped a second time here — a
    /// stop awaits the one before it), a reload's pass (awaited by that reload as well), and an
    /// earlier shutdown's (a folder switch's, when the quit lands during it — that connection
    /// is no longer listed). Each of them is bounded: a stop's own close by the budget it was
    /// given — `MCPConstants.shutdownBudget` on every production path, the quit's included —
    /// and every lifecycle's and restart's close by zero. Each began no later than this call on
    /// a budget no larger than the quit's, so at quit none outlasts the quit's own closes; and
    /// the termination delegate's timeout bounds the quit whatever happens here
    /// (`AppTerminationDelegate.saveTimeout`). Until the fifth pass of group D's
    /// review (2026-09-24) it awaited only the stops it made, and a connection an edit had
    /// stopped — or that an earlier shutdown had dropped — was left closing when it returned.
    ///
    /// It ends the folder the manager served, too: the paths, the folder's opt-out file and the
    /// rules read from it. A folder switch whose open then fails leaves the manager shut down with
    /// no folder opened since, and until 2026-10-28 it went on holding the folder the app had
    /// left — the server page offered that folder's rule, and a flip there wrote its file.
    func shutdown(budget: TimeInterval = MCPConstants.shutdownBudget) async {
        epoch += 1
        isShutDown = true
        workFolderPaths = nil
        folderOverrides = nil
        folderRules = .empty
        staleSweep?.cancel()
        staleSweep = nil
        let stopping = connections
        connections = []
        registry.removeAll()
        rebuildSnapshot()
        beginStopping(stopping, budget: budget)
        await awaitClosing()
    }

    // MARK: - Editing the catalogue

    /// Which of the server's Keychain accounts held a value at the last reading — what the
    /// editor offers to keep. No Keychain query: read with the rows, and again by every edit.
    func storedSecretKeys(of serverID: UUID) -> Set<String> {
        storedSecrets[serverID] ?? []
    }

    /// Saves one server — the editor's Save, and every other edit of a server's row: one that
    /// types no secret passes `MCPServerSecretEdit()`, which keeps every stored secret and
    /// still clears what the edit DROPS (`MCPSecretChangePlan`). The three writes and their
    /// order are `MCPServerSaveCoordinator.save`'s; this half applies whatever landed, FAILURE
    /// OR NOT — the reading, the snapshot, the route's approved hashes — so the rows and a
    /// running step's gate show what the disk and the Keychain hold, never what the save meant
    /// to write.
    ///
    /// **A re-point withdraws the old address first**, and what that guarantees is this: no
    /// request goes to the address the person is moving AWAY from while the save runs — while
    /// its approvals are forgotten and its accounts cleared. So a save that points the server at
    /// another scheme, host or port (`isRepointed(from:)`) takes a turn in the reload chain — no
    /// reload decides while it runs, so none builds the old address again — stops the server's
    /// live connection, awaits every close still pending (`withdrawConnection`: the stop's own,
    /// the lifecycle's, every restart's — a legacy server's `DELETE` is a request too), and only
    /// then writes. A re-point the stores then refuse reloads before it throws: the disk still
    /// names the old address, and the server runs there again on its stored terms.
    ///
    /// Keeping the new host's secrets off the old host is NOT this order's job: it holds by
    /// construction. Every account names the origin it was entered for
    /// (`MCPServerConfig.originAccountPrefix`), a re-point writes only the new origin's, and a
    /// connection reads only its own — so no failure, and no order of events, lets the old
    /// address read what was typed for the new one. Until the third pass of group D's review
    /// (2026-09-24) both addresses read `<uuid>/bearer`, the order was all that stood between
    /// them, and a Keychain that refused the undo as well defeated it.
    ///
    /// Only a re-point takes a turn. Any other save writes at once, so a stricter mode or a new
    /// token reaches the snapshot without waiting behind a reload's closes (group C's review,
    /// 2026-09-23); and it needs no turn to stay clear of the launch sweep, because it writes
    /// the Keychain and the list in ONE main-actor turn (`MCPServerSaveCoordinator.save` is
    /// synchronous), and the sweep decides and deletes in one of its own.
    func save(_ config: MCPServerConfig, secrets edit: MCPServerSecretEdit) async throws {
        let repoints = catalogueStore.server(id: config.id).map { config.isRepointed(from: $0) } ?? false
        let written: Result<Void, any Error>
        if repoints {
            written = await inReloadTurn { [self] in
                await withdrawConnection(of: config.id)
                return Result { try saver.save(config, secrets: edit) }
            }
        } else {
            written = Result { try saver.save(config, secrets: edit) }
        }
        do {
            try written.get()
        } catch {
            // A re-point the list refused leaves the old address running without the approvals
            // it already cleared; its route must stop accepting the texts they covered.
            connection(for: config.id)?.adoptTrustRecord()
            applyWrittenEdit()
            // A failed re-point stopped the old address's connection before it wrote, and the
            // disk still says the server lives there: the reload builds it again on its stored
            // terms. It reads only its own origin's accounts — what the save put back, or
            // nothing if the Keychain refused that too — never what was typed for the new one.
            if repoints { await reload() }
            throw error
        }
        lastError = nil
        applyWrittenEdit()
        await reload()
        // A save is a person attending to this server — often with a new token, which lives in
        // the Keychain and leaves the config EQUAL, so the reload kept the connection as it
        // was. One that failed is dialled again (F7).
        await connection(for: config.id)?.restartIfFailed()
    }

    /// Deleting takes the approvals and the secrets with it (`MCPServerSaveCoordinator.remove`).
    /// A removal the list refused, or one that left a credential or the approvals behind, is
    /// reported on the list pane (`lastError`) — the confirmation that asked is gone by then.
    func remove(id: UUID) async {
        do {
            lastError = try saver.remove(id: id)?.message
        } catch {
            lastError = (error as? MCPServerEditError)?.message ?? "The server could not be removed."
            return
        }
        applyWrittenEdit()
        await reload()
    }

    /// Switches a server on or off app-wide — the server page's power switch — changing nothing
    /// else about it: the row is re-read from the list on disk, not from what the page held, so
    /// an edit that landed since is kept, and it goes through `save` with the empty secret edit
    /// like every other edit of a row. Until 2026-09-24 the only switch was in the editor's
    /// Approval card (F40). A server no longer listed is refused — the switch does not bring it
    /// back — and a switch to where the server already is writes nothing.
    func setServerEnabled(id: UUID, enabled: Bool) async throws {
        guard var config = catalogueStore.server(id: id) else { throw MCPServerEditError.serverNotFound }
        guard config.isEnabled != enabled else { return }
        config.isEnabled = enabled
        try await save(config, secrets: MCPServerSecretEdit())
    }

    /// Whether a work folder is open, so there is a folder rule to show and change. Without one
    /// "Allowed in this work folder" has nowhere to write (`MCPServerEditError.noWorkFolder`), and
    /// every server is allowed.
    var hasWorkFolder: Bool { folderOverrides != nil }

    /// Every server the last reload read, switched on or off, allowed in this folder or not, and
    /// every connection still held — closing ones included, whose close can still send a
    /// request — part of what the `bash` Seatbelt profile reserves the loopback ports of
    /// (`NTMSOrchestrator.seatbeltMCPServerPorts`, which adds the catalogue on disk). This
    /// property reads no file.
    var configuredServers: [MCPServerConfig] { configured + connections.map(\.config) }

    /// Allows or blocks a server in the open work folder. Throws when there is no folder to
    /// write to, and when its file refuses the write — the switch then snaps back, and the
    /// server page says why instead of leaving the person to wonder.
    func setServerEnabledInThisFolder(_ serverID: UUID, enabled: Bool) async throws {
        guard let folderOverrides else { throw MCPServerEditError.noWorkFolder }
        do {
            try folderOverrides.setServer(serverID, enabled: enabled)
        } catch {
            throw MCPServerEditError.folderRuleNotSaved
        }
        applyWrittenEdit()
        await reload()
    }

    /// The server's RUNNING connection — `nil` while there is none. A connection stopped for good
    /// stays listed while its close runs — replaced by an edit, until the reload that awaits the
    /// close builds its successor — and is not the server's: every write through it is refused
    /// (`MCPServerConnection.setAlwaysAllow`), its catalogue is the one being left, and a page
    /// handed it would offer switches that cannot take. Its readers: the server page
    /// (`MCPServersSettingsView.detail(for:manager:)`), which then shows the server as it stands
    /// between connections; and `save`, whose trust-record refresh and restart ask a running
    /// connection anyway (`restartIfFailed` refuses a stopped one). Until 2026-10-28 the
    /// stopped one was handed out.
    func connection(for serverID: UUID) -> MCPServerConnection? {
        connections.first { $0.config.id == serverID && !$0.isStopped }
    }

    /// One row per CONFIGURED server for the Settings list — including the ones no connection
    /// exists for, which is most of what that list is about.
    ///
    /// `connections` alone cannot answer this: `reload` builds one only for a server that is
    /// both enabled and allowed in this folder, so a switched-off server is simply absent —
    /// and a list that cannot show it cannot switch it back on.
    ///
    /// Read from what the last reload read (`configured`, `folderRules`, `storedSecrets`):
    /// no file and no Keychain per read.
    var serverRows: [MCPServerRow] {
        let byID = Dictionary(
            connections.map { ($0.config.id, $0) }, uniquingKeysWith: { first, _ in first })
        return configured.map { config in
            MCPServerRow(
                config: config,
                status: status(of: config, connection: byID[config.id]),
                standing: standing(of: config, connection: byID[config.id]),
                isAllowedInThisFolder: folderRules.allows(config.id),
                hasRequiredSecrets: config.hasRequiredSecrets(among: storedSecretKeys(of: config.id)),
                catalogueUnverified: byID[config.id]?.catalogueUnverified ?? false,
                tools: byID[config.id]?.toolTally ?? .none,
                nothingItPublishesCanBeOffered: byID[config.id]?.nothingItPublishesCanBeOffered ?? false)
        }
    }

    // MARK: - The launch sweep

    /// Deletes, once per manager and only for the manager the app built
    /// (`MCPEnvironment.sweepsOrphanedSecrets`), every MCP secret no configured server reads —
    /// what a refused Add left under an id no server has (its message says it may have), what a
    /// removal left when the Keychain refused its clear, and every account a current server no
    /// longer reads: another address's, a bearer its mode does not send, one spelled before an
    /// account named its origin (`MCPSecretStore.orphanedAccounts(readBy:)`).
    ///
    /// It keeps every account a CONFIGURED server reads — switched on or off app-wide, allowed
    /// or blocked in the folder that is open: the folder's rules never narrow what it keeps. A
    /// rule is one folder's and the secrets are app-wide, so a server blocked here runs in every
    /// other folder on exactly these accounts; deciding from the folder's list would delete its
    /// token at launch and leave it reading "Needs a token" everywhere else.
    ///
    /// Asked by the first folder open, after its reload, and run in a turn of the chain like
    /// every decision made from the list — so it never decides while a re-point is between its
    /// stop and its writes.
    private func sweepOrphanedSecretsOnce() async {
        guard owesSecretSweep else { return }
        owesSecretSweep = false
        await inReloadTurn { [self] in sweepOrphanedSecrets() }
    }

    /// One main-actor turn, no await: the list read, the Keychain listed, every orphan cleared.
    /// A save writes the Keychain and the list in one turn of its own, so the two never
    /// interleave — the sweep never sees a new server's accounts before the list names it, and
    /// an Add asked meanwhile writes after the sweep has cleared.
    ///
    /// Only from a list read CLEANLY (`orphanedSecretSweepReading(of:)`) — anything else is "do
    /// not know", never "no servers", and the skip logs one line saying what was found and what
    /// lets the sweep run again; a list never saved, a fresh install, logs nothing. Every
    /// configured server, never the folder's runnable few (see above). A Keychain that refuses
    /// the listing or a delete is logged and skipped — it runs again next launch — and never
    /// reaches the person: nothing they did failed. Every line goes to the console through
    /// `print`, as all of the app's do; what a skip logs is pinned where it is decided.
    private func sweepOrphanedSecrets() {
        let configured: [MCPServerConfig]
        switch Self.orphanedSecretSweepReading(of: catalogueStore) {
        case .servers(let servers):
            configured = servers
        case .skipped(let logLine):
            if let logLine { print(logLine) }
            return
        }
        let secrets = MCPSecretStore(storage: environment.secretStorage)
        let orphans: [String]
        do {
            orphans = try secrets.orphanedAccounts(readBy: configured)
        } catch {
            print("[MCPServerManager] WARNING: orphaned-secret sweep skipped, the Keychain refused the "
                + "listing (\(Self.keychainRefusal(error))); it runs again next launch.")
            return
        }
        let refused = secrets.clear(orphans)
        if refused > 0 {
            print("[MCPServerManager] WARNING: orphaned-secret sweep: the Keychain refused to delete "
                + "\(refused) of \(orphans.count) accounts; they are tried again next launch.")
        }
    }

    /// What the launch sweep reads the server list as.
    nonisolated enum OrphanedSecretSweepReading: Equatable, Sendable {
        /// A list read cleanly: every configured server, whose accounts the sweep keeps.
        case servers([MCPServerConfig])
        /// Anything else — "do not know", never "no servers" — and the one line the sweep logs
        /// about it, `nil` when there is nothing to say.
        case skipped(logLine: String?)
    }

    /// The sweep's reading of the list (`MCPServerCatalogueStore.reading()`): the servers of one
    /// that exists, decodes, has no list moved aside kept beside it and was not written by a
    /// newer version — or a skip, and what it logs:
    /// - a list moved aside (`servers.json.bak`, from this launch or an earlier one): the
    ///   servers it named are unknown whatever `servers.json` names since, so the sweep never
    ///   runs while it is kept — and without this line nothing would say there is one to remove;
    /// - a list that cannot be read, which the reload could not move aside either;
    /// - a list a newer version wrote, whose servers this one's tolerant decoding could read as
    ///   none; the next launch of a version that reads it sweeps;
    /// - no list at all logs NOTHING: nothing was ever saved, a fresh install, and nothing is
    ///   wrong.
    /// Paths and schema numbers only — no error's own text (`ErrorResponsePinTests`). Until the
    /// fifth pass of group D's review (2026-09-24) every skip was silent, and a `.bak` kept the
    /// sweep off at every launch with no trace anywhere.
    nonisolated static func orphanedSecretSweepReading(
        of store: MCPServerCatalogueStore
    ) -> OrphanedSecretSweepReading {
        let skipped = "[MCPServerManager] WARNING: orphaned-secret sweep skipped, "
        switch store.reading() {
        case .read(let file) where file.schemaVersion <= MCPServerCatalogueFile.currentSchemaVersion:
            return .servers(file.servers)
        case .read(let file):
            return .skipped(logLine: skipped + "the server list at \(store.fileURL.path) was written by a "
                + "newer version (schema \(file.schemaVersion); this one reads "
                + "\(MCPServerCatalogueFile.currentSchemaVersion)); it runs at the next launch of a "
                + "version that reads it.")
        case .missing:
            return .skipped(logLine: nil)
        case .unreadable:
            return .skipped(logLine: skipped + "the server list at \(store.fileURL.path) cannot be read; "
                + "it runs at the next launch that can read it.")
        case .quarantined:
            return .skipped(logLine: skipped + "a server list moved aside is kept at "
                + "\(store.backupURL.path); it runs at the next launch once that file is removed.")
        }
    }

    /// A Keychain refusal as the sweep's log line names it: the status code, never the error's
    /// localized sentence (`ErrorResponsePinTests`).
    private static func keychainRefusal(_ error: any Error) -> String {
        switch error as? KeychainError {
        case .unhandled(let status)?: "OSStatus \(status)"
        case .invalidUTF8?: "an entry that is not UTF-8"
        case nil: "\(type(of: error))"
        }
    }

    // MARK: - The snapshot

    /// Rebuilds the catalogue, and the snapshot FROM it.
    ///
    /// One walk, two values, and the derivation is the point: the picker, the badge and the
    /// wire cannot disagree about which tools are approved, because the snapshot is literally
    /// `catalogue.shippedEntries`. A second independent walk is how the two would drift.
    ///
    /// `runsUnattended` is computed HERE, once, rather than by each reader: the policy lives
    /// in `Services` and the two Domain types do not reach across that line. Freezing the
    /// answer onto the entry is also what makes `resolved(humanPresent:)` a pure split.
    private func rebuildSnapshot() {
        revision += 1
        let connectionsByID = Dictionary(
            connections.map { ($0.config.id, $0) }, uniquingKeysWith: { first, _ in first })

        var servers: [MCPGrantCatalogue.Server] = []
        for config in configured {
            let connection = connectionsByID[config.id]
            servers.append(MCPGrantCatalogue.Server(
                id: config.id,
                slug: config.slug,
                displayName: config.effectiveDisplayName,
                status: status(of: config, connection: connection),
                standing: standing(of: config, connection: connection),
                approvalMode: config.approvalMode,
                judgeStrictness: config.judgeStrictness,
                isTrusted: config.isTrusted,
                tools: connection.map { tools(of: $0, under: config) } ?? [],
                catalogueUnverified: connection?.catalogueUnverified ?? false,
                nothingItPublishesCanBeOffered: connection?.nothingItPublishesCanBeOffered ?? false,
                refusedToolNames: connection?.refusedModelFacingNames ?? []))
        }

        grantCatalogue = MCPGrantCatalogue(servers: servers, revision: revision)
        snapshot = MCPToolsSnapshot(
            entries: grantCatalogue.shippedEntries,
            statusByServerID: Dictionary(
                servers.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first }),
            lastCommittedApprovalsOfUnverifiedServers: grantCatalogue.lastCommittedApprovalsOfUnverifiedServers,
            revision: revision,
            invoker: registry)

        var promptEntries: [MCPPromptsSnapshot.Entry] = []
        for config in configured where isSwitchedOn(config) {
            guard let connection = connectionsByID[config.id],
                  connection.status.isConnected,
                  !connection.catalogueUnverified else { continue }
            for prompt in connection.approvedPrompts {
                promptEntries.append(MCPPromptsSnapshot.Entry(
                    serverID: config.id,
                    slug: config.slug,
                    serverDisplayName: config.effectiveDisplayName,
                    descriptor: prompt))
            }
        }
        promptsSnapshot = MCPPromptsSnapshot(entries: promptEntries, folderAllowedServerIDs: nil)
    }

    /// Everything one connection publishes, reviewed or not, each carrying the approval
    /// decision its own pin and its server's mode produce.
    ///
    /// The policy comes from `config` — the CATALOGUE's row, the one the rest of the rebuild
    /// reads — never from a copy the connection took when it was made: a policy edit keeps
    /// the connection, and a second copy of the mode is how the snapshot would disagree with
    /// the server list about it.
    ///
    /// The server's trust record is read ONCE per rebuild, and from the store's memory: a
    /// rebuild runs on every status flip, refresh and approval, on the main actor, and it used
    /// to read and decode the trust file once per TOOL. Each descriptor's state comes from its
    /// OWN hash against the pin, through the same rule the connection's rows use
    /// (`MCPPinState(liveHash:pin:)`), and its refusal off the same record through the one
    /// reading of a refusal the Settings list's tally counts with
    /// (`MCPServerTrustRecord.isRejected`), so the picker and the Settings list cannot disagree.
    private func tools(
        of connection: MCPServerConnection, under config: MCPServerConfig
    ) -> [MCPGrantCatalogue.Tool] {
        let record = trustStore.record(for: config.id)
        let pins = record.toolPins
        return connection.descriptors.map { descriptor in
            let pin = pins[descriptor.originalName]
            let pinState = MCPPinState(liveHash: descriptor.pinHash, pin: pin)
            let runsUnattended = MCPPermissionService.runsUnattended(
                approvalMode: config.approvalMode,
                serverTrusted: config.isTrusted,
                annotations: descriptor.annotations,
                pin: pin,
                liveHash: descriptor.pinHash)
            return MCPGrantCatalogue.Tool(
                descriptor: descriptor,
                pinState: pinState,
                alwaysAllowed: pinState.isApproved && (pin?.alwaysAllow ?? false),
                runsUnattended: runsUnattended,
                isRejected: record.isRejected(descriptor))
        }
    }

    // MARK: - Staleness

    /// One sweep for every connection rather than a timer per server: a timer per server is a
    /// wake-up per server, and most catalogues never change.
    private func startStaleSweepIfNeeded() {
        guard staleSweep == nil, !connections.isEmpty else { return }
        staleSweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(MCPConstants.minimumCatalogueTTL * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.refreshStaleCatalogues()
            }
        }
    }

    func refreshStaleCatalogues() async {
        // `rereadCatalogue`, not a bare refresh: a lifetime that ran out is the server saying
        // its list may have moved, and a listing that then fails leaves the catalogue unverified.
        for connection in connections where connection.catalogueIsStale {
            await connection.rereadCatalogue()
        }
        _ = try? trustStore.pruneRemoved()
    }
}
