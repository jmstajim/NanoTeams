import Foundation
import Observation

/// Measures a list of models one after another, and owns the only cancellable task the benchmark
/// screen has.
///
/// **A single run is a sweep of one.** The Run button builds a one-entry plan and comes through
/// this same loop, so there is one door, one Cancel and one "is anything measuring" predicate
/// rather than two of each that have to agree. `GenerationBenchmarkRunner` measures one model and
/// no longer owns a `Task` at all: the thing that decides how many models are measured is the
/// thing that should decide when to stop.
///
/// Lives for the app's lifetime, not the screen's. `BenchmarkSettingsView` is torn down by a
/// Settings tab switch, so a sweep held in its `@State` would lose its progress the moment the
/// user looked at anything else — during an hour of work they certainly will. Closing Settings
/// deliberately does NOT cancel: the measurements already paid for keep being taken, and the
/// screen finds them still going when it comes back.
@MainActor
@Observable
final class BenchmarkSweepRunner {

    enum Phase: Equatable, Sendable {
        case idle
        case measuring(index: Int, of: Int)
        case finished(measured: Int, failed: Int, skipped: Int)
        case stopped(StopReason, measured: Int)
    }

    enum StopReason: Equatable, Sendable {
        case cancelled
        /// A team task started streaming. Every sample taken from here on would be voided
        /// `.concurrentActivity` anyway, so the sweep stops instead of spending an hour
        /// producing them.
        case taskStartedRunning
    }

    private(set) var phase: Phase = .idle
    /// One row per provider — what was looked for, where, and what it answered.
    private(set) var servers: [BenchmarkSweepServer] = []
    private(set) var entries: [BenchmarkSweepEntry] = []

    /// Bumped once per entry reaching a terminal state.
    ///
    /// A counter rather than a phase, because the history table reloads on this edge and two
    /// consecutive targets that both fail produce an identical phase twice — `onChange` would see
    /// no change and miss the second (CLAUDE.md #34).
    private(set) var settledCount = 0

    /// The door, and the reason it is a stored flag rather than `runner.isRunning`: that property
    /// is derived from a `phase` assigned INSIDE the measuring task, so two callers arriving in
    /// the same runloop turn would both read `.idle` and both proceed. This is set synchronously,
    /// before the task is spawned.
    private(set) var isMeasuring = false

    /// A scan is in flight.
    ///
    /// Its own property rather than a `Phase` case. Scanning and measuring are different questions
    /// with different answers ("what is out there" / "how fast is this"), and the moment they
    /// shared one slot the end of a scan wrote `.idle` over whatever the measuring loop had just
    /// published.
    private(set) var isScanning = false

    /// The single-model engine. Exposed so the card can render its per-sample phase; it has no
    /// control surface left to misuse.
    let runner: GenerationBenchmarkRunner
    let history: BenchmarkHistoryStore

    /// More than one model is being measured, so the progress belongs to the sweep.
    var isSweeping: Bool { isMeasuring && entries.count > 1 }

    /// The per-sample phase belonging to a SINGLE-model run, and `.idle` while a sweep is running.
    ///
    /// Without the distinction the single-model card would render the sweep's ninth model as
    /// "Sample 3 of 5…" directly under its own target's name — narrating someone else's work under
    /// this one's label, which is worse than saying nothing.
    var singleRunPhase: GenerationBenchmarkRunner.Phase {
        isSweeping ? .idle : runner.phase
    }

    /// The result of the last SINGLE-model run, hidden for the same reason while a sweep runs: the
    /// figures under the target's name would be another model's.
    var singleRunSummary: BenchmarkMetricsPolicy.RunSummary? {
        isSweeping ? nil : runner.summary
    }

    private let discovery: any BenchmarkModelDiscovering
    /// Whether any other LLM stream is in flight. Read BETWEEN targets here and per-sample inside
    /// the runner — one fact with one producer, two readers that ask it at the granularity each
    /// can act on.
    private let isBusy: @MainActor () -> Bool
    private let settings: any BenchmarkSweepSettings

    private var task: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    init(
        runner: GenerationBenchmarkRunner,
        history: BenchmarkHistoryStore,
        discovery: any BenchmarkModelDiscovering,
        isBusy: @escaping @MainActor () -> Bool,
        settings: any BenchmarkSweepSettings
    ) {
        self.runner = runner
        self.history = history
        self.discovery = discovery
        self.isBusy = isBusy
        self.settings = settings
        let excluded = settings.benchmarkExcludedProviders
        self.servers = LLMProvider.allCases.map { provider in
            // What the app knows, or — failing that — the provider's documented default. The
            // default is proposed only because this value lands in an editable, labelled field the
            // user reads before pressing anything; that visibility is the entire licence for it.
            let known = settings.knownLLMEndpoints(for: provider).first
            return BenchmarkSweepServer(
                provider: provider,
                baseURLString: known ?? provider.defaultBaseURL,
                isIncluded: !excluded.contains(provider),
                isProposedAddress: known == nil)
        }
    }

    // MARK: - Scan

    /// Asks every included provider what it offers, then rebuilds the plan.
    ///
    /// Sequential, and guarded against itself: `ModelCatalog.refresh` returns false without
    /// waiting when a fetch for the same key is already in flight, so two overlapping scans would
    /// make each other's answers `.undetermined`.
    func scan() async {
        await beginScan(onlyUnanswered: false)
    }

    /// Scans only the rows that have never answered.
    ///
    /// What the screen calls when it appears, so the Run button is honest about which servers it
    /// will clear without the user having pressed anything — and so a Settings tab switch, which
    /// destroys the view but not this object, does not re-interrogate two servers every time.
    func scanIfNeeded() async {
        await beginScan(onlyUnanswered: true)
    }

    /// Runs the scan in a task this object owns, then waits for it.
    ///
    /// The unstructured `Task` is the point. The caller is a SwiftUI `.task`, whose cancellation
    /// arrives on every Settings tab switch — and a cancelled model listing does not come back
    /// empty, it comes back as a transport error, which `classify` would faithfully record as
    /// `no answer` for a server that was simply no longer being asked. An answer nobody waited for
    /// must not become a fact about the machine.
    ///
    /// A second caller arriving mid-scan waits for the first rather than starting another: two
    /// overlapping scans coalesce inside `ModelCatalog` and make each other's results
    /// `.undetermined`.
    private func beginScan(onlyUnanswered: Bool) async {
        guard !isMeasuring else { return }
        if isScanning {
            await scanTask?.value
            return
        }
        isScanning = true
        let task = Task { [weak self] () -> Void in
            await self?.performScan(onlyUnanswered: onlyUnanswered)
        }
        scanTask = task
        await task.value
    }

    private func performScan(onlyUnanswered: Bool) async {
        defer {
            isScanning = false
            scanTask = nil
        }
        for index in servers.indices {
            let row = servers[index]
            guard row.isIncluded, !row.baseURLString.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                servers[index].outcome = nil
                continue
            }
            // `.undetermined` is not an answer, so a needs-only scan retries it. That is the
            // whole reason it is a case of its own rather than folded into `.noAnswer`.
            if onlyUnanswered, let outcome = row.outcome, outcome != .undetermined { continue }
            let outcome = await discovery.chatModels(on: row.server)
            // Re-read the index after the suspension: the row may have been edited or switched
            // off while the server was being asked, and writing the answer back by position would
            // staple it to whatever now sits there (CLAUDE.md #54).
            guard let current = servers.firstIndex(where: { $0.provider == row.provider }),
                  servers[current].server == row.server
            else { continue }
            servers[current].outcome = outcome
        }
        rebuildPlan()
    }

    /// Switching a provider off means it literally: none of its models are measured, AND nothing
    /// on it is unloaded. Persisted, because that second half is a safety statement and one that
    /// evaporated on relaunch would re-arm the unloads without telling anyone.
    func setIncluded(_ included: Bool, for provider: LLMProvider) {
        guard let index = servers.firstIndex(where: { $0.provider == provider }) else { return }
        servers[index].isIncluded = included
        var excluded = settings.benchmarkExcludedProviders
        if included { excluded.remove(provider) } else { excluded.insert(provider) }
        settings.benchmarkExcludedProviders = excluded
        rebuildPlan()
    }

    /// A retyped address invalidates what the old one answered. Keeping the outcome would let a
    /// row read "12 models" about a server it no longer points at.
    func setEndpoint(_ url: String, for provider: LLMProvider) {
        guard let index = servers.firstIndex(where: { $0.provider == provider }) else { return }
        guard servers[index].baseURLString != url else { return }
        servers[index].baseURLString = url
        servers[index].outcome = nil
        // Typed by the user, so it is no longer a proposal — whatever it now says.
        servers[index].isProposedAddress = false
        rebuildPlan()
    }

    /// Models the user has ticked OFF, by entry id.
    ///
    /// Held here rather than on the entries because `rebuildPlan` regenerates those from scratch
    /// on every rescan and endpoint edit — a selection stored only on the row would be silently
    /// restored to "all" by a Rescan, which is the one press most likely to follow a careful
    /// deselection. Deselected-set rather than selected-set so a model that appears for the first
    /// time is included by default, which is what "all models" means.
    private var deselected: Set<String> = []

    /// Ticks one model in or out of the next run.
    func setSelected(_ selected: Bool, entryID: String) {
        guard !isMeasuring else { return }
        if selected { deselected.remove(entryID) } else { deselected.insert(entryID) }
        applySelection()
    }

    /// Ticks every model in the plan in or out at once.
    func setAllSelected(_ selected: Bool) {
        guard !isMeasuring else { return }
        deselected = selected ? [] : Set(entries.map(\.id))
        applySelection()
    }

    /// What "Run N models" will actually measure.
    var selectedEntries: [BenchmarkSweepEntry] { entries.filter(\.isSelected) }

    private func applySelection() {
        for index in entries.indices {
            entries[index].isSelected = !deselected.contains(entries[index].id)
        }
    }

    private func rebuildPlan() {
        guard !isMeasuring else { return }
        entries = BenchmarkSweepPlan.entries(from: servers)
        applySelection()
        settledCount = 0
    }

    // MARK: - Control

    /// Measures every SELECTED model the scan found, in plan order.
    ///
    /// Hands the loop the WHOLE list, not the selected subset, and lets it skip the rest. Passing
    /// only the subset would drop the unticked models off the screen for the duration of the run
    /// and leave them there afterwards — so the checkbox the user would need to put one back would
    /// be gone along with it.
    func startSweep() {
        start(entries: entries)
    }

    /// Picks a stopped sweep back up where it left off, keeping what was already measured.
    ///
    /// The entries are reused rather than rebuilt from a fresh plan: rebuilding would re-measure
    /// the models the stopped sweep already paid for, and their runs are already on disk. Entries
    /// the stop marked `.skipped` go back to `.pending` — that state means "never attempted", so
    /// it is precisely the set a resume is for.
    func resumeSweep() {
        guard canResume else { return }
        var plan = entries
        for index in plan.indices where plan[index].state == .skipped {
            plan[index].state = .pending
        }
        start(entries: plan)
    }

    /// A stopped sweep with something left to measure. `.finished` cannot be resumed — there is
    /// nothing left — and neither can a plan whose every entry settled.
    ///
    /// Selected entries only: an unticked model sits at `.pending` for the life of the plan, so
    /// counting it would leave Resume permanently offering to finish a sweep that is finished.
    var canResume: Bool {
        guard !isMeasuring, case .stopped = phase else { return false }
        return entries.contains {
            $0.isSelected && ($0.state == .skipped || $0.state == .pending)
        }
    }

    /// Measures one model — the Run button. Same loop, same Cancel, plan of length one.
    func measureOne(_ target: BenchmarkTarget) {
        start(entries: [BenchmarkSweepEntry(target: target)])
    }

    private func start(entries plan: [BenchmarkSweepEntry]) {
        // Not while a scan is in flight: the scan's own model listings would be running against
        // the server being measured, and its final `rebuildPlan()` would replace the plan out from
        // under the loop that is walking it.
        guard !isMeasuring, !isScanning, !plan.isEmpty else { return }
        isMeasuring = true
        entries = plan
        settledCount = 0
        task = Task { [weak self] in
            await self?.runLoop()
            self?.isMeasuring = false
            self?.task = nil
        }
    }

    /// Stops after cancelling whatever is in flight. Samples already taken are still recorded — a
    /// partial run is evidence, and discarding it would hide that the machine was measured at all.
    func cancel() {
        task?.cancel()
    }

    // MARK: - The loop

    private func runLoop() async {
        /// Addresses that stopped answering. Entered only on POSITIVE evidence — a question that
        /// went out and came back with nothing — never on a measurement failure alone, since a
        /// model can fail for its own reasons on a perfectly healthy server (CLAUDE.md #92).
        var silentServers: Set<String> = []
        /// Counted over the SELECTED entries only, so "measuring 3 of 12" agrees with the button
        /// that said "Run 12 models" rather than with however many rows happen to be on screen.
        let planned = entries.count(where: \.isSelected)
        var position = 0

        for index in entries.indices {
            if Task.isCancelled { break }

            // Left at `.pending` rather than marked skipped: the user did not ask for this one, and
            // "not measured" is a statement about a sweep that tried and could not.
            guard entries[index].isSelected else { continue }

            // Between targets, not mid-stream: the run in flight when a task starts is already
            // handled per-sample by the runner's own `isBusy` check, which voids the contaminated
            // samples. What this prevents is the next fifteen models being measured against a busy
            // machine and quietly producing fifteen useless rows.
            if isBusy() {
                settle(.taskStartedRunning)
                return
            }

            let target = entries[index].target
            // Already settled — this is a resumed sweep walking past what the last one measured.
            if entries[index].state.isSettled { continue }

            let address = target.baseURLString.normalizedBaseURL
            // One cheap GET before committing to minutes of streaming. A server that has stopped
            // answering costs `repeats + 1` requests that each wait out the full request timeout,
            // and it costs that on every remaining model — so the governor is asked per target,
            // not once per server. Written as two statements because `await` cannot live inside
            // `||`'s short-circuiting autoclosure; the ordering is the point either way, since a
            // server already known silent must not be asked again.
            var isSilent = silentServers.contains(address)
            if !isSilent {
                isSilent = await !discovery.isAnswering(target.server)
            }
            if isSilent {
                silentServers.insert(address)
                entries[index].state = .skipped
                settledCount += 1
                continue
            }

            entries[index].state = .measuring
            position += 1
            phase = .measuring(index: position, of: planned)

            let outcome = await runner.run(
                config: settings.benchmarkConfig(for: target),
                repeats: settings.benchmarkRepeats,
                otherServers: otherServers(excluding: target.server))

            if let failure = outcome.failure {
                entries[index].state = .failed(failure)
            } else if let recorded = outcome.recorded {
                entries[index].state = .measured(recorded.summary)
            } else {
                // Cancelled, or refused because something else was measuring. Nothing was recorded
                // and nothing was learned about the model, so this is not a failure of it.
                entries[index].state = .skipped
            }
            settledCount += 1
        }

        if Task.isCancelled {
            settle(.cancelled)
        } else {
            phase = .finished(
                measured: tally.measured, failed: tally.failed, skipped: tally.skipped)
        }
    }

    /// Marks everything still unreached as never-attempted and settles the phase.
    ///
    /// Takes no index. It used to take the loop position and mark `tail >= index`, which was
    /// silently a no-op on the cancellation path — that call passed `entries.count`, so the
    /// predicate was false for every entry and the tail stayed `.pending` forever: a stopped sweep
    /// that looked like it was still about to measure fifteen models. Any entry that is not
    /// settled is by definition one this pass did not reach, so the position was never the
    /// question.
    ///
    /// `.skipped`, never `.failed`: a sweep that was stopped has learned nothing about the models
    /// it did not reach, and marking them failed would libel every one of them — and would put
    /// them beyond the reach of Resume, which is defined on exactly that set.
    private func settle(_ reason: StopReason) {
        for index in entries.indices
            where entries[index].isSelected && !entries[index].state.isSettled {
            entries[index].state = .skipped
        }
        settledCount += 1
        phase = .stopped(reason, measured: tally.measured)
    }

    /// Counted from the entries rather than accumulated in the loop, so a RESUMED sweep reports
    /// the whole plan's outcome instead of only what this pass happened to touch.
    private var tally: (measured: Int, failed: Int, skipped: Int) {
        var measured = 0, failed = 0, skipped = 0
        for entry in entries {
            switch entry.state {
            case .measured: measured += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            case .pending, .measuring: break
            }
        }
        return (measured, failed, skipped)
    }

    /// The servers this run may clear: every included one that ANSWERED a scan, minus the target's
    /// own. A server earns the right to receive an unload command by having answered a read.
    func otherServers(excluding target: BenchmarkServer) -> [BenchmarkServer] {
        BenchmarkSweepPlan.verifiedServers(from: servers)
            .filter { !$0.isSameServer(as: target) }
    }
}
