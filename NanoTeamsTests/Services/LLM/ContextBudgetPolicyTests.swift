import XCTest

@testable import NanoTeams

/// Corner coverage for `ContextBudgetPolicy` — the pre-send check that tells the user a
/// prompt no longer fits the model's context window.
///
/// The failure it guards is silent: an oversized prompt is not rejected, it is truncated
/// from the START (dropping the system prompt and tool catalog) and answered HTTP 200. The
/// user sees "the role ignored its instructions" with nothing pointing at the cause.
final class ContextBudgetPolicyTests: XCTestCase {

    // MARK: - verdict: a failed probe must never manufacture a warning

    func testVerdict_nilContextLength_isUnknown() {
        XCTAssertEqual(
            ContextBudgetPolicy.verdict(promptTokens: 1_000_000, contextLength: nil), .unknown,
            "no probe ⇒ no opinion; a wrong overflow warning is worse than silence")
    }

    func testVerdict_nonPositiveContextLength_isUnknown_notExceeded() {
        for bogus in [0, -1, Int.min] {
            XCTAssertEqual(
                ContextBudgetPolicy.verdict(promptTokens: 10, contextLength: bogus), .unknown,
                "a zero/negative window is a broken probe, not a tiny window")
        }
    }

    // MARK: - verdict: the boundary

    func testVerdict_exactlyAtTheWindow_isExceeded() {
        XCTAssertEqual(
            ContextBudgetPolicy.verdict(promptTokens: 4096, contextLength: 4096),
            .exceeded(promptTokens: 4096, contextLength: 4096),
            "a prompt that fills the window leaves no room to generate into")
    }

    func testVerdict_oneBelowTheWindow_isWithinBudget() {
        XCTAssertEqual(
            ContextBudgetPolicy.verdict(promptTokens: 4095, contextLength: 4096),
            .withinBudget(promptTokens: 4095, contextLength: 4096))
    }

    func testVerdict_emptyPromptAgainstTinyWindow_isWithinBudget() {
        XCTAssertEqual(
            ContextBudgetPolicy.verdict(promptTokens: 0, contextLength: 1),
            .withinBudget(promptTokens: 0, contextLength: 1))
    }

    func testVerdict_isExceededFlag_matchesTheCase() {
        XCTAssertTrue(ContextBudgetPolicy.verdict(promptTokens: 99, contextLength: 10).isExceeded)
        XCTAssertFalse(ContextBudgetPolicy.verdict(promptTokens: 1, contextLength: 10).isExceeded)
        XCTAssertFalse(
            ContextBudgetPolicy.verdict(promptTokens: 99, contextLength: nil).isExceeded,
            "unknown must not read as exceeded at any call site")
    }

    /// The estimator over-counts by design, so the threshold sits exactly at the window with
    /// no extra safety margin stacked on top. Pinned: lowering this re-introduces warnings on
    /// prompts that fit, and a warning nobody believes is worse than no warning.
    func testOverflowFraction_isExactlyTheWindow() {
        XCTAssertEqual(ContextBudgetPolicy.overflowFraction, 1.0)
    }

    // MARK: - estimateTokens

    func testEstimate_emptyRequest_isZero() {
        XCTAssertEqual(ContextBudgetPolicy.estimateTokens(messages: []), 0)
    }

    func testEstimate_nilContentMessage_contributesNothing() {
        let msg = ChatMessage(role: .assistant, content: nil)
        XCTAssertEqual(ContextBudgetPolicy.estimateTokens(messages: [msg]), 0)
    }

    func testEstimate_sumsEveryMessageBody() {
        let body = String(repeating: "a", count: 350)
        let one = ContextBudgetPolicy.estimateTokens(
            messages: [ChatMessage(role: .user, content: body)])
        let three = ContextBudgetPolicy.estimateTokens(
            messages: (0..<3).map { _ in ChatMessage(role: .user, content: body) })
        XCTAssertGreaterThan(one, 0)
        XCTAssertEqual(three, one * 3)
    }

    /// `toolSchemaText` is whatever the CLIENT will still append to the system prompt — empty
    /// when the messages already carry the catalog, which for a role step they always do. The
    /// caller owns that gate (`NativeLMStudioClient.toolSchemaTextForMeasurement`, pinned by
    /// `ContextBudgetWireParityTests`); this function stays a pure sum. It is also the largest
    /// fixed cost in a small window, so when it IS appended, omitting it would under-count
    /// exactly the requests most likely to overflow.
    func testEstimate_countsWhateverTheClientWillAppend() {
        let schema = String(repeating: "tool catalog ", count: 200)
        let without = ContextBudgetPolicy.estimateTokens(messages: [])
        let with = ContextBudgetPolicy.estimateTokens(messages: [], toolSchemaText: schema)
        XCTAssertEqual(without, 0)
        XCTAssertGreaterThan(with, 0)
    }

    /// A base64 screenshot is the single most likely thing to blow a small window; counting
    /// its characters is wrong in detail and right in direction.
    func testEstimate_countsImagePayloads() {
        let payload = String(repeating: "Q", count: 4000)
        let textOnly = ChatMessage(role: .user, content: "look")
        let withImage = ChatMessage(
            role: .user, content: "look",
            imageContent: [ImageContent(base64Data: payload, mimeType: "image/png")])
        XCTAssertGreaterThan(
            ContextBudgetPolicy.estimateTokens(messages: [withImage]),
            ContextBudgetPolicy.estimateTokens(messages: [textOnly]))
    }

    /// Same heuristic as the work-folder context planner, so the two surfaces cannot drift
    /// into disagreeing about what "too big" means.
    func testEstimate_delegatesToTheSharedEstimator() {
        let text = "Проверка кириллицы and ASCII mixed together."
        XCTAssertEqual(
            ContextBudgetPolicy.estimateTokens(messages: [ChatMessage(role: .user, content: text)]),
            WorkFolderContextPromptPlanner.estimateTokens(text))
    }

    // MARK: - estimateTokens: tool-call envelopes

    /// Both builders re-materialize `ChatMessage.toolCalls` as Harmony envelope text, because
    /// the streaming path truncates that envelope out of the assistant `content`. An
    /// envelope-only turn therefore has `content == nil` and used to be priced at zero while
    /// the wire carried the whole thing.
    ///
    /// Exact, not a tolerance: the fix adds precisely the shared renderer's output, so anything
    /// else means the estimator grew a second opinion about the format.
    func testEstimate_countsToolCallEnvelopes_exactly() {
        let call = ChatToolCall(
            id: "tc-1", name: "read_file", argumentsJSON: #"{"path":"NanoTeams/App.swift"}"#)
        let withCalls = ChatMessage(role: .assistant, content: "checking", toolCalls: [call])
        let withoutCalls = ChatMessage(role: .assistant, content: "checking")

        XCTAssertEqual(
            ContextBudgetPolicy.estimateTokens(messages: [withCalls])
                - ContextBudgetPolicy.estimateTokens(messages: [withoutCalls]),
            WorkFolderContextPromptPlanner.estimateTokens(
                HarmonyToolCallEnvelope.appendedWireText(for: withCalls)))
    }

    /// Neither builder reads `toolCalls` outside the `.assistant` branch, so neither may the
    /// estimator — the type permits the field on any role.
    func testEstimate_toolCallsOnANonAssistantRole_costNothing() {
        let call = ChatToolCall(id: "a", name: "read_file", argumentsJSON: "{}")
        XCTAssertEqual(
            ContextBudgetPolicy.estimateTokens(
                messages: [ChatMessage(role: .tool, content: "x", toolCalls: [call])]),
            ContextBudgetPolicy.estimateTokens(
                messages: [ChatMessage(role: .tool, content: "x")]))
    }

    /// Why this omission mattered more than the labels and joins the wire-parity test tolerates:
    /// those are a fixed few tokens per message, whereas `argumentsJSON` is unbounded —
    /// `create_artifact` / `write_file` / `edit_file` carry the entire body, and it is resent on
    /// every remaining iteration of the step.
    func testEstimate_unboundedArgument_movesTheFigureByThousands() {
        let body = String(repeating: "deliverable prose. ", count: 700)  // ~13 KB
        let turn = ChatMessage(
            role: .assistant, content: nil,
            toolCalls: [ChatToolCall(
                id: "a", name: "create_artifact",
                argumentsJSON: #"{"name":"Release Notes","content":""# + body + #""}"#)])
        XCTAssertGreaterThan(
            ContextBudgetPolicy.estimateTokens(messages: [turn]), 3000,
            "an envelope-only turn used to price at zero")
    }

    // MARK: - warningMessage

    func testWarningMessage_namesModelBothNumbersAndTruncationDirection() {
        let msg = ContextBudgetPolicy.warningMessage(
            modelName: "qwen3.6:35b", promptTokens: 9000, contextLength: 4096, provider: .ollama)
        XCTAssertTrue(msg.contains("qwen3.6:35b"))
        XCTAssertTrue(msg.contains("9000"))
        XCTAssertTrue(msg.contains("4096"))
        XCTAssertTrue(
            msg.lowercased().contains("start"),
            "which END gets truncated is the whole point — it explains why instructions vanish")
    }

    /// The remedy is server-specific, and pointing at the wrong server's setting sends the
    /// user somewhere that does not exist.
    func testWarningMessage_remedyIsProviderSpecific() {
        let ollama = ContextBudgetPolicy.warningMessage(
            modelName: "m", promptTokens: 9000, contextLength: 4096, provider: .ollama)
        let lmStudio = ContextBudgetPolicy.warningMessage(
            modelName: "m", promptTokens: 9000, contextLength: 4096, provider: .lmStudio)
        XCTAssertTrue(ollama.contains("OLLAMA_CONTEXT_LENGTH"))
        XCTAssertTrue(ollama.contains("num_ctx"))
        XCTAssertTrue(lmStudio.contains("LM Studio"))
        XCTAssertFalse(
            lmStudio.contains("OLLAMA_CONTEXT_LENGTH"),
            "an LM Studio user has no OLLAMA_CONTEXT_LENGTH to raise")
    }
}
