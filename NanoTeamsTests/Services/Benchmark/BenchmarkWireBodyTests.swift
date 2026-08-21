import XCTest

@testable import NanoTeams

/// Pins the request facet of the prompt sheet: what it renders really is the body the clients
/// build, and it really does carry the four facts the benchmark rests on.
final class BenchmarkWireBodyTests: XCTestCase {

    /// RED: re-spell the request shape here instead of calling `buildRequest` → the pane can
    /// describe a body no client sends, which is the whole reason it is built by delegation.
    func testLMStudioBody_isWhatTheClientWouldBuild() throws {
        let body = try XCTUnwrap(BenchmarkWireBody.json(config: config(provider: .lmStudio)))
        let expected = try JSONCoderFactory.makeWireEncoder().encode(
            NativeLMStudioClient.buildRequest(
                config: config(provider: .lmStudio),
                messages: BenchmarkPrompt.messages(nonce: BenchmarkPrompt.noncePlaceholder),
                tools: []))
        XCTAssertEqual(body, String(data: expected, encoding: .utf8))
    }

    func testOllamaBody_isWhatTheClientWouldBuild() throws {
        let body = try XCTUnwrap(BenchmarkWireBody.json(config: config(provider: .ollama)))
        let expected = try JSONCoderFactory.makeWireEncoder().encode(
            OllamaClient.buildRequest(
                config: config(provider: .ollama),
                messages: BenchmarkPrompt.messages(nonce: BenchmarkPrompt.noncePlaceholder),
                tools: []))
        XCTAssertEqual(body, String(data: expected, encoding: .utf8))
    }

    /// Three of the four facts the sheet states, checked against the bytes on both providers.
    /// RED: send tools, or let a system prompt in → the benchmark stops measuring the workload it
    /// claims to, and this fires before anyone reads the pane.
    ///
    /// The two providers spell "no system prompt" differently and the pin has to know that: LM
    /// Studio carries a `system_prompt` KEY beside a single text input, Ollama carries a turn with
    /// `"role":"system"` in a message list. A shared needle would pass vacuously on one of them.
    func testBothBodies_carryNoSystemPromptNoToolsAndNoTemperature() throws {
        for provider in LLMProvider.allCases {
            let body = try XCTUnwrap(BenchmarkWireBody.json(config: config(provider: provider)))
            XCTAssertFalse(
                body.contains("system_prompt"), "\(provider): a system prompt is on the wire")
            XCTAssertFalse(
                body.contains("\"role\":\"system\""), "\(provider): a system turn is on the wire")
            XCTAssertFalse(body.contains("\"tools\""), "\(provider): tool schemas are on the wire")
            XCTAssertFalse(
                body.contains("temperature"), "\(provider): a temperature is on the wire")
        }
    }

    /// The fourth fact, one provider at a time because the shapes genuinely differ.
    /// RED: let a second turn in on either provider → "one user turn" stops being true, and the
    /// prefill figure starts measuring something the sheet does not show.
    func testLMStudioBody_isASingleTextInput() throws {
        let body = try XCTUnwrap(BenchmarkWireBody.json(config: config(provider: .lmStudio)))
        XCTAssertTrue(
            body.contains("\"input\":\"Request \(BenchmarkPrompt.noncePlaceholder)"),
            String(body.prefix(200)))
    }

    func testOllamaBody_carriesExactlyOneTurnAndItIsTheUsers() throws {
        let body = try XCTUnwrap(BenchmarkWireBody.json(config: config(provider: .ollama)))
        XCTAssertEqual(
            body.components(separatedBy: "\"role\"").count - 1, 1,
            "the request carries more than one turn")
        XCTAssertTrue(body.contains("\"role\":\"user\""), String(body.prefix(200)))
    }

    /// RED: drop `maxOutputTokens` from the config or the request builder → runs stop being cut at
    /// the ceiling the leaderboard's comparability rests on, and nothing on screen would say so.
    func testBothBodies_carryTheOutputCeiling() throws {
        for provider in LLMProvider.allCases {
            let body = try XCTUnwrap(BenchmarkWireBody.json(config: config(provider: provider)))
            XCTAssertTrue(
                body.contains("\(BenchmarkPrompt.maxOutputTokens)"),
                "\(provider) body does not carry the 512-token ceiling")
        }
    }

    /// The marker must reach the body, or the request facet would show a prompt that differs from
    /// the one the prompt facet shows.
    func testBody_carriesTheSamePlaceholderTheProseExplains() throws {
        let body = try XCTUnwrap(BenchmarkWireBody.json(config: config(provider: .lmStudio)))
        XCTAssertTrue(body.contains(BenchmarkPrompt.noncePlaceholder), String(body.prefix(200)))
    }

    /// RED: return an empty string instead of nil, or render nothing at all → "could not be
    /// encoded" and "nothing is sent" become the same pane.
    func testUnavailableCopy_saysWhyRatherThanShowingNothing() {
        XCTAssertFalse(BenchmarkWireBody.unavailable.isEmpty)
        XCTAssertTrue(BenchmarkWireBody.unavailable.contains("could not be encoded"))
    }

    private func config(provider: LLMProvider) -> LLMConfig {
        BenchmarkTarget(provider: provider, baseURLString: provider.defaultBaseURL, modelName: "m")
            .llmConfig(requestTimeoutSeconds: 600, keepAliveSeconds: nil)
    }
}
