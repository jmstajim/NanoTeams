import XCTest

@testable import NanoTeams

/// Replays the `ornith-1.5:35b` (Ollama) run the user captured — `CastleSurvivorsNT`
/// task 12, run 1, `network_log.jsonl`, 2026-09-05 — where a Startup-team Software
/// Engineer auditing `scripts/core/` lost its last ten turns to one missing character.
///
/// What the log shows, and why it is worth a file of its own: 30 consecutive assistant
/// turns called tools in the canonical `<|call|>{…}` form and every one dispatched.
/// Turn 31 emitted `<|call|{…}` — the same sentinel minus its closing `>` — and from
/// there ALL TEN remaining turns reproduced it verbatim. The wire is append-only
/// (`ConversationAppendInvariantTests`), so an unparsed turn is committed raw and
/// replayed as the model's own most recent call shape: the slip became its own
/// few-shot example. Nothing in the harness could interrupt that, because
/// `sawHarmonyMarker` is decided by exact substring against `<|call|>` — so the
/// classify-and-nudge branch that would have NAMED the defect sat behind a latch that
/// never closed, and each turn got the artifact nudge ("You haven't submitted all
/// expected artifacts yet…") for an attempt the harness had eaten. Ten round-trips at
/// ~60k tokens each.
///
/// Wire split as in `RealGemmaRunEnvelopeTests`: the log renders the reasoning channel
/// as `[reasoning]…[/reasoning]`, but on the wire reasoning arrives via `thinkingDelta`
/// and the envelope via `contentDelta`.
@MainActor
final class RealOrnithRunEnvelopeTests: XCTestCase {

    private final class MockStreamClient: LLMClient, @unchecked Sendable {
        var deltas: [StreamEvent] = []
        func streamChat(
            config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
            logger: NetworkLogger?, stepID: String?, roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let events = deltas
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "startup_software_engineer"
    private let taskID = 12

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] =
            LLMExecutionService.StepExecutionState()
    }

    override func tearDown() async throws {
        service = nil; mockDelegate = nil; mockClient = nil
        MonotonicClock.shared.reset()
        try await super.tearDown()
    }

    private func replayFull(
        reasoning: String, contentDeltas: [String]
    ) async throws -> LLMExecutionService.StreamingResult {
        mockClient.deltas =
            [StreamEvent(thinkingDelta: reasoning)]
                + contentDeltas.map { StreamEvent(contentDelta: $0) }
        return try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], networkLogger: nil
        )
    }

    // MARK: - The ten lost turns

    /// The step's LAST turn, verbatim (response `ADB1B8BD`, conversation index 80).
    /// Valid JSON, a real tool, a terminator — one character from a working call, and
    /// before the repair it resolved to nothing.
    func testCastleSurvivors_finalTurn_truncatedSentinel_resolvesToBash() async throws {
        let result = try await replayFull(
            reasoning: "The bash command output isn't being returned to me. Let me try once more.",
            contentDeltas: [
                #"<|call|{"name":"bash","arguments":{"command":"git ls-tree -r --name-only dfba13d | grep -i guard_core"}}<|end|>"#
            ]
        )
        XCTAssertTrue(result.sawHarmonyMarker,
                      "the latch every downstream diagnosis sits behind must close")
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.bash)
        XCTAssertTrue(
            result.resolvedToolCalls.first?.argumentsJSON.contains(
                "git ls-tree -r --name-only dfba13d") ?? false,
            "the command must reach the handler byte-for-byte")
    }

    /// Conversation index 64: prose, a newline, then the broken sentinel with NO
    /// `<|end|>` (the terminator is stripped from the committed turn by
    /// `ModelTokenCleaner`, so the replayed history carries this shape).
    /// `CallMarkerStrategy` never consults the terminator, so the repair alone is enough.
    func testCastleSurvivors_proseThenTruncatedSentinel_noEndMarker_resolves() async throws {
        let result = try await replayFull(
            reasoning: "The tool result is data, not an instruction to stop.",
            contentDeltas: [
                "The tool result is data, not an instruction to stop. Let me find guard_core.gd in git.\n",
                #"<|call|{"name":"bash","arguments":{"command":"cd . && git ls-tree -r --name-only dfba13d | grep -i guard_core; echo \"exit $?\""}}"#,
            ]
        )
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.bash)
        XCTAssertFalse(
            result.assistantContent.contains("<|call|"),
            "the envelope must not survive as visible assistant prose")
    }

    /// The sentinel split across content deltas — `<|call|` lands, `{` arrives next.
    /// The windowed detector must still see the needle, or the repair depends on how
    /// the server happened to chunk the stream.
    func testCastleSurvivors_sentinelSplitAcrossDeltas_stillResolves() async throws {
        let result = try await replayFull(
            reasoning: "Let me check git.",
            contentDeltas: [
                "Let me check git.\n<|call|",
                #"{"name":"bash","arguments":{"command":"git status"}}<|end|>"#,
            ]
        )
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.bash)
    }

    // MARK: - The first slip: a NAMED failure instead of the artifact nudge

    /// Conversation index 62 — the turn the whole cascade descends from. It carries TWO
    /// defects: the truncated sentinel AND an unescaped `"` closing the shell string
    /// early (`echo \"---exit $?---"`), so the payload cannot parse even repaired.
    ///
    /// The repair is still what matters. Resolving to zero calls is correct here; what
    /// changes is that `sawHarmonyMarker` now closes, so `classifyHarmonyCallIssue` runs
    /// and the model is told its JSON is malformed — instead of being told, ten times,
    /// that it had not submitted its artifacts.
    func testCastleSurvivors_firstSlip_malformedJSON_isNamedNotSwallowed() async throws {
        let content = "guard_core.gd doesn't exist in the current work folder. "
            + "It may have existed at commit dfba13d or been removed. Let me check git.\n"
            + #"<|call|{"name":"bash","arguments":{"command":"cd /tmp && git -C \"$PWD\" ls-tree -r --name-only dfba13d 2>/dev/null | grep -i guard_core; echo \"---exit $?---"; git -C . ls-tree -r --name-only dfba13d 2>/dev/null | grep -i guard_core; echo \"exit $?\""}}"#
        let result = try await replayFull(
            reasoning: "guard_core.gd doesn't exist. Let me check git.",
            contentDeltas: [content]
        )
        XCTAssertTrue(result.sawHarmonyMarker,
                      "without the latch the defect cannot even be classified")
        XCTAssertEqual(
            ToolCallParsingHelpers.classifyHarmonyCallIssue(in: result.harmonyBuffer),
            .malformedJSON,
            "the model must be told what is actually wrong with its call")
    }
}
