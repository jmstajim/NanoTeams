import XCTest
@testable import NanoTeams

/// Pins the `BubbleInputs` discriminated union — the `MessageBubbleView`
/// dispatcher receives streaming-only and committed-only fields through
/// case-derived accessors, never via shared payloads. The cases
/// statically rule out illegal combinations like "streaming bubble with
/// attachments".
@MainActor
final class BubbleInputsTests: XCTestCase {

    typealias BubbleInputs = TeamActivityFeedView.BubbleInputs

    // MARK: - Bubble-feeding accessors (case-derived semantics)

    /// Streaming case: payload fields surface; committed-only fields
    /// return their genuine empty values.
    func testStreamingAccessors_returnPayloadFields_andNeutralCommittedFields() async {
        let inputs = BubbleInputs.streaming(
            content: "live",
            thinking: "thoughts",
            processingProgress: 0.42,
            hasStreamActivity: true,
            isStreamingToolCall: false
        )
        XCTAssertEqual(inputs.contentForBubble, "live")
        XCTAssertEqual(inputs.thinkingForBubble, "thoughts")
        XCTAssertEqual(inputs.processingProgress, 0.42)
        XCTAssertTrue(inputs.hasStreamActivity)
        XCTAssertFalse(inputs.isStreamingToolCall)
        XCTAssertTrue(inputs.attachmentPaths.isEmpty,
                      "Streaming bubbles never carry attachment paths.")
        XCTAssertTrue(inputs.clippedTexts.isEmpty,
                      "Streaming bubbles never carry clipped texts.")
    }

    /// Committed case: payload fields surface; streaming-only fields
    /// return their genuine empty values.
    func testCommittedAccessors_returnPayloadFields_andNeutralStreamingFields() async {
        let inputs = BubbleInputs.committed(
            content: "final body",
            thinking: "rationale",
            attachmentPaths: ["/path/to/file.swift"],
            clippedTexts: ["let x = 1"]
        )
        XCTAssertEqual(inputs.contentForBubble, "final body")
        XCTAssertEqual(inputs.thinkingForBubble, "rationale")
        XCTAssertEqual(inputs.attachmentPaths, ["/path/to/file.swift"])
        XCTAssertEqual(inputs.clippedTexts, ["let x = 1"])
        XCTAssertNil(inputs.processingProgress,
                     "Committed bubbles never carry processingProgress.")
        XCTAssertFalse(inputs.hasStreamActivity,
                       "Committed bubbles never claim stream activity.")
        XCTAssertFalse(inputs.isStreamingToolCall,
                       "Committed bubbles never claim tool-call streaming — no stale 'Generating'.")
    }

    /// `isStreaming` flag matches the case discriminator. Pinned so the
    /// dispatcher's `inputs.isStreaming` forwarding to `MessageBubbleView`
    /// stays in sync if the cases ever rearrange.
    func testIsStreaming_matchesCase() async {
        let s = BubbleInputs.streaming(content: "x", thinking: nil, processingProgress: nil, hasStreamActivity: false, isStreamingToolCall: false)
        let c = BubbleInputs.committed(content: "x", thinking: nil, attachmentPaths: [], clippedTexts: [])
        XCTAssertTrue(s.isStreaming)
        XCTAssertFalse(c.isStreaming)
    }

    /// Streaming case surfaces the tool-call flag through its accessor.
    func testStreamingAccessor_surfacesIsStreamingToolCall() async {
        let inputs = BubbleInputs.streaming(
            content: "frozen prose",
            thinking: nil,
            processingProgress: nil,
            hasStreamActivity: true,
            isStreamingToolCall: true
        )
        XCTAssertTrue(inputs.isStreamingToolCall)
    }

    // MARK: - Equatable synthesis

    func testEquatable_streamingVsCommitted_sameContent_neverEqual() async {
        let s = BubbleInputs.streaming(content: "x", thinking: nil, processingProgress: nil, hasStreamActivity: false, isStreamingToolCall: false)
        let c = BubbleInputs.committed(content: "x", thinking: nil, attachmentPaths: [], clippedTexts: [])
        XCTAssertNotEqual(s, c, "Cross-case must never compare equal even with same content.")
    }

    func testEquatable_sameCaseSameFields_areEqual() async {
        let a = BubbleInputs.committed(content: "x", thinking: "t", attachmentPaths: ["/p"], clippedTexts: ["c"])
        let b = BubbleInputs.committed(content: "x", thinking: "t", attachmentPaths: ["/p"], clippedTexts: ["c"])
        XCTAssertEqual(a, b)
    }

    func testEquatable_sameCaseDifferentField_areNotEqual() async {
        let a = BubbleInputs.streaming(content: "x", thinking: nil, processingProgress: 0.1, hasStreamActivity: true, isStreamingToolCall: false)
        let b = BubbleInputs.streaming(content: "x", thinking: nil, processingProgress: 0.2, hasStreamActivity: true, isStreamingToolCall: false)
        XCTAssertNotEqual(a, b, "Different progress in same case must compare not-equal.")
    }

    func testEquatable_differentToolCallFlag_areNotEqual() async {
        let a = BubbleInputs.streaming(content: "x", thinking: nil, processingProgress: nil, hasStreamActivity: true, isStreamingToolCall: false)
        let b = BubbleInputs.streaming(content: "x", thinking: nil, processingProgress: nil, hasStreamActivity: true, isStreamingToolCall: true)
        XCTAssertNotEqual(a, b, "Tool-call flag flip must propagate through Equatable — the TimelineView tick relies on it.")
    }
}
