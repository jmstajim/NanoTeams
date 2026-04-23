import XCTest
@testable import NanoTeams

/// Tests for `StreamingPreviewManager.replaceContent` — the Harmony-marker
/// rewind path. Called from `LLMExecutionService+Streaming` when a Harmony
/// tool-call marker (`<|channel|>`, `<|call|>`, `<|start|>functions.`) is
/// detected mid-flush, so partial prefixes like `<` or `<|` don't linger
/// on screen after the streaming service has decided they belong to a
/// tool-call envelope rather than user-visible content.
///
/// Pinned behavior:
/// - When a preview already exists, content is replaced in one shot (no
///   structural version bump — it's a content update, not a new message).
/// - When no preview exists and the rewind target is empty, nothing is
///   created (a marker at position 0 must not materialize an empty bubble).
/// - When no preview exists and the rewind target is non-empty, a fresh
///   preview is materialized (structural version increments so views
///   notice the new item).
/// - `replaceContent` is idempotent: calling with the same content twice
///   leaves state unchanged.
/// - `replaceContent` does not touch `thinkingPreviews` or
///   `processingProgress`.
@MainActor
final class StreamingPreviewManagerReplaceContentTests: XCTestCase {

    var manager: StreamingPreviewManager!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        manager = StreamingPreviewManager()
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Rewind from existing preview

    /// Canonical Harmony rewind: some plain text has already streamed, then
    /// the service detects `<|channel|>` and rewinds to the pre-marker portion.
    func testReplaceContent_rewindsFromStreamedPrefix_toEmpty() {
        let stepID = "pm"
        let messageID = UUID()
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .productManager)
        manager.append(stepID: stepID, messageID: messageID,
                       role: .productManager, content: "<|")

        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "")

        XCTAssertEqual(manager.streamingContent(for: stepID), "",
                       "Partial marker prefix `<|` must not linger")
        XCTAssertTrue(manager.isStreaming(messageID: messageID),
                      "Streaming state should be preserved — only content rewound")
    }

    func testReplaceContent_rewindsFromStreamedPrefix_toPreMarkerText() {
        let stepID = "pm"
        let messageID = UUID()
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .productManager)
        manager.append(stepID: stepID, messageID: messageID,
                       role: .productManager, content: "Plan overview. <|")

        // Service rewinds to the text that was emitted BEFORE the marker.
        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "Plan overview. ")

        XCTAssertEqual(manager.streamingContent(for: stepID), "Plan overview. ",
                       "Only the marker prefix should be trimmed")
    }

    func testReplaceContent_preservesMessageID_andRole() {
        let stepID = "pm"
        let messageID = UUID()
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .productManager)
        manager.append(stepID: stepID, messageID: messageID,
                       role: .productManager, content: "Initial <")

        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "Initial ")

        XCTAssertEqual(manager.preview(for: stepID)?.id, messageID,
                       "replaceContent must preserve the original messageID")
        XCTAssertEqual(manager.preview(for: stepID)?.role, .productManager)
    }

    func testReplaceContent_doesNotBumpStructuralVersion_onExistingPreview() {
        // Content updates are not structural — views poll content via TimelineView.
        // Bumping structuralVersion on a content rewind would cause spurious
        // rebuilds of the entire timeline on every partial-marker pause.
        let stepID = "pm"
        let messageID = UUID()
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .productManager)
        manager.append(stepID: stepID, messageID: messageID,
                       role: .productManager, content: "abc<|")

        let versionBefore = manager.structuralVersion
        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "abc")

        XCTAssertEqual(manager.structuralVersion, versionBefore,
                       "Content rewind must NOT bump structuralVersion — triggers full timeline rebuild")
    }

    func testReplaceContent_doesNotAffectThinkingPreview() {
        let stepID = "pm"
        let messageID = UUID()
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .productManager)
        manager.appendThinking(stepID: stepID, content: "Reasoning about the plan...")
        manager.append(stepID: stepID, messageID: messageID,
                       role: .productManager, content: "Plan <|")

        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "Plan ")

        XCTAssertEqual(manager.streamingThinking(for: stepID), "Reasoning about the plan...",
                       "Thinking buffer is independent of the rewind")
    }

    func testReplaceContent_doesNotAffectProcessingProgress() {
        let stepID = "pm"
        let messageID = UUID()
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .productManager)
        manager.updateProcessingProgress(stepID: stepID, progress: 0.4)
        manager.append(stepID: stepID, messageID: messageID,
                       role: .productManager, content: "Intro <|")

        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "Intro ")

        XCTAssertEqual(manager.processingProgress[stepID], 0.4)
    }

    // MARK: - Rewind with no existing preview

    /// Marker at position 0: the very first thing the model emits is a
    /// Harmony marker. The service calls `replaceContent` with an empty
    /// pre-marker portion. The manager must NOT create an empty preview
    /// bubble (the user would see an empty Role bubble flash on screen).
    func testReplaceContent_noPreview_emptyContent_doesNotMaterializePreview() {
        let stepID = "pm"
        let messageID = UUID()

        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "")

        XCTAssertNil(manager.preview(for: stepID),
                     "An empty rewind on a non-existent preview must not create one")
        XCTAssertFalse(manager.hasPreview(for: stepID))
    }

    func testReplaceContent_noPreview_emptyContent_doesNotBumpStructuralVersion() {
        let stepID = "pm"
        let versionBefore = manager.structuralVersion

        manager.replaceContent(stepID: stepID, messageID: UUID(),
                               role: .productManager, content: "")

        XCTAssertEqual(manager.structuralVersion, versionBefore,
                       "No preview created → no structural change")
    }

    /// When content IS non-empty and there's no preview yet, materialize one.
    /// This covers the case where `beginStreaming` was skipped (content-only
    /// flush path) and the first rewind carries real pre-marker text.
    func testReplaceContent_noPreview_nonEmptyContent_createsPreview() {
        let stepID = "pm"
        let messageID = UUID()

        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "Preamble.")

        XCTAssertEqual(manager.preview(for: stepID)?.content, "Preamble.")
        XCTAssertEqual(manager.preview(for: stepID)?.id, messageID)
        XCTAssertEqual(manager.preview(for: stepID)?.role, .productManager)
    }

    func testReplaceContent_noPreview_nonEmptyContent_bumpsStructuralVersion() {
        let stepID = "pm"
        let versionBefore = manager.structuralVersion

        manager.replaceContent(stepID: stepID, messageID: UUID(),
                               role: .productManager, content: "Preamble.")

        XCTAssertEqual(manager.structuralVersion, versionBefore &+ 1,
                       "New preview materialization IS a structural change")
    }

    // MARK: - Idempotency + isolation

    func testReplaceContent_calledTwiceWithSameContent_isIdempotent() {
        let stepID = "pm"
        let messageID = UUID()
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .productManager)
        manager.append(stepID: stepID, messageID: messageID,
                       role: .productManager, content: "abc<|")

        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "abc")
        let versionAfterFirst = manager.structuralVersion

        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "abc")

        XCTAssertEqual(manager.streamingContent(for: stepID), "abc")
        XCTAssertEqual(manager.structuralVersion, versionAfterFirst,
                       "Second identical rewind must be a no-op for structural version")
    }

    func testReplaceContent_isolatedPerStep() {
        let stepA = "pm"
        let stepB = "tech_lead"
        let messageA = UUID()
        let messageB = UUID()
        manager.beginStreaming(stepID: stepA, messageID: messageA, role: .productManager)
        manager.beginStreaming(stepID: stepB, messageID: messageB, role: .techLead)
        manager.append(stepID: stepA, messageID: messageA,
                       role: .productManager, content: "PM text <|")
        manager.append(stepID: stepB, messageID: messageB,
                       role: .techLead, content: "TL unaffected")

        manager.replaceContent(stepID: stepA, messageID: messageA,
                               role: .productManager, content: "PM text ")

        XCTAssertEqual(manager.streamingContent(for: stepA), "PM text ")
        XCTAssertEqual(manager.streamingContent(for: stepB), "TL unaffected",
                       "Rewind on one step must not touch another step")
    }

    // MARK: - Interaction with commit

    /// After a Harmony rewind to empty content, the subsequent commit should
    /// return nil because the committed preview has no visible text (whitespace-
    /// only commit contract — CLAUDE.md §StreamingPreviewManager).
    func testReplaceContent_toEmpty_thenCommit_returnsNil() {
        let stepID = "pm"
        let messageID = UUID()
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .productManager)
        manager.append(stepID: stepID, messageID: messageID,
                       role: .productManager, content: "<")

        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "")

        let committed = manager.commit(stepID: stepID)
        XCTAssertNil(committed,
                     "An empty preview (post-rewind) must not materialize a bubble on commit")
    }

    /// Rewind to non-empty content: commit returns the rewound value, not
    /// the pre-rewind content that included the marker prefix.
    func testReplaceContent_toNonEmpty_thenCommit_returnsRewoundValue() {
        let stepID = "pm"
        let messageID = UUID()
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .productManager)
        manager.append(stepID: stepID, messageID: messageID,
                       role: .productManager, content: "Answer: 42. <|")

        manager.replaceContent(stepID: stepID, messageID: messageID,
                               role: .productManager, content: "Answer: 42. ")

        let committed = manager.commit(stepID: stepID)
        XCTAssertEqual(committed?.content, "Answer: 42. ",
                       "Commit must reflect the post-rewind content, not the marker-polluted prefix")
    }
}
