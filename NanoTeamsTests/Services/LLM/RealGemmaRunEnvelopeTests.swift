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
            session: LLMSession?, logger: NetworkLogger?, stepID: String?, roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let events = deltas
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var mockClient: MockStreamClient!
    private let stepID = "step0"
    private let taskID = 0

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        mockClient = MockStreamClient()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] =
            LLMExecutionService.StepExecutionState()
    }

    override func tearDown() {
        service = nil; mockDelegate = nil; mockClient = nil
        MonotonicClock.shared.reset()
        super.tearDown()
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
            tools: [], conversationMessages: [], session: nil, networkLogger: nil
        )
        return result.resolvedToolCalls
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

    /// Record `1716B94F` (planning). Garbled marker `<|tool_call>call|>` — does NOT
    /// contain the literal `<|call|>` substring, so it never trips
    /// `sawHarmonyMarker`. Log: fell through to the planning prose fallback
    /// ("Plan recorded from your text response") — NO tool call. The "silent" case.
    func testTechLead_updateScratchpad_garbledToolCallMarker_doesNotResolve() async throws {
        let calls = try await replay(
            reasoning: "I will use update_scratchpad to create my plan.",
            content: #"<|tool_call>call|>{"name":"update_scratchpad","arguments":{"content":"1. Review requirements.\n2. Define architecture."}}"/>"#
        )
        XCTAssertTrue(calls.isEmpty,
            "Garbled `<|tool_call>call|>` marker must not resolve (matches the prose-fallback the run took)")
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
