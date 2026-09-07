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

    // MARK: - The ChatML wrapper (MeditationApp task 39 run 1, 2026-09-07)

    /// A SECOND defect from the same model, and structurally the inverse of the one above.
    ///
    /// Here the envelope parses and the call dispatches — nothing fails, nothing is
    /// classified, nothing is nudged. What leaks is the model's own native ChatML tag
    /// wrapped AROUND the canonical envelope the prompt teaches:
    ///
    ///     …and ContentView.swift.<tool_call>
    ///     <|call|>{"name":"read_file","arguments":{"path":"MeditationApp/ContentView.swift"}}
    ///     <|end|>
    ///     </tool_call>
    ///
    /// The opening tag sits BEFORE the earliest marker, so the truncation rewind keeps it
    /// in `assistantCollected`; `ModelTokenCleaner` cannot see it (its contract is `<|…|>`
    /// spans, and this form has no pipes); `displayContent` is the identity for assistant
    /// turns and the bubble is a plain `NSTextView`. So it rendered verbatim to the user
    /// AND rode the append-only wire, where it became the model's own freshest example.
    ///
    /// Measured over the run's 28 assistant turns: phase 1 (17 turns) was clean, phase 2
    /// slipped on its FIRST turn, and 10 of 10 non-empty turns after that carried the tag —
    /// 64 occurrences replayed back across all requests. The gap between tag and marker
    /// was a single `\n` every time.
    private let wrappedProse = "I'll start by reading the key files to understand the "
        + "current structure before implementing the Today tab. Let me first look at the "
        + "folder layout and ContentView.swift."

    private var wrappedEnvelopeDeltas: [String] {
        [
            wrappedProse + "<tool_call>\n",
            #"<|call|>{"name":"read_file","arguments":{"path":"MeditationApp/ContentView.swift"}}"#,
            "\n<|end|>\n</tool_call>",
        ]
    }

    /// Two postconditions, and the first is an EQUALITY rather than a `!contains`: the tag
    /// must be gone AND the prose must be exactly what the model wrote. A `!contains`
    /// assertion passes just as well when the whole turn is swallowed.
    func testMeditationApp_chatMLWrappedEnvelope_resolvesAndLeavesCleanProse() async throws {
        let result = try await replayFull(
            reasoning: "Let me look at the folder layout first.",
            contentDeltas: wrappedEnvelopeDeltas)
        XCTAssertEqual(result.assistantContent, wrappedProse)
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.readFile)
        XCTAssertTrue(
            result.resolvedToolCalls.first?.argumentsJSON
                .contains("MeditationApp/ContentView.swift") ?? false,
            "the path must reach the handler byte-for-byte")
    }

    /// **The pin the loop descends from.** Everything else here is a symptom; this is the
    /// link that turned one slip into ten. `processStreamingResult` is what writes the
    /// assistant turn onto the wire, and the wire is append-only (R3.9.1), so a tag that
    /// survives here is re-presented to the model as its own most recent call shape on
    /// every subsequent request.
    func testMeditationApp_chatMLWrapper_neverReachesTheWire() async throws {
        let result = try await replayFull(
            reasoning: "Let me look at the folder layout first.",
            contentDeltas: wrappedEnvelopeDeltas)
        var conversation: [ChatMessage] = []
        await service.processStreamingResult(
            result, stepID: stepID, taskID: taskID, conversationMessages: &conversation)

        let assistantTurns = conversation.filter { $0.role == .assistant }
        XCTAssertEqual(assistantTurns.count, 1)
        XCTAssertEqual(assistantTurns.first?.content, wrappedProse)
        for message in conversation {
            XCTAssertFalse(message.content?.contains("<tool_call>") ?? false,
                           "the wire must not carry the tag back to the model")
        }
    }

    /// The persisted/displayed half of the same turn — `commitStreaming` is what the
    /// activity feed renders, and it is a separate funnel from the wire.
    func testMeditationApp_chatMLWrapper_commitCarriesNoTag() async throws {
        _ = try await replayFull(
            reasoning: "Let me look at the folder layout first.",
            contentDeltas: wrappedEnvelopeDeltas)
        let commit = try XCTUnwrap(mockDelegate.commitStreamingCalls.last)
        XCTAssertEqual(commit.2, wrappedProse)
    }

    /// Records 68 and 80: the whole visible turn WAS the tag. Stripping it leaves empty
    /// content — which is correct and not a regression, because such a turn still carries
    /// reasoning, and `ActivityFeedBuilder` keeps a message with no content but with
    /// thinking as a thinking-only row (exactly how an ordinary envelope-only turn already
    /// renders). Also the `floor` boundary: the tag starts at buffer position 0.
    func testMeditationApp_tagOnlyTurn_commitsEmptyContentAndStaysAThinkingRow() async throws {
        let result = try await replayFull(
            reasoning: "I need to read the view model before editing it.",
            contentDeltas: [
                "<tool_call>\n",
                #"<|call|>{"name":"read_file","arguments":{"path":"MeditationApp/TodayView.swift"}}"#,
                "\n<|end|>\n</tool_call>",
            ])
        XCTAssertEqual(result.assistantContent, "")
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.readFile)

        let commit = try XCTUnwrap(mockDelegate.commitStreamingCalls.last)
        XCTAssertEqual(commit.2, "", "content is empty — the tag was the entire turn")
        XCTAssertNotNil(commit.3, "thinking is what keeps the row on screen")
    }

    /// The tag straddles a delta boundary, so the windowed detector must still latch and
    /// the full-buffer normalize must still see the wrapper whole.
    func testMeditationApp_wrapperTagSplitAcrossDeltas_stillStripped() async throws {
        let result = try await replayFull(
            reasoning: "Reading the file.",
            contentDeltas: [
                "Checking the layout.<tool_c",
                "all>\n<|ca",
                #"ll|>{"name":"read_file","arguments":{"path":"a.swift"}}<|end|>"#,
            ])
        XCTAssertEqual(result.assistantContent, "Checking the layout.")
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.readFile)
    }

    /// Composition with the 2026-09-05 family from the same model: the wrapper must not
    /// survive in front of a sentinel this same pass repairs, or the leak just moves one
    /// family to the left.
    func testMeditationApp_wrapperAroundTruncatedSentinel_bothRepaired() async throws {
        let result = try await replayFull(
            reasoning: "Checking git.",
            contentDeltas: [
                "Let me check git.<tool_call>\n",
                #"<|call|{"name":"bash","arguments":{"command":"git status"}}"#,
            ])
        XCTAssertEqual(result.assistantContent, "Let me check git.")
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.bash)
    }

    /// The wrapper is stripped before ANY marker the streamer latches on — the family is
    /// `HarmonyToolCallParser.harmonyMarkers`, not a `<|call|>` literal.
    func testMeditationApp_wrapperBeforeChannelForm_stripped() async throws {
        let result = try await replayFull(
            reasoning: "Reading the file.",
            contentDeltas: [
                "Looking now.<tool_call>\n",
                ##"<|channel|>commentary to=functions.read_file <|constrain|>json<|message|>{"name":"read_file","arguments":{"path":"a.swift"}}"##,
            ])
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertEqual(result.assistantContent, "Looking now.")
    }

    /// The branch `ModelTokenCleaner` could never have covered. With zero resolved calls
    /// the turn is rebuilt from `unresolvedEnvelopeAnchor`, which carries the raw
    /// `harmonyBuffer` and is deliberately never `clean`ed — evidence beats cleanliness
    /// (2026-08-14). It is covered here only because `harmonyBuffer` is assigned from the
    /// ALREADY-normalized `uiBuffer`. Assert on the whole joined turn, since the anchor is
    /// appended to the prose and the tag could hide in either half.
    func testMeditationApp_unresolvedAnchorCarriesNoOpeningTag() async throws {
        let result = try await replayFull(
            reasoning: "Let me check git.",
            contentDeltas: [
                "guard_core.gd is missing. Let me check git.<tool_call>\n",
                #"<|call|>{"name":"bash","arguments":{"command":"echo \"---exit $?---"; git status"}}"#,
            ])
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertTrue(result.resolvedToolCalls.isEmpty, "the payload cannot parse — that is the fixture")
        XCTAssertFalse(result.harmonyBuffer.contains("<tool_call>"),
                       "the anchor's source must already be clean")

        var conversation: [ChatMessage] = []
        await service.processStreamingResult(
            result, stepID: stepID, taskID: taskID, conversationMessages: &conversation)
        for message in conversation {
            XCTAssertFalse(message.content?.contains("<tool_call>") ?? false,
                           "neither half of the anchor join may carry the tag")
        }
    }

    // MARK: - The whitespace gap (MeditationApp task 39 run 8, 2026-09-06)

    /// A THIRD shape from the same model, and the one the 2026-09-05 repair was pinned
    /// AGAINST: `<|call|` followed by a SPACE and then the payload. The abutment rule was
    /// stated as "the prefix is a prefix of `<|call|>`, so any tolerance reaches shapes
    /// that already parse" — true for a debris run, false for whitespace, because
    /// `prefixTable` is longest-first and a `.truncatedCanonical` hit therefore proves the
    /// next character is not `>`. The pin was written on 2026-09-05 with the fixture
    /// `<|call| {"name":"search"}`; the model produced exactly that string the next day.
    ///
    /// Measured over this run's 117 log records: 17 responses carried the shape, 0 resolved,
    /// and the role received `You haven't submitted all expected artifacts yet` 16 times
    /// for a format defect — 18 `retryNudge` turns in `step_log.jsonl` in total.

    /// Record 83, verbatim — the first implementation-phase slip, two envelopes in one turn.
    func testMeditationApp_gapSentinel_resolvesBothEnvelopes() async throws {
        let result = try await replayFull(
            reasoning: "Let me read SessionDetailView and SessionPlayerView to understand "
                + "how sessions are opened and how the player works.",
            contentDeltas: [
                #"<|call| {"name":"read_file", "arguments": {"path": "MeditationApp/SessionPlayer.swift"}}<|end|>"# + "\n",
                #"<|call| {"name":"read_file", "arguments": {"path": "MeditationApp/SessionPlayerView.swift"}}<|end|>"#,
            ])
        XCTAssertTrue(result.sawHarmonyMarker,
                      "the latch every downstream diagnosis sits behind must close")
        XCTAssertEqual(result.resolvedToolCalls.count, 2)
        XCTAssertEqual(result.resolvedToolCalls.map(\.name), [ToolNames.readFile, ToolNames.readFile])
        XCTAssertTrue(
            result.resolvedToolCalls.first?.argumentsJSON.contains("SessionPlayer.swift") ?? false)
    }

    /// Record 85, verbatim — prose, the gap sentinel, and `<|end|>` on its own line.
    /// The EQUALITY is the load-bearing half: the user's report was that the marker
    /// rendered in the bubble, and `assistantContent` is what `commitStreaming` persists.
    func testMeditationApp_gapSentinelAfterProse_leavesCleanProse() async throws {
        let result = try await replayFull(
            reasoning: "I need to continue reading the necessary files.",
            contentDeltas: [
                "I need to continue reading the necessary files before making changes. "
                    + "Let me read the remaining files.\n",
                #"<|call| {"name":"read_file", "arguments": {"path": "MeditationApp/SessionPlayer.swift"}}"# + "\n<|end|>",
            ])
        XCTAssertEqual(
            result.assistantContent,
            "I need to continue reading the necessary files before making changes. "
                + "Let me read the remaining files.")
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.readFile)
    }

    /// Record 60 — the planning-phase turn the whole cascade descends from. Unparsed, it
    /// was recorded as the step's PLAN and carried across the phase boundary into the
    /// implementation wire's first USER turn, where it rode every later request as the
    /// most authoritative example in the conversation.
    func testMeditationApp_gapSentinel_planningTurn_resolvesToSearch() async throws {
        let result = try await replayFull(
            reasoning: "Let me verify what views exist.",
            contentDeltas: [
                "TodayModel and TodayView are untracked leftovers that don't match the "
                    + "committed ContentView reference (`TodayDashboardView`) nor the actual "
                    + "model APIs. Let me gather what views exist so I can fix the Today tab to build.\n",
                #"<|call| {"name":"search","arguments":{"query":": View"}}<|end|>"#,
            ])
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.search)
        XCTAssertFalse(result.assistantContent.contains("<|call|"),
                       "an unparsed marker here becomes the step's durable plan")
    }

    /// The gap sentinel must not reach the append-only wire, for the same reason the
    /// wrapper must not: it returns as the model's own freshest call shape. Over this run
    /// it did, 18 times, and the model never recovered the canonical form.
    func testMeditationApp_gapSentinel_neverReachesTheWire() async throws {
        let result = try await replayFull(
            reasoning: "Reading the player.",
            contentDeltas: [
                #"<|call| {"name":"read_file", "arguments": {"path": "MeditationApp/SessionPlayer.swift"}}<|end|>"#
            ])
        var conversation: [ChatMessage] = []
        await service.processStreamingResult(
            result, stepID: stepID, taskID: taskID, conversationMessages: &conversation)
        for message in conversation {
            XCTAssertFalse(message.content?.contains("<|call| ") ?? false,
                           "the wire must not carry the broken form back to the model")
        }
    }

    /// Record 115 — the turn that finally escaped the loop. It opens with a bare `<|` on
    /// its own line, then a healthy envelope. The truncation rewind cuts at the earliest
    /// marker, so the two characters survived as prose and reached the user as a
    /// two-character bubble; `ModelTokenCleaner` cannot see them (no `|>` follows).
    func testMeditationApp_danglingSentinelOpen_leavesNoResidueInProse() async throws {
        let result = try await replayFull(
            reasoning: "The create_artifact doesn't seem to be taking. Let me submit it.",
            contentDeltas: [
                "<|\n",
                ##"<|call|>{"name":"create_artifact","arguments":{"name":"Engineering Notes","content":"# Notes","format":"markdown"}}"##,
            ])
        XCTAssertEqual(result.assistantContent, "",
                       "the dangling opener must not survive as visible assistant prose")
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.createArtifact)
    }
}
