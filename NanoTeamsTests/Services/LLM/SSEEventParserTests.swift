import XCTest
@testable import NanoTeams

final class SSEEventParserTests: XCTestCase {

    private var parser: SSEEventParser!

    override func setUp() {
        super.setUp()
        parser = SSEEventParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - Content Delta

    func testContentDelta_returnsContent() {
        _ = parser.parse(line: "event: message.delta")
        let result = parser.parse(line: "data: {\"content\": \"Hello\"}")
        if case .contentDelta(let text) = result {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected contentDelta, got \(String(describing: result))")
        }
    }

    // MARK: - Thinking Delta

    func testThinkingDelta_returnsThinking() {
        _ = parser.parse(line: "event: reasoning.delta")
        let result = parser.parse(line: "data: {\"content\": \"Let me think...\"}")
        if case .thinkingDelta(let text) = result {
            XCTAssertEqual(text, "Let me think...")
        } else {
            XCTFail("Expected thinkingDelta, got \(String(describing: result))")
        }
    }

    // MARK: - Chat End

    func testChatEnd_returnsUsage() {
        _ = parser.parse(line: "event: chat.end")
        let json = "{\"response_id\": \"resp-123\", \"stats\": {\"input_tokens\": 100, \"total_output_tokens\": 50}}"
        let result = parser.parse(line: "data: \(json)")
        // `response_id` is deliberately dropped — nothing resumes a chain.
        if case .chatEnd(let usage, _, _, _) = result {
            XCTAssertEqual(usage?.inputTokens, 100)
            XCTAssertEqual(usage?.outputTokens, 50)
        } else {
            XCTFail("Expected chatEnd, got \(String(describing: result))")
        }
    }

    // MARK: - Error

    func testError_returnsMessage() {
        _ = parser.parse(line: "event: error")
        let result = parser.parse(line: "data: {\"message\": \"Model not loaded\"}")
        if case .error(let msg) = result {
            XCTAssertEqual(msg, "Model not loaded")
        } else {
            XCTFail("Expected error, got \(String(describing: result))")
        }
    }

    func testError_noMessage_defaultsToStreamError() {
        _ = parser.parse(line: "event: error")
        let result = parser.parse(line: "data: {}")
        if case .error(let msg) = result {
            XCTAssertEqual(msg, "Stream error")
        } else {
            XCTFail("Expected error, got \(String(describing: result))")
        }
    }

    // MARK: - Processing Progress

    func testProcessingStart_returnsZero() {
        _ = parser.parse(line: "event: prompt_processing.start")
        let result = parser.parse(line: "data: {}")
        if case .processingProgress(let p) = result {
            XCTAssertEqual(p, 0.0, accuracy: 0.001)
        } else {
            XCTFail("Expected processingProgress(0.0), got \(String(describing: result))")
        }
    }

    func testProcessingProgress_returnsProgress() {
        _ = parser.parse(line: "event: prompt_processing.progress")
        let result = parser.parse(line: "data: {\"progress\": 0.5}")
        if case .processingProgress(let p) = result {
            XCTAssertEqual(p, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Expected processingProgress(0.5), got \(String(describing: result))")
        }
    }

    func testProcessingEnd_returnsOne() {
        _ = parser.parse(line: "event: prompt_processing.end")
        let result = parser.parse(line: "data: {}")
        if case .processingProgress(let p) = result {
            XCTAssertEqual(p, 1.0, accuracy: 0.001)
        } else {
            XCTFail("Expected processingProgress(1.0), got \(String(describing: result))")
        }
    }

    // MARK: - Unknown event type

    func testUnknownEventType_returnsIgnored() {
        _ = parser.parse(line: "event: chat.start")
        let result = parser.parse(line: "data: {}")
        if case .ignored = result {
            // OK
        } else {
            XCTFail("Expected ignored, got \(String(describing: result))")
        }
    }

    // MARK: - Non-data/event lines

    func testNonDataLine_returnsNil() {
        XCTAssertNil(parser.parse(line: "some random text"))
    }

    func testEmptyLine_returnsNil() {
        XCTAssertNil(parser.parse(line: ""))
    }

    func testEventLine_returnsNil() {
        // event: lines don't produce results, only set state
        XCTAssertNil(parser.parse(line: "event: message.delta"))
    }

    func testEmptyData_returnsNil() {
        _ = parser.parse(line: "event: message.delta")
        XCTAssertNil(parser.parse(line: "data: "))
    }

    // MARK: - Stateful event type tracking

    func testEventType_persistsBetweenCalls() {
        // Set event type once
        _ = parser.parse(line: "event: message.delta")

        // First data with this type
        let r1 = parser.parse(line: "data: {\"content\": \"A\"}")
        if case .contentDelta(let t) = r1 { XCTAssertEqual(t, "A") }
        else { XCTFail("Expected contentDelta") }

        // Second data without new event: line — uses same type
        let r2 = parser.parse(line: "data: {\"content\": \"B\"}")
        if case .contentDelta(let t) = r2 { XCTAssertEqual(t, "B") }
        else { XCTFail("Expected contentDelta") }
    }

    func testEventType_changesOnNewEventLine() {
        _ = parser.parse(line: "event: message.delta")
        let r1 = parser.parse(line: "data: {\"content\": \"Hello\"}")
        if case .contentDelta = r1 { /* OK */ }
        else { XCTFail("Expected contentDelta") }

        // Switch to reasoning
        _ = parser.parse(line: "event: reasoning.delta")
        let r2 = parser.parse(line: "data: {\"content\": \"Thinking\"}")
        if case .thinkingDelta(let t) = r2 { XCTAssertEqual(t, "Thinking") }
        else { XCTFail("Expected thinkingDelta") }
    }

    // MARK: - Empty content

    func testContentDelta_emptyContent_returnsIgnored() {
        _ = parser.parse(line: "event: message.delta")
        let result = parser.parse(line: "data: {\"content\": \"\"}")
        if case .ignored = result { /* OK */ }
        else { XCTFail("Expected ignored for empty content, got \(String(describing: result))") }
    }

    func testContentDelta_nilContent_returnsIgnored() {
        _ = parser.parse(line: "event: message.delta")
        let result = parser.parse(line: "data: {}")
        if case .ignored = result { /* OK */ }
        else { XCTFail("Expected ignored for nil content, got \(String(describing: result))") }
    }

    // MARK: - chat.end → ServerPrefillReport

    /// The LM Studio half of the prompt-prefix cache's server signals had zero tests. The unit
    /// conversion, the deliberately-absent prefill rate, and the empty-report collapse are all
    /// load-bearing for `PrefixCachePolicy.resolve`, and all three were unpinned.

    private func chatEndPrefill(_ statsJSON: String) -> ServerPrefillReport? {
        _ = parser.parse(line: "event: chat.end")
        let result = parser.parse(line: "data: {\"stats\": \(statsJSON)}")
        guard case .chatEnd(_, let prefill, _, _) = result else {
            XCTFail("Expected chatEnd, got \(String(describing: result))")
            return nil
        }
        return prefill
    }

    func testChatEnd_modelLoadTimeSeconds_isConvertedToMilliseconds() {
        let prefill = chatEndPrefill(
            "{\"input_tokens\": 12927, \"total_output_tokens\": 8, \"model_load_time_seconds\": 2.2366}")
        XCTAssertEqual(prefill?.modelLoadMs ?? 0, 2236.6, accuracy: 0.001)
        XCTAssertEqual(prefill?.promptTokens, 12927)
    }

    /// LM Studio reports `time_to_first_token_seconds`, which includes queue time — and parallel
    /// roles on one model are this app's normal mode, so a queued warm request would be
    /// indistinguishable from a cold one. The omission is deliberate; this pins it so a future
    /// "we already have a number, let's use it" change fails loudly.
    func testChatEnd_prefillRateIsDeliberatelyAbsentOnLMStudio() {
        let prefill = chatEndPrefill(
            "{\"input_tokens\": 12927, \"total_output_tokens\": 8, \"model_load_time_seconds\": 2.2366, "
                + "\"time_to_first_token_seconds\": 4.2}")
        XCTAssertNil(
            prefill?.nsPerToken,
            "the rate branch of the detector must never be fed LM Studio's TTFT")
    }

    /// The universal warm case on this provider: `model_load_time_seconds` is exactly 0 on all 27
    /// baseline rows. Zero is NOT nil, so `isEmpty` is false and the report survives — which is
    /// what keeps `promptTokens` reachable on LM Studio at all. `isEmpty` deliberately ignores
    /// `promptTokens` (a denominator, not a signal), so a server that reported ONLY the token
    /// count would drop the whole report; the surviving zero is the only reason that corner is
    /// unreachable here. Anything reading `promptTokens` must not assume this holds forever.
    func testChatEnd_zeroModelLoadTime_stillCarriesTheTokenCount() {
        let prefill = chatEndPrefill(
            "{\"input_tokens\": 900, \"total_output_tokens\": 8, \"model_load_time_seconds\": 0}")
        XCTAssertEqual(prefill?.modelLoadMs, 0, "zero is a measurement, not an absence")
        XCTAssertEqual(prefill?.promptTokens, 900)
        XCTAssertNil(prefill?.nsPerToken)
    }

    /// The complement, and the reason the line above matters: with the load figure genuinely
    /// absent the report carries only `promptTokens`, and `isEmpty` throws it away.
    func testChatEnd_withNoLoadFigure_dropsTheReportEvenThoughTokensAreKnown() {
        XCTAssertNil(
            chatEndPrefill("{\"input_tokens\": 900, \"total_output_tokens\": 8}"),
            "`isEmpty` ignores promptTokens by design — a consumer must have a fallback source")
    }

    func testChatEnd_missingStats_yieldsNoUsageAndNoPrefill() {
        _ = parser.parse(line: "event: chat.end")
        let result = parser.parse(line: "data: {\"response_id\": \"r\"}")
        guard case .chatEnd(let usage, let prefill, _, _) = result else {
            return XCTFail("Expected chatEnd, got \(String(describing: result))")
        }
        XCTAssertNil(usage)
        XCTAssertNil(prefill)
    }

    // MARK: - chat.end: telemetry must not cost content

    /// `decodeIfPresent` returns nil for an ABSENT key but THROWS on a type mismatch (#83), and
    /// this parser decodes the whole frame under a single `try?` — so one mistyped telemetry
    /// field discards the token counts and the prefill report along with it. The Ollama twin of
    /// this was fixed on 2026-08-19 and its LM Studio sibling was left standing (#51).
    func testChatEnd_withMistypedModelLoadTime_stillReportsTheTokenCounts() {
        _ = parser.parse(line: "event: chat.end")
        let result = parser.parse(
            line: "data: {\"stats\": {\"input_tokens\": 900, \"total_output_tokens\": 8, "
                + "\"model_load_time_seconds\": \"fast\"}}")
        guard case .chatEnd(let usage, _, _, _) = result else {
            return XCTFail(
                "one mistyped telemetry field discarded the whole frame, got "
                    + String(describing: result))
        }
        XCTAssertEqual(
            usage, TokenUsage(inputTokens: 900, outputTokens: 8),
            "telemetry is decoration; it must never cost content")
    }

    /// The neighbour of `testChatEnd_missingStats_yieldsNoUsageAndNoPrefill`, and the pair is
    /// where the parser contradicts itself: an ABSENT `stats` object yields nil usage, while a
    /// PRESENT one carrying no token keys yields `TokenUsage(0, 0)` — counts the server never
    /// sent. Downstream the fabricated zero is indistinguishable from a measurement:
    /// `GenerationSampleRecorder` raises `.noTokensReported` only when usage is nil, so a
    /// benchmark run that measured nothing renders as a finished run of dashes. Ollama's parser
    /// guards this (`promptEvalCount != nil || evalCount != nil`); this one did not.
    func testChatEnd_statsWithNoTokenKeys_reportsNoUsageRatherThanZeros() {
        _ = parser.parse(line: "event: chat.end")
        let result = parser.parse(line: "data: {\"stats\": {\"model_load_time_seconds\": 0}}")
        guard case .chatEnd(let usage, let prefill, _, _) = result else {
            return XCTFail("Expected chatEnd, got \(String(describing: result))")
        }
        XCTAssertNil(usage, "a fabricated zero is indistinguishable from a measured one")
        XCTAssertEqual(prefill?.modelLoadMs, 0, "the figure the server DID send still survives")
    }

    /// The same trap as the load figure, on the field added for the benchmark. Its own value may
    /// be lost; the counts beside it may not.
    func testChatEnd_withMistypedTokensPerSecond_stillReportsTheTokenCounts() {
        _ = parser.parse(line: "event: chat.end")
        let result = parser.parse(
            line: "data: {\"stats\": {\"input_tokens\": 900, \"total_output_tokens\": 8, "
                + "\"tokens_per_second\": \"fast\"}}")
        guard case .chatEnd(let usage, _, let rate, _) = result else {
            return XCTFail("a mistyped rate discarded the frame, got \(String(describing: result))")
        }
        XCTAssertEqual(usage, TokenUsage(inputTokens: 900, outputTokens: 8))
        XCTAssertNil(rate, "the mistyped field itself is the only casualty")
    }

    // MARK: - chat.end: the server's own generation rate

    /// Verbatim, with no scaling and no fence-post correction of ours. Measured on LM Studio
    /// 0.4.21: the server's figure is `completion_tokens / (generation_time − TTFT)`, which is
    /// Ollama's convention exactly — so re-deriving it here could only introduce a difference.
    func testChatEnd_tokensPerSecond_isCarriedVerbatim() {
        _ = parser.parse(line: "event: chat.end")
        let result = parser.parse(
            line: "data: {\"stats\": {\"input_tokens\": 12, \"total_output_tokens\": 232, "
                + "\"tokens_per_second\": 70.88376163013098, \"reasoning_output_tokens\": 214}}")
        guard case .chatEnd(_, _, let rate, let reasoning) = result else {
            return XCTFail("Expected chatEnd, got \(String(describing: result))")
        }
        XCTAssertEqual(rate ?? 0, 70.88376163013098, accuracy: 1e-12, "no rounding, no scaling")
        XCTAssertEqual(reasoning, 214)
    }

    /// #80, as a round trip rather than a constant: the rate must reach the benchmark as a RATE.
    /// Turning it into a window here would fabricate endpoints the server never disclosed, and
    /// routing it through `ServerPrefillReport` would hand the prompt-prefix cache detector a
    /// number it is deliberately denied.
    func testChatEnd_tokensPerSecond_neverBecomesAPrefillFigure() {
        _ = parser.parse(line: "event: chat.end")
        let result = parser.parse(
            line: "data: {\"stats\": {\"input_tokens\": 900, \"total_output_tokens\": 8, "
                + "\"model_load_time_seconds\": 0, \"tokens_per_second\": 70.9}}")
        guard case .chatEnd(_, let prefill, let rate, _) = result else {
            return XCTFail("Expected chatEnd, got \(String(describing: result))")
        }
        XCTAssertEqual(rate, 70.9)
        XCTAssertNil(prefill?.prefillNs, "the rate must not be spent as a prefill window")
        XCTAssertNil(prefill?.nsPerToken, "and the detector's rate branch stays unreachable")
    }

    /// The zero is a measurement on this wire too — the parser thresholds nothing, exactly as it
    /// thresholds nothing on `modelLoadMs`. Whether a zero is usable is the policy layer's call.
    func testChatEnd_zeroTokensPerSecond_isCarriedThroughAsZero() {
        _ = parser.parse(line: "event: chat.end")
        let result = parser.parse(
            line: "data: {\"stats\": {\"input_tokens\": 9, \"total_output_tokens\": 1, "
                + "\"tokens_per_second\": 0}}")
        guard case .chatEnd(_, _, let rate, _) = result else {
            return XCTFail("Expected chatEnd, got \(String(describing: result))")
        }
        XCTAssertEqual(rate, 0)
    }

    /// Ollama's shape, arriving on this parser's provider: no rate key at all.
    func testChatEnd_withoutTokensPerSecond_leavesTheRateAbsent() {
        _ = parser.parse(line: "event: chat.end")
        let result = parser.parse(
            line: "data: {\"stats\": {\"input_tokens\": 9, \"total_output_tokens\": 4}}")
        guard case .chatEnd(let usage, _, let rate, let reasoning) = result else {
            return XCTFail("Expected chatEnd, got \(String(describing: result))")
        }
        XCTAssertEqual(usage, TokenUsage(inputTokens: 9, outputTokens: 4))
        XCTAssertNil(rate)
        XCTAssertNil(reasoning)
    }

    /// One count present, the other absent: the usage is real and the missing half reads as 0,
    /// which is the same rule Ollama's parser applies. Distinct from the both-absent case above,
    /// where there is no usage at all.
    func testChatEnd_withOnlyOneTokenCount_stillReportsUsage() {
        _ = parser.parse(line: "event: chat.end")
        let result = parser.parse(line: "data: {\"stats\": {\"total_output_tokens\": 7}}")
        guard case .chatEnd(let usage, _, _, _) = result else {
            return XCTFail("Expected chatEnd, got \(String(describing: result))")
        }
        XCTAssertEqual(usage, TokenUsage(inputTokens: 0, outputTokens: 7))
    }
}
