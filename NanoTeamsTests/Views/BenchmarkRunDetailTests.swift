import XCTest

@testable import NanoTeams

/// The run detail sheet — the first reader the record's provenance has ever had.
///
/// `serverFields` was written on every run since the feature shipped and rendered nowhere; so were
/// `modelLoadMs`, `totalMs`, `voidDetail`, the token counts, the thermal state and the residency
/// flag. These pin what the sheet does with them.
final class BenchmarkRunDetailTests: XCTestCase {

    // MARK: - Fixtures

    private static let runID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private static func run(
        provider: LLMProvider = .ollama,
        serverFields: [String: String] = [:],
        samplingParameters: [String: String] = [:],
        thermalState: String = BenchmarkThermalState.nominal,
        lowPowerMode: Bool = false
    ) -> GenerationBenchmarkRun {
        GenerationBenchmarkRun(
            id: runID,
            startedAt: Date(timeIntervalSince1970: 1_755_000_000),
            provider: provider,
            baseURLString: "http://127.0.0.1:11434",
            modelName: "qwen3.8:27b-mlx",
            providerVersion: "0.32.14",
            modelFormat: "gguf",
            quantization: "Q4_K_M",
            serverFields: serverFields,
            samplingParameters: samplingParameters,
            temperature: nil,
            requestTimeoutSeconds: 600,
            keepAliveSeconds: nil,
            promptID: BenchmarkPrompt.id,
            promptVersion: BenchmarkPrompt.version,
            repeats: 5,
            thermalState: thermalState,
            lowPowerMode: lowPowerMode,
            modelWasResident: false,
            appVersion: "1.8.5")
    }

    private static func sample(
        phase: GenerationBenchmarkSample.Phase = .measured,
        index: Int = 0,
        inputTokens: Int? = 2480,
        outputTokens: Int? = 512,
        void: BenchmarkVoidReason? = nil,
        voidDetail: String? = nil,
        doneReason: String? = nil,
        modelLoadMs: Double? = nil,
        appModelLoadMs: Double? = nil,
        serverTotalMs: Double? = nil
    ) -> GenerationBenchmarkSample {
        GenerationBenchmarkSample(
            id: UUID(),
            runID: runID,
            recordedAt: Date(timeIntervalSince1970: 1_755_000_000),
            phase: phase,
            sampleIndex: index,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            timeToFirstTokenMs: 1400,
            generationMs: 16_000,
            prefillMs: 5500,
            prefillSource: .serverPromptEval,
            serverGenerationMs: 16_000,
            reasoningOutputTokens: nil,
            modelLoadMs: modelLoadMs,
            appModelLoadMs: appModelLoadMs,
            totalMs: 18_000,
            serverTotalMs: serverTotalMs,
            doneReason: doneReason,
            void: void,
            voidDetail: voidDetail)
    }

    // MARK: - Samples

    /// The whole reason the table exists. The medians deliberately exclude the warm-up and every
    /// void, so those samples have nowhere else in the app to be seen — and the warm-up is the
    /// only place the cost of loading the model is visible at all.
    /// RED: filter the rows through `BenchmarkMetricsPolicy.usableSamples` → both vanish. A test
    /// asserting "only usable samples appear" would be characterizing that defect (CLAUDE.md #63).
    func testSampleRows_showTheSamplesTheMediansExcluded() {
        let rows = BenchmarkRunDetailSheet.sampleRows(for: [
            Self.sample(phase: .warmup, index: 0, void: .stoppedEarly),
            Self.sample(index: 0),
            Self.sample(index: 1, void: .httpError, voidDetail: "HTTP 503"),
        ])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first?.index, "warm-up", "the warm-up must lead, and be named")
        XCTAssertEqual(rows.map(\.isVoid), [true, false, true])
    }

    /// RED: render `void` without `voidDetail` → "3 samples could not be used" never becomes
    /// "HTTP 503", which is the one form of it a reader can act on.
    func testSampleRows_nameTheVoidReasonAndItsDetail() {
        let row = BenchmarkRunDetailSheet.sampleRows(
            for: [Self.sample(void: .httpError, voidDetail: "HTTP 503")])[0]
        XCTAssertTrue(row.outcome.contains("HTTP 503"), row.outcome)
        XCTAssertTrue(row.outcome.contains(BenchmarkVoidReason.httpError.rawValue), row.outcome)
    }

    /// The warm-up carries `stoppedEarly` on every healthy run — it is stopped on purpose the
    /// moment it has done its job. RED: print the raw reason for it too → every successful run
    /// shows a row that reads as a failure.
    func testSampleRows_readTheWarmUpsOwnStopAsTheHealthyOutcomeItIs() {
        let warmUp = BenchmarkRunDetailSheet.sampleRows(
            for: [Self.sample(phase: .warmup, void: .stoppedEarly)])[0]
        let measured = BenchmarkRunDetailSheet.sampleRows(
            for: [Self.sample(void: .stoppedEarly)])[0]
        XCTAssertEqual(warmUp.outcome, "stopped once warm")
        XCTAssertEqual(measured.outcome, BenchmarkVoidReason.stoppedEarly.rawValue)
    }

    /// RED: print a bare number for both → the app's own measurement and the server's are two
    /// clocks, and a cell that mixed them silently would be an inference indistinguishable from a
    /// measurement.
    func testSampleRows_sayWhoseClockMeasuredTheModelLoad() {
        let server = BenchmarkRunDetailSheet.sampleRows(for: [Self.sample(modelLoadMs: 2100)])[0]
        let app = BenchmarkRunDetailSheet.sampleRows(for: [Self.sample(appModelLoadMs: 2100)])[0]
        XCTAssertFalse(server.load.contains("app"), server.load)
        XCTAssertTrue(app.load.contains("(app)"), app.load)
        XCTAssertNotEqual(server.load, app.load)
    }

    /// RED: drop the server figure → `total_duration` goes back to being decoded and never read,
    /// which is where this change found it.
    func testSampleRows_showTheServersOwnTotalBesideTheAppsWhenItHasOne() {
        let withServer = BenchmarkRunDetailSheet.sampleRows(
            for: [Self.sample(serverTotalMs: 17_500)])[0]
        let without = BenchmarkRunDetailSheet.sampleRows(for: [Self.sample()])[0]
        XCTAssertTrue(withServer.total.contains("srv"), withServer.total)
        XCTAssertFalse(without.total.contains("srv"), without.total)
    }

    /// RED: fall back to `"stop"` when the provider says nothing → LM Studio rows, which carry no
    /// `done_reason` at all, would claim the model finished on its own.
    func testSampleRows_leaveTheStopReasonBlankWhereTheProviderDoesNotSayIt() {
        XCTAssertEqual(
            BenchmarkRunDetailSheet.sampleRows(for: [Self.sample(doneReason: "length")])[0].stop,
            "length")
        XCTAssertEqual(
            BenchmarkRunDetailSheet.sampleRows(for: [Self.sample()])[0].stop,
            BenchmarkMetricsPolicy.noValue)
    }

    /// A sample that measured nothing prints a dash, never a zero: "0 tok/s" is a claim about the
    /// model, and no such measurement was made.
    func testSampleRows_printADashForWhatWasNeverMeasured() {
        let row = BenchmarkRunDetailSheet.sampleRows(
            for: [Self.sample(inputTokens: nil, outputTokens: nil, void: .noOutput)])[0]
        XCTAssertEqual(row.promptTokens, BenchmarkMetricsPolicy.noValue)
        XCTAssertEqual(row.outputTokens, BenchmarkMetricsPolicy.noValue)
        XCTAssertEqual(row.outcome, BenchmarkVoidReason.noOutput.rawValue)
    }

    // MARK: - Conditions

    /// RED: collapse the two into one `wasThrottled` row → a third representation of a fact that
    /// already has two, and which of the two was true is lost (CLAUDE.md #95).
    func testConditionRows_nameThermalStateAndLowPowerSeparately() {
        let rows = BenchmarkRunDetailSheet.conditionRows(
            for: Self.run(thermalState: BenchmarkThermalState.serious, lowPowerMode: false))
        let labels = rows.map(\.label)
        XCTAssertTrue(labels.contains("Thermal state"), "\(labels)")
        XCTAssertTrue(labels.contains("Low Power Mode"), "\(labels)")
        XCTAssertEqual(rows.first { $0.label == "Thermal state" }?.value, "serious")
        XCTAssertEqual(rows.first { $0.label == "Low Power Mode" }?.value, "no")
    }

    /// RED: print `false` / `true` → the reader has to guess what the flag was asserting.
    func testConditionRows_sayWhatResidencyMeantRatherThanPrintingABool() {
        let value = BenchmarkRunDetailSheet
            .conditionRows(for: Self.run())
            .first { $0.label == "Model was resident" }?.value
        XCTAssertEqual(value, "no — it was loaded first")
    }

    /// RED: print a dash for an unsent parameter → a dash is what this screen uses for "the server
    /// reported none", and these were never asked for in the first place.
    func testConditionRows_distinguishNotSentFromNotReported() {
        let rows = BenchmarkRunDetailSheet.conditionRows(for: Self.run())
        XCTAssertEqual(rows.first { $0.label == "Temperature" }?.value, "not sent")
        XCTAssertEqual(rows.first { $0.label == "Keep-alive" }?.value, "not sent")
    }

    // MARK: - What the server said

    /// RED: uppercase or normalize a value → this string is what you would match against a model
    /// card or another tool's output, and a tidied-up spelling matches nothing. The same verbatim
    /// rule `ModelDescriptorText.quantization` already holds.
    func testServerFieldRows_areVerbatimAndKeySorted() {
        let rows = BenchmarkRunDetailSheet.serverFieldRows(for: Self.run(serverFields: [
            "VRAM": "18.2 GB",
            "Architecture": "qwen3moe",
            "Output cap": "512 tokens",
        ]))
        XCTAssertEqual(rows.map(\.label), ["Architecture", "Output cap", "VRAM"])
        XCTAssertEqual(rows.first { $0.label == "Architecture" }?.value, "qwen3moe")
    }

    /// RED: render an empty dictionary as an empty list → a section drawing nothing is
    /// indistinguishable from a rendering fault, and silence is a measurement here.
    func testEmptyServerFields_areStatedRatherThanDrawnAsNothing() {
        XCTAssertTrue(BenchmarkRunDetailSheet.serverFieldRows(for: Self.run()).isEmpty)
        XCTAssertGreaterThan(BenchmarkRunDetailSheet.noServerFields.count, 40)
    }

    /// RED: one wording for both providers → LM Studio's absence is structural (it keeps sampling
    /// parameters in a per-model config its REST API does not expose), and reporting it the same
    /// way as Ollama's would read as "none were used".
    func testEmptySamplingParameters_nameTheProviderAsymmetry() {
        let lmStudio = BenchmarkRunDetailSheet.noSamplingParameters(provider: .lmStudio)
        let ollama = BenchmarkRunDetailSheet.noSamplingParameters(provider: .ollama)
        XCTAssertNotEqual(lmStudio, ollama)
        XCTAssertTrue(lmStudio.contains("not because none were used"), lmStudio)
    }

    // MARK: - Identity

    func testSubtitle_namesTheProviderTheServerAndWhen() {
        let subtitle = BenchmarkRunDetailSheet.subtitle(for: Self.run())
        XCTAssertTrue(subtitle.contains(LLMProvider.ollama.displayName), subtitle)
        XCTAssertTrue(subtitle.contains("127.0.0.1:11434"), subtitle)
        XCTAssertTrue(
            subtitle.contains(
                BenchmarkResultsCard.runTimestampFull(Date(timeIntervalSince1970: 1_755_000_000))),
            subtitle)
    }

    /// RED: drop a column from the header while the rows still emit its cell → the table
    /// silently shifts every value one column left.
    func testSampleTableHeadings_matchTheCellsARowEmits() {
        XCTAssertEqual(BenchmarkRunDetailSheet.sampleColumnTitles.count, 10)
        XCTAssertEqual(
            BenchmarkRunDetailSheet.sampleColumnTitles,
            ["#", "Prompt", "Output", "TTFT", "Prefill", "Generation", "Load", "Total", "Stop",
             "Outcome"])
    }
}
