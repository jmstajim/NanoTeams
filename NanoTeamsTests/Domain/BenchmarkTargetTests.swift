import XCTest

@testable import NanoTeams

/// The benchmark's target is separate from the app's settings on purpose; these pin that it stays
/// separate and that it carries only what belongs to it.
final class BenchmarkTargetTests: XCTestCase {

    func testSeedsFromTheAppSettings() {
        let config = LLMConfig(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "qwen3.8")
        let target = BenchmarkTarget(seededFrom: config)

        XCTAssertEqual(target.provider, .ollama)
        XCTAssertEqual(target.baseURLString, "http://127.0.0.1:11434")
        XCTAssertEqual(target.modelName, "qwen3.8")
    }

    /// Transport policy comes from the app, not from the target. RED: give the benchmark its own
    /// timeout → it measures under settings real work never runs under.
    func testCarriesTransportPolicyFromTheApp_notFromItself() {
        let target = BenchmarkTarget(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
        let config = target.llmConfig(requestTimeoutSeconds: 900, keepAliveSeconds: 1800)

        XCTAssertEqual(config.requestTimeoutSeconds, 900)
        XCTAssertEqual(config.keepAliveSeconds, 1800)
        XCTAssertEqual(config.modelName, "m")
    }

    /// RED: send a sampling temperature → the benchmark measures a regime the server's own
    /// per-model config would not have used, and the figure stops describing normal work.
    func testSendsNoSamplingTemperature() {
        let target = BenchmarkTarget(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
        XCTAssertNil(target.llmConfig(requestTimeoutSeconds: 600, keepAliveSeconds: nil).temperature)
    }

    /// The wiring, not the wire. Everything else about the ceiling is pinned one layer down — the
    /// key name on each provider, the options build, the honoured/not-honoured verdict — and all
    /// of it stays green if the benchmark simply stops asking for one. This is the only assertion
    /// that fails then, and a mutation run proved it was missing: removing the ceiling here
    /// reddened nothing at all.
    ///
    /// RED: `maxOutputTokens: nil` in `llmConfig` → samples are unbounded again, runs go back to
    /// minutes each, and every row on the leaderboard is measured over a sequence length the model
    /// chose for itself.
    func testCarriesTheWorkloadCeiling() {
        let target = BenchmarkTarget(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
        let config = target.llmConfig(requestTimeoutSeconds: 600, keepAliveSeconds: nil)

        XCTAssertEqual(config.maxOutputTokens, BenchmarkPrompt.maxOutputTokens)
        XCTAssertNotNil(config.maxOutputTokens, "a nil ceiling is no ceiling")
    }

    /// The ceiling belongs to the WORKLOAD, so it must not come from transport policy the way the
    /// timeout does. RED: read it off a setting → two rows of one leaderboard could be measured
    /// over different sequence lengths with nothing on screen saying so.
    func testTheCeilingDoesNotVaryWithTransportPolicy() {
        let target = BenchmarkTarget(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")
        let quick = target.llmConfig(requestTimeoutSeconds: 30, keepAliveSeconds: nil)
        let patient = target.llmConfig(requestTimeoutSeconds: 900, keepAliveSeconds: 1800)

        XCTAssertEqual(quick.maxOutputTokens, patient.maxOutputTokens)
    }

    /// RED: drop the emptiness check → Run is offered for a target with no model, and the run
    /// fails at the server instead of being refused at the button.
    func testIsRunnable_requiresBothAnEndpointAndAModel() {
        XCTAssertFalse(
            BenchmarkTarget(provider: .lmStudio, baseURLString: "", modelName: "m").isRunnable)
        XCTAssertFalse(
            BenchmarkTarget(provider: .lmStudio, baseURLString: "http://x", modelName: "  ")
                .isRunnable)
        XCTAssertTrue(
            BenchmarkTarget(provider: .lmStudio, baseURLString: "http://x", modelName: "m")
                .isRunnable)
    }

    func testRoundTripsThroughJSON() throws {
        let target = BenchmarkTarget(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "qwen3.8:27b")
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(target)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(BenchmarkTarget.self, from: data)
        XCTAssertEqual(decoded, target)
    }
}
