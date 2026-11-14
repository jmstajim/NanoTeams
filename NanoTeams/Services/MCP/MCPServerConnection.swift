import Foundation
import Observation

/// One configured server's live state: connect, catalogue, pins, reconnect.
///
/// `@MainActor @Observable` because this IS the Settings row — the status, the tool list, the
/// review counts. The protocol work happens on the `MCPClient` actor it owns; what lives here
/// is everything a person looks at plus the policy about when to try again.
@MainActor
@Observable
final class MCPServerConnection {

    /// What this connection was built from, plus the policy it currently runs under. The
    /// transport half (`MCPServerConfig.ConnectionTerms`) is fixed for the connection's life;
    /// the policy half moves in place through `adopt(_:)`.
    private(set) var config: MCPServerConfig
    private(set) var status: MCPServerStatus
    private(set) var serverInfo: MCPServerInfo = .unknown
    /// Every tool the server publishes, projected — approved or not. The snapshot filters;
    /// the review sheet needs the whole list. Unique by the server's own name
    /// (`MCPToolDescriptorFactory` refuses a repeat), which is what lets the pins be keyed by it.
    private(set) var descriptors: [MCPToolDescriptor] = []
    /// Every prompt the server publishes (`prompts/list`), projected — approved or not.
    private(set) var promptDescriptors: [MCPPromptDescriptor] = []
    /// This server's trust record as last read or written — its pins, its refusals, the
    /// standing grants. OBSERVED, so a row, a chip or a sheet redraws when an approval lands,
    /// and none of them asks the store from inside `body`. Re-adopted after every write and
    /// every listing (`adoptTrustRecord`), which are the only ways it moves.
    private(set) var trustRecord: MCPServerTrustRecord = .empty
    /// Where each live tool stands against the pins — derived, per descriptor at ITS OWN hash,
    /// from `descriptors` and `trustRecord` in one place (`adoptTrustRecord`).
    private(set) var pinStates: [String: MCPPinState] = [:]
    /// Tools the factory could not accept, so the detail view can say which and why rather
    /// than silently showing a shorter list.
    private(set) var rejections: [MCPToolDescriptorFactory.Rejection] = []
    /// Set when the server's whole catalogue is unusable — a name collision. Distinct from
    /// `status.failed`, because the connection is fine and the CATALOGUE is not.
    private(set) var catalogueError: String?
    /// The model-facing names the last committed listing published that the app offers nothing
    /// for (`MCPToolDescriptorFactory.unofferedModelFacingNames`): every entry of a collided
    /// listing, and each entry the factory refused. What a role's grant of one of them reads as
    /// the app's refusal rather than the server's withdrawal (`MCPGrantState.toolNotOfferable`) —
    /// the manager copies it onto the grant catalogue's server.
    private(set) var refusedModelFacingNames: Set<String> = []

    private let environment: MCPEnvironment
    // Internal, not private, for `MCPServerConnection+Review.swift` — the review actions
    // write through the same store, log and change hook as the rest of the connection.
    let trustStore: MCPTrustStore
    private let registry: MCPClientRegistry
    let log: MCPRPCLog?
    let onChange: @MainActor () -> Void

    /// The live session's client — set by the lifecycle that opened it, and taken back, in the
    /// same main-actor turn, by whatever ends that lifecycle (`endLifecycle()`). Nothing else
    /// writes it, so a stop can never clear a client a newer lifecycle installed.
    private var client: MCPClient?
    private var lifecycle: Task<Void, Never>?
    /// Bumped whenever a lifecycle begins or ends. A lifecycle holds the value it began under
    /// and writes NOTHING once the value moved — no status, no route, no client, no failure —
    /// so a superseded one, resuming from an await, cannot overwrite its successor.
    private var generation = 0
    /// The newest restart — the Reconnect button's, or a save's (`restartIfFailed()`). A newer
    /// one cancels it and awaits it (`beginRestart`); a stop cancels it and awaits it
    /// (`beginStop`). Each restart's task ends only after the one it superseded, so awaiting
    /// this one awaits every restart this connection began.
    private var reconnect: Task<Void, Never>?
    /// The newest stop's task (`beginStop`). A later stop's task awaits it, so a connection
    /// stopped twice — an edit's stop and then a shutdown's, as the manager does routinely —
    /// tells its second caller it is done no sooner than its first: the first stop took the
    /// session, the lifecycle and the restart, and left the second nothing else to wait for.
    private var stopping: Task<Void, Never>?
    /// Numbers every listing as it is asked for. Two `list_changed` in quick succession send
    /// two, and their replies may land in either order.
    private var listingsAsked = 0
    /// The number of the newest listing that COMMITTED — not the newest asked. A reply commits
    /// only when it is newer than this, so an older reply never overwrites a newer catalogue,
    /// and a newer listing that FAILS cancels nothing: the older success is still the newest
    /// word the server gave (second review of group C, 2026-09-23).
    private var committedListing = 0
    /// The number of a listing that should have read a change to the server's tools — asked
    /// after its `list_changed`, or once its stated catalogue lifetime ran out — and FAILED on the live
    /// session. While set the catalogue is UNVERIFIED (`catalogueUnverified`): nothing says
    /// which text the server serves now, so the route refuses every call — as a tool list being
    /// read again, or as changed when its text is not one the last committed listing approved —
    /// and the manager ships none of this server's tools. Cleared by the first listing asked
    /// after it that commits, and with the session.
    private var unverifiedSince: Int?
    /// The listing asked again on the reconnect backoff while the catalogue is unverified — one
    /// at a time, ended with its session (`forgetUnverifiedCatalogue`).
    private var listingRetry: Task<Void, Never>?
    /// Which retry `listingRetry` is, so one that ends after its successor began clears nothing.
    private var listingRetryNumber = 0
    private var catalogueTTL: TimeInterval?
    private var lastRefresh: Date?
    /// Failure timestamps inside the crash-loop window.
    private var recentFailures: [Date] = []
    /// How many failures have been counted into the backoff since the last healthy session —
    /// the index of the next delay (`MCPReconnectPolicy.delay(afterFailure:)`).
    private(set) var backoffIndex = 0
    private(set) var isStopped = true
    /// Set by `stop()`: this connection is done — removed, replaced by an edit, switched off,
    /// shut down — and nothing starts it again. The manager builds a new one instead.
    private var isRetired = false

    #if DEBUG
    /// Connect loops that have RETURNED: the documented test seam `MCPServerConnectionTests` reads
    /// "not retried" at. A loop that returned dials nothing more — only `start` or a restart
    /// begins another — so once the count moves after a terminal failure, a connect count read
    /// then is final, with no window to wait out. DEBUG-only; production reads nothing of it.
    @ObservationIgnored var _testLoopsEnded = 0
    /// `rereadCatalogue` calls that have returned — how a test knows a `list_changed`'s listing
    /// was fully handled, failure included, when its outcome changes nothing it could watch.
    @ObservationIgnored var _testRereadsFinished = 0
    /// Whether a listing retry is armed right now: set in the same turn as the failure that
    /// begins it, so read after a re-read finished it says whether one began — before its first
    /// sleep reaches the clock.
    var _testListingRetryArmed: Bool { listingRetry != nil }
    /// Whether a restart (Reconnect, a save's `restartIfFailed`) is armed: set in the turn that
    /// begins one, cleared only by a stop — so after a stop it says whether anything began one.
    var _testRestartArmed: Bool { reconnect != nil }
    /// The newest restart ever begun — kept past the stop that cancels it, which clears
    /// `reconnect`. Until 2026-10-28 `_testRestartsFinished()` read `reconnect`, so after a stop
    /// it awaited nothing: a restart the stop cancelled, still coming back from its close, ran on
    /// past the point the seam promised.
    @ObservationIgnored private var _testNewestRestart: Task<Void, Never>?
    /// Returns once every restart begun so far has run to its end — one a stop cancelled
    /// included: each restart awaits the one it cancelled, so awaiting the newest awaits them all.
    func _testRestartsFinished() async { await _testNewestRestart?.value }
    #endif

    init(
        config: MCPServerConfig,
        environment: MCPEnvironment,
        trustStore: MCPTrustStore,
        registry: MCPClientRegistry,
        log: MCPRPCLog?,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.config = config
        self.environment = environment
        self.trustStore = trustStore
        self.registry = registry
        self.log = log
        self.onChange = onChange
        self.status = config.isEnabled ? .connecting : .disabled
    }

    // MARK: - Lifecycle

    /// Starts the connect loop. Refused for a server that is switched off, and for a connection
    /// already stopped for good (`stop()`).
    func start() {
        guard isStopped, !isRetired, config.isEnabled else { return }
        isStopped = false
        beginLifecycle()
    }

    /// Takes a catalogue edit that leaves the session's terms alone — the approval mode, the
    /// trust mark, the name on screen — without reconnecting. Returns `false`, and changes
    /// nothing, for an edit to what the session was built from
    /// (`MCPServerConfig.ConnectionTerms`): that one is a new connection.
    ///
    /// In place, because a policy is read per call and a session is not: in-flight calls, the
    /// catalogue and the pins all survive, so a running step does not see the server's tools
    /// as drifted because a person changed how their calls are approved. The manager rebuilds
    /// the snapshot after, which is how the gate of a running step sees the new policy.
    ///
    /// A connection that has FAILED refuses a policy edit too — returns `false` and changes
    /// nothing — so the manager REPLACES it, on its own serialized path (`await stop()`, then a
    /// new connection), exactly as every edit did before policy edits were taken in place. An
    /// edit is a person attending to this server, and one who fixed the token and switched the
    /// mode in the same save expects that save to reconnect. Replacing costs nothing here: a
    /// failed connection has no session, no call in flight and no published tools. An
    /// IDENTICAL config is kept, failed or not — and a save of it retries a failed connection
    /// through `restartIfFailed()`, which `MCPServerManager.save` calls.
    @discardableResult
    func adopt(_ edited: MCPServerConfig) -> Bool {
        guard edited.id == config.id, edited.connectionTerms == config.connectionTerms else { return false }
        guard edited != config else { return true }
        guard !status.hasFailed else { return false }
        config = edited
        return true
    }

    /// Stops this connection for good: the manager removed it, replaced it with one built from
    /// an edit, switched it off, or is shutting down. A reconnect already under way does not
    /// bring it back, and neither does `start()`. Returns once every close of this connection
    /// has — the first stop's or a later one's alike (`beginStop`).
    func stop(budget: TimeInterval = MCPConstants.shutdownBudget) async {
        await beginStop(budget: budget).value
    }

    /// `stop`, with the close handed back rather than waited for. Everything that ends the
    /// session happens HERE, in the caller's turn — the lifecycle is superseded, the route
    /// withdrawn, the status set — so a caller that stops a connection and builds its
    /// successor in the same turn never sees the two overlap, and one that stops several
    /// closes them all at once. Only the close, which may spend `budget` on a legacy server's
    /// `DELETE`, is left to the returned task.
    ///
    /// The returned task ends only when EVERY close of this connection has returned — every
    /// close a lifecycle, a restart or a stop made, this one or one before it. Each is a legacy
    /// server's `DELETE`, a request built through the authorizer, and cancelling the task that
    /// makes it does not un-send it; a caller that awaits this task — the manager's
    /// `withdrawConnection`, a reload, a shutdown — is told the connection is done only once
    /// nothing of it can build a request any more. It awaits, in this order:
    /// - its own close, of the session the stop took, on `budget`;
    /// - the lifecycle it ended, which may still be closing a client it had already let go of:
    ///   a lost session's (`run`) or an abandoned attempt's (`abandon`). AFTER the close,
    ///   because the lifecycle may be awaiting a connect on the very client that close ends,
    ///   and a transport's connect need not answer to cancellation;
    /// - the newest restart, which awaits the lifecycle IT ended (`restart()`) and the restart
    ///   it superseded (`beginRestart`) — so every restart and every lifecycle this connection
    ///   ever began is awaited, each by whoever ended it;
    /// - the stop before it, if there was one (`stopping`), which awaited all of the above for
    ///   what IT ended. A later stop — the manager stops a connection an edit or a re-point
    ///   already stopped whenever a shutdown finds it still listed — finds the session, the
    ///   lifecycle and the restart already taken, and would otherwise return while the first
    ///   stop's closes still ran. Last, like every await here: nothing of this stop's waits on
    ///   the earlier one, and it has nothing of its own to close anyway, since a retired
    ///   connection begins no lifecycle and no restart.
    ///
    /// None of that waits on a server's answer or on the clock. The lifecycle is cancelled and
    /// its client closed, so at every place it can be waiting it leaves at once: a connect or a
    /// listing in flight fails (the close fails every request in flight, and a request answers
    /// to cancellation too — `MCPClient.call`), the wait for a lost session ends, the backoff
    /// sleep returns (`MCPClock.sleep` returns on cancellation), and it writes nothing past its
    /// generation check. What remains are closes, each on a budget of zero but a stop's own —
    /// this one's `budget`, and an earlier stop's the budget IT was given. A restart, resumed,
    /// begins nothing: this connection is retired.
    ///
    /// Until the third pass of group D's review (2026-09-24) the task closed only what the stop
    /// took, and until the fourth (same day) it awaited only the newest restart besides: a lost
    /// session's close, an abandoned attempt's, a lifecycle a restart had ended and a restart a
    /// second press had superseded all ran on after the stop returned. Until the fifth (same
    /// day) a second stop awaited nothing at all, and a shutdown that found a connection an
    /// edit had stopped returned while that edit's close — a legacy server's `DELETE` — was
    /// still in flight.
    @discardableResult
    func beginStop(budget: TimeInterval = MCPConstants.shutdownBudget) -> Task<Void, Never> {
        isRetired = true
        isStopped = true
        let restarting = reconnect
        reconnect?.cancel()
        reconnect = nil
        let running = lifecycle
        let ending = endLifecycle()
        status = .disabled
        onChange()
        let earlier = stopping
        let stop = Task {
            await ending?.close(budget: budget)
            await running?.value
            await restarting?.value
            await earlier?.value
        }
        stopping = stop
        return stop
    }

    /// Reconnects now, ignoring the backoff — the Reconnect button. A second press cancels a
    /// first still closing its session, so two presses leave one session, not two — and awaits
    /// it, so a stop after both awaits both closes (`beginRestart`).
    func reconnectNow() {
        guard !isRetired, !isStopped else { return }
        beginRestart()
    }

    /// A save is a person attending to this server. One whose connection failed — waiting for a
    /// person (a refused token, a refused address, a server it cannot speak to) or waiting out
    /// its backoff — is dialled again now, its failure count cleared. `MCPServerManager.save`
    /// calls this for the server it saved, because a new token lives in the Keychain, not in
    /// the config: a save that only changes the token hands `save` an UNCHANGED config, and
    /// without this the row went on saying the token was refused until someone found the
    /// Reconnect button (F7).
    ///
    /// Through the same tracked restart as the button, so a save and a press cancel each other
    /// rather than each beginning a session; and on the connection's own task, not the caller's
    /// — a caller cancelled while the old session closes (the sheet dismissed mid-save) must not
    /// leave the lifecycle ended and none begun.
    func restartIfFailed() async {
        guard !isRetired, !isStopped, status.hasFailed else { return }
        await beginRestart().value
    }

    /// The newest restart: it cancels the one it supersedes, and its task ends only after that
    /// one's — so awaiting the newest (`beginStop`, `restartIfFailed()`) awaits every restart
    /// before it, and every close each of them made.
    ///
    /// Awaited LAST, after `restart()` has run, not before it: the press acts at once, exactly
    /// as it did — it ends whatever runs now and dials, the older restart still closing beside
    /// it — and the older one, coming back from its close, finds the lifecycle this one began
    /// and begins nothing (`restart()`'s own rule; two presses, one session). Awaited first, the
    /// older restart — which cancellation does not stop, see `restart()` — would come back to
    /// no lifecycle and begin one, and this one would then end it and dial again: a session
    /// dialled for nothing on every double press. Until the fourth pass of group D's review
    /// (2026-09-24) a restart forgot the one it superseded, and a stop awaiting the newest
    /// returned while an older press's close was still running.
    @discardableResult
    private func beginRestart() -> Task<Void, Never> {
        let previous = reconnect
        previous?.cancel()
        let restarting = Task { [weak self] in
            await self?.restart()
            await previous?.value
        }
        reconnect = restarting
        #if DEBUG
        _testNewestRestart = restarting
        #endif
        return restarting
    }

    /// Ends the running lifecycle and begins a fresh one — a new session, the failure count
    /// cleared.
    ///
    /// After the close it begins a lifecycle only if none began meanwhile. A newer restart that
    /// cancelled this one may have begun one already — two restarts that both came back from
    /// their closes began two, the first never cancelled, its session open until the app quit
    /// (review of group C, 2026-09-23). Cancellation is NOT what decides it: the cancelling
    /// restart may itself still be closing, and a restart that gave up on cancellation left the
    /// connection with no lifecycle at all.
    ///
    /// Then it awaits the lifecycle it ended, which may still be closing a client it had let go
    /// of — a lost session's, an abandoned attempt's — so a stop that awaits this restart awaits
    /// that close as well. After beginning, so the new session does not wait on it: the old
    /// lifecycle is cancelled and its client closed, and it writes nothing once superseded.
    private func restart() async {
        guard !Task.isCancelled, !isRetired else { return }
        let running = lifecycle
        let ending = endLifecycle()
        status = .connecting
        onChange()
        if let ending { await ending.close(budget: 0) }
        if !isRetired, !isStopped, lifecycle == nil { beginLifecycle() }
        await running?.value
    }

    private func beginLifecycle() {
        generation += 1
        backoffIndex = 0
        recentFailures = []
        status = .connecting
        onChange()
        let generation = self.generation
        lifecycle = Task { [weak self] in
            await self?.run(generation: generation)
            #if DEBUG
            self?._testLoopsEnded += 1
            #endif
        }
    }

    /// Supersedes the running lifecycle in one main-actor turn — from here on nothing it does
    /// after an await can write — withdraws the route its session opened, and hands back that
    /// session's client for the caller to close.
    private func endLifecycle() -> MCPClient? {
        generation += 1
        lifecycle?.cancel()
        lifecycle = nil
        let ending = client
        client = nil
        forgetUnverifiedCatalogue()
        if let ending { registry.withdraw(serverID: config.id, through: ending) }
        return ending
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !isStopped && generation == self.generation && !Task.isCancelled
    }

    private var policy: MCPReconnectPolicy { environment.reconnectPolicy }
    /// What the reconnect schedule, the crash-loop window and the catalogue's lifetime are
    /// measured on — and what this connection's clients time their requests on.
    private var clock: any MCPClock { environment.clock }

    /// One long-lived loop: connect, wait for the session to end, and dial again under the
    /// failure accounting — the backoff and the crash-loop window.
    ///
    /// A lost session is a failure like a refused connect and is counted the same way. Until
    /// 2026-09-23 it went through `reconnectNow()` instead, which bypassed the backoff and
    /// cleared the crash-loop count, and a server that dropped every session at once — a
    /// push GET answered 404 read as exactly that — was redialled every few milliseconds until
    /// the app quit (F1). A session counts as healthy, and its end starts the count afresh,
    /// only once it outlived the crash-loop window: a success inside the window does not wipe
    /// the failures around it.
    private func run(generation: Int) async {
        while isCurrent(generation) {
            let delay: TimeInterval?
            do {
                guard let session = try await connectOnce(generation: generation) else { return }
                let connectedAt = clock.now()
                for await _ in session.lost { break }
                guard isCurrent(generation) else { return }
                let lived = clock.now().timeIntervalSince(connectedAt)
                end(session)
                await session.client.close(budget: 0)
                guard isCurrent(generation) else { return }
                if lived >= policy.crashLoopWindow {
                    backoffIndex = 0
                    recentFailures = []
                }
                delay = recordFailure(MCPClientError.transport(.sessionLost))
            } catch {
                guard isCurrent(generation) else { return }
                delay = recordFailure(error)
            }
            guard let delay else { return }
            await clock.sleep(until: clock.now().addingTimeInterval(max(0, delay)))
        }
    }

    /// One session: its client, and the signal that the server forgot it.
    private struct Session {
        let client: MCPClient
        let lost: AsyncStream<Void>
    }

    /// One attempt. `nil` when the lifecycle was superseded while it connected — a stop, a
    /// restart — in which case it has written nothing. On any throw the attempt's client is
    /// closed before the error leaves: until 2026-09-23 the retry overwrote it and nothing
    /// ever closed it — its URLSession, its pump and, for a legacy server whose handshake
    /// succeeded before the listing failed, a session with a push stream, all kept until the
    /// app quit (F5).
    private func connectOnce(generation: Int) async throws -> Session? {
        if case .unsupported(let kind, _) = config.transport {
            throw MCPClientError.transport(.endpointRefused(
                "Transport \"\(kind)\" is not supported — this client speaks Streamable HTTP only."))
        }
        let http = config.transport.http
        let authorizer = StaticBearerAuthorizer.make(config: config, storage: environment.secretStorage)
        let transport = environment.makeTransport(http, authorizer, config.timeouts)
        // Named apart from the `client` property on purpose: this function assigns that
        // property, and a local of the same name makes every line after it ambiguous.
        let freshClient = MCPClient(
            transport: transport, log: log, timeouts: config.timeouts,
            credentials: { authorizer.credentialsToRedact() }, clock: clock)
        client = freshClient
        // Per session, so a late report from a session already replaced lands on a stream
        // nobody reads.
        let (lost, lostSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

        do {
            if let url = http.url { log?.noteConnect(url: url) }
            await freshClient.onNotification { [weak self] notification in
                Task { @MainActor in self?.handle(notification) }
            }
            await freshClient.onSessionLost { lostSignal.yield() }

            let connection = try await freshClient.connect(cachedEra: trustStore.cachedEra(serverID: config.id))
            guard isCurrent(generation), freshClient === client else {
                await abandon(freshClient)
                return nil
            }
            try? trustStore.cacheEra(serverID: config.id, era: connection.era)
            serverInfo = connection.serverInfo
            catalogueTTL = connection.catalogueTTL

            // The route opens only on a catalogue THIS session listed: after a reconnect
            // `descriptors` still hold the LAST session's, and opening the route on those put the
            // previous session's approved hashes on a server that may have rewritten the tools
            // since — the unreviewed-text send A1/A2 closed (review of group C, 2026-09-23).
            // One listing: if it did not commit, a newer one of this session did. Nothing checks
            // that at runtime; two facts hold it. Every listing is numbered while `client` is
            // this session — `refreshCatalogue` and `rereadCatalogue` read `client` in the same
            // turn as they number, and the listing retry numbers only while `client === session`
            // — and a lifecycle that is not current ends at the guard below.
            _ = try await refreshCatalogue()
            // The route opens HERE and nowhere else: after the listing, because a session that
            // has not listed has no approved text a call could be checked against, and in the
            // same stretch as the status turning connected, because that status is what puts
            // this server's tools in the snapshot — and the gate decides only calls the
            // snapshot shows it. A later listing (a `list_changed`, the stale sweep) only
            // updates the route this session opened; one that lands on a session that FAILED
            // must not open a route the row and the snapshot say does not exist.
            //
            // Nor may a lifecycle a `stop()` or a reconnect superseded while it listed — a
            // reply read before the stop reached the client still comes back. It is stale, and
            // it ends here, BEFORE the status as well as the route: a row marked connected
            // with no route behind it puts the server's tools in the snapshot, and the gate
            // may then hold a card for a call dispatch will refuse.
            guard isCurrent(generation), freshClient === client else {
                await abandon(freshClient)
                return nil
            }
            registry.publish(
                freshClient, approvedHashes: approvedHashes, catalogueUnverified: catalogueUnverified,
                era: connection.era, for: config.id,
                // A call the server answered `HeaderMismatch`: its tool list is read again, as for
                // a `list_changed` — the spec's "call `tools/list` to check for changes to the
                // tool's `inputSchema`" (`MCPClientRegistry.callTool`).
                onHeaderMismatch: { [weak self] in Task { @MainActor [weak self] in await self?.rereadCatalogue() } })
            status = .connected(era: connection.era)
            onChange()
            return Session(client: freshClient, lost: lost)
        } catch {
            await abandon(freshClient)
            throw error
        }
    }

    /// Closes an attempt's client, and lets go of it if this connection still holds it. The
    /// close is idempotent: a stop that already closed it costs nothing here.
    private func abandon(_ attempt: MCPClient) async {
        if client === attempt {
            client = nil
            forgetUnverifiedCatalogue()
        }
        await attempt.close(budget: 0)
    }

    /// The server forgot the session. In one main-actor turn — before the caller closes the
    /// client, with no `DELETE` budget since there is no session left to release — its route
    /// goes, the connection lets go of the client, and the row stops reading connected: a row
    /// marked connected with no route behind it puts the server's tools in the snapshot, and
    /// the gate may hold a card for a call dispatch will refuse. Until the second review of
    /// group C (2026-09-23) the status moved only once the close had returned. The failure is
    /// COUNTED after the close (`recordFailure`), and only if nothing superseded the lifecycle
    /// meanwhile — a stop during the close leaves the row Off and the backoff untouched.
    private func end(_ session: Session) {
        if client === session.client {
            client = nil
            forgetUnverifiedCatalogue()
        }
        registry.withdraw(serverID: config.id, through: session.client)
        status = .failed(reason: MCPClientError.transport(.sessionLost).message)
        onChange()
    }

    /// Classifies a failure: returns the delay before the next attempt, or `nil` when retrying
    /// cannot help — a refused endpoint, a rejected credential, a server that speaks nothing
    /// this client does will refuse identically forever; a dropped connection will not.
    ///
    /// Failures bunching up inside the crash-loop window slow the retries to the backoff
    /// table's LAST step and say so. They never stop them: until 2026-09-23 three failures in
    /// five seconds ended the loop for good, so a server that failed instantly (a desktop app
    /// not yet launched) used only the first two steps of the table and then waited for a
    /// click forever (F8).
    private func recordFailure(_ error: any Error) -> TimeInterval? {
        if let terminal = Self.terminalStatus(for: error) {
            status = terminal
            onChange()
            return nil
        }
        let now = clock.now()
        recentFailures.append(now)
        recentFailures.removeAll { now.timeIntervalSince($0) > policy.crashLoopWindow }
        let crashLooping = recentFailures.count >= policy.crashLoopFailureCount
        if crashLooping { backoffIndex = max(backoffIndex, policy.backoff.count - 1) }
        let delay = policy.delay(afterFailure: backoffIndex)
        backoffIndex += 1
        if crashLooping {
            status = .failed(reason: "This server failed \(recentFailures.count) times in a few seconds, "
                + "so it is tried only every \(Self.spoken(delay)) now. Fix it, then use Reconnect to try at once.")
        } else {
            status = .failed(reason: (error as? MCPClientError)?.message ?? "The server could not be reached.")
        }
        onChange()
        return delay
    }

    /// The status of a failure no retry can repair, or `nil` for one the loop retries.
    private static func terminalStatus(for error: any Error) -> MCPServerStatus? {
        switch error as? MCPClientError {
        case .transport(.unauthorized(_, let challenge))?:
            return .needsAuth(reason: challenge ?? "The server refused the credentials.")
        case .transport(.endpointRefused(let reason))?, .transport(.redirectRefused(_, let reason))?:
            return .unsupportedTransport(reason: reason)
        case .transport(let transport)? where !transport.isRetryable:
            // What is left that retrying cannot repair is the server's to change: a catalogue
            // past the frame ceiling.
            return .incompatible(reason: transport.message)
        case .unsupportedProtocolVersion(let offered, let serverSupports)?:
            return .incompatible(reason: MCPClientError.unsupportedProtocolVersion(
                offered: offered, serverSupports: serverSupports).message)
        case .handshakeRefused(let code, let message)?:
            // A modern server's refusal of the probe in one of its revision's own codes: the
            // next probe sends the same envelope and the same headers, so it is the server's to
            // change — or this app's — and the row says so in the server's words.
            return .incompatible(reason: MCPClientError.handshakeRefused(code: code, message: message).message)
        case .pageLimitExceeded(let limit)?:
            // A catalogue that never stops paging, and — the one `malformedResult` there is — one
            // that repeats its cursor: the listing is the server's, and it answers the same way
            // every time. Until the review of 2026-09-23 both fell through to the retrying arm and
            // were listed again every thirty seconds, forever.
            return .incompatible(reason: MCPClientError.pageLimitExceeded(limit).message)
        case .malformedResult(let detail)?:
            return .incompatible(reason: MCPClientError.malformedResult(detail).message)
        case .unknownResultType(let type)?:
            // A catalogue page that is not a finished answer — a type this client does not know,
            // or input asked for where the revision allows none: the server answers it the same
            // way every time.
            return .incompatible(reason: MCPClientError.unknownResultType(type).message)
        case .inputRequired?:
            return .incompatible(reason: MCPClientError.inputRequired.message)
        default:
            return nil
        }
    }

    /// `30 s`, `0.2 s`.
    private static func spoken(_ seconds: TimeInterval) -> String {
        String(format: "%g s", seconds)
    }

    // MARK: - Catalogue

    /// Lists, projects, pins and reconciles — the one path that turns a server's answer into
    /// something a role can hold.
    ///
    /// Returns whether this listing was ADOPTED: `false` when a newer listing had already
    /// committed by the time its reply came. Every caller can ignore the difference — the newer
    /// listing adopted the server's later word itself. The connect path, which opens its route
    /// after one listing whatever it returned, relies on WHICH session a newer listing was
    /// asked of instead: every listing is numbered while `client` is this session (this
    /// function and `rereadCatalogue` read `client` in the turn they number), and the listing
    /// retry numbers only while `client === session`, so a newer listing that committed over
    /// the connect's is always this session's.
    @discardableResult
    func refreshCatalogue() async throws -> Bool {
        guard let session = client else { throw MCPClientError.notConnected }
        listingsAsked += 1
        return try await commitListing(listingsAsked, of: session)
    }

    /// Listing number `asked`, of `session`: the reply commits iff it is newer than the newest
    /// listing that committed.
    @discardableResult
    private func commitListing(_ asked: Int, of session: MCPClient) async throws -> Bool {
        // The session's era, read before the listing: `x-mcp-header` is a keyword of the
        // 2026-07-28 revision only (`MCPToolDescriptorFactory.build`). A session's era is
        // settled by its connect and never moves, so reading it first reads the one the
        // listing is answered in.
        let era = await session.currentEra
        let raw = try await session.listAllTools()
        let extras = session.listedExtras.load()
        let rawResources = extras.resources
        let rawTemplates = extras.resourceTemplates
        let rawPrompts = extras.prompts
        // A newer listing already committed: it is the server's later word, whichever reply
        // landed last. Until 2026-09-23 the last reply to arrive won, and the row and the
        // snapshot could show a catalogue the server no longer served until its next change.
        // Compared against the newest COMMITTED listing, not the newest asked: a newer one
        // that failed — its error swallowed by a `list_changed` handler — left nothing behind,
        // and dropping this success too kept the route on the pre-change hashes (second review
        // of group C, 2026-09-23).
        guard asked > committedListing else { return false }
        committedListing = asked
        // Asked after the listing that failed, so it read whatever that one should have: the
        // catalogue is verified again, and the adoption below restores the route.
        if let since = unverifiedSince, asked > since { unverifiedSince = nil }
        lastRefresh = clock.now()

        do {
            let outcome = try MCPToolDescriptorFactory.build(
                rawTools: raw,
                rawResources: rawResources,
                rawResourceTemplates: rawTemplates,
                slug: config.slug,
                era: era)
            let promptOutcome = MCPToolDescriptorFactory.buildPrompts(
                rawPrompts: rawPrompts,
                slug: config.slug)
            descriptors = outcome.descriptors
            promptDescriptors = promptOutcome.prompts
            rejections = outcome.rejections + promptOutcome.rejections
            catalogueError = nil
            refusedModelFacingNames = MCPToolDescriptorFactory.unofferedModelFacingNames(
                of: raw, slug: config.slug, offered: outcome.descriptors)
        } catch let error as MCPToolDescriptorFactory.CatalogueError {
            // The namespace itself is unusable, so no tool of this server reaches a prompt —
            // but the connection is fine, and saying "not connected" would send the user to
            // the wrong repair.
            descriptors = []
            promptDescriptors = []
            rejections = []
            catalogueError = error.errorDescription
            refusedModelFacingNames = MCPToolDescriptorFactory.unofferedModelFacingNames(
                of: raw, slug: config.slug, offered: [])
            adoptTrustRecord()
            onChange()
            return true
        }

        var liveHashes = Dictionary(
            descriptors.map { ($0.originalName, $0.pinHash) }, uniquingKeysWith: { first, _ in first })
        for prompt in promptDescriptors where liveHashes[prompt.pinKey] == nil {
            liveHashes[prompt.pinKey] = prompt.pinHash
        }
        // One pass over the pins: mark what vanished, clear what came back, and drop the
        // standing grant of anything published at another hash than the one approved.
        try? trustStore.reconcile(serverID: config.id, liveHashes: liveHashes)
        adoptTrustRecord()
        let diff = trustStore.pinDiff(serverID: config.id, liveHashes: liveHashes)
        for name in diff.newNames { log?.notePin(tool: name, state: "new") }
        for name in diff.changedNames { log?.notePin(tool: name, state: "changed") }
        onChange()
        return true
    }

    /// The server says its list moved.
    private func handle(_ notification: JSONRPCNotification) {
        guard MCPWire.catalogueListChangedNotifications.contains(notification.method) else { return }
        Task { [weak self] in await self?.rereadCatalogue() }
    }

    /// The server says its list moved (`list_changed`), or its stated lifetime ran out (the
    /// manager's stale sweep): list again.
    ///
    /// A listing that FAILS on the live session leaves the catalogue unverified — the server
    /// said its tools changed and nothing has read what they are now. Until the third pass of
    /// group C's second review (2026-09-23) the failure was swallowed and nothing listed again:
    /// the route kept the pre-change approvals, and a call built from the old text went out to
    /// whatever the server served since. A listing that SUCCEEDS withdraws nothing, not even
    /// while it is in flight — a normal change opens no window of refusals.
    func rereadCatalogue() async {
        #if DEBUG
        defer { _testRereadsFinished += 1 }
        #endif
        guard let session = client else { return }
        listingsAsked += 1
        let asked = listingsAsked
        do {
            try await commitListing(asked, of: session)
        } catch {
            catalogueListingFailed(asked, on: session)
        }
    }

    /// Listing `asked` should have read a change — the server's `list_changed`, or its stated
    /// catalogue lifetime running out — and failed. On the session it was asked of, if that is
    /// still this connection's, and unless a newer listing has committed meanwhile (it read
    /// the change): the catalogue is unverified, and the route is marked so through that
    /// session, keeping the hashes of the listing that last committed — dispatch refuses every
    /// call, as changed when its text is not one of those, else as a tool list being read
    /// again. The manager, rebuilt in the same turn, ships none of this server's tools and
    /// hands the live catalogue that listing's approvals, so the gate and the drift check give
    /// the same refusal and no card is held for a call dispatch would refuse. The listing is
    /// asked again on the reconnect backoff.
    ///
    /// A second failure moves the mark to ITS listing (`max`): a retry already in flight was
    /// asked before that change, and must not verify it.
    private func catalogueListingFailed(_ asked: Int, on session: MCPClient) {
        guard client === session, asked > committedListing else { return }
        unverifiedSince = max(unverifiedSince ?? 0, asked)
        adoptTrustRecord()
        onChange()
        beginListingRetry(on: session)
    }

    private func beginListingRetry(on session: MCPClient) {
        guard listingRetry == nil else { return }
        listingRetryNumber += 1
        let number = listingRetryNumber
        listingRetry = Task { [weak self] in
            await self?.relistUntilVerified(on: session)
            self?.listingRetryEnded(number)
        }
    }

    /// Lists again, on the reconnect backoff and its clock, until a listing commits — which
    /// verifies the catalogue and restores the route through the ordinary adoption — or the
    /// session stops being this connection's.
    private func relistUntilVerified(on session: MCPClient) async {
        var failures = 0
        while catalogueUnverified, client === session, !Task.isCancelled {
            await clock.sleep(until: clock.now().addingTimeInterval(policy.delay(afterFailure: failures)))
            guard catalogueUnverified, client === session, !Task.isCancelled else { return }
            listingsAsked += 1
            do {
                try await commitListing(listingsAsked, of: session)
            } catch {
                failures += 1
            }
        }
    }

    private func listingRetryEnded(_ number: Int) {
        guard number == listingRetryNumber else { return }
        listingRetry = nil
    }

    /// The session the mark was about is over: its retry ends, and the next session's first
    /// listing is what verifies a catalogue.
    private func forgetUnverifiedCatalogue() {
        listingRetry?.cancel()
        listingRetry = nil
        unverifiedSince = nil
    }

    /// Whether the catalogue is unverified: a listing that should have read a change — its
    /// `list_changed`, or its stated catalogue lifetime running out — failed, and none asked
    /// after it has committed. The manager ships none of this server's tools while it is
    /// (`MCPGrantCatalogue.Server.catalogueUnverified`), answering each from `descriptors` —
    /// still the last committed listing — and the route refuses every call (`MCPClientRegistry`).
    var catalogueUnverified: Bool { unverifiedSince != nil }

    /// Whether the server's own catalogue lifetime has run out. Read by the manager's periodic
    /// sweep rather than by a timer per connection — a timer per server is a wake-up per
    /// server, and most of them never change.
    var catalogueIsStale: Bool {
        guard let catalogueTTL, let lastRefresh else { return false }
        return clock.now().timeIntervalSince(lastRefresh) > catalogueTTL
    }

    // MARK: - Reading

    /// Re-reads this server's record from the store — memory, not disk — and re-derives every
    /// live tool's state from it. The one place `trustRecord` and `pinStates` move, so the two
    /// can never disagree.
    ///
    /// Also where the registry's route learns the approvals moved: an approval, a revocation
    /// or a refusal changes which texts a call may reach, and a call made against a text that
    /// stopped being approved a moment ago must be refused at dispatch, not sent. Only through
    /// this connection's own session: a stopped connection has none, and the route for its
    /// server may already be a successor's (`MCPClientRegistry.updateApprovedHashes`). The
    /// unverified mark rides in the same write, so a listing that verifies the catalogue hands
    /// the route its new hashes and lifts the mark at once.
    func adoptTrustRecord() {
        let record = trustStore.record(for: config.id)
        if record != trustRecord { trustRecord = record }
        var states: [String: MCPPinState] = [:]
        for descriptor in descriptors {
            states[descriptor.originalName] = pinState(of: descriptor)
        }
        for prompt in promptDescriptors {
            states[prompt.pinKey] = pinState(of: prompt)
        }
        if states != pinStates { pinStates = states }
        if let client {
            registry.updateApprovedHashes(
                approvedHashes, catalogueUnverified: catalogueUnverified, for: config.id, through: client)
        }
    }
}
