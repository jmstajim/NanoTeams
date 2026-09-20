import XCTest

@testable import NanoTeams

/// The two no-call branches the native wave added to `handleNoToolCalls` (2026-09-13):
///
/// - a native call the SERVER could not parse (`StreamingResult.nativeCallRejection`) — the
///   exact twin of the `.malformedJSON` arm, sharing its counter and its 3-strike escalation;
/// - a turn the server CUT at its output ceiling with no call made (`done_reason: length`,
///   measured on `gemma-4-26b`: 599 tokens of reasoning about a tool the schema did not
///   carry) — first strike named, second consecutive escalated.
@MainActor
final class NativeCallRejectionAndTruncationBranchTests: XCTestCase {
    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private let stepID = "engineer"
    private let allowed: Set<String> = [ToolNames.readFile]

    /// Verbatim malformed payload (`LLMExecutionServiceParseFailureCapTests`) — a prompt-taught
    /// turn that lands in the `.malformedJSON` arm, for the shared-counter test.
    private static let malformedHarmonyPayload = """
    <|call|>{"name":"create_artifact","arguments":{"content":"<button onclick=\\"appendOperator('-')">-</button>","name":"index.html"}}<|end|>
    """

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "Engineer", status: .running)
        task = NTMSTask(id: 0, title: "T", supervisorTask: "goal", runs: [Run(id: 0, steps: [step])])
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() async throws {
        service = nil; delegate = nil; task = nil
        try await super.tearDown()
    }

    private func turn(
        rejection: String? = nil,
        doneReason: String? = nil,
        content: String = "",
        sawHarmonyMarker: Bool = false,
        mode: ToolCallingMode = .native
    ) async -> (stop: LLMStepStop, appended: [ChatMessage]) {
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: content,
            sawHarmonyMarker: sawHarmonyMarker,
            task: delegate.taskToMutate ?? task,
            roleDefinition: nil,
            conversationMessages: &messages,
            allowedToolNames: allowed,
            serverDoneReason: doneReason,
            nativeCallRejection: rejection,
            toolCallingMode: mode)
        return (stop, messages)
    }

    private var parseFailures: Int {
        service._testHarmonyParseFailureCounter(stepID: stepID, taskID: task.id)
    }

    // MARK: - Native call rejected by the server

    func testRejection_firstStrike_nudgesWithTheServersSentence_andCountsOnTheSharedCounter() async {
        let reason = "tool call does not match the expected peg-native format"
        let (stop, appended) = await turn(rejection: reason)
        guard case .continueLoop = stop else { return XCTFail("expected .continueLoop, got \(stop)") }
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended[0].role, .user)
        let nudge = appended[0].content ?? ""
        XCTAssertEqual(
            nudge, NoToolTurnNudges.nativeCallRejected(reason: reason, allowedToolNames: allowed),
            "the branch appends exactly the registered nudge")
        XCTAssertTrue(nudge.contains("peg-native"), "the server's own sentence is the diagnosis")
        XCTAssertFalse(nudge.contains("<|call|>"), "no house envelope under native")
        XCTAssertTrue(nudge.contains("`read_file`"), "names a tool the role holds")
        XCTAssertEqual(parseFailures, 1)
    }

    func testRejection_thirdStrike_escalates_persistsTheQuestion_andResetsTheCounter() async {
        for _ in 0..<2 { _ = await turn(rejection: "peg-native") }
        XCTAssertEqual(parseFailures, 2)

        let (stop, appended) = await turn(rejection: "peg-native")
        guard case .needsSupervisorInput(let question, _) = stop else {
            return XCTFail("third rejection must escalate, got \(stop)")
        }
        XCTAssertEqual(
            question,
            LLMExecutionService.nativeCallRejectedEscalationQuestion(
                roleName: Role.softwareEngineer.displayName))
        XCTAssertTrue(question.contains("prompt-taught"), "offers the fallback protocol: \(question)")
        XCTAssertTrue(appended.isEmpty, "no nudge on the escalating turn")
        XCTAssertEqual(parseFailures, 0, "reset so a post-Supervisor restart starts clean")
        XCTAssertEqual(delegate.taskToMutate?.runs[0].steps[0].supervisorQuestion, question)
        XCTAssertEqual(delegate.taskToMutate?.runs[0].steps[0].needsSupervisorInput, true)
    }

    /// Three in any MIXTURE is the same evidence that nudging has stopped working.
    func testRejection_sharesTheMalformedJSONCounter() async {
        for _ in 0..<2 {
            let (stop, _) = await turn(
                content: Self.malformedHarmonyPayload, sawHarmonyMarker: true, mode: .promptTaught)
            guard case .continueLoop = stop else { return XCTFail("\(stop)") }
        }
        XCTAssertEqual(parseFailures, 2)
        let (stop, _) = await turn(rejection: "peg-native")
        guard case .needsSupervisorInput = stop else {
            return XCTFail("two malformed envelopes and one rejection are three strikes, got \(stop)")
        }
    }

    func testRejection_duringRevision_nudgesWithoutCounting() async {
        delegate.taskToMutate?.runs[0].steps[0].revisionComment = "Supervisor: try again"
        for _ in 0..<3 {
            let (stop, appended) = await turn(rejection: "peg-native")
            guard case .continueLoop = stop else { return XCTFail("\(stop)") }
            XCTAssertEqual(appended.count, 1)
        }
        XCTAssertEqual(parseFailures, 0, "the Supervisor is already driving")
    }

    func testRejection_withAnEmptyReason_nudgesWithoutQuotingAnEmptySentence() async {
        let (stop, appended) = await turn(rejection: "  ")
        guard case .continueLoop = stop else { return XCTFail("\(stop)") }
        let nudge = appended[0].content ?? ""
        XCTAssertFalse(nudge.contains("The server reported:"))
        XCTAssertTrue(nudge.contains("could not parse"))
    }

    /// The rejection is the most specific claim a turn can carry: it wins over a `length`
    /// reason on the same turn, and the truncation counter is not touched by it.
    func testRejection_outranksATruncationReason_onTheSameTurn() async {
        let (stop, appended) = await turn(rejection: "peg-native", doneReason: StreamEvent.lengthDoneReason)
        guard case .continueLoop = stop else { return XCTFail("\(stop)") }
        XCTAssertTrue((appended[0].content ?? "").contains("could not parse"))
        XCTAssertEqual(parseFailures, 1)

        // Only ONE truncation has been seen after this — no escalation.
        let (second, _) = await turn(doneReason: StreamEvent.lengthDoneReason)
        guard case .continueLoop = second else { return XCTFail("the rejected turn did not count as a truncation: \(second)") }
    }

    // MARK: - Output truncated at the ceiling, no call

    func testTruncation_firstStrike_nudges_secondConsecutiveEscalates() async {
        let (first, appended) = await turn(doneReason: StreamEvent.lengthDoneReason)
        guard case .continueLoop = first else { return XCTFail("\(first)") }
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(
            appended[0].content,
            NoToolTurnNudges.outputTruncated(allowedToolNames: allowed, mode: .native))
        XCTAssertFalse((appended[0].content ?? "").contains("<|call|>"))
        XCTAssertEqual(parseFailures, 0, "a truncation is not a parse failure")

        let (second, appended2) = await turn(doneReason: StreamEvent.lengthDoneReason)
        guard case .needsSupervisorInput(let question, _) = second else {
            return XCTFail("second consecutive truncation must escalate, got \(second)")
        }
        XCTAssertEqual(
            question,
            LLMExecutionService.outputTruncatedEscalationQuestion(
                roleName: Role.softwareEngineer.displayName))
        XCTAssertTrue(appended2.isEmpty)
        XCTAssertEqual(delegate.taskToMutate?.runs[0].steps[0].supervisorQuestion, question)
    }

    /// Consecutive means consecutive: an untruncated no-call turn between two cuts resets.
    func testTruncation_counterResets_onAnUntruncatedTurnBetween() async {
        let (a, _) = await turn(doneReason: StreamEvent.lengthDoneReason)
        guard case .continueLoop = a else { return XCTFail("\(a)") }
        let (b, _) = await turn(doneReason: "stop", content: "I will read the file next.")
        guard case .continueLoop = b else { return XCTFail("\(b)") }
        let (c, _) = await turn(doneReason: StreamEvent.lengthDoneReason)
        guard case .continueLoop = c else { return XCTFail("a reset counter must not escalate on the next cut: \(c)") }
    }

    func testTruncation_underPromptTaught_illustratesTheEnvelope() async {
        let (stop, appended) = await turn(doneReason: StreamEvent.lengthDoneReason, mode: .promptTaught)
        guard case .continueLoop = stop else { return XCTFail("\(stop)") }
        XCTAssertTrue((appended[0].content ?? "").contains("<|call|>"),
                      "the prompt-taught clause shows the shape; the native one only names a tool")
    }

    func testTruncation_duringRevision_nudgesWithoutCounting() async {
        delegate.taskToMutate?.runs[0].steps[0].revisionComment = "Supervisor: again"
        for _ in 0..<3 {
            let (stop, _) = await turn(doneReason: StreamEvent.lengthDoneReason)
            guard case .continueLoop = stop else { return XCTFail("\(stop)") }
        }
    }

    /// A `stop` turn with nothing in it takes the ordinary generic path — neither new branch
    /// fires, and `.promptTaught` is the default the helper and the result carry.
    func testAnOrdinaryNoCallTurn_touchesNeitherBranch() async {
        let (stop, appended) = await turn(doneReason: "stop", content: "Working on it.", mode: .promptTaught)
        guard case .continueLoop = stop else { return XCTFail("\(stop)") }
        XCTAssertEqual(appended.count, 1)
        let nudge = appended[0].content ?? ""
        XCTAssertFalse(nudge.contains("could not parse"))
        XCTAssertFalse(nudge.contains("cut off at the output limit"))
        XCTAssertEqual(parseFailures, 0)
    }


    // MARK: - An escalation that cannot persist aborts the step

    /// The delegate refuses the mutation (a torn-down task): the cap has been reached, the
    /// question cannot be written, and the branch fails the step instead of looping on.
    func testRejection_thirdStrike_whenTheQuestionCannotPersist_failsTheStep() async {
        for _ in 0..<2 { _ = await turn(rejection: "peg-native") }
        delegate.taskToMutate = nil
        let (stop, _) = await turn(rejection: "peg-native")
        guard case .toolFailure(let message) = stop else { return XCTFail("\(stop)") }
        XCTAssertTrue(message.contains("Native-call rejection cap exceeded"), message)
        XCTAssertTrue(message.contains("escalation failed to persist"), message)
    }

    func testTruncation_secondStrike_whenTheQuestionCannotPersist_failsTheStep() async {
        _ = await turn(doneReason: StreamEvent.lengthDoneReason)
        delegate.taskToMutate = nil
        let (stop, _) = await turn(doneReason: StreamEvent.lengthDoneReason)
        guard case .toolFailure(let message) = stop else { return XCTFail("\(stop)") }
        XCTAssertTrue(message.contains("Output-truncation cap exceeded"), message)
    }


    // MARK: - The near-miss sentinel cap shares the arms (prompt-taught)

    /// `<|call|` with a payload and no closing `>` is a near-miss the repair refuses: the same
    /// 3-strike counter, so a revision must reset it exactly as it does for the other arms.
    private static let nearMissTurn = #"<|call|read_file{"path":"a.swift"}"#

    func testNearMissSentinel_revisionResetsTheCounter() async {
        for _ in 0..<2 {
            let (stop, _) = await turn(content: Self.nearMissTurn, mode: .promptTaught)
            guard case .continueLoop = stop else { return XCTFail("\(stop)") }
        }
        delegate.taskToMutate?.runs[0].steps[0].revisionComment = "Supervisor: try again"
        let (third, _) = await turn(content: Self.nearMissTurn, mode: .promptTaught)
        guard case .continueLoop = third else { return XCTFail("a revision resets the count; got \(third)") }
        XCTAssertNil(delegate.taskToMutate?.runs[0].steps[0].supervisorQuestion)
    }

    func testNearMissSentinel_thirdStrike_whenTheQuestionCannotPersist_failsTheStep() async {
        for _ in 0..<2 { _ = await turn(content: Self.nearMissTurn, mode: .promptTaught) }
        delegate.taskToMutate = nil
        let (stop, _) = await turn(content: Self.nearMissTurn, mode: .promptTaught)
        guard case .toolFailure(let message) = stop else { return XCTFail("\(stop)") }
        XCTAssertTrue(message.contains("Sentinel-failure cap exceeded"), message)
        XCTAssertTrue(message.contains("escalation failed to persist"), message)
    }


    // MARK: - The truncation counter is CONSECUTIVE across dispatched turns too

    /// A dispatched turn never enters `handleNoToolCalls`, so the centralised reset that runs
    /// before every dispatch (`resetCountersOnParseableToolCall`) must clear this counter as
    /// well: `length` → a real call → `length` is two cuts, not two consecutive ones.
    func testTruncation_aParseableCallBetweenTwoCuts_resetsTheCounter() async {
        _ = await turn(doneReason: StreamEvent.lengthDoneReason)
        service.resetCountersOnParseableToolCall(stepID: stepID, taskID: task.id)
        let (stop, appended) = await turn(doneReason: StreamEvent.lengthDoneReason)
        guard case .continueLoop = stop else { return XCTFail("\(stop)") }
        XCTAssertEqual(appended.count, 1, "the first-strike nudge again, not the escalation")
        XCTAssertNil(delegate.taskToMutate?.runs[0].steps[0].supervisorQuestion)
    }

    // MARK: - A rejection is a turn on the wire, and the card files the attempt

    /// Nothing of the refused call reaches the client on Ollama (the grammar refuses before
    /// any delta): the wire still gets an assistant turn, so the nudge that anchors on "the
    /// turn immediately before this note" names a turn the model can see.
    func testRejectedTurn_withNoContent_stillAppendsAnAssistantTurn() async {
        var messages = [ChatMessage(role: .user, content: "go")]
        let result = LLMExecutionService.StreamingResult(
            assistantContent: "", thinkingContent: "", resolvedToolCalls: [],
            sawHarmonyMarker: false, harmonyBuffer: "",
            nativeCallRejection: "peg-native", toolCallingMode: .native)
        await service.processStreamingResult(
            result, stepID: stepID, taskID: task.id, conversationMessages: &messages)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertTrue((messages.last?.toolCalls ?? []).isEmpty)
    }

    /// The attempt goes to the CARD, never onto the wire: the model is not shown its refused
    /// call in a syntax the provider's parser never reads.
    func testRejection_filesTheAttemptOnTheCard_notOnTheWire() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: delegate.taskToMutate ?? task, roleDefinition: nil,
            conversationMessages: &messages, allowedToolNames: allowed,
            nativeCallRejection: "peg-native",
            nativeCallAttempt: #"read_file {"path":"a.swift"}"#, toolCallingMode: .native)
        let card = delegate.taskToMutate?.runs[0].steps[0].toolCalls.last
        XCTAssertEqual(card?.name, "rejected_tool_call")
        XCTAssertTrue(card?.argumentsJSON.contains(#"read_file {"path":"a.swift"}"#) == true, card?.argumentsJSON ?? "nil")
        XCTAssertFalse(messages.contains { $0.content?.contains("a.swift") == true }, "the wire carries the nudge only")
    }

    func testRenderedAttempt_oneLinePerCall_nilWhenNothingStreamed() {
        XCTAssertNil(LLMExecutionService.renderedAttempt([]))
        XCTAssertEqual(
            LLMExecutionService.renderedAttempt([
                StepToolCall(providerID: nil, name: "read_file", argumentsJSON: #"{"path":"a"}"#),
                StepToolCall(providerID: "c2", name: "git_status", argumentsJSON: ""),
            ]),
            "read_file {\"path\":\"a\"}\ngit_status")
    }
}
