import XCTest

@testable import NanoTeams

/// `BashExplainService.explain` produces the "Ask AI" advisory — what the command
/// does plus an independent safety read. It is advisory (never the gate verdict) and
/// fails SOFT: any error, an empty reply, or content-channel silence resolves to ""
/// (the UI hides the line). It reuses the dedicated judge model override so the
/// advisory comes from the same model the user configured for bash decisions.
final class BashExplainServiceTests: XCTestCase {

    func testExplain_returnsModelAdvisory() async {
        let client = StubExplainClient(content: "Lists files in the current directory. It looks safe — it only reads.")
        let out = await BashExplainService.explain(
            command: "ls -la", workingDirectory: nil,
            policy: BashPolicy(), config: LLMConfig(), client: client)
        XCTAssertEqual(out, "Lists files in the current directory. It looks safe — it only reads.")
    }

    // MARK: - Prompt contract (pins the describe-then-assess shape directly)

    func testExplainSystemPrompt_asksForWhatItDoesThenWhetherSafe() {
        let p = BashExplainService.explainSystemPrompt(policy: BashPolicy()).lowercased()
        XCTAssertTrue(p.contains("what the given shell command does") || p.contains("what the command does"),
                      "system prompt must ask what the command does")
        XCTAssertTrue(p.contains("safe"),
                      "system prompt must ask whether the command looks safe — a revert to describe-only must fail here")
    }

    func testExplainSystemPrompt_isGroundedInSandboxLimits() {
        // The safety read must be grounded in the actual sandbox so it rarely
        // contradicts the gate glyph — the confinement description must be present.
        let p = BashExplainService.explainSystemPrompt(policy: BashPolicy())
        XCTAssertTrue(p.contains("limits"), "prompt must surface the sandbox limits")
        XCTAssertTrue(p.contains(BashJudgeService.sandboxConfinementDescription(policy: BashPolicy())),
                      "prompt must embed the same confinement description the judge uses")
    }

    func testExplainUserPrompt_asksForSafety() {
        // The advise()-level sentinel keys off this phrase to route explain vs judge.
        let u = BashExplainService.explainUserPrompt(command: "ls", workingDirectory: nil)
        XCTAssertTrue(u.contains("whether it is safe"),
                      "user prompt must request the safety read (also the advise() routing sentinel)")
    }

    func testExplain_doesNotMangleTwoSentenceQuotedReply() async {
        // A model that quotes EACH sentence isn't a single wrapped span — unwrapQuotes
        // must leave it intact rather than strip the outer pair into dangling quotes.
        let quotedPair = "\"Removes the build dir.\" \"It is risky — it deletes files.\""
        let client = StubExplainClient(content: quotedPair)
        let out = await BashExplainService.explain(
            command: "rm -rf build", workingDirectory: nil,
            policy: BashPolicy(), config: LLMConfig(), client: client)
        XCTAssertEqual(out, quotedPair, "a per-sentence-quoted reply must not be mangled")
    }

    func testExplain_failsSoftToEmptyOnClientError() async {
        let out = await BashExplainService.explain(
            command: "rm -rf /", workingDirectory: nil,
            policy: BashPolicy(), config: LLMConfig(),
            client: StubExplainClient(throwError: true))
        XCTAssertEqual(out, "", "a transport error must fail soft to an empty description, never block")
    }

    func testExplain_emptyContent_fallsBackToThinkingChannel() async {
        // Reasoning models sometimes emit the sentence only in the thinking channel.
        let client = StubExplainClient(content: "", thinking: "Removes the build directory.")
        let out = await BashExplainService.explain(
            command: "rm -rf build", workingDirectory: nil,
            policy: BashPolicy(), config: LLMConfig(), client: client)
        XCTAssertEqual(out, "Removes the build directory.")
    }

    func testExplain_stripsWrappingQuotes() async {
        let client = StubExplainClient(content: "\"Prints the working directory path.\"")
        let out = await BashExplainService.explain(
            command: "pwd", workingDirectory: nil,
            policy: BashPolicy(), config: LLMConfig(), client: client)
        XCTAssertEqual(out, "Prints the working directory path.")
    }

    func testExplain_whitespaceOnlyReply_isEmpty() async {
        let client = StubExplainClient(content: "   \n  ")
        let out = await BashExplainService.explain(
            command: "true", workingDirectory: nil,
            policy: BashPolicy(), config: LLMConfig(), client: client)
        XCTAssertEqual(out, "")
    }

    func testExplain_appliesJudgeModelOverride() async {
        let client = StubExplainClient(content: "x")
        var policy = BashPolicy()
        policy.judgeOverride = LLMOverride(modelName: "dedicated-judge-model")
        _ = await BashExplainService.explain(
            command: "ls", workingDirectory: nil, policy: policy,
            config: LLMConfig(modelName: "global-model"), client: client)
        XCTAssertEqual(client.lastConfig?.modelName, "dedicated-judge-model",
                       "explainer must reuse the dedicated judge model override")
    }

    /// The verdict path pins temperature to 0 (strict-JSON extraction); the
    /// advisory is GENERATIVE prose and must keep the operator's temperature —
    /// the explainer uses `JudgeConfig.applying`, never `configForJudge`.
    func testExplain_keepsOperatorTemperature_noVerdictPin() async {
        let client = StubExplainClient(content: "x")
        var policy = BashPolicy()
        policy.judgeOverride = LLMOverride(modelName: "dedicated-judge-model")
        _ = await BashExplainService.explain(
            command: "ls", workingDirectory: nil, policy: policy,
            config: LLMConfig(modelName: "global-model", temperature: 0.7), client: client)
        XCTAssertEqual(client.lastConfig?.temperature, 0.7,
                       "advisory stream must not inherit the verdict temp-0 pin")
    }
}

// MARK: - Stub

/// Streams a fixed content (and optional thinking) reply, or throws; records the
/// config it was handed.
private final class StubExplainClient: LLMClient, @unchecked Sendable {
    let content: String
    let thinking: String
    let throwError: Bool
    private(set) var lastConfig: LLMConfig?

    init(content: String = "", thinking: String = "", throwError: Bool = false) {
        self.content = content
        self.thinking = thinking
        self.throwError = throwError
    }

    struct StubError: Error {}

    func streamChat(
        config: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lastConfig = config
        let c = content, t = thinking, err = throwError
        return AsyncThrowingStream { continuation in
            if err {
                continuation.finish(throwing: StubError())
                return
            }
            continuation.yield(StreamEvent(contentDelta: c, thinkingDelta: t))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
