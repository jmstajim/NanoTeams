import XCTest

@testable import NanoTeams

/// What the providers say about themselves, turned into the flat record a benchmark row carries.
/// Pure transforms over value types, so nothing here is `@MainActor` and nothing touches a server.
final class BenchmarkProvenanceTests: XCTestCase {

    // MARK: - serverFields

    func testServerFields_keyEveryReportedFieldByItsLabel() {
        let details = ModelLoadDetails(fields: [
            .init(label: "Quantization", value: "nvfp4"),
            .init(label: "Format", value: "safetensors"),
        ])
        XCTAssertEqual(
            BenchmarkProvenance.serverFields(from: details),
            ["Quantization": "nvfp4", "Format": "safetensors"])
    }

    /// RED: keep empty values → the provenance popover renders rows that say a field exists and
    /// then say nothing, which reads as a measurement of blank rather than as absence.
    func testServerFields_dropEmptyValues() {
        let details = ModelLoadDetails(fields: [
            .init(label: "Family", value: ""),
            .init(label: "Format", value: "gguf"),
        ])
        XCTAssertEqual(BenchmarkProvenance.serverFields(from: details), ["Format": "gguf"])
    }

    func testServerFields_noDetails_isEmpty() {
        XCTAssertTrue(BenchmarkProvenance.serverFields(from: nil).isEmpty)
    }

    // MARK: - samplingParameters

    /// Measured live on Ollama 0.32.14: `/api/show` returns the modelfile block as one string.
    func testSamplingParameters_parseTheModelfileBlock() {
        let block = """
        presence_penalty               0
        repeat_penalty                 1
        temperature                    1
        top_k                          20
        top_p                          0.95
        min_p                          0
        """
        let details = ModelLoadDetails(fields: [
            .init(label: ModelLoadDetails.modelfileParametersLabel, value: block)
        ])
        XCTAssertEqual(
            BenchmarkProvenance.samplingParameters(from: details),
            [
                "presence_penalty": "0", "repeat_penalty": "1", "temperature": "1",
                "top_k": "20", "top_p": "0.95", "min_p": "0",
            ])
    }

    /// LM Studio reports no sampling at all — its per-model config is server-side only. RED: fill
    /// this with the app's defaults → the record claims the server used values it never named.
    func testSamplingParameters_absentBlock_isEmptyNotDefaulted() {
        let details = ModelLoadDetails(fields: [.init(label: "Format", value: "mlx")])
        XCTAssertTrue(BenchmarkProvenance.samplingParameters(from: details).isEmpty)
        XCTAssertTrue(BenchmarkProvenance.samplingParameters(from: nil).isEmpty)
    }

    /// RED: store a nameless or valueless line → the record grows a key that means nothing, and
    /// `jq` over the history starts returning entries nobody wrote.
    func testParseModelfileParameters_skipsLinesWithoutBothHalves() {
        let parsed = BenchmarkProvenance.parseModelfileParameters(
            """
            temperature 1
            justaname
            
               
            top_p 0.95
            """)
        XCTAssertEqual(parsed, ["temperature": "1", "top_p": "0.95"])
    }

    /// A value with internal spaces is one value, not a truncated one.
    func testParseModelfileParameters_keepsInternalSpacing() {
        let parsed = BenchmarkProvenance.parseModelfileParameters("stop   <|im_end|> <|end|>")
        XCTAssertEqual(parsed, ["stop": "<|im_end|> <|end|>"])
    }

    func testParseModelfileParameters_empty_isEmpty() {
        XCTAssertTrue(BenchmarkProvenance.parseModelfileParameters("").isEmpty)
    }

    // MARK: - outputCapField

    /// The two providers disagree about a rejected key: LM Studio's `/api/v1/chat` answers HTTP
    /// 400 on an unknown one, Ollama ignores it. So on Ollama a wrong key would leave the run
    /// silently uncapped — this reads the recorded counts back and says so.
    ///
    /// RED: report the requested ceiling unconditionally → a row measured with no ceiling at all
    /// claims one, and the leaderboard mixes two regimes with nothing on screen saying which.
    func testOutputCapField_namesAServerThatIgnoredTheCeiling() {
        let fields = BenchmarkProvenance.outputCapField(
            requested: 512,
            measuredSamples: [sample(outputTokens: 400), sample(outputTokens: 12_040)])
        XCTAssertEqual(fields["Output cap"], "512 requested — NOT honoured (a sample returned 12040)")
    }

    func testOutputCapField_honouredWhenEverySampleIsWithin() {
        let fields = BenchmarkProvenance.outputCapField(
            requested: 512, measuredSamples: [sample(outputTokens: 512), sample(outputTokens: 40)])
        XCTAssertEqual(fields["Output cap"], "512 tokens")
    }

    /// A sample landing exactly ON the ceiling is the server doing what it was asked, not
    /// violating it. RED: use `>=` → every honoured run reports as violated, and the one signal
    /// that would catch a real miss becomes noise nobody reads.
    func testOutputCapField_exactlyAtTheCeilingIsHonoured() {
        let fields = BenchmarkProvenance.outputCapField(
            requested: 512, measuredSamples: [sample(outputTokens: 512)])
        XCTAssertEqual(fields["Output cap"], "512 tokens")
    }

    /// Nothing to say beats saying something unfounded: no ceiling asked for, or no sample that
    /// reported a count, means the field is absent rather than a claim.
    func testOutputCapField_saysNothingWithoutEvidence() {
        XCTAssertTrue(
            BenchmarkProvenance.outputCapField(requested: nil, measuredSamples: []).isEmpty)
        XCTAssertTrue(
            BenchmarkProvenance.outputCapField(requested: 0, measuredSamples: []).isEmpty)
        XCTAssertTrue(
            BenchmarkProvenance.outputCapField(
                requested: 512, measuredSamples: [sample(outputTokens: nil)]).isEmpty)
    }

    private func sample(outputTokens: Int?) -> GenerationBenchmarkSample {
        GenerationBenchmarkSample(
            runID: UUID(), recordedAt: Date(), phase: .measured, sampleIndex: 0,
            outputTokens: outputTokens)
    }

    // MARK: - residencyFields

    /// "already alone" and "could not check" are different facts about a measurement, and only one
    /// of them means the figure is trustworthy. RED: record nothing when nothing was cleared →
    /// the two become indistinguishable in the history.
    func testResidencyFields_alwaysRecordTheOutcome() {
        let unverified = BenchmarkProvenance.residencyFields(BenchmarkResidencyPreparer.Report())
        XCTAssertEqual(unverified["Residency"], "not verified")
        XCTAssertNil(unverified["Unloaded for this run"])

        var clean = BenchmarkResidencyPreparer.Report()
        clean.couldInspect = true
        XCTAssertEqual(BenchmarkProvenance.residencyFields(clean)["Residency"], "already alone")
    }

    func testResidencyFields_listWhatWasUnloaded_sorted() {
        var report = BenchmarkResidencyPreparer.Report()
        report.couldInspect = true
        report.unloadedModels = ["zeta", "alpha"]
        let fields = BenchmarkProvenance.residencyFields(report)
        XCTAssertEqual(fields["Unloaded for this run"], "alpha, zeta")
        XCTAssertEqual(fields["Residency"], "unloaded 2 other models")
    }

    /// RED: swallow the failure → a run whose housekeeping was refused looks exactly like one
    /// where it succeeded.
    func testResidencyFields_carryTheWarning() {
        var report = BenchmarkResidencyPreparer.Report()
        report.couldInspect = true
        report.failure = "could not unload stuck: busy"
        XCTAssertEqual(
            BenchmarkProvenance.residencyFields(report)["Residency warning"],
            "could not unload stuck: busy")
    }

    // MARK: - What the server said about itself

    /// The two engine keys are different sentences on purpose, and that IS the honesty mechanism:
    /// `listEngines` answers "what is installed here", a probe request answers "what served this
    /// model seconds ago". Neither may appear under a bare `"Engine"`, which a reader would take
    /// for the engine of the measured samples.
    func testProvenanceFields_keepsInstalledAndServingEnginesApart() {
        let fields = BenchmarkProvenance.provenanceFields(
            ServerProvenance(
                version: "0.4.21",
                build: "2",
                installedEngines: [
                    .init(name: "mlx-llm", version: "1.11.0"),
                    .init(name: "llama.cpp", version: "2.29.0"),
                ]),
            servingEngine: .init(name: "llama.cpp-mac-arm64-apple-metal-advsimd", version: "2.29.0"))

        XCTAssertEqual(fields["Engines installed"], "llama.cpp 2.29.0, mlx-llm 1.11.0")
        XCTAssertEqual(
            fields["Engine (probe request)"], "llama.cpp-mac-arm64-apple-metal-advsimd 2.29.0")
        XCTAssertNil(fields["Engine"], "a bare label would read as the engine of the samples")
    }

    /// Sorted, so two runs on one machine produce the same string and group in the leaderboard
    /// instead of splitting on whatever order the server happened to list.
    func testProvenanceFields_installedEnginesAreSorted() {
        let fields = BenchmarkProvenance.provenanceFields(
            ServerProvenance(installedEngines: [
                .init(name: "zeta", version: "1"),
                .init(name: "alpha", version: "2"),
            ]),
            servingEngine: nil)
        XCTAssertEqual(fields["Engines installed"], "alpha 2, zeta 1")
    }

    /// The build is recorded beside the version, never joined into it.
    func testProvenanceFields_recordsTheBuildSeparately() {
        let fields = BenchmarkProvenance.provenanceFields(
            ServerProvenance(version: "0.4.21", build: "2"), servingEngine: nil)
        XCTAssertEqual(fields["Server build"], "2")
        XCTAssertNil(fields["Server version"], "the version is a typed column, not a bag entry")
    }

    /// Absence is absence: a provider that says nothing produces no keys at all, rather than keys
    /// whose empty values would render as "the server answered, and the answer was blank".
    func testProvenanceFields_emptyProvenance_writesNothing() {
        XCTAssertTrue(
            BenchmarkProvenance.provenanceFields(ServerProvenance(), servingEngine: nil).isEmpty)
    }

    func testProvenanceFields_emptyBuildString_isNotRecorded() {
        let fields = BenchmarkProvenance.provenanceFields(
            ServerProvenance(version: "0.4.21", build: ""), servingEngine: nil)
        XCTAssertNil(fields["Server build"])
    }

    // MARK: - The output cap: a fact where the server states one

    private func capSample(outputTokens: Int, doneReason: String?) -> GenerationBenchmarkSample {
        GenerationBenchmarkSample(
            runID: UUID(), recordedAt: Date(), phase: .measured, sampleIndex: 0,
            outputTokens: outputTokens, doneReason: doneReason)
    }

    /// RED: ignore `doneReason` and keep the bare "512 tokens" → a run cut off AT the ceiling
    /// reads exactly like one the model finished on its own, and those are different workloads.
    func testOutputCap_saysWhenTheCeilingActuallyBoundTheRun() {
        let fields = BenchmarkProvenance.outputCapField(
            requested: 512,
            measuredSamples: [capSample(outputTokens: 512, doneReason: "length")])
        XCTAssertEqual(fields["Output cap"], "512 tokens — reached, generation was cut off there")
    }

    /// The mirror, and its own mutation (CLAUDE.md #59): a model that stopped on its own must not
    /// be reported as truncated. RED: return the "reached" wording unconditionally → fails.
    func testOutputCap_saysWhenTheModelStoppedOnItsOwn() {
        let fields = BenchmarkProvenance.outputCapField(
            requested: 512,
            measuredSamples: [capSample(outputTokens: 400, doneReason: "stop")])
        XCTAssertEqual(
            fields["Output cap"], "512 tokens — not reached, the model stopped on its own")
    }

    /// LM Studio reports no stop reason at all, so the inference-free wording has to survive.
    /// RED: assume "stop" when nothing was reported → LM Studio rows claim a fact never stated.
    func testOutputCap_staysSilentOnProvenanceTheProviderDidNotGive() {
        let fields = BenchmarkProvenance.outputCapField(
            requested: 512,
            measuredSamples: [capSample(outputTokens: 400, doneReason: nil)])
        XCTAssertEqual(fields["Output cap"], "512 tokens")
    }

    /// The violation branch still wins: a server returning MORE than it was asked for is a
    /// stronger statement than any `done_reason`.
    /// RED: check `doneReason` first → the broken-ceiling case is silently downgraded.
    func testOutputCap_reportsAViolationEvenWhenTheServerSaysItStopped() {
        let fields = BenchmarkProvenance.outputCapField(
            requested: 512,
            measuredSamples: [capSample(outputTokens: 900, doneReason: "stop")])
        XCTAssertEqual(
            fields["Output cap"], "512 requested — NOT honoured (a sample returned 900)")
    }
}
