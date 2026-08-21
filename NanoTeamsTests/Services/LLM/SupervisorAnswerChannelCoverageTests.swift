import XCTest

@testable import NanoTeams

/// What the app does with the Supervisor's answer once it has one — and what it does when
/// it never gets one.
///
/// `SupervisorAutoAnswerService.swift` measured 58/58 lines covered before this file
/// existed, which is the point worth recording: every branch ran, and all three defects
/// below were live. Coverage says a line executed, not that anyone checked what it produced.
final class SupervisorAnswerChannelCoverageTests: XCTestCase {

    // MARK: - Doubles

    /// Emits a scripted stream. `thinking` goes to the reasoning channel, which is where a
    /// reasoning model puts everything — neither client ever routes it into `contentDelta`
    /// (`SSEEventParser` maps `reasoning.delta` to `.thinkingDelta`, and Ollama's
    /// `ThinkTagSplitter` actively pulls inline `<think>` OUT of content).
    private final class ScriptedClient: LLMClient, @unchecked Sendable {
        var content: [String] = []
        var thinking: [String] = []
        var error: Error?

        func streamChat(
            config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
            logger: NetworkLogger?, stepID: String?, roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let (content, thinking, error) = (self.content, self.thinking, self.error)
            return AsyncThrowingStream { continuation in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                for chunk in thinking { continuation.yield(StreamEvent(thinkingDelta: chunk)) }
                for chunk in content { continuation.yield(StreamEvent(contentDelta: chunk)) }
                continuation.finish()
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    private var client: ScriptedClient!
    private var task: NTMSTask!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        client = ScriptedClient()
        var seeded = NTMSTask(id: 1, title: "T", supervisorTask: "brief")
        var run = Run(id: 0, teamID: NTMSID.from(name: "team"))
        run.steps = [StepExecution(id: "engineer", role: .softwareEngineer, title: "Build")]
        seeded.runs = [run]
        task = seeded
    }

    override func tearDown() {
        client = nil
        task = nil
        super.tearDown()
    }

    private func generate() async -> String? {
        await SupervisorAutoAnswerService.generateAnswer(
            question: "Postgres or SQLite?",
            task: task, runIndex: 0, stepIndex: 0,
            client: client,
            config: LLMConfig(provider: .lmStudio, baseURLString: "http://x", modelName: "m"),
            artifactReader: { _ in nil })
    }

    // MARK: - The reasoning channel

    /// RED: drop the `thinkingDelta` accumulation and the empty-content fallback → the
    /// answer becomes `fallbackAnswer`.
    ///
    /// A reasoning model that writes its decision into `reasoning_content` and leaves
    /// `content` empty had that decision thrown away and replaced with "Proceed with the
    /// most reasonable assumption and document the decision." The role was told to guess on
    /// the very turn a real answer had been produced. `+TeammateConsultation` and both
    /// judges next door already recover it.
    func testReasoningOnlyReply_isUsed_notReplacedByTheCannedFallback() async {
        client.thinking = ["Use Postgres — ", "the app needs transactions."]
        client.content = []

        let answer = await generate()

        XCTAssertEqual(answer, "Use Postgres — the app needs transactions.")
        XCTAssertNotEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    /// Content wins when both channels speak — the reasoning channel is a fallback, not a
    /// second source. Otherwise a model that thinks out loud and then answers would have
    /// its deliberation delivered as the decision.
    func testContentWins_whenBothChannelsSpeak() async {
        client.thinking = ["hmm, maybe SQLite, no wait"]
        client.content = ["Use Postgres."]

        let answer = await generate()

        XCTAssertEqual(answer, "Use Postgres.")
    }

    /// Both channels empty is a genuinely absent answer, and the canned fallback is the
    /// right outcome there. Without this the fix above could be "always prefer thinking".
    func testBothChannelsEmpty_stillFallsBack() async {
        let answer = await generate()
        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    // MARK: - Model tokens

    /// RED: remove the `cleanHarmonyTokens` call → the raw envelope survives.
    ///
    /// This string is JSON-encoded into the `ask_supervisor` tool result (resent on every
    /// later iteration of the step) AND persisted to `step.supervisorAnswer`, which the feed
    /// renders as the Supervisor speaking. Nothing downstream sanitizes either copy — the
    /// `ModelTokenCleaner` calls in the streaming path all clean the ASSISTANT's own output,
    /// never a tool-role message the app injects.
    func testHarmonyEnvelope_isStrippedFromTheAnswer() async {
        client.content = ["<|channel|>final<|message|>Use Postgres.<|end|>"]

        let answer = await generate()

        XCTAssertEqual(answer, "Use Postgres.")
        XCTAssertFalse(answer?.contains("<|") ?? true, "raw model tokens reached the answer")
    }

    /// The reasoning fallback is cleaned too — a reasoning channel is MORE likely to carry
    /// envelope debris, not less.
    func testHarmonyEnvelope_isStrippedFromTheReasoningFallback() async {
        client.thinking = ["<|channel|>final<|message|>Use SQLite.<|end|>"]

        let answer = await generate()

        XCTAssertEqual(answer, "Use SQLite.")
    }

    /// An UNRECOGNISED channel keyword (`analysis` is not in `cleanHarmonyTokens`' list)
    /// leaves its bare word behind — `<|channel|>` goes, `analysis` stays. Recorded as the
    /// current shape rather than asserted as desirable: the guarantee this fix owes is that
    /// no `<|…|>` token reaches the answer, and that holds.
    func testUnrecognisedChannelKeyword_leavesNoTokens_evenIfItLeavesItsWord() async {
        client.thinking = ["<|channel|>analysis<|message|>Use SQLite.<|end|>"]

        let answer = await generate()

        XCTAssertFalse(answer?.contains("<|") ?? true, "no model tokens may survive: \(answer ?? "nil")")
        XCTAssertTrue(answer?.contains("Use SQLite.") ?? false, answer ?? "nil")
    }

    // MARK: - Cancellation is not an answer

    /// RED: replace the cancellation arm with the old bare `catch { return fallbackAnswer }`
    /// → this returns the canned decision instead of nil.
    ///
    /// Pause cancels the step task and `streamChat` throws. `cancelStepExecution` AWAITS the
    /// running task before clearing the execution state, so `isExecutionLive` is still true
    /// in the catch — `recordAutoSupervisorAnswer` would stamp "Proceed with the most
    /// reasonable assumption and document the decision." onto the step as an auto answer,
    /// clear `needsSupervisorInput`, and resolve the question the user paused to consider.
    func testCancellation_yieldsNoAnswerAtAll() async {
        client.error = CancellationError()
        let answer = await generate()
        XCTAssertNil(answer, "a Pause must not be recorded as a Supervisor decision")
    }

    /// URLSession reports a cancelled streaming task as `URLError.cancelled`, not
    /// `CancellationError`; which one surfaces depends on where the task happened to be
    /// suspended, i.e. on timing. Both spellings must mean the same thing.
    func testURLErrorCancelled_isAlsoTreatedAsCancellation() async {
        client.error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let answer = await generate()
        XCTAssertNil(answer)
    }

    /// A real transport failure is NOT a cancellation: the run continues, so the role needs
    /// an answer and the canned fallback is the correct one. This is the assertion that
    /// keeps the fix above from degenerating into "any error means cancelled".
    func testTransportFailure_stillFallsBack() async {
        client.error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        let answer = await generate()
        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    // MARK: - The classifier itself

    /// RED: narrow `TeamGenerationService.isCancellation` to `error is CancellationError`
    /// (dropping the `URLError.cancelled` half) → the second case diverges and this fires.
    ///
    /// `TeamGenerationService` owned this rule and three other services were getting it
    /// wrong, so it moved to `CancellationClassifier` and the old name became an alias. Its
    /// own doc comment states why the two must agree: otherwise a paused generation is
    /// marked `.failed` at one layer and `.paused` at the other.
    func testTeamGenerationAlias_agreesWithTheClassifier() {
        let cases: [Error] = [
            CancellationError(),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            NSError(domain: "com.example", code: NSURLErrorCancelled),
        ]
        for error in cases {
            XCTAssertEqual(
                TeamGenerationService.isCancellation(error),
                CancellationClassifier.isCancellation(error),
                "divergence on \(error)")
        }
    }

    /// The domain matters: an unrelated domain that happens to use the same numeric code is
    /// not a cancellation. A bare `code == NSURLErrorCancelled` check would swallow it.
    func testForeignDomainWithTheSameCode_isNotCancellation() {
        XCTAssertFalse(
            CancellationClassifier.isCancellation(
                NSError(domain: "com.example", code: NSURLErrorCancelled)))
    }
}
