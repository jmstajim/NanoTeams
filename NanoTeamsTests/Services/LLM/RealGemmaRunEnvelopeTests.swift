import XCTest

@testable import NanoTeams

/// Replays the actual `google/gemma-4-e4b` FAANG run the user captured
/// (`network_log.json`), one test per role turn. Each fixture uses the VERBATIM
/// envelope structure and trailing garbage from the log; only long markdown
/// `content` bodies are excerpted (content text is parsing-irrelevant — the
/// markers, escaping, and trailing junk are what matter).
///
/// Wire split: the log renders the reasoning channel as `[reasoning]…[/reasoning]`
/// (see `NativeLMStudioClient` responseBody assembly), but on the wire reasoning
/// arrives via `reasoning.delta` and the `<|call|>` envelope via `message.delta`.
/// So each fixture feeds reasoning as `thinkingDelta` and the post-`[/reasoning]`
/// payload as `contentDelta`.
///
/// Each assertion is annotated with the log record id and the outcome the run
/// actually produced (the next request's `[Tool Result]` / nudge).
@MainActor
final class RealGemmaRunEnvelopeTests: XCTestCase {

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
    private let stepID = "step0"
    private let taskID = 0

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

    /// Feeds `reasoning` on the reasoning channel and `content` on the content
    /// channel (the real wire split), returns the resolved tool calls.
    private func replay(reasoning: String, content: String) async throws -> [StepToolCall] {
        mockClient.deltas = [
            StreamEvent(thinkingDelta: reasoning),
            StreamEvent(contentDelta: content),
        ]
        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .productManager,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], networkLogger: nil
        )
        return result.resolvedToolCalls
    }

    /// Same wire split, but returns the whole result so a test can assert on the
    /// marker flag, the preserved envelope, and the visible prose.
    private func replayFull(
        reasoning: String, content: String
    ) async throws -> LLMExecutionService.StreamingResult {
        mockClient.deltas = [
            StreamEvent(thinkingDelta: reasoning),
            StreamEvent(contentDelta: content),
        ]
        return try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .productManager,
            client: mockClient, config: LLMConfig(),
            tools: [], conversationMessages: [], networkLogger: nil
        )
    }

    // MARK: - MeditationApp run, 2026-08-07 — the two silently dropped calls

    /// Record `[33]` @13:51:15.910Z, verbatim. Garbled OPENING sentinel plus the stray
    /// `|` this model appends in 30% of envelopes. Before the normalizer both defects
    /// had to be survived at once and neither was: `sawHarmonyMarker` stayed false, and
    /// `BareToolCallSalvage` Rule A rejected the payload on the single trailing `|`.
    /// The JSON then reached the user as a chat bubble and was recorded as the step's
    /// plan.
    func testMeditationApp_record33_garbledSentinelPlusStrayPipe_resolves() async throws {
        let result = try await replayFull(
            reasoning: "I should list files inside the `MeditationApp` directory.",
            content: #"<|tool_call>call|>{"name":"list_files","arguments":{"path":"MeditationApp"}}|<|<end|>"#
        )
        XCTAssertTrue(result.sawHarmonyMarker)
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.listFiles)
        XCTAssertTrue(result.assistantContent.isEmpty,
                      "the envelope must never survive as visible assistant prose")
    }

    /// Record `[39]` @13:52:24.821Z, body excerpted. The model invented a batch schema
    /// (`call_multiple` + `{"contributions":[…]}`) NanoTeams never advertised.
    ///
    /// This deliberately does NOT resolve: the payload carries no top-level `name`, and
    /// a batch envelope contradicts the one-tool-per-response rule. What the fix buys is
    /// that the failure becomes NAMEABLE — `sawHarmonyMarker` is now set, so
    /// `classifyHarmonyCallIssue` (gated on it) can run at all, and `ModelTokenCleaner`
    /// no longer eats the payload on the way. Before, the model was told only "you
    /// haven't submitted all expected artifacts" — for an attempt the harness had
    /// swallowed.
    ///
    /// The named defect is `.malformedJSON`, not `.missingToolName`: this record carries
    /// TWO defects, and the closers are wrong (`…"}}}]}`) so the brace walker stops on an
    /// unparseable span before the absent `name` is ever reachable. That is the more
    /// useful of the two nudges here anyway — the JSON genuinely is malformed.
    func testMeditationApp_record39_inventedBatchSchema_isNamedNotSwallowed() async throws {
        let content = #"""
        This completes the implementation of M1. I have introduced a minimal navigation structure using `NavigationView` in `ContentView.swift`.
        
        <|tool_call>call_multiple{"contributions":[{"toolName":"create_artifact","arguments":{"name":"Engineering Notes","content":"# Engineering Notes\n\n## Summary of Work Implemented (M1)\n"}}}]}<|end|>
        """#
        let result = try await replayFull(
            reasoning: "I will submit the Engineering Notes artifact.", content: content)

        XCTAssertTrue(result.sawHarmonyMarker,
                      "the mangled sentinel must be recognised so the diagnostic path is reachable")
        XCTAssertTrue(result.resolvedToolCalls.isEmpty,
                      "an invented batch schema names no tool and must not be inferred into one")
        XCTAssertTrue(result.harmonyBuffer.contains("create_artifact"),
                      "the payload must survive for the diagnostic — this is what ModelTokenCleaner used to eat")
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(in: result.harmonyBuffer)
        XCTAssertEqual(issue, .malformedJSON,
                       "must be classified as a named defect, not `.noCallEnvelope` / `.noEnvelopeAttempt` "
                           + "(which are what an unrecognised sentinel produces, and neither yields a usable nudge)")
        XCTAssertTrue(result.assistantContent.hasPrefix("This completes the implementation of M1."),
                      "genuine pre-marker prose stays visible")
        XCTAssertFalse(result.assistantContent.contains("contributions"),
                       "no part of the envelope may reach the chat as text")
    }

    // MARK: - Product Manager

    /// Record `F241CA4A` (planning). Trailing `}}|<|end|>` — a stray `|` between
    /// the closing braces and `<|end|>`. Log: executed (`updated:true, ok:true`).
    func testPM_updateScratchpad_pipeBeforeEndMarker() async throws {
        let calls = try await replay(
            reasoning: "My first step must be to create a plan using update_scratchpad.",
            content: #"<|call|>{"name":"update_scratchpad","arguments":{"content":"1. Review project requirements and scope definition.\n2. Design the overall system architecture.\n3. Define the API contract.\n4. Identify technology stack components."}}|<|end|>"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.updateScratchpad)
    }

    /// Record `89D3D71E`. Trailing `}}</|end|>` (a `</` mangling of `<|end|>`).
    /// Log: Product Requirements artifact created.
    func testPM_createArtifact_productRequirements_mangledEnd() async throws {
        let calls = try await replay(
            reasoning: "I will draft the Product Requirements now.",
            content: #"<|call|>{"name":"create_artifact","arguments":{"name":"Product Requirements","content":"Problem statement and target users. Acceptance criteria AC1-AC5.\n","format":"markdown"}}</|end|>"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.createArtifact)
    }

    /// Record `0DEC592D`. Clean-ish `list_files` with `}}|<|end|>`.
    func testPM_listFiles_pipeBeforeEndMarker() async throws {
        let calls = try await replay(
            reasoning: "I will use list_files to explore the work folder.",
            content: #"<|call|>{"name":"list_files","arguments":{"path":"SpriteCrAItor"}}|<|end|>"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "list_files")
    }

    // MARK: - Tech Lead

    /// Record `1716B94F` (planning). Garbled marker `<|tool_call>call|>` — the model
    /// spliced its own `<|tool_call|>` sentinel into the `<|call|>` the system prompt
    /// teaches, and the result contains none of the three literal `harmonyMarkers`.
    ///
    /// This assertion is INVERTED from what it pinned before 2026-08-07. It used to
    /// assert `calls.isEmpty` "matches the prose-fallback the run took" — i.e. it froze
    /// the observed behaviour as desired. That behaviour is the defect:
    /// `HarmonySentinelNormalizer` now canonicalises the sentinel, so the call the model
    /// plainly made is dispatched instead of reaching the user as a raw-JSON bubble.
    func testTechLead_updateScratchpad_garbledToolCallMarker_nowResolves() async throws {
        let calls = try await replay(
            reasoning: "I will use update_scratchpad to create my plan.",
            content: #"<|tool_call>call|>{"name":"update_scratchpad","arguments":{"content":"1. Review requirements.\n2. Define architecture."}}"/>"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.updateScratchpad)
    }

    /// Record `F905540C`. Extreme trailing garbage after the balanced object:
    /// `}}"/></body></html>"}},"format":"markdown"}`. The brace walker exits at the
    /// first depth-0 close; the HTML/JSON tag soup after it is ignored.
    /// Log: Implementation Plan artifact created.
    func testTechLead_createArtifact_htmlTagSoupTrailing() async throws {
        let calls = try await replay(
            reasoning: "I will produce the detailed Implementation Plan.",
            content: #"<|call|>{"name":"create_artifact","arguments":{"name":"Implementation Plan","content":"Architecture overview. Step-by-step tasks. Image display.\n"}}"/></body></html>"}},"format":"markdown"}"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.createArtifact)
    }

    // MARK: - UX Designer

    /// Record `898623EB`. The entire Design Spec written as markdown PROSE with no
    /// `<|call|>` at all. Log: "Missing deliverables: Design Spec" nudge — no tool
    /// call. The other "silent" case.
    func testUXDesigner_proseDesignSpec_noMarker_doesNotResolve() async throws {
        let calls = try await replay(
            reasoning: "Let's proceed with generating the Design Spec.",
            content: "Design Specification: SpriteCrAItor (MVP)\n\n1. High-Level User Flow\nThe app follows a linear workflow.\n2. Layout Structure\nHeader, generation panel, output viewer."
        )
        XCTAssertTrue(calls.isEmpty)
    }

    /// Record `BF2AD303`. Missing the outer closing brace (single `}` closes
    /// `arguments`), duplicate `name` key, no `<|end|>`. Depth-1 salvage repairs it.
    /// Log: Design Spec artifact created.
    func testUXDesigner_createArtifact_missingBrace_dupNameKey() async throws {
        let calls = try await replay(
            reasoning: "Now I must submit it using the create_artifact tool call.",
            content: #"<|call|>{"name":"create_artifact","arguments":{"name":"Design Spec","content":"Linear transaction workflow with status updates.\n","format":"markdown","name":"Design Spec"}"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.createArtifact)
    }

    // MARK: - Software Engineer

    /// Record `3E8491E7`. Tool name OUTSIDE the JSON: `<|call|>write_file{…}</|end|>`.
    /// Log: executed (`<§W1§>` write success).
    func testSWE_writeFile_nameOutsideJSON_mangledEnd() async throws {
        let calls = try await replay(
            reasoning: "I will create lmstudio_api_client.py with the client stub.",
            content: #"<|call|>write_file{"path":"lmstudio_api_client.py","content":"import time\n\nclass LMStudioClient:\n    pass\n"}</|end|>"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.writeFile)
    }

    /// Record `A94693F3` (planning). Trailing `}}</extract>` tag.
    /// Log: executed (`content_length:2301, updated:true`).
    func testSWE_updateScratchpad_extractTagTrailing() async throws {
        let calls = try await replay(
            reasoning: "I will plan Phase 1 backend implementation.",
            content: #"<|call|>{"name":"update_scratchpad","arguments":{"content":"Software Engineering Plan: Phase 1.\n1. LMStudio client stub.\n2. FastAPI gateway."}}</extract>"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.updateScratchpad)
    }

    // MARK: - Code Reviewer

    /// Record `8642D338` (planning) — the turn the user pointed at. Trailing
    /// ` maximale}}`, no `<|end|>`. Log: executed (`content_length:489, ok:true`,
    /// "✅ Plan recorded"). The card SHOULD render from this resolved call.
    func testCodeReviewer_updateScratchpad_maximaleTrailing() async throws {
        let calls = try await replay(
            reasoning: "I will start by creating a plan to approach this review comprehensively.",
            content: #"<|call|>{"name":"update_scratchpad","arguments":{"content":"1. Review the artifacts provided.\n2. Analyze the scope.\n3. Critique the limitations.\n4. Structure the review findings."}} maximale}}"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.updateScratchpad)
    }

    /// Record `776A203E`. `create_artifact` Code Review Summary, trailing `</|end|>`.
    /// Log: Code Review Summary artifact created.
    func testCodeReviewer_createArtifact_codeReviewSummary() async throws {
        let calls = try await replay(
            reasoning: "I must now use the create_artifact tool call to make it official.",
            content: #"<|call|>{"name":"create_artifact","arguments":{"name":"Code Review Summary","content":"Overall Status: Approved. No critical bugs found.\n"}}</|end|>"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.createArtifact)
    }

    // MARK: - SRE

    /// Record `F9AB4286` (planning). Trailing `}}"/>`.
    /// Log: executed (`content_length:1765, updated:true`).
    func testSRE_updateScratchpad_slashGtTrailing() async throws {
        let calls = try await replay(
            reasoning: "I will document my SRE architectural review.",
            content: #"<|call|>{"name":"update_scratchpad","arguments":{"content":"SRE Architectural Review.\nReliability MEDIUM. Performance LOW."}}"/>"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.updateScratchpad)
    }

    /// Record `8F775B81`. FLAT payload — `<|call|>` directly followed by the args
    /// object `{content, format, name}` with NO `{"name":"create_artifact",
    /// "arguments":…}` wrapper, then `<tool_call|><afthought>` junk. Some models
    /// collapse the canonical `{"name":"create_artifact","arguments":{"name":
    /// "<Artifact>",…}}` into this flat shape where the top-level `name` is the
    /// ARTIFACT name, not the tool.
    ///
    /// The parser must resolve `create_artifact` (not a tool named after the
    /// artifact) and carry the artifact name through in the arguments.
    func testSRE_createArtifact_flatPayload_resolvesToCreateArtifact() async throws {
        let calls = try await replay(
            reasoning: "I will submit the Production Readiness assessment.",
            content: #"<|call|>{"content":"Production Readiness assessment. Reliability MEDIUM.","format":"markdown","name":"Production Readiness"}<tool_call|><afthought>I have submitted the first artifact.</afthought>"#
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolNames.createArtifact,
                       "Flat artifact-shaped payload must resolve to create_artifact, not a tool named after the artifact")
        XCTAssertTrue(calls.first?.argumentsJSON.contains("Production Readiness") == true,
                      "The artifact name must survive in the arguments")
    }
}
