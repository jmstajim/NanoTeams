import XCTest

@testable import NanoTeams

/// `JudgeCall.run` — the one call every approval judge makes: the verdict config, the two
/// attempts, the channel policy, the throw → `.callFailed` mapping. Driven by a scripted client,
/// no server.
final class JudgeCallTests: XCTestCase {

    private static let opening = [
        ChatMessage(role: .system, content: "system"),
        ChatMessage(role: .user, content: "user"),
    ]

    private func run(
        _ client: JudgeCallScriptedClient,
        config: LLMConfig = LLMConfig(modelName: "role-model", temperature: 0.8),
        override: LLMOverride? = nil
    ) async -> JudgeCall.Outcome {
        await JudgeCall.run(opening: Self.opening, config: config, override: override, client: client, logger: nil)
    }

    // MARK: - One attempt

    func testCleanAllow_isParsedAllow_inOneCall() async {
        let client = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK","reason":"reads"}"#)])
        let outcome = await run(client)
        XCTAssertEqual(outcome, .parsed(.allow(reason: "reads")))
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].messages.map(\.content), ["system", "user"],
                       "the opening turns go out exactly as the judge built them")
    }

    func testCleanDeny_isParsedDeny() async {
        let outcome = await run(JudgeCallScriptedClient([.reply(content: #"{"decision":"DENY","reason":"wipes"}"#)]))
        XCTAssertEqual(outcome, .parsed(.deny(reason: "wipes")))
    }

    func testEmptyReply_isParsedNoVerdict_notARetry() async {
        let client = JudgeCallScriptedClient([.reply(content: "")])
        let outcome = await run(client)
        XCTAssertEqual(outcome, .parsed(.noVerdict))
        XCTAssertEqual(client.requests.count, 1, "silence is a deny, never a second attempt")
    }

    /// The stream cleaning must not strip what the parser has to reject: a zero-width space
    /// after the object is text around it. RED until 2026-09-23 — `ModelTokenCleaner.clean`
    /// trims U+200B, so both judges allowed the padded object (see `run`'s `prepare`).
    func testTrailingZeroWidthSpace_survivesThePreparation_andIsNotASingleObject() async {
        let outcome = await run(JudgeCallScriptedClient([.reply(content: "{\"decision\":\"OK\"}\u{200B}")]))
        XCTAssertEqual(outcome, .parsed(.notSingleObject))
    }

    func testLeadingZeroWidthSpaceAndBOM_areNotStripped() async {
        for padded in ["\u{200B}{\"decision\":\"OK\"}", "\u{FEFF}{\"decision\":\"OK\"}", "{\"decision\":\"OK\"}\u{FEFF}"] {
            let outcome = await run(JudgeCallScriptedClient([.reply(content: padded)]))
            XCTAssertEqual(outcome, .parsed(.notSingleObject), padded.debugDescription)
        }
    }

    /// A content channel holding only an invisible character is not empty: it is the reply,
    /// and it is no verdict. It must not fall through to the reasoning channel's `OK`.
    func testInvisibleOnlyContent_isTheReply_notAFallThroughToReasoning() async {
        let client = JudgeCallScriptedClient([.reply(content: "\u{200B}", thinking: #"{"decision":"OK"}"#)])
        let outcome = await run(client)
        XCTAssertEqual(outcome, .parsed(.notSingleObject))
        XCTAssertEqual(client.requests.count, 1)
    }

    /// Ordinary whitespace and newlines around the object still trim — the tightening is about
    /// invisible format characters, not about pretty-printing.
    func testNewlinesAndSpacesAroundTheObject_stillTrim() async {
        let outcome = await run(JudgeCallScriptedClient([.reply(content: "\n  {\"decision\":\"OK\"}  \n\t")]))
        XCTAssertEqual(outcome, .parsed(.allow(reason: nil)))
    }

    /// Through both judges: the padded allow is a deny with each judge's own sentence.
    func testBothJudges_denyAZeroWidthPaddedAllow() async {
        let padded = "{\"decision\":\"OK\"}\u{200B}"
        let bash = await BashJudgeService.judge(
            command: "ls", workingDirectory: nil, policy: BashPolicy(), config: LLMConfig(),
            client: JudgeCallScriptedClient([.reply(content: padded)]))
        XCTAssertEqual(bash, .decided(BashJudgeService.Decision(allowed: false, reason: JudgeFailClosedReason.bashNotSingleObject)))
        let action = await ComputerUseJudgeService.judge(
            action: .pressKey(keys: "a", target: nil), policy: ComputerUsePolicy(), config: LLMConfig(),
            client: JudgeCallScriptedClient([.reply(content: padded)]))
        XCTAssertEqual(action, .decided(ComputerUseJudgeService.Decision(allowed: false, reason: JudgeFailClosedReason.actionUnparseable)))
    }

    func testModelTokens_areCleanedBeforeParsing() async {
        let outcome = await run(JudgeCallScriptedClient([.reply(content: "<|channel|>" + #"{"decision":"OK"}"#)]))
        XCTAssertEqual(outcome, .parsed(.allow(reason: nil)))
    }

    // MARK: - Reasoning channel

    func testReasoningOnlyDeny_isHonoured_withoutARetry() async {
        let client = JudgeCallScriptedClient([.reply(content: "", thinking: #"{"decision":"DENY","reason":"no"}"#)])
        let outcome = await run(client)
        XCTAssertEqual(outcome, .parsed(.deny(reason: "no")))
        XCTAssertEqual(client.requests.count, 1)
    }

    func testReasoningOnlyAllow_retriesOnce_withTheRetryInstruction_thenTakesTheVisibleVerdict() async {
        let client = JudgeCallScriptedClient([
            .reply(content: "", thinking: #"{"decision":"OK"}"#),
            .reply(content: #"{"decision":"OK","reason":"visible now"}"#),
        ])
        let outcome = await run(client)
        XCTAssertEqual(outcome, .parsed(.allow(reason: "visible now")))
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[1].messages.map(\.content),
                       ["system", "user", JudgeReplyChannelPolicy.retryInstruction],
                       "the retry appends ONE turn to the same opening")
    }

    func testReasoningOnlyAllowTwice_isReasoningOnlyAllow_andStopsAtTwoCalls() async {
        let client = JudgeCallScriptedClient([
            .reply(content: "", thinking: #"{"decision":"OK"}"#),
            .reply(content: "", thinking: #"{"decision":"OK"}"#),
            .reply(content: #"{"decision":"OK"}"#),
        ])
        let outcome = await run(client)
        XCTAssertEqual(outcome, .reasoningOnlyAllow)
        XCTAssertEqual(client.requests.count, 2, "two attempts, never a third")
        XCTAssertEqual(client.requests[1].messages.filter { $0.content == JudgeReplyChannelPolicy.retryInstruction }.count, 1)
    }

    // MARK: - Transport

    func testThrowOnFirstAttempt_isCallFailed_withTheClassifiedMessage() async {
        let client = JudgeCallScriptedClient([.fail(URLError(.timedOut))])
        let outcome = await run(client)
        XCTAssertEqual(outcome, .callFailed(message: "The request timed out."),
                       "classified, stable English — not the system language")
    }

    func testThrowOnTheRetry_isCallFailed() async {
        let client = JudgeCallScriptedClient([
            .reply(content: "", thinking: #"{"decision":"OK"}"#),
            .fail(URLError(.cannotConnectToHost)),
        ])
        let outcome = await run(client)
        XCTAssertEqual(outcome, .callFailed(message: "The server could not be reached."))
        XCTAssertEqual(client.requests.count, 2)
    }

    /// An app-authored error's own description passes through verbatim.
    func testLocalizedError_passesThroughVerbatim() async {
        let outcome = await run(JudgeCallScriptedClient([.fail(StubError())]))
        XCTAssertEqual(outcome, .callFailed(message: "stub transport broke"))
    }

    // MARK: - Cancellation

    /// A stream the task's cancellation ends QUIETLY — `AsyncThrowingStream` returns nil to a
    /// cancelled consumer, it does not throw — would otherwise read as an empty reply, a deny.
    func testCancelledWhileTheReplyStreams_isCancelled_notANoVerdictDeny() async {
        let client = JudgeCallScriptedClient([.hang])
        let task = Task { await JudgeCall.run(opening: Self.opening, config: LLMConfig(), override: nil, client: client, logger: nil) }
        await waitForRequests(client, count: 1)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
    }

    /// Cancelled before the request even goes out: the same answer, not a deny — and no request.
    /// A gate's batch can hold several calls that need a verdict; after a Pause cut the first
    /// judge short, the rest reach here under the cancelled task, and each one sent used to be
    /// a request (and a `network_log.jsonl` record) for a run that had already stopped.
    func testAlreadyCancelledTask_isCancelled_andSendsNothing() async {
        let client = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK"}"#)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await JudgeCall.run(opening: Self.opening, config: LLMConfig(), override: nil, client: client, logger: nil)
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled, "a verdict that raced a Pause is not this run's answer")
        XCTAssertTrue(client.requests.isEmpty, "a stopped run asks no judge, got \(client.requests.count) request(s)")
    }

    /// The same for both judges' entry points: a cancelled caller is answered without a request.
    func testBothJudges_calledFromAStoppedRun_sendNothing() async {
        let bashClient = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK"}"#)])
        let bash = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BashJudgeService.judge(command: "rm -rf build", workingDirectory: nil,
                                                policy: BashPolicy(mode: .auto), config: LLMConfig(), client: bashClient)
        }.value
        XCTAssertEqual(bash, .cancelled)
        XCTAssertTrue(bashClient.requests.isEmpty, "bash judge sent \(bashClient.requests.count) request(s)")

        let cuClient = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK"}"#)])
        let action = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ComputerUseJudgeService.judge(action: .pressKey(keys: "return", target: nil),
                                                       policy: ComputerUsePolicy(mode: .auto), config: LLMConfig(),
                                                       client: cuClient)
        }.value
        XCTAssertEqual(action, .cancelled)
        XCTAssertTrue(cuClient.requests.isEmpty, "computer-use judge sent \(cuClient.requests.count) request(s)")
    }

    /// The two spellings of a cancellation a client can throw (`CancellationClassifier`), whether
    /// or not the task itself was cancelled — neither is a transport failure.
    func testThrownCancellation_inEitherSpelling_isCancelled_notCallFailed() async {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            let outcome = await run(JudgeCallScriptedClient([.fail(error)]))
            XCTAssertEqual(outcome, .cancelled, "\(error)")
        }
    }

    /// A cancellation that lands during the RETRY is still a cancellation, and there is no
    /// third attempt.
    func testCancelledDuringTheRetry_isCancelled() async {
        let client = JudgeCallScriptedClient([.reply(content: "", thinking: #"{"decision":"OK"}"#), .hang])
        let task = Task { await JudgeCall.run(opening: Self.opening, config: LLMConfig(), override: nil, client: client, logger: nil) }
        await waitForRequests(client, count: 2)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(client.requests.count, 2)
    }

    func testRuling_cancelled_isNoDecision_forEitherSubject() {
        for subject in JudgeFailClosedReason.Subject.allCases {
            let ruling = JudgeCall.ruling(.cancelled, subject: subject) { _ in
                XCTFail("a cancelled call has no reply to read")
                return JudgeDecision(allowed: true, reason: "")
            }
            XCTAssertEqual(ruling, .cancelled)
            XCTAssertNil(ruling.decision)
        }
    }

    func testBothJudges_answerACancelledCallWithNoRuling() async {
        let bashClient = JudgeCallScriptedClient([.hang])
        let bash = Task {
            await BashJudgeService.judge(command: "rm -rf build", workingDirectory: nil,
                                         policy: BashPolicy(mode: .auto), config: LLMConfig(), client: bashClient)
        }
        await waitForRequests(bashClient, count: 1)
        bash.cancel()
        let bashRuling = await bash.value
        XCTAssertEqual(bashRuling, .cancelled)

        let cuClient = JudgeCallScriptedClient([.hang])
        let action = Task {
            await ComputerUseJudgeService.judge(action: .pressKey(keys: "return", target: nil),
                                                policy: ComputerUsePolicy(mode: .auto), config: LLMConfig(), client: cuClient)
        }
        await waitForRequests(cuClient, count: 1)
        action.cancel()
        let actionRuling = await action.value
        XCTAssertEqual(actionRuling, .cancelled)
    }

    private func waitForRequests(_ client: JudgeCallScriptedClient, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while client.requests.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(client.requests.count, count, "premise: the judge's request went out")
    }

    // MARK: - Verdict config

    func testConfig_isPinnedToTemperatureZero_withNoOverride() async {
        let client = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK"}"#)])
        _ = await run(client, config: LLMConfig(baseURLString: "http://role:1", modelName: "role-model", temperature: 0.9))
        let sent = client.requests[0].config
        XCTAssertEqual(sent.temperature, 0)
        XCTAssertEqual(sent.modelName, "role-model")
        XCTAssertEqual(sent.baseURLString, "http://role:1")
    }

    func testConfig_appliesTheJudgeOverride_trimmed_andStillZero() async {
        let client = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK"}"#)])
        _ = await run(
            client, config: LLMConfig(baseURLString: "http://role:1", modelName: "role-model", temperature: 0.9),
            override: LLMOverride(baseURLString: "  http://judge:2  ", modelName: " judge-model "))
        let sent = client.requests[0].config
        XCTAssertEqual(sent.baseURLString, "http://judge:2")
        XCTAssertEqual(sent.modelName, "judge-model")
        XCTAssertEqual(sent.temperature, 0)
        XCTAssertEqual(sent, JudgeConfig.forVerdict(
            LLMConfig(baseURLString: "http://role:1", modelName: "role-model", temperature: 0.9),
            override: LLMOverride(baseURLString: "  http://judge:2  ", modelName: " judge-model ")),
            "one definition of the verdict config")
    }

    func testRetry_goesOutWithTheSameVerdictConfig() async {
        let client = JudgeCallScriptedClient([
            .reply(content: "", thinking: #"{"decision":"OK"}"#),
            .reply(content: #"{"decision":"DENY"}"#),
        ])
        _ = await run(client, override: LLMOverride(modelName: "judge-model"))
        XCTAssertEqual(client.requests.map(\.config.modelName), ["judge-model", "judge-model"])
        XCTAssertEqual(client.requests.map(\.config.temperature), [0, 0])
    }

    func testJudgeCall_isToolless_andCarriesNoStepID() async {
        let client = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK"}"#)])
        _ = await run(client)
        XCTAssertEqual(client.requests[0].toolCount, 0)
        XCTAssertNil(client.requests[0].stepID)
    }

    // MARK: - Both judges map it the same way

    func testBothJudges_mapCallFailedToTheirOwnSubject() async {
        let bash = await BashJudgeService.judge(
            command: "rm -rf build", workingDirectory: nil, policy: BashPolicy(mode: .auto),
            config: LLMConfig(), client: JudgeCallScriptedClient([.fail(URLError(.timedOut))]))
        XCTAssertEqual(bash, .decided(BashJudgeService.Decision(
            allowed: false, reason: "Command judge call failed (The request timed out.); denied for safety.")))
        let action = await ComputerUseJudgeService.judge(
            action: .pressKey(keys: "return", target: nil), policy: ComputerUsePolicy(mode: .auto),
            config: LLMConfig(), client: JudgeCallScriptedClient([.fail(URLError(.timedOut))]))
        XCTAssertEqual(action, .decided(ComputerUseJudgeService.Decision(
            allowed: false, reason: "Action judge call failed (The request timed out.); denied for safety.")))
    }

    func testBothJudges_sendTheirOwnPromptsAsTheOpening() async {
        let bashClient = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK"}"#)])
        _ = await BashJudgeService.judge(
            command: "ls", workingDirectory: "/p", policy: BashPolicy(), config: LLMConfig(), client: bashClient)
        XCTAssertEqual(bashClient.requests[0].messages.map(\.content), [
            BashJudgeService.judgeSystemPrompt(policy: BashPolicy()),
            BashJudgeService.judgeUserPrompt(command: "ls", workingDirectory: "/p"),
        ])
        XCTAssertEqual(bashClient.requests[0].messages.map(\.role), [.system, .user])

        let cuClient = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK"}"#)])
        let action = ComputerUseAction.typeText(text: "hello", target: "Notes")
        _ = await ComputerUseJudgeService.judge(
            action: action, policy: ComputerUsePolicy(), config: LLMConfig(), client: cuClient)
        XCTAssertEqual(cuClient.requests[0].messages.map(\.content), [
            ComputerUseJudgeService.systemPrompt(policy: ComputerUsePolicy()),
            ComputerUseJudgeService.userPrompt(action: action),
        ])
    }

    /// What each judge's request CARRIED, for its policy's `judgeOverride`: temperature 0 always,
    /// the override's URL and model trimmed, a blank field leaving the role's — and the same
    /// config from both judges for the same inputs. Read off the wire, not off a helper: until
    /// 2026-09-23 this was pinned on `configForJudge`, a function production had stopped calling
    /// (`JudgeCall.run` resolves `JudgeConfig.forVerdict` itself), so a judge that dropped its
    /// policy's override kept those tests green.
    func testBothJudges_sendTheirPolicysOverride_asTheVerdictConfig() async {
        let base = LLMConfig(baseURLString: "http://global:1234", modelName: "global-model", temperature: 0.9)
        let cases: [(override: LLMOverride?, url: String, model: String)] = [
            (nil, "http://global:1234", "global-model"),
            (LLMOverride(modelName: "judge-model"), "http://global:1234", "judge-model"),
            (LLMOverride(baseURLString: "  http://judge:9999  ", modelName: "  judge-model  "),
             "http://judge:9999", "judge-model"),
            (LLMOverride(baseURLString: "   "), "http://global:1234", "global-model"),
        ]
        for (override, url, model) in cases {
            let label = String(describing: override)
            let bashClient = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK"}"#)])
            _ = await BashJudgeService.judge(
                command: "ls", workingDirectory: nil, policy: BashPolicy(judgeOverride: override),
                config: base, client: bashClient)
            let cuClient = JudgeCallScriptedClient([.reply(content: #"{"decision":"OK"}"#)])
            _ = await ComputerUseJudgeService.judge(
                action: .pressKey(keys: "a", target: nil), policy: ComputerUsePolicy(judgeOverride: override),
                config: base, client: cuClient)
            guard let bash = bashClient.requests.first?.config, let action = cuClient.requests.first?.config else {
                XCTFail("premise: both judges sent a request for \(label)")
                continue
            }
            for (judge, sent) in [("bash", bash), ("computer-use", action)] {
                XCTAssertEqual(sent.temperature, 0, "\(judge) \(label)")
                XCTAssertEqual(sent.baseURLString, url, "\(judge) \(label)")
                XCTAssertEqual(sent.modelName, model, "\(judge) \(label)")
            }
            XCTAssertEqual(bash, action, "the two judges' verdict configs diverged for \(label)")
        }
    }

    func testBothJudges_mapReasoningOnlyAllowToTheSharedReason() async {
        let twice: [JudgeCallScriptedClient.Step] = [
            .reply(content: "", thinking: #"{"decision":"OK"}"#),
            .reply(content: "", thinking: #"{"decision":"OK"}"#),
        ]
        let bash = await BashJudgeService.judge(
            command: "x", workingDirectory: nil, policy: BashPolicy(), config: LLMConfig(),
            client: JudgeCallScriptedClient(twice))
        XCTAssertEqual(bash, .decided(JudgeDecision(allowed: false, reason: JudgeReplyChannelPolicy.reasoningOnlyAllowReason)))
        let action = await ComputerUseJudgeService.judge(
            action: .pressKey(keys: "a", target: nil), policy: ComputerUsePolicy(), config: LLMConfig(),
            client: JudgeCallScriptedClient(twice))
        XCTAssertEqual(action, .decided(JudgeDecision(allowed: false, reason: JudgeReplyChannelPolicy.reasoningOnlyAllowReason)))
    }

    // MARK: - JudgeFailClosedReason.Subject — the derived lists

    func testEverySubject_callFailed_isFailClosed() {
        for subject in JudgeFailClosedReason.Subject.allCases {
            XCTAssertTrue(JudgeFailClosedReason.isFailClosed(
                JudgeFailClosedReason.callFailed(subject: subject, message: "anything")), subject.rawValue)
            // An empty classified message is still recognisably the runtime's.
            XCTAssertTrue(JudgeFailClosedReason.isFailClosed(
                JudgeFailClosedReason.callFailed(subject: subject, message: "")), subject.rawValue)
        }
    }

    func testEverySubject_unparseableReplyReasons_areFailClosed_andNonEmpty() {
        for subject in JudgeFailClosedReason.Subject.allCases {
            XCTAssertFalse(subject.unparseableReplyReasons.isEmpty, subject.rawValue)
            for reason in subject.unparseableReplyReasons {
                XCTAssertTrue(JudgeFailClosedReason.isFailClosed(reason), reason)
            }
        }
    }

    /// The two judges' `parse` write exactly their subject's sentences for an unreadable reply —
    /// the list `isFailClosed` derives from is the list the code returns.
    func testEachJudgesUnparseableReasons_areWhatItsParseReturns() {
        let unreadable = ["", "prose", #"{"decision":"OK","decision":"DENY"}"#, #"{"decision":"#]
        let bash = Set(unreadable.map { BashJudgeService.parse($0).reason })
        XCTAssertTrue(bash.isSubset(of: Set(JudgeFailClosedReason.Subject.command.unparseableReplyReasons)), "\(bash)")
        let action = Set(unreadable.map { ComputerUseJudgeService.parse($0).reason })
        XCTAssertTrue(action.isSubset(of: Set(JudgeFailClosedReason.Subject.action.unparseableReplyReasons)), "\(action)")
    }

    /// A subject's name at the start of a model's own sentence is not the runtime's prefix.
    func testAModelReasonThatMerelyMentionsASubject_isNotFailClosed() {
        XCTAssertFalse(JudgeFailClosedReason.isFailClosed("Command deletes files; denied."))
        XCTAssertFalse(JudgeFailClosedReason.isFailClosed("Action judge call failed"),
                       "the prefix includes the opening parenthesis the runtime writes")
    }
}

// MARK: - Test doubles

private struct StubError: LocalizedError {
    var errorDescription: String? { "stub transport broke" }
}

/// Replays one scripted step per request and records what each request carried.
private final class JudgeCallScriptedClient: LLMClient, @unchecked Sendable {
    enum Step {
        case reply(content: String, thinking: String = "")
        case fail(Error)
        /// Yields nothing and holds the stream until the consumer goes away.
        case hang
    }

    struct Request {
        let config: LLMConfig
        let messages: [ChatMessage]
        let toolCount: Int
        let stepID: String?
    }

    private let lock = NSLock()
    private let steps: [Step]
    private var _requests: [Request] = []

    init(_ steps: [Step]) {
        precondition(!steps.isEmpty)
        self.steps = steps
    }

    var requests: [Request] { lock.withLock { _requests } }

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger _: NetworkLogger?,
        stepID: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let step: Step = lock.withLock {
            _requests.append(Request(config: config, messages: messages, toolCount: tools.count, stepID: stepID))
            return steps[min(_requests.count - 1, steps.count - 1)]
        }
        return AsyncThrowingStream { continuation in
            switch step {
            case .reply(let content, let thinking):
                if !thinking.isEmpty { continuation.yield(StreamEvent(thinkingDelta: thinking)) }
                if !content.isEmpty { continuation.yield(StreamEvent(contentDelta: content)) }
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            case .hang:
                let producer = Task.detached {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
