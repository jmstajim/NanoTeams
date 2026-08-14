import Foundation

/// Polls the configured LLM server on a background interval and exposes reachability
/// as observable state. Injected into the environment from the app entry point so
/// polling lifecycle is independent of view rendering.
///
/// Three ways in besides the poll loop:
/// - `checkNow()` — an out-of-band probe fired by an explicit user gesture (opening
///   the status-bar model picker). Without it the pill is up to `interval` stale,
///   which is exactly the window a user stares at after starting their server.
/// - `noteReachable()` — one-way positive evidence from a caller that reached the
///   same endpoint by another route (a successful model-list fetch). See
///   `ModelCatalog.refresh`'s return value for why that is proof.
/// - `noteProbeOutcome(reachable:)` — both directions of a foreign probe's verdict
///   (Test Connection): positive is accepted directly, negative triggers a
///   self-probe so the pill can turn red without waiting out the poll interval.
@Observable @MainActor
final class LLMStatusMonitor {
    /// How long a server may take to answer and still count as reachable. Named
    /// rather than inlined because reachability is ONE bit written by two kinds of
    /// evidence — this probe, and `noteReachable()` from callers whose own request
    /// used a different (looser) timeout. The asymmetry is deliberate and one-way:
    /// a slower answer can only turn the pill green, never red.
    nonisolated static let probeTimeout: TimeInterval = 2.0

    nonisolated struct Endpoint: Equatable {
        let baseURL: String
        let provider: LLMProvider

        init(_ pair: (baseURL: String, provider: LLMProvider)) {
            self.baseURL = pair.baseURL
            self.provider = pair.provider
        }
    }

    private(set) var isReachable: Bool = false
    private(set) var lastCheckedAt: Date?
    /// A probe is in flight. Rendered only where the user just asked for a check
    /// (the model picker's popover) — never on the pill, which would otherwise
    /// blink for up to 2 s every `interval` for a check nobody requested.
    private(set) var isChecking: Bool = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Bool, Never>?
    /// The endpoint the in-flight probe is measuring. Coalescing is only sound
    /// against the SAME endpoint: a provider flip rewrites URL + model with no Test
    /// Connection, so a caller arriving inside the ≤2 s probe window would otherwise
    /// inherit a verdict about the server it just navigated away from — and, in the
    /// direction that does not self-heal, publish `true` for a host never contacted.
    @ObservationIgnored private var probeEndpoint: Endpoint?
    /// Bumped on every probe start AND in `stopMonitoring`. See the identity guard
    /// in `checkNow`.
    @ObservationIgnored private var probeGeneration = 0
    @ObservationIgnored private var endpointProvider:
        (@MainActor () -> (baseURL: String, provider: LLMProvider))?
    @ObservationIgnored private let session: any NetworkSession

    /// `session` is the house DIP-for-NetworkSession seam that `LLMConnectionChecker`
    /// already accepts, so tests drive real probe classification rather than stubbing
    /// the checker out from under it.
    init(session: any NetworkSession = URLSession.shared) {
        self.session = session
    }

    /// Starts a background polling loop. `endpointProvider` is a closure so the monitor
    /// picks up live configuration changes (URL AND provider) without restart. Runs on
    /// the main actor so the provider can read `@MainActor`-isolated state directly.
    func startMonitoring(
        endpointProvider: @escaping @MainActor () -> (baseURL: String, provider: LLMProvider),
        interval: TimeInterval = 120
    ) {
        stopMonitoring()
        self.endpointProvider = endpointProvider
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // The loop does NOT probe directly: it goes through the same
                // primitive as the manual path, so there is exactly one in-flight
                // slot and exactly one writer of `isReachable`. Opening the picker
                // during a loop tick therefore costs zero extra requests and cannot
                // publish out of order.
                _ = await self.checkNow()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Probes now, out of band with the poll loop. Coalesces onto any probe already
    /// in flight, so re-opening the picker cannot fan out into N requests.
    ///
    /// Deliberately does NOT restart the poll loop: restarting would re-phase the
    /// interval on every picker open, so a user who touches the picker more often
    /// than `interval` would never get a background poll again.
    @discardableResult
    func checkNow() async -> Bool {
        // No endpoint installed (never wired, or stopped) — nothing to probe.
        guard let endpointProvider else { return isReachable }
        let endpoint = Endpoint(endpointProvider())

        // Coalesce only against a probe measuring the SAME endpoint. Inheriting a
        // verdict about a different server is worse than paying for a second probe.
        if let inFlight = probeTask, probeEndpoint == endpoint { return await inFlight.value }
        // A probe for a stale endpoint can no longer speak for us: cancel it and
        // bump the generation so it cannot publish or clear the new slot.
        if probeTask != nil {
            probeTask?.cancel()
            probeTask = nil
            probeGeneration &+= 1
        }

        probeGeneration &+= 1
        let generation = probeGeneration
        let session = self.session
        // Set on the CALLER's frame, before any suspension, so two `checkNow()`
        // calls in one synchronous frame cannot both start a probe.
        isChecking = true

        let task = Task { @MainActor [weak self] () -> Bool in
            let reachable = await LLMConnectionChecker.check(
                baseURL: endpoint.baseURL,
                provider: endpoint.provider,
                timeout: Self.probeTimeout,
                session: session
            )
            guard let self else { return reachable }

            // IDENTITY GUARD. A probe cancelled by `stopMonitoring` / `startMonitoring`
            // resumes fast (URLError.cancelled), possibly AFTER a newer probe has taken
            // the slot. Clearing `probeTask` unconditionally would nil the LIVE handle,
            // and the next `checkNow()` would start a second concurrent probe — breaking
            // the single-slot invariant this method exists to hold.
            if self.probeGeneration == generation {
                self.probeTask = nil
                self.probeEndpoint = nil
                self.isChecking = false
            }
            // Honour a stop that landed mid-probe: never publish after teardown.
            guard !Task.isCancelled else { return reachable }
            self.publish(reachable)
            return reachable
        }
        // Safe: we are on MainActor and the body is @MainActor, so the body cannot
        // start until this frame suspends at the `await` below.
        probeTask = task
        probeEndpoint = endpoint
        return await task.value
    }

    /// Positive-only evidence from a caller that reached the same endpoint another
    /// way. One-way by construction: a failed fetch proves nothing (401 = reachable
    /// but unauthorized; a decode error = reachable but mismatched), so only a probe
    /// can ever turn the pill red.
    func noteReachable() {
        publish(true)
    }

    /// Evidence from a foreign probe (Test Connection). Positive evidence is
    /// accepted directly — the same 2xx-from-the-same-path argument as
    /// `noteReachable`. Negative evidence is NOT trusted: the foreign probe's
    /// bearer token may differ from the token the monitor resolves from Keychain,
    /// so a failure there is evidence, not a verdict — it triggers an
    /// authoritative self-probe (`checkNow`, own credentials), which CAN turn the
    /// pill red. `publish(false)` therefore still has exactly one writer.
    func noteProbeOutcome(reachable: Bool) async {
        if reachable {
            noteReachable()
        } else {
            _ = await checkNow()
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        probeTask?.cancel()
        probeTask = nil
        probeEndpoint = nil
        // Invalidate any probe still resuming, so its identity guard fails and it
        // cannot clear a future slot or a future `isChecking`.
        probeGeneration &+= 1
        // The canceller owns the flag: the cancelled probe's guard returns without
        // clearing it, so without this a stop mid-probe strands `isChecking == true`
        // and the picker shows "Checking server…" forever.
        isChecking = false
        endpointProvider = nil
    }

    private func publish(_ reachable: Bool) {
        isReachable = reachable
        // Elapsed-time marker for display, not an ordering source — `Date()` is the
        // right clock here (and is what this property has always carried).
        lastCheckedAt = Date()
    }

    nonisolated deinit {
        pollTask?.cancel()
        probeTask?.cancel()
    }
}
