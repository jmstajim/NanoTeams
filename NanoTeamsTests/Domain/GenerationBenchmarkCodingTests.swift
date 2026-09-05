import XCTest

@testable import NanoTeams

/// The persisted shapes: what an old row decodes to, what a newer one keeps, and what the derived
/// properties say. These rows outlive the build that wrote them, so every default here is a
/// promise about a file somebody will read in six months.
final class GenerationBenchmarkCodingTests: XCTestCase {

    private let decoder = JSONCoderFactory.makeDateDecoder()
    private let encoder = JSONCoderFactory.makeJSONLEncoder()

    // MARK: - Sample

    func testSample_roundTripsEveryField() throws {
        let sample = GenerationBenchmarkSample(
            runID: UUID(), recordedAt: Date(timeIntervalSince1970: 1000),
            phase: .measured, sampleIndex: 2,
            inputTokens: 2480, outputTokens: 799,
            timeToFirstTokenMs: 6100, generationMs: 28_912, prefillMs: 5520,
            prefillSource: .serverPromptEval, serverGenerationMs: 28_912,
            modelLoadMs: 36, appModelLoadMs: nil, totalMs: 35_000,
            void: nil, voidDetail: nil)
        let decoded = try decoder.decode(
            GenerationBenchmarkSample.self, from: try encoder.encode(sample))
        XCTAssertEqual(decoded, sample)
    }

    /// A row written before a field existed must decode, with the field absent rather than zero.
    /// RED: decode with `decode` instead of `decodeIfPresent` → every historical row is lost the
    /// first time a field is added.
    func testSample_legacyRowWithoutOptionalFields_decodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","runID":"\(UUID().uuidString)",
         "recordedAt":"2026-08-19T21:00:00.000Z","phase":"measured","sampleIndex":0}
        """
        let sample = try decoder.decode(GenerationBenchmarkSample.self, from: Data(json.utf8))
        XCTAssertNil(sample.outputTokens)
        XCTAssertNil(sample.prefillSource)
        XCTAssertNil(sample.serverGenerationMs)
        XCTAssertNil(sample.void)
    }

    /// RED: default a missing phase to `.warmup` → historical rows silently drop out of every
    /// median, and the history quietly reports fewer samples than it holds.
    func testSample_missingPhase_defaultsToMeasured() throws {
        let json = """
        {"runID":"\(UUID().uuidString)","recordedAt":"2026-08-19T21:00:00.000Z"}
        """
        let sample = try decoder.decode(GenerationBenchmarkSample.self, from: Data(json.utf8))
        XCTAssertEqual(sample.phase, .measured)
        XCTAssertEqual(sample.sampleIndex, 0)
    }

    func testSample_isUsable_tracksTheVoidReason() {
        var sample = GenerationBenchmarkSample(
            runID: UUID(), recordedAt: Date(), phase: .measured, sampleIndex: 0)
        XCTAssertTrue(sample.isUsable)
        sample.void = .noOutput
        XCTAssertFalse(sample.isUsable)
    }

    // MARK: - Run

    /// The fixture keeps the typed `modelFormat`/`quantization` CONSISTENT with their
    /// `serverFields` copies — which is the only state the runner ever writes, since both come
    /// from one `ModelLoadDetails` in the same breath. An inconsistent fixture (typed nil beside
    /// a non-empty `serverFields["Format"]`) is not round-trippable BY DESIGN: decode promotes
    /// the legacy key, which is the migration working, not a defect.
    func testRun_roundTripsEveryField() throws {
        let run = GenerationBenchmarkRun(
            startedAt: Date(timeIntervalSince1970: 2000),
            provider: .ollama, baseURLString: "http://127.0.0.1:11434",
            modelName: "qwen3.8:27b-mlx", instanceID: nil,
            providerVersion: "0.32.14",
            modelFormat: "safetensors", quantization: "nvfp4",
            serverFields: [
                "Format": "safetensors", "Quantization": "nvfp4",
                "Requires Ollama": "0.32.12",
            ],
            samplingParameters: ["temperature": "1", "top_k": "20"],
            temperature: nil, requestTimeoutSeconds: 600, keepAliveSeconds: 1800,
            promptID: BenchmarkPrompt.id, promptVersion: BenchmarkPrompt.version,
            repeats: 5, thermalState: BenchmarkThermalState.nominal,
            lowPowerMode: false, modelWasResident: true, appVersion: "1.8.8")
        let decoded = try decoder.decode(GenerationBenchmarkRun.self, from: try encoder.encode(run))
        XCTAssertEqual(decoded, run)
    }

    func testRun_legacyRowWithoutOptionalFields_decodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","startedAt":"2026-08-19T21:00:00.000Z",
         "provider":"lmStudio"}
        """
        let run = try decoder.decode(GenerationBenchmarkRun.self, from: Data(json.utf8))
        XCTAssertNil(run.providerVersion)
        XCTAssertNil(run.modelFormat)
        XCTAssertNil(run.quantization)
        XCTAssertTrue(run.serverFields.isEmpty)
        XCTAssertTrue(run.samplingParameters.isEmpty)
        XCTAssertEqual(run.thermalState, BenchmarkThermalState.unknown)
        XCTAssertFalse(run.lowPowerMode)
    }

    /// Rows written before the typed fields existed already carry the same facts in
    /// `serverFields`, under the labels the provider clients report them with. RED: drop the
    /// `?? run.serverFields[...]` fallback in `decode` → every historical row loses its chips,
    /// though the file states the format in plain sight.
    func testRun_legacyRow_promotesFormatAndQuantizationFromServerFields() throws {
        let json = """
        {"id":"\(UUID().uuidString)","startedAt":"2026-08-19T21:00:00.000Z",
         "provider":"ollama",
         "serverFields":{"Format":"gguf","Quantization":"Q4_K_M"}}
        """
        let run = try decoder.decode(GenerationBenchmarkRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.modelFormat, "gguf")
        XCTAssertEqual(run.quantization, "Q4_K_M")

        // Promotion at decode rather than at display means a re-encode self-heals the row: the
        // typed keys are in the file from the next write on.
        let reEncoded = try decoder.decode(
            GenerationBenchmarkRun.self, from: try encoder.encode(run))
        XCTAssertEqual(reEncoded.modelFormat, "gguf")
        XCTAssertEqual(reEncoded.quantization, "Q4_K_M")
    }

    /// A `serverFields` key under a DIFFERENT casing is not the legacy spelling and must not be
    /// promoted — the fallback reads the exact labels the clients wrote, not a fuzzy match.
    func testRun_legacyRow_lowercaseServerFieldKeys_areNotPromoted() throws {
        let json = """
        {"id":"\(UUID().uuidString)","startedAt":"2026-08-19T21:00:00.000Z",
         "provider":"ollama","serverFields":{"format":"gguf","quantization":"Q4_K_M"}}
        """
        let run = try decoder.decode(GenerationBenchmarkRun.self, from: Data(json.utf8))
        XCTAssertNil(run.modelFormat)
        XCTAssertNil(run.quantization)
    }

    /// RED: swap the fallback to `run.serverFields[...] ?? decoded` → a row that carries BOTH
    /// (every row written after the promotion) starts preferring the untyped copy, and the typed
    /// field stops being the authority its name claims.
    func testRun_typedFieldsWinOverServerFieldsOnDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","startedAt":"2026-08-19T21:00:00.000Z",
         "provider":"lmStudio","modelFormat":"mlx","quantization":"4bit",
         "serverFields":{"Format":"gguf","Quantization":"Q4_K_M"}}
        """
        let run = try decoder.decode(GenerationBenchmarkRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.modelFormat, "mlx")
        XCTAssertEqual(run.quantization, "4bit")
    }

    /// RED: fold low-power into "nominal" → a run measured on battery ranks beside one on mains,
    /// and the leaderboard's throttled marker never fires for the commonest laptop case.
    func testRun_wasThrottled_coversBothCauses() {
        func run(thermal: String, lowPower: Bool) -> GenerationBenchmarkRun {
            GenerationBenchmarkRun(
                startedAt: Date(), provider: .lmStudio, baseURLString: "u", modelName: "m",
                requestTimeoutSeconds: 600, promptID: "p", promptVersion: 1, repeats: 5,
                thermalState: thermal, lowPowerMode: lowPower, modelWasResident: true,
                appVersion: "1")
        }
        XCTAssertFalse(run(thermal: BenchmarkThermalState.nominal, lowPower: false).wasThrottled)
        XCTAssertTrue(run(thermal: BenchmarkThermalState.serious, lowPower: false).wasThrottled)
        XCTAssertTrue(run(thermal: BenchmarkThermalState.nominal, lowPower: true).wasThrottled)
        // An unverifiable thermal state is not a claim of health.
        XCTAssertTrue(run(thermal: BenchmarkThermalState.unknown, lowPower: false).wasThrottled)
    }

    // MARK: - Thermal labels

    func testThermalLabels_areStableStrings() {
        XCTAssertEqual(BenchmarkThermalState.label(for: .nominal), "nominal")
        XCTAssertEqual(BenchmarkThermalState.label(for: .fair), "fair")
        XCTAssertEqual(BenchmarkThermalState.label(for: .serious), "serious")
        XCTAssertEqual(BenchmarkThermalState.label(for: .critical), "critical")
    }

    // MARK: - Prefill source

    func testPrefillSource_rawValuesAreStable() {
        // These strings live in a file the user can read months later; renaming one silently
        // orphans every row that already carries it.
        XCTAssertEqual(PrefillSource.serverPromptEval.rawValue, "serverPromptEval")
        XCTAssertEqual(PrefillSource.promptProcessingFrames.rawValue, "promptProcessingFrames")
        XCTAssertEqual(PrefillSource.timeToFirstToken.rawValue, "timeToFirstToken")
    }

    func testVoidReason_rawValuesAreStable() {
        XCTAssertEqual(
            Set(BenchmarkVoidReason.allCases.map(\.rawValue)),
            ["httpError", "transportError", "cancelled", "noTokensReported", "noOutput",
             "concurrentActivity", "windowTooShort", "stoppedEarly"])
    }

    // MARK: - The two facts added after rows already existed on disk

    /// RED: drop either `decodeIfPresent` line → the field round-trips as nil and the detail
    /// sheet's Stop and Total columns go permanently blank on Ollama.
    func testSample_roundTripsTheServersTotalAndStopReason() throws {
        let sample = GenerationBenchmarkSample(
            runID: UUID(), recordedAt: Date(timeIntervalSince1970: 1_755_000_000),
            phase: .measured, sampleIndex: 0,
            totalMs: 18_000, serverTotalMs: 17_500, doneReason: "length")
        let data = try JSONCoderFactory.makeJSONLEncoder().encode(sample)
        let decoded = try JSONCoderFactory.makeDateDecoder()
            .decode(GenerationBenchmarkSample.self, from: data)
        XCTAssertEqual(decoded.serverTotalMs, 17_500)
        XCTAssertEqual(decoded.doneReason, "length")
        XCTAssertEqual(decoded.totalMs, 18_000, "the app's own clock is a separate field")
    }

    /// A row written before these fields existed must decode as "the server did not say", not as
    /// a failure. RED: make either key required → every historical row stops loading.
    func testSample_writtenBeforeTheseFieldsExisted_stillDecodes() throws {
        let json = """
        {"runID":"\(UUID().uuidString)","recordedAt":"2026-08-19T21:00:00.000Z",\
        "phase":"measured","sampleIndex":0,"totalMs":18000}
        """
        let decoded = try JSONCoderFactory.makeDateDecoder()
            .decode(GenerationBenchmarkSample.self, from: Data(json.utf8))
        XCTAssertNil(decoded.serverTotalMs)
        XCTAssertNil(decoded.doneReason)
        XCTAssertEqual(decoded.totalMs, 18_000)
    }
}
