import XCTest

@testable import NanoTeams

/// Pins the sequencer: what it measures, in what order, what it refuses, and what it says about
/// the models it never reached.
///
/// `@MainActor` because the runner is, with EVERY test `async` and every main-actor object built in
/// `setUp` — a sync test method that constructs a main-actor class in its body aborts the process
/// on CI, and `setUp` is the one place XCTest guarantees main-actor dispatch.
@MainActor
final class BenchmarkSweepRunnerTests: XCTestCase, @unchecked Sendable {

    private var directory: URL!
    private var history: BenchmarkHistoryStore!
    private var settings: FakeSweepSettings!
    private var discovery: FakeDiscovery!
    private var clock: SweepSteppingClock!
    /// Drives `isBusy` in `testATaskStartingMidSweep_stopsIt_namingTheReason`.
    ///
    /// A FIELD, not a local `var`: `isBusy` is `@escaping`, and a local mutated after the
    /// closure captured it is a data race by the letter of Swift 6 (`'busy' mutated after
    /// capture by sendable closure`). An `Atomic<Bool>` cannot replace it either — `Atomic`
    /// is `~Copyable` and so cannot be captured by an escaping closure at all. As a field it
    /// is isolated to this `@MainActor` class, which is where the closure already runs.
    private var busy = false

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        history = BenchmarkHistoryStore(directory: directory)
        settings = FakeSweepSettings()
        discovery = FakeDiscovery()
        clock = SweepSteppingClock(stepMilliseconds: 500)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        history = nil
        settings = nil
        discovery = nil
        clock = nil
        directory = nil
        try await super.tearDown()
    }

    // MARK: - Building

    private func makeSut(
        client: any LLMClient = HealthyClient(),
        probe: any ServerProvenanceProbe = NoProvenanceProbe(),
        isBusy: @escaping @MainActor () -> Bool = { false }
    ) -> BenchmarkSweepRunner {
        // The clock is injected for the same reason the single-run suite injects one: a scripted
        // stream yields every event in the same instant, so on the real clock the generation
        // window is 0 ms and every sample is voided `windowTooShort`
        // (`BenchmarkMetricsPolicy.minimumWindowMs = 50`). A sweep of voided runs still records a
        // run per target, which is exactly why this was invisible in the count assertions and only
        // showed up in the per-entry states.
        let clock = clock!
        return BenchmarkSweepRunner(
            runner: GenerationBenchmarkRunner(
                client: client,
                probe: probe,
                store: history,
                isBusy: { false },
                appVersion: "1.8.8",
                now: { clock.next() }),
            history: history,
            discovery: discovery,
            isBusy: isBusy,
            settings: settings)
    }

    /// Two servers, each answering with models, already scanned.
    private func seedScanned(
        lmStudio: [String] = ["lm-a"], ollama: [String] = ["oll-a"]
    ) async -> BenchmarkSweepRunner {
        discovery.outcomes[LLMProvider.lmStudio.defaultBaseURL.normalizedBaseURL] =
            .answered(lmStudio)
        discovery.outcomes[LLMProvider.ollama.defaultBaseURL.normalizedBaseURL] =
            .answered(ollama)
        let sut = makeSut()
        await sut.scan()
        return sut
    }

    private func waitUntilSettled(_ sut: BenchmarkSweepRunner) async {
        while sut.isMeasuring { await Task.yield() }
    }

    // MARK: - Seeding

    /// One row per provider, always — a provider absent from the list could never be found, and
    /// "every provider that is running" would silently mean "the one already configured".
    func testInit_seedsOneRowPerProvider() async {
        let sut = makeSut()
        XCTAssertEqual(sut.servers.map(\.provider), LLMProvider.allCases)
    }

    /// RED: seed from `defaultBaseURL` unconditionally → a user's customised endpoint is ignored
    /// and the sweep looks for their server at an address they moved it off.
    func testInit_prefersAKnownEndpointOverTheDefault() async {
        settings.knownEndpoints[.ollama] = ["http://ollama-box:11434"]
        let sut = makeSut()

        let row = sut.servers.first { $0.provider == .ollama }
        XCTAssertEqual(row?.baseURLString, "http://ollama-box:11434")
        XCTAssertEqual(row?.isProposedAddress, false)
    }

    /// The default is a PROPOSAL and the row has to say so — this screen is where a proposal can
    /// turn into a server the app sends unload commands to.
    ///
    /// RED: leave `isProposedAddress` false → the disclosure line disappears and a guessed address
    /// is indistinguishable from one the user configured.
    func testInit_marksAnUnconfiguredProvidersAddressAsProposed() async {
        let sut = makeSut()

        let row = sut.servers.first { $0.provider == .ollama }
        XCTAssertEqual(row?.baseURLString, LLMProvider.ollama.defaultBaseURL)
        XCTAssertEqual(row?.isProposedAddress, true)
    }

    /// RED: ignore the persisted exclusions at seed time → "do not unload my Ollama" survives the
    /// toggle but not the relaunch, which is when the user is least likely to be watching.
    func testInit_honoursPersistedExclusions() async {
        settings.benchmarkExcludedProviders = [.ollama]
        let sut = makeSut()

        XCTAssertEqual(sut.servers.first { $0.provider == .ollama }?.isIncluded, false)
        XCTAssertEqual(sut.servers.first { $0.provider == .lmStudio }?.isIncluded, true)
    }

    /// RED: mutate only the row → the choice is forgotten on relaunch.
    func testSetIncluded_persistsTheChoice() async {
        let sut = makeSut()
        sut.setIncluded(false, for: .lmStudio)

        XCTAssertEqual(settings.benchmarkExcludedProviders, [.lmStudio])
        sut.setIncluded(true, for: .lmStudio)
        XCTAssertTrue(settings.benchmarkExcludedProviders.isEmpty)
    }

    /// RED: keep the outcome across an address change → the row reads "12 models" about a server
    /// it no longer points at.
    func testSetEndpoint_dropsTheOldAddressesAnswer() async {
        let sut = await seedScanned()
        XCTAssertFalse(sut.entries.isEmpty)

        sut.setEndpoint("http://elsewhere:11434", for: .ollama)

        XCTAssertNil(sut.servers.first { $0.provider == .ollama }?.outcome)
        XCTAssertFalse(sut.entries.contains { $0.target.provider == .ollama })
    }

    // MARK: - Sequencing

    /// RED: run the targets concurrently → two models are measured on one machine at once, each
    /// one's residency pass evicting the other's target.
    func testSweep_measuresEveryModelExactlyOnce_inPlanOrder() async {
        let sut = await seedScanned(lmStudio: ["lm-a", "lm-b"], ollama: ["oll-a"])
        sut.startSweep()
        await waitUntilSettled(sut)

        XCTAssertEqual(history.loadRuns().count, 3)
        XCTAssertEqual(
            history.loadRuns().map(\.modelName), ["lm-a", "lm-b", "oll-a"],
            "runs are appended in the order they were measured")
        XCTAssertEqual(sut.phase, .finished(measured: 3, failed: 0, skipped: 0))
    }

    /// RED: rebuild the plan from `servers` inside the loop → a rescan mid-sweep replaces the list
    /// being walked, and entries are measured twice or skipped.
    func testSweep_reportsProgressAgainstTheEntryList() async {
        let sut = await seedScanned(lmStudio: ["a", "b"], ollama: [])
        sut.startSweep()
        await waitUntilSettled(sut)

        XCTAssertEqual(sut.entries.count, 2)
        XCTAssertTrue(sut.entries.allSatisfy {
            if case .measured = $0.state { return true }
            return false
        })
    }

    /// The single Run button is a sweep of one, so it comes through the same loop and settles the
    /// same way.
    func testMeasureOne_recordsExactlyOneRun() async {
        let sut = makeSut()
        sut.measureOne(BenchmarkTarget(
            provider: .ollama, baseURLString: LLMProvider.ollama.defaultBaseURL,
            modelName: "solo"))
        await waitUntilSettled(sut)

        XCTAssertEqual(history.loadRuns().map(\.modelName), ["solo"])
        XCTAssertEqual(sut.entries.count, 1)
    }

    /// One machine, one measurement. RED: drop the `isMeasuring` guard in `start` → a second press
    /// replaces the plan mid-walk and two loops write to `entries` at once.
    func testStartingASecondSweepWhileMeasuring_isIgnored() async {
        let sut = await seedScanned(lmStudio: ["a"], ollama: ["b"])
        sut.startSweep()
        let planned = sut.entries.count

        sut.measureOne(BenchmarkTarget(
            provider: .ollama, baseURLString: "http://x:11434", modelName: "intruder"))
        XCTAssertEqual(sut.entries.count, planned, "the plan must not be replaced")

        await waitUntilSettled(sut)
        XCTAssertFalse(history.loadRuns().contains { $0.modelName == "intruder" })
    }

    // MARK: - Selection

    /// "All models" means all of them. RED: default to nothing selected → the user has to tick
    /// twelve boxes to say what they already said by opening the tab.
    func testEverythingFoundIsSelectedByDefault() async {
        let sut = await seedScanned(lmStudio: ["a", "b"], ollama: ["c"])

        XCTAssertEqual(sut.selectedEntries.count, 3)
        XCTAssertTrue(sut.entries.allSatisfy(\.isSelected))
    }

    /// RED: measure every entry regardless → the models the user ticked off are measured anyway,
    /// which is the one thing the checkbox exists to prevent.
    func testASweepMeasuresOnlyTheSelectedModels() async {
        let sut = await seedScanned(lmStudio: ["keep", "drop"], ollama: [])
        let dropped = try? XCTUnwrap(sut.entries.first { $0.target.modelName == "drop" })
        sut.setSelected(false, entryID: dropped?.id ?? "")

        sut.startSweep()
        await waitUntilSettled(sut)

        XCTAssertEqual(history.loadRuns().map(\.modelName), ["keep"])
    }

    /// An unticked model was never attempted, so it is not "skipped" — that word is reserved for a
    /// model the sweep tried to reach and could not.
    ///
    /// RED: settle the unselected tail too → every deselected model reads as one the sweep failed
    /// to measure, and `canResume` offers to finish a sweep that finished.
    func testAnUnselectedModelStaysPending_andDoesNotKeepResumeAlive() async {
        let sut = await seedScanned(lmStudio: ["keep", "drop"], ollama: [])
        let dropped = try? XCTUnwrap(sut.entries.first { $0.target.modelName == "drop" })
        sut.setSelected(false, entryID: dropped?.id ?? "")

        sut.startSweep()
        await waitUntilSettled(sut)

        XCTAssertEqual(sut.entries.first { $0.target.modelName == "drop" }?.state, .pending)
        XCTAssertFalse(sut.canResume)
    }

    /// RED: keep the selection on the entries only → a Rescan rebuilds them and silently re-ticks
    /// everything, which is the press most likely to follow a careful deselection.
    func testTheSelectionSurvivesARescan() async {
        let sut = await seedScanned(lmStudio: ["a", "b"], ollama: [])
        let first = try? XCTUnwrap(sut.entries.first)
        sut.setSelected(false, entryID: first?.id ?? "")

        await sut.scan()

        XCTAssertEqual(sut.entries.first { $0.id == first?.id }?.isSelected, false)
        XCTAssertEqual(sut.selectedEntries.count, 1)
    }

    /// RED: implement "select all" as a stored allow-list → a model that appears after the toggle
    /// (a freshly pulled one) arrives unselected, and "all models" quietly means "the ones that
    /// existed when you last pressed this".
    func testSelectAll_thenANewModelAppears_isSelectedToo() async {
        let sut = await seedScanned(lmStudio: ["a"], ollama: [])
        sut.setAllSelected(true)

        discovery.outcomes[LLMProvider.lmStudio.defaultBaseURL.normalizedBaseURL] =
            .answered(["a", "brand-new"])
        await sut.scan()

        XCTAssertEqual(sut.selectedEntries.count, 2)
    }

    func testSelectNone_leavesNothingToRun() async {
        let sut = await seedScanned(lmStudio: ["a", "b"], ollama: ["c"])
        sut.setAllSelected(false)

        XCTAssertTrue(sut.selectedEntries.isEmpty)
        sut.startSweep()
        await waitUntilSettled(sut)
        XCTAssertEqual(history.loadRuns().count, 0)
    }

    // MARK: - Whose progress is on screen

    /// One model measured through this same runner is NOT a sweep, so the single-model card keeps
    /// narrating it. `isSweeping` is what separates the two, and it reads the plan, not the button
    /// that was pressed.
    /// RED: define `isSweeping` as `isMeasuring` alone → a single measurement suppresses the very
    /// card that started it, and the screen goes silent for the whole run.
    func testSingleRunPhaseAndSummary_passThroughWhenOnlyOneModelIsPlanned() async {
        let sut = await seedScanned(lmStudio: ["only"], ollama: [])
        XCTAssertEqual(sut.entries.count, 1)

        sut.startSweep()
        XCTAssertFalse(sut.isSweeping, "one model is not a sweep")
        XCTAssertEqual(sut.singleRunPhase, sut.runner.phase)
        await waitUntilSettled(sut)
        XCTAssertNotNil(sut.singleRunSummary)
    }

    /// …and with more than one model the single-model card must say nothing at all: its own target
    /// is not what is being measured, and "Sample 3 of 5" under that name would be another model's
    /// progress narrated under this one's label.
    /// RED: return `runner.phase` / `runner.summary` unconditionally → both assertions fail while
    /// the ninth model of a sweep is in flight.
    func testSingleRunPhaseAndSummary_areSilencedWhileASweepRuns() async {
        let sut = await seedScanned(lmStudio: ["a", "b"], ollama: ["c"])
        sut.startSweep()

        XCTAssertTrue(sut.isSweeping)
        XCTAssertEqual(sut.singleRunPhase, .idle, "the sweep's per-sample phase is not this card's")
        XCTAssertNil(sut.singleRunSummary)
        sut.cancel()
        await waitUntilSettled(sut)
    }

    /// Not measuring at all leaves both pass-through, so a finished single run keeps its figures on
    /// screen instead of being blanked by the sweep that never started.
    func testSingleRunPhase_passesThroughWhenNothingIsMeasuring() async {
        let sut = makeSut()
        XCTAssertFalse(sut.isSweeping)
        XCTAssertEqual(sut.singleRunPhase, sut.runner.phase)
    }

    // MARK: - Scanning

    /// A second caller arriving mid-scan WAITS for the first instead of starting another. Two
    /// overlapping scans coalesce inside `ModelCatalog` and make each other's results
    /// `.undetermined` — the row would then ask for a rescan right after one had just run.
    /// RED: drop the `await scanTask?.value` branch and return immediately → the second caller
    /// returns while `isScanning` is still true, so the assertion that the scan has finished fails.
    func testScan_secondCallerAwaitsTheFirstRatherThanStartingAnother() async {
        discovery.outcomes[LLMProvider.lmStudio.defaultBaseURL.normalizedBaseURL] =
            .answered(["a"])
        discovery.outcomes[LLMProvider.ollama.defaultBaseURL.normalizedBaseURL] = .answered(["b"])
        let sut = makeSut()

        async let first: Void = sut.scan()
        async let second: Void = sut.scan()
        _ = await (first, second)

        XCTAssertFalse(sut.isScanning, "both callers must have observed the scan finish")
        XCTAssertEqual(sut.entries.count, 2)
        XCTAssertEqual(
            discovery.chatModelCalls.count, 2,
            "one lookup per server — a second scan would double this")
    }

    /// A target the shared engine REFUSED is `.skipped`, not `.failed`.
    ///
    /// `GenerationBenchmarkRunner.run` guards on `isRunning` and returns `.nothingRecorded` — no
    /// record, and no failure either, because nothing was learned about the model. Calling that a
    /// failure would libel a model that was never measured, and it would do it in the leaderboard's
    /// own vocabulary.
    /// RED: fold the `wasRecorded == false` branch into the `failure` branch (or drop the `else`
    /// so the entry keeps whatever it had) → the entry reads `.failed` and the sweep reports one
    /// failure instead of one skip.
    func testTarget_refusedByTheBusyEngine_isSkippedNotFailed() async {
        // A probe that blocks holds the engine in `.preparing`, which is exactly the window in
        // which a second caller is refused. Nothing else in the runner offers a suspension point
        // this test can stand in.
        let gate = SweepProbeGate()
        let sut = makeSut(probe: GatedProvenanceProbe(gate: gate))
        discovery.outcomes[LLMProvider.lmStudio.defaultBaseURL.normalizedBaseURL] =
            .answered(["a"])
        discovery.outcomes[LLMProvider.ollama.defaultBaseURL.normalizedBaseURL] = .answered([])
        await sut.scan()

        let holding = Task { [runner = sut.runner, settings = settings!] in
            _ = await runner.run(
                config: settings.benchmarkConfig(
                    for: BenchmarkTarget(
                        provider: .lmStudio,
                        baseURLString: LLMProvider.lmStudio.defaultBaseURL,
                        modelName: "other")),
                repeats: 1,
                otherServers: [])
        }
        while !sut.runner.isRunning { await Task.yield() }

        sut.startSweep()
        await waitUntilSettled(sut)

        XCTAssertEqual(sut.entries.first?.state, .skipped)
        guard case .finished(let measured, let failed, let skipped) = sut.phase else {
            return XCTFail("a refusal is not a stop — expected .finished, got \(sut.phase)")
        }
        XCTAssertEqual((measured, failed, skipped).0, 0)
        XCTAssertEqual(failed, 0, "refused is not failed")
        XCTAssertEqual(skipped, 1)

        await gate.open()
        _ = await holding.value
    }

    // MARK: - Stopping

    /// A stopped sweep has learned nothing about the models it never reached, and Resume is
    /// defined on exactly that set.
    ///
    /// RED: narrow `settle`'s loop to `entries[index].isSelected` alone, dropping the
    /// `!entries[index].state.isSettled` half → nothing is left `.pending`, but a model already
    /// `.measured` is overwritten as `.skipped`; restore that half and instead have `settle` mark
    /// only from the current index onward — the shape this replaced, whose `tail >= index`
    /// predicate matched nothing at a boundary index → the first assertion fails, because every
    /// unreached model stays `.pending` and a stopped sweep looks like it is still about to
    /// measure them.
    func testCancel_marksEveryUnreachedModelSkipped_notPending() async {
        let sut = await seedScanned(lmStudio: ["a", "b", "c"], ollama: ["d", "e"])
        sut.startSweep()
        sut.cancel()
        await waitUntilSettled(sut)

        XCTAssertFalse(sut.entries.contains { $0.state == .pending },
                       "nothing may be left looking like it is about to be measured")
        XCTAssertTrue(sut.entries.contains { $0.state == .skipped })
        if case .stopped(let reason, _) = sut.phase {
            XCTAssertEqual(reason, .cancelled)
        } else {
            XCTFail("expected a stopped phase, got \(sut.phase)")
        }
    }

    /// RED: keep measuring while a task streams → every remaining sample is voided
    /// `.concurrentActivity` anyway, so the sweep spends an hour producing unusable rows.
    func testATaskStartingMidSweep_stopsIt_namingTheReason() async {
        discovery.outcomes[LLMProvider.lmStudio.defaultBaseURL.normalizedBaseURL] =
            .answered(["a", "b", "c"])
        discovery.outcomes[LLMProvider.ollama.defaultBaseURL.normalizedBaseURL] = .answered([])
        let sut = makeSut(isBusy: { self.busy })
        await sut.scan()

        // Busy from the very first check, so the stop is unambiguous.
        busy = true
        sut.startSweep()
        await waitUntilSettled(sut)

        XCTAssertEqual(history.loadRuns().count, 0)
        if case .stopped(let reason, _) = sut.phase {
            XCTAssertEqual(reason, .taskStartedRunning)
        } else {
            XCTFail("expected a stopped phase, got \(sut.phase)")
        }
        XCTAssertTrue(sut.entries.allSatisfy { $0.state == .skipped })
    }

    /// RED: mark the unreached tail `.failed` → every model a stopped sweep never tried reads as
    /// broken, and Resume (defined on `.skipped`/`.pending`) can no longer see them.
    func testResume_measuresOnlyWhatWasNeverReached() async {
        let sut = await seedScanned(lmStudio: ["a", "b"], ollama: [])
        sut.startSweep()
        sut.cancel()
        await waitUntilSettled(sut)

        let alreadyMeasured = history.loadRuns().count
        XCTAssertTrue(sut.canResume)

        sut.resumeSweep()
        await waitUntilSettled(sut)

        XCTAssertEqual(history.loadRuns().count, 2, "every model ends up measured exactly once")
        XCTAssertGreaterThanOrEqual(history.loadRuns().count, alreadyMeasured)
        XCTAssertEqual(sut.phase, .finished(measured: 2, failed: 0, skipped: 0))
    }

    /// RED: allow resume from `.finished` → pressing it re-measures a completed sweep and doubles
    /// every row in the history.
    func testCanResume_isFalseAfterACompletedSweep() async {
        let sut = await seedScanned(lmStudio: ["a"], ollama: [])
        sut.startSweep()
        await waitUntilSettled(sut)

        XCTAssertFalse(sut.canResume)
    }

    // MARK: - Cost governor

    /// A server that stopped answering costs `repeats + 1` requests that each wait out the request
    /// timeout — 600 s by default — and it costs that on EVERY remaining model.
    ///
    /// RED: drop the pre-target liveness check → a sweep whose server died at model 2 of 20 keeps
    /// trying all eighteen, at up to an hour each.
    func testAServerThatStopsAnswering_skipsItsRemainingModelsWithoutMeasuring() async {
        let sut = await seedScanned(lmStudio: ["a", "b", "c"], ollama: [])
        discovery.answering[LLMProvider.lmStudio.defaultBaseURL.normalizedBaseURL] = false

        sut.startSweep()
        await waitUntilSettled(sut)

        XCTAssertEqual(history.loadRuns().count, 0, "not one streaming request may be spent")
        XCTAssertTrue(sut.entries.allSatisfy { $0.state == .skipped })
    }

    /// RED: ask the liveness question once per server instead of per target → a server that dies
    /// halfway is only noticed at the next server boundary, which may never come.
    func testTheLivenessCheckIsAskedPerTarget() async {
        let sut = await seedScanned(lmStudio: ["a", "b"], ollama: [])
        sut.startSweep()
        await waitUntilSettled(sut)

        XCTAssertEqual(discovery.answeringCalls.count, 2, "\(discovery.answeringCalls)")
    }

    /// RED: mark a server silent because a MODEL failed → one bad model takes its whole server's
    /// remaining models down with it, on a machine that was answering the entire time.
    func testAModelFailingOnAHealthyServer_doesNotSkipItsSiblings() async {
        discovery.outcomes[LLMProvider.lmStudio.defaultBaseURL.normalizedBaseURL] =
            .answered(["a", "b"])
        discovery.outcomes[LLMProvider.ollama.defaultBaseURL.normalizedBaseURL] = .answered([])
        let sut = makeSut(client: FailingClient())
        await sut.scan()

        sut.startSweep()
        await waitUntilSettled(sut)

        XCTAssertEqual(sut.entries.count, 2)
        XCTAssertTrue(sut.entries.allSatisfy {
            if case .failed = $0.state { return true }
            return false
        }, "both were attempted — \(sut.entries.map(\.state))")
    }

    // MARK: - Clearing

    /// The read-earns-write rule, at the point where it is spent: a run may clear only the servers
    /// a scan heard from.
    ///
    /// RED: hand over every seeded row → an unload command goes to an address that answered
    /// nothing, which is precisely what `DEBTS.md` D-B1 §2 refused.
    func testOtherServers_areOnlyTheOnesThatAnswered() async {
        discovery.outcomes[LLMProvider.lmStudio.defaultBaseURL.normalizedBaseURL] =
            .answered(["a"])
        discovery.outcomes[LLMProvider.ollama.defaultBaseURL.normalizedBaseURL] =
            .noAnswer(detail: "connection refused")
        let sut = makeSut()
        await sut.scan()

        let others = sut.otherServers(excluding: BenchmarkServer(
            provider: .ollama, baseURLString: LLMProvider.ollama.defaultBaseURL))

        XCTAssertEqual(others.map(\.provider), [.lmStudio])
    }

    /// RED: forget to exclude the target's own server → the pass that clears "the others" unloads
    /// the model the run is about to measure.
    func testOtherServers_neverIncludeTheTargetsOwn() async {
        let sut = await seedScanned()

        let others = sut.otherServers(excluding: BenchmarkServer(
            provider: .lmStudio, baseURLString: LLMProvider.lmStudio.defaultBaseURL + "/"))

        XCTAssertFalse(others.contains { $0.provider == .lmStudio },
                       "a trailing slash is not a different machine")
    }

    // MARK: - Scanning

    /// RED: overwrite an answered row on every appear → the screen re-interrogates both servers on
    /// every Settings tab switch, and on Ollama that is an `/api/show` per model each time.
    func testScanIfNeeded_doesNotReAskAServerThatAlreadyAnswered() async {
        let sut = await seedScanned()
        let asked = discovery.chatModelCalls.count

        await sut.scanIfNeeded()

        XCTAssertEqual(discovery.chatModelCalls.count, asked)
    }

    /// `.undetermined` is not an answer, which is the whole reason it is a case of its own.
    ///
    /// RED: treat it as answered → a scan that observed nothing is never retried, and the row is
    /// stuck telling the user to rescan while the button that would do it declines.
    func testScanIfNeeded_retriesAnUndeterminedRow() async {
        discovery.outcomes[LLMProvider.lmStudio.defaultBaseURL.normalizedBaseURL] = .undetermined
        discovery.outcomes[LLMProvider.ollama.defaultBaseURL.normalizedBaseURL] = .answered([])
        let sut = makeSut()
        await sut.scan()
        let asked = discovery.chatModelCalls.count

        await sut.scanIfNeeded()

        XCTAssertGreaterThan(discovery.chatModelCalls.count, asked)
    }

    /// RED: skip the `isIncluded` guard → the sweep interrogates a provider the user switched off,
    /// which is the half of the promise they cannot see being broken.
    func testScan_doesNotAskASwitchedOffProvider() async {
        let sut = makeSut()
        sut.setIncluded(false, for: .ollama)
        await sut.scan()

        XCTAssertFalse(discovery.chatModelCalls.contains {
            $0.provider == .ollama
        }, "\(discovery.chatModelCalls)")
    }
}

// MARK: - Doubles

/// Advances a fixed step on every read, so a run produces deterministic windows with no sleeps.
private final class SweepSteppingClock: @unchecked Sendable {
    private let step: Duration
    private var current: ContinuousClock.Instant

    init(stepMilliseconds: Int) {
        self.step = .milliseconds(stepMilliseconds)
        self.current = ContinuousClock.now
    }

    func next() -> ContinuousClock.Instant {
        defer { current = current.advanced(by: step) }
        return current
    }
}

/// Scripted answers per normalized address, with a call log.
@MainActor
private final class FakeDiscovery: BenchmarkModelDiscovering {
    var outcomes: [String: BenchmarkDiscoveryOutcome] = [:]
    /// Liveness per normalized address; absent means answering.
    var answering: [String: Bool] = [:]
    private(set) var chatModelCalls: [BenchmarkServer] = []
    private(set) var answeringCalls: [BenchmarkServer] = []

    func chatModels(on server: BenchmarkServer) async -> BenchmarkDiscoveryOutcome {
        chatModelCalls.append(server)
        return outcomes[server.baseURLString.normalizedBaseURL] ?? .noAnswer(detail: "unset")
    }

    func isAnswering(_ server: BenchmarkServer) async -> Bool {
        answeringCalls.append(server)
        return answering[server.baseURLString.normalizedBaseURL] ?? true
    }
}

@MainActor
private final class FakeSweepSettings: BenchmarkSweepSettings {
    var benchmarkRepeats = 1
    var benchmarkExcludedProviders: Set<LLMProvider> = []
    var knownEndpoints: [LLMProvider: [String]] = [:]

    func benchmarkConfig(for target: BenchmarkTarget) -> LLMConfig {
        target.llmConfig(requestTimeoutSeconds: 5, keepAliveSeconds: nil)
    }

    func knownLLMEndpoints(for provider: LLMProvider) -> [String] {
        knownEndpoints[provider] ?? []
    }
}

/// A complete, usable answer every time — enough deltas to satisfy the warm-up policy, then the
/// terminal usage frame so the sample is not voided for want of token counts.
private struct HealthyClient: LLMClient {
    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for index in 0..<(BenchmarkWarmUpPolicy.sufficientDeltas + 4) {
                continuation.yield(StreamEvent(contentDelta: "t\(index)"))
            }
            continuation.yield(
                StreamEvent(tokenUsage: TokenUsage(inputTokens: 800, outputTokens: 401)))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// Every request fails at the transport, so each target produces a failed run on a server that is
/// otherwise answering.
private struct FailingClient: LLMClient {
    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMClientError.missingResponse) }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// Holds a probe open until the test lets go, so the engine can be parked in `.preparing`.
private actor SweepProbeGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private struct GatedProvenanceProbe: ServerProvenanceProbe {
    let gate: SweepProbeGate

    func serverProvenance(config _: LLMConfig) async -> ServerProvenance {
        await gate.wait()
        return ServerProvenance()
    }

    func probeServingEngine(config _: LLMConfig) async -> ServerProvenance.Engine? { nil }
}

private struct NoProvenanceProbe: ServerProvenanceProbe {
    func serverProvenance(config _: LLMConfig) async -> ServerProvenance { ServerProvenance() }
    func probeServingEngine(config _: LLMConfig) async -> ServerProvenance.Engine? { nil }
}
