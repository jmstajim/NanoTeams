import SwiftUI

/// Settings → Support → Benchmark. Measures how fast a model generates, and keeps a sortable
/// history so "which model is fastest on this machine" is answered by a table rather than memory.
///
/// The screen owns its OWN provider / endpoint / model. Measuring a model must not switch the app
/// onto it, so nothing here writes to the active LLM settings — `StoreConfiguration.benchmarkTarget`
/// is a separate persisted value, seeded once from the app's settings and independent afterwards.
///
/// What it does NOT own is the measuring itself. `BenchmarkSweepRunner` lives at app root, because
/// a sweep over every model on the machine takes the better part of an hour and this view is torn
/// down by every Settings tab switch.
struct BenchmarkSettingsView: View {
    @Environment(NTMSOrchestrator.self) private var store
    @Environment(StoreConfiguration.self) private var config
    @Environment(ModelCatalog.self) private var modelCatalog
    @Environment(BenchmarkSweepRunner.self) private var sweep

    /// Which of the two ways to measure is on screen.
    ///
    /// One at a time rather than stacked, because they are alternatives, not steps: both cards
    /// carry a provider, an endpoint and a Run button, and showing them together asks the reader to
    /// work out which pair of controls the button below belongs to. The sweep keeps running while
    /// the other mode is shown — the switch changes what is displayed, never what is measuring.
    enum Mode: String, CaseIterable, Hashable {
        case single = "Run"
        case all = "All models"
    }

    @State private var mode: Mode = .single
    @State private var runs: [GenerationBenchmarkRun] = []
    @State private var samples: [GenerationBenchmarkSample] = []
    /// Set only when a delete could not do what its confirmation promised. Cleared by the next
    /// successful one — a stale error under a table that no longer holds the rows would be its own
    /// small lie.
    @State private var deletionError: String?

    var body: some View {
        @Bindable var config = config

        ScrollView {
            VStack(spacing: Spacing.xl) {
                switch mode {
                case .single:
                    BenchmarkRunCard(
                        target: Binding(
                            get: { config.benchmarkTarget ?? BenchmarkTarget(seededFrom: config.globalLLMConfig) },
                            set: { config.benchmarkTarget = $0 }),
                        repeats: $config.benchmarkRepeats,
                        availableModels: modelCatalog.models(for: target.baseURLString, provider: target.provider),
                        selectedModelInfo: modelCatalog.info(
                            for: target.baseURLString,
                            provider: target.provider,
                            modelName: target.modelName),
                        isFetchingModels: modelCatalog.isFetching(target.baseURLString, provider: target.provider),
                        onRefreshModels: {
                            Task {
                                _ = await modelCatalog.refresh(
                                    url: target.baseURLString, provider: target.provider)
                            }
                        },
                        onUseAppSettings: {
                            config.benchmarkTarget = BenchmarkTarget(seededFrom: config.globalLLMConfig)
                        },
                        wireConfig: benchmarkConfig,
                        // The SINGLE run's phase, which is `.idle` while a sweep is measuring — a
                        // sweep's ninth model must not report "Sample 3 of 5" under this target's
                        // name.
                        phase: sweep.singleRunPhase,
                        summary: sweep.singleRunSummary,
                        blockReason: blockReason,
                        modePicker: modePicker,
                        onRun: { sweep.measureOne(target) },
                        onCancel: { sweep.cancel() })

                case .all:
                    BenchmarkSweepCard(
                        servers: sweep.servers,
                        entries: sweep.entries,
                        phase: sweep.phase,
                        targetPhase: sweep.runner.phase,
                        isMeasuring: sweep.isMeasuring,
                        isScanning: sweep.isScanning,
                        canResume: sweep.canResume,
                        // Not `blockReason`: a sweep in flight puts Cancel where Run was, so this
                        // card never needs to explain its own measuring to itself.
                        blockReason: store.hasRunningTasks ? .taskRunning : nil,
                        badges: modelBadges,
                        repeats: $config.benchmarkRepeats,
                        wireConfig: sweepWireConfig,
                        onSetIncluded: { sweep.setIncluded($1, for: $0) },
                        onSetEndpoint: { sweep.setEndpoint($1, for: $0) },
                        onSetSelected: { sweep.setSelected($1, entryID: $0) },
                        onSetAllSelected: { sweep.setAllSelected($0) },
                        onRescan: { Task { await sweep.scan() } },
                        onRunAll: { sweep.startSweep() },
                        onResume: { sweep.resumeSweep() },
                        onCancel: { sweep.cancel() },
                        modePicker: modePicker)
                }

                BenchmarkResultsCard(
                    runs: runs, samples: samples,
                    onDelete: { ids in apply(sweep.history.delete(runIDs: ids)) },
                    onClearAll: { apply(sweep.history.clear()) },
                    isMeasuring: sweep.isMeasuring)

                if let deletionError {
                    Text(deletionError)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
        .task {
            if config.benchmarkTarget == nil {
                config.benchmarkTarget = BenchmarkTarget(seededFrom: config.globalLLMConfig)
            }
            reload()
            // Ask each provider what it has, once per app session unless the user rescans. This is
            // what makes the single Run button honest without a prior press: the servers a run
            // will CLEAR are the ones that answered here, and they are on screen before it starts.
            await sweep.scanIfNeeded()
        }
        // Fetch the model list for whatever the target points at, and re-fetch when it moves. The
        // catalog is idempotent, so this costs one request per distinct (endpoint, provider).
        .task(id: catalogKey) {
            await modelCatalog.loadIfNeeded(url: target.baseURLString, provider: target.provider)
        }
        // One edge per settled measurement. A counter rather than the phase, because a sweep whose
        // 3rd and 4th models both fail produces an identical phase twice and `onChange` would see
        // no change (CLAUDE.md #34). The other thing that changes the history is a delete, which
        // reloads from its own callback.
        .onChange(of: sweep.settledCount) { _, _ in reload() }
    }

    private var target: BenchmarkTarget {
        config.benchmarkTarget ?? BenchmarkTarget(seededFrom: config.globalLLMConfig)
    }

    /// The Run / All models switch, handed to whichever card is showing.
    ///
    /// Built once here rather than by each card: the control belongs to the screen, and the card
    /// that is off screen cannot host the switch that brings it back.
    private var modePicker: AnyView {
        AnyView(
            TerminalSegmentedPicker(
                selection: $mode,
                options: Mode.allCases.map { ($0, $0.rawValue) }))
    }

    /// Why the single Run is unavailable. A task's stream and this screen's own sweep both make a
    /// measurement meaningless, but for different reasons and with different remedies, so the card
    /// is told which — a single flag would have it narrate one while the other was true.
    private var blockReason: BenchmarkBlockReason? {
        if store.hasRunningTasks { return .taskRunning }
        if sweep.isMeasuring { return .measuring }
        return nil
    }

    /// Keyed on the endpoint STRING here, not on a commit generation: this field is the
    /// benchmark's own and is edited rarely, so the per-keystroke re-fetch the LLM tab guards
    /// against is not a concern — and `ModelCatalog.loadIfNeeded` is idempotent per key anyway.
    private var catalogKey: String {
        "\(target.provider.rawValue)|\(target.baseURLString)"
    }

    /// The one config this screen sends. Read by the prompt sheet's request facet, so what a user
    /// reads there is what a run would post — and assembled by the same method the sweep calls per
    /// target, because a second assembly of the same fields is exactly how a preview and the wire
    /// come to disagree.
    private var benchmarkConfig: LLMConfig {
        config.benchmarkConfig(for: target)
    }

    /// The request the sweep's prompt sheet previews: the FIRST model it will actually measure,
    /// falling back to the screen's own target when nothing is planned. The prompt text is
    /// identical for every model — only the name in the body differs — so previewing a model that
    /// is not in the plan would be the one detail on that sheet that was not true.
    private var sweepWireConfig: LLMConfig {
        guard let first = sweep.selectedEntries.first else { return benchmarkConfig }
        return config.benchmarkConfig(for: first.target)
    }

    /// What is known about each planned model, keyed by the sweep entry's id.
    ///
    /// The key is `BenchmarkLeaderboard.groupKey`, which is also `BenchmarkSweepEntry.id` — the
    /// single reason both were made to share one definition of "the same model on the same
    /// server". Nothing here issues a request: the history is already loaded for the table below,
    /// and the catalog was filled by the sweep's own scan, whose `/api/v1/models` and `/api/tags`
    /// responses carry each model's format and quantization alongside its name.
    ///
    /// The merge rule — and why the live answer wins over a past run's — lives on
    /// `BenchmarkSweepCard.badges`, which is where it can be tested without a view.
    private var modelBadges: [String: LLMModelInfo] {
        BenchmarkSweepCard.badges(
            runs: runs,
            servers: sweep.servers,
            infos: { modelCatalog.infos(for: $0.baseURLString, provider: $0.provider) })
    }

    /// Reloads, and says so when the store could not do what the dialog promised. A delete that
    /// silently failed leaves the rows on screen and the user clicking again.
    private func apply(_ outcome: BenchmarkHistoryStore.DeleteOutcome) {
        deletionError = BenchmarkDeletion.failureMessage(outcome)
        reload()
    }

    /// Re-reads both files. Cheap enough to do synchronously on every change — the history is
    /// capped at `BenchmarkMetricsPolicy.historyRowLimit` rows — and synchronous is what keeps the
    /// table and the disk from disagreeing after a delete.
    ///
    /// A run in flight needs no lock, but it does have an observable consequence worth stating:
    /// the runner appends only once it has finished, through the store's own serial queue, so a
    /// benchmark that was already running when the user pressed Clear will record itself into the
    /// emptied history a minute later. Nothing is corrupted and nothing the user deleted comes
    /// back — the new row is the run that was in progress.
    private func reload() {
        runs = sweep.history.loadRuns()
        samples = sweep.history.loadSamples()
    }
}
