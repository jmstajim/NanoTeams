import XCTest
@testable import NanoTeams

/// Tests for StreamingPreviewManager - streaming content accumulation
@MainActor
final class StreamingPreviewManagerTests: XCTestCase {

    var manager: StreamingPreviewManager!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        manager = StreamingPreviewManager()
    }

    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialStateIsEmpty() {
        XCTAssertTrue(manager.previews.isEmpty)
    }

    // MARK: - Append Tests

    func testAppendCreatesPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Hello")

        XCTAssertNotNil(manager.preview(stepID: stepID, taskID: 0))
    }

    func testAppendSetsContent() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Hello")

        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.content, "Hello")
    }

    func testAppendAccumulatesContent() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Hello")
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: " World")

        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.content, "Hello World")
    }

    func testAppendPreservesRole() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .sre, content: "Test")

        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.role, .sre)
    }

    func testAppendPreservesMessageID() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Test")

        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.id, messageID)
    }

    func testAppendIgnoresEmptyContent() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "")

        XCTAssertNil(manager.preview(stepID: stepID, taskID: 0))
    }

    func testAppendMultipleSteps() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        let messageID1 = UUID()
        let messageID2 = UUID()

        manager.append(stepID: stepID1, taskID: 0, messageID: messageID1, role: .productManager, content: "Step 1")
        manager.append(stepID: stepID2, taskID: 0, messageID: messageID2, role: .softwareEngineer, content: "Step 2")

        XCTAssertEqual(manager.preview(stepID: stepID1, taskID: 0)?.content, "Step 1")
        XCTAssertEqual(manager.preview(stepID: stepID2, taskID: 0)?.content, "Step 2")
    }

    // MARK: - Commit Tests

    // `commit` returns Void (wave 33): its former `StepMessage?` return had zero
    // production consumers, and the one candidate (`NTMSOrchestrator.commitStreaming`)
    // persists the SERVICE's cleaned content, never this manager's raw UI buffer —
    // so the value was wrong for the only place that could read it. The whitespace-
    // only "no orphan bubble" suppression the return advertised is owned and pinned
    // at `ActivityFeedBuilderTests` (content-less, thinking-less turn → suppressed).
    // What remains observable here is STATE: the preview is gone, per-step transient
    // flags are gone, and `structuralVersion` bumps only when a preview existed.

    func testCommitRemovesPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Test")
        manager.commit(stepID: stepID, taskID: 0)

        XCTAssertNil(manager.preview(stepID: stepID, taskID: 0))
    }

    /// A commit with no preview is a safe no-op for the feed's rebuild trigger:
    /// no structural change happened, so `structuralVersion` must not move —
    /// a phantom bump would re-fingerprint the timeline on every out-of-band
    /// commit (cancellation paths call commit unconditionally).
    func testCommit_nonexistentStep_doesNotBumpStructuralVersion() {
        let before = manager.structuralVersion

        manager.commit(stepID: "test_step", taskID: 0)

        XCTAssertEqual(manager.structuralVersion, before)
    }

    /// The inverse: committing a LIVE preview is a structural change (a row
    /// leaves the timeline), so the version must advance exactly once.
    func testCommit_livePreview_bumpsStructuralVersionOnce() {
        let stepID = "test_step"
        manager.append(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer, content: "Test")
        let before = manager.structuralVersion

        manager.commit(stepID: stepID, taskID: 0)

        XCTAssertEqual(manager.structuralVersion, before + 1)
    }

    // MARK: - Clear Tests

    func testClearRemovesPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Test")
        manager.clear(stepID: stepID, taskID: 0)

        XCTAssertNil(manager.preview(stepID: stepID, taskID: 0))
    }

    func testClearOnNonexistentStepDoesNothing() {
        manager.clear(stepID: "test_step", taskID: 0)

        // Should not throw or crash
        XCTAssertTrue(manager.previews.isEmpty)
    }

    func testClearOnlyAffectsSpecifiedStep() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        let messageID1 = UUID()
        let messageID2 = UUID()

        manager.append(stepID: stepID1, taskID: 0, messageID: messageID1, role: .productManager, content: "Step 1")
        manager.append(stepID: stepID2, taskID: 0, messageID: messageID2, role: .softwareEngineer, content: "Step 2")

        manager.clear(stepID: stepID1, taskID: 0)

        XCTAssertNil(manager.preview(stepID: stepID1, taskID: 0))
        XCTAssertNotNil(manager.preview(stepID: stepID2, taskID: 0))
    }

    // MARK: - ClearAll Tests

    func testClearAllRemovesAllPreviews() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        let messageID1 = UUID()
        let messageID2 = UUID()

        manager.append(stepID: stepID1, taskID: 0, messageID: messageID1, role: .productManager, content: "Step 1")
        manager.append(stepID: stepID2, taskID: 0, messageID: messageID2, role: .softwareEngineer, content: "Step 2")

        manager.clearAll()

        XCTAssertTrue(manager.previews.isEmpty)
    }

    func testClearAllOnEmptyManagerDoesNothing() {
        manager.clearAll()

        XCTAssertTrue(manager.previews.isEmpty)
    }

    // MARK: - Preview Accessor Tests

    func testPreviewReturnsExistingPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Test")
        let preview = manager.preview(stepID: stepID, taskID: 0)

        XCTAssertNotNil(preview)
        XCTAssertEqual(preview?.content, "Test")
    }

    func testPreviewReturnsNilForNonexistentStep() {
        let preview = manager.preview(stepID: "nonexistent", taskID: 0)

        XCTAssertNil(preview)
    }

    // MARK: - HasPreview Tests

    func testHasPreviewReturnsTrueWhenExists() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Test")

        XCTAssertTrue(manager.hasPreview(stepID: stepID, taskID: 0))
    }

    func testHasPreviewReturnsFalseWhenNotExists() {
        XCTAssertFalse(manager.hasPreview(stepID: "nonexistent", taskID: 0))
    }

    func testHasPreviewReturnsFalseAfterClear() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Test")
        manager.clear(stepID: stepID, taskID: 0)

        XCTAssertFalse(manager.hasPreview(stepID: stepID, taskID: 0))
    }

    func testHasPreviewReturnsFalseAfterCommit() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Test")
        manager.commit(stepID: stepID, taskID: 0)

        XCTAssertFalse(manager.hasPreview(stepID: stepID, taskID: 0))
    }

    // MARK: - Multiple Chunks Tests

    func testAppendMultipleChunksInSequence() {
        let stepID = "test_step"
        let messageID = UUID()

        let chunks = ["The ", "quick ", "brown ", "fox ", "jumps"]

        for chunk in chunks {
            manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: chunk)
        }

        let preview = manager.preview(stepID: stepID, taskID: 0)
        XCTAssertEqual(preview?.content, "The quick brown fox jumps")
    }

    func testAppendWithNewlines() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Line 1\n")
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Line 2\n")
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Line 3")

        let preview = manager.preview(stepID: stepID, taskID: 0)
        XCTAssertEqual(preview?.content, "Line 1\nLine 2\nLine 3")
    }

    // MARK: - Timestamp Tests

    func testAppendSetsCreatedAt() {
        let stepID = "test_step"
        let messageID = UUID()

        // Bracket with MonotonicClock — the SAME clock `append` stamps `createdAt`
        // with (max(Date(), lastTimestamp+1ms), strictly increasing process-wide).
        // Mixing Date() bounds with a MonotonicClock value flakes: any concurrent
        // now() call elsewhere in the process pushes the monotonic clock sub-second
        // ahead of wall-clock, so createdAt can exceed a Date()-sourced `after`.
        // MonotonicClock's strict global ordering makes before < createdAt < after
        // hold deterministically.
        let before = MonotonicClock.shared.now()
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Test")
        let after = MonotonicClock.shared.now()

        let preview = manager.preview(stepID: stepID, taskID: 0)
        XCTAssertNotNil(preview?.createdAt)
        XCTAssertGreaterThanOrEqual(preview!.createdAt, before)
        XCTAssertLessThanOrEqual(preview!.createdAt, after)
    }

    // MARK: - Role Variety Tests

    func testAppendWithAllRoles() {
        let roles: [Role] = [.supervisor, .productManager, .tpm, .uxDesigner, .codeReviewer, .softwareEngineer, .sre]

        for (index, role) in roles.enumerated() {
            let stepID = "step_\(index)"
            let messageID = UUID()

            manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: role, content: "Test \(index)")

            XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.role, role)
        }
    }

    func testAppendWithCustomRole() {
        let stepID = "test_step"
        let messageID = UUID()
        let customRole = Role.custom(id: "securityReviewer")

        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: customRole, content: "Security check")

        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.role, customRole)
    }

    // MARK: - Structural Version Tests

    func testStructuralVersionIncrementsOnNewPreview() {
        let initial = manager.structuralVersion
        manager.append(stepID: "test_step", taskID: 0, messageID: UUID(), role: .softwareEngineer, content: "Hello")
        XCTAssertEqual(manager.structuralVersion, initial + 1)
    }

    func testStructuralVersionDoesNotIncrementOnContentAppend() {
        let stepID = "test_step"
        manager.append(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer, content: "Hello")
        let afterFirst = manager.structuralVersion
        manager.append(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer, content: " World")
        XCTAssertEqual(manager.structuralVersion, afterFirst)
    }

    func testStructuralVersionIncrementsOnCommit() {
        let stepID = "test_step"
        manager.append(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer, content: "Test")
        let afterAppend = manager.structuralVersion
        manager.commit(stepID: stepID, taskID: 0)
        XCTAssertEqual(manager.structuralVersion, afterAppend + 1)
    }

    func testStructuralVersionIncrementsOnClear() {
        let stepID = "test_step"
        manager.append(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer, content: "Test")
        let afterAppend = manager.structuralVersion
        manager.clear(stepID: stepID, taskID: 0)
        XCTAssertEqual(manager.structuralVersion, afterAppend + 1)
    }

    func testStructuralVersionDoesNotIncrementOnClearNonexistent() {
        let before = manager.structuralVersion
        manager.clear(stepID: "test_step", taskID: 0)
        XCTAssertEqual(manager.structuralVersion, before)
    }

    func testStructuralVersionIncrementsOnClearAll() {
        manager.append(stepID: "test_step", taskID: 0, messageID: UUID(), role: .softwareEngineer, content: "A")
        manager.append(stepID: "test_step", taskID: 0, messageID: UUID(), role: .softwareEngineer, content: "B")
        let afterAppends = manager.structuralVersion
        manager.clearAll()
        XCTAssertEqual(manager.structuralVersion, afterAppends + 1)
    }

    func testStructuralVersionDoesNotIncrementOnClearAllEmpty() {
        let before = manager.structuralVersion
        manager.clearAll()
        XCTAssertEqual(manager.structuralVersion, before)
    }

    func testStructuralVersionIncrementsOnBeginStreaming() {
        let initial = manager.structuralVersion
        manager.beginStreaming(stepID: "test_step", taskID: 0, messageID: UUID(), role: .softwareEngineer)
        XCTAssertEqual(manager.structuralVersion, initial + 1)
    }

    func testStructuralVersionDoesNotIncrementOnBeginStreamingExistingStep() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)
        let afterFirst = manager.structuralVersion
        // Re-begin on same step — preview already exists, no structural change
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)
        XCTAssertEqual(manager.structuralVersion, afterFirst)
    }

    func testStructuralVersionDoesNotIncrementOnAppendThinking() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)
        let afterBegin = manager.structuralVersion
        manager.appendThinking(stepID: stepID, taskID: 0, content: "Thinking...")
        XCTAssertEqual(manager.structuralVersion, afterBegin)
    }

    func testStructuralVersionDoesNotIncrementOnProcessingProgress() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)
        let afterBegin = manager.structuralVersion
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.5)
        XCTAssertEqual(manager.structuralVersion, afterBegin)
    }

    // MARK: - Begin Streaming Tests

    func testBeginStreamingCreatesPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .techLead)

        XCTAssertNotNil(manager.preview(stepID: stepID, taskID: 0))
        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.id, messageID)
        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.role, .techLead)
        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.content, "")
    }

    func testBeginStreamingRegistersStreamingMessageID() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)

        XCTAssertEqual(manager.streamingMessageIDs[TaskStepKey(taskID: 0, stepID: stepID)], messageID)
    }

    func testBeginStreamingOverwritesExistingPreview() {
        let stepID = "test_step"
        let messageID1 = UUID()
        let messageID2 = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID1, role: .productManager)
        manager.append(stepID: stepID, taskID: 0, messageID: messageID1, role: .productManager, content: "Some content")

        // Begin again on same step — should overwrite
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID2, role: .techLead)

        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.id, messageID2)
        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.role, .techLead)
        XCTAssertEqual(manager.preview(stepID: stepID, taskID: 0)?.content, "")
        XCTAssertEqual(manager.streamingMessageIDs[TaskStepKey(taskID: 0, stepID: stepID)], messageID2)
    }

    // MARK: - isStreaming Tests

    func testIsStreamingReturnsTrueDuringStreaming() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)

        XCTAssertTrue(manager.isStreaming(messageID: messageID))
    }

    func testIsStreamingReturnsFalseForUnknownMessage() {
        XCTAssertFalse(manager.isStreaming(messageID: UUID()))
    }

    func testIsStreamingReturnsFalseAfterCommit() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "content")
        manager.commit(stepID: stepID, taskID: 0)

        XCTAssertFalse(manager.isStreaming(messageID: messageID))
    }

    func testIsStreamingReturnsFalseAfterClear() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.clear(stepID: stepID, taskID: 0)

        XCTAssertFalse(manager.isStreaming(messageID: messageID))
    }

    func testIsStreamingReturnsFalseAfterClearAll() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.clearAll()

        XCTAssertFalse(manager.isStreaming(messageID: messageID))
    }

    // MARK: - Streaming Content Tests

    func testStreamingContentReturnsAccumulatedContent() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Hello")
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: " World")

        XCTAssertEqual(manager.streamingContent(stepID: stepID, taskID: 0), "Hello World")
    }

    func testStreamingContentReturnsEmptyForNewStream() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)

        XCTAssertEqual(manager.streamingContent(stepID: stepID, taskID: 0), "")
    }

    func testStreamingContentReturnsNilForUnknownStep() {
        XCTAssertNil(manager.streamingContent(stepID: "nonexistent", taskID: 0))
    }

    func testStreamingContentReturnsNilAfterCommit() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "data")
        manager.commit(stepID: stepID, taskID: 0)

        XCTAssertNil(manager.streamingContent(stepID: stepID, taskID: 0))
    }

    // MARK: - Streaming Thinking Tests

    func testAppendThinkingAccumulatesContent() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)

        manager.appendThinking(stepID: stepID, taskID: 0, content: "Let me ")
        manager.appendThinking(stepID: stepID, taskID: 0, content: "think about this...")

        XCTAssertEqual(manager.streamingThinking(stepID: stepID, taskID: 0), "Let me think about this...")
    }

    func testAppendThinkingIgnoresEmptyContent() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)

        manager.appendThinking(stepID: stepID, taskID: 0, content: "")

        XCTAssertNil(manager.streamingThinking(stepID: stepID, taskID: 0))
    }

    func testStreamingThinkingReturnsNilForUnknownStep() {
        XCTAssertNil(manager.streamingThinking(stepID: "nonexistent", taskID: 0))
    }

    func testStreamingThinkingReturnsNilAfterCommit() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)
        manager.appendThinking(stepID: stepID, taskID: 0, content: "Reasoning...")
        manager.commit(stepID: stepID, taskID: 0)

        XCTAssertNil(manager.streamingThinking(stepID: stepID, taskID: 0))
    }

    func testStreamingThinkingReturnsNilAfterClear() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)
        manager.appendThinking(stepID: stepID, taskID: 0, content: "Reasoning...")
        manager.clear(stepID: stepID, taskID: 0)

        XCTAssertNil(manager.streamingThinking(stepID: stepID, taskID: 0))
    }

    func testStreamingThinkingReturnsNilAfterClearAll() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)
        manager.appendThinking(stepID: stepID, taskID: 0, content: "Reasoning...")
        manager.clearAll()

        XCTAssertNil(manager.streamingThinking(stepID: stepID, taskID: 0))
    }

    // MARK: - Processing Progress Tests

    func testUpdateProcessingProgressStoresValue() {
        let stepID = "test_step"
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.45)

        XCTAssertEqual(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)], 0.45)
    }

    func testUpdateProcessingProgressUpdatesValue() {
        let stepID = "test_step"
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.3)
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.7)

        XCTAssertEqual(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)], 0.7)
    }

    func testClearProcessingProgressRemovesValue() {
        let stepID = "test_step"
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.5)
        manager.clearProcessingProgress(stepID: stepID, taskID: 0)

        XCTAssertNil(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)])
    }

    func testClearProcessingProgressOnNonexistentIsNoOp() {
        // Should not crash
        manager.clearProcessingProgress(stepID: "test_step", taskID: 0)
        XCTAssertTrue(manager.processingProgress.isEmpty)
    }

    func testProcessingProgressClearedOnCommit() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.8)
        manager.commit(stepID: stepID, taskID: 0)

        XCTAssertNil(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)])
    }

    func testProcessingProgressClearedOnClear() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: UUID(), role: .softwareEngineer)
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.5)
        manager.clear(stepID: stepID, taskID: 0)

        XCTAssertNil(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)])
    }

    func testProcessingProgressClearedOnClearAll() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        manager.updateProcessingProgress(stepID: stepID1, taskID: 0, progress: 0.3)
        manager.updateProcessingProgress(stepID: stepID2, taskID: 0, progress: 0.6)
        manager.clearAll()

        XCTAssertTrue(manager.processingProgress.isEmpty)
    }

    // MARK: - Commit Clears All Streaming State

    func testCommitClearsAllStreamingState() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "content")
        manager.appendThinking(stepID: stepID, taskID: 0, content: "thinking")
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.5)

        manager.commit(stepID: stepID, taskID: 0)

        XCTAssertNil(manager.preview(stepID: stepID, taskID: 0))
        XCTAssertFalse(manager.isStreaming(messageID: messageID))
        XCTAssertNil(manager.streamingThinking(stepID: stepID, taskID: 0))
        XCTAssertNil(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)])
        XCTAssertNil(manager.streamingMessageIDs[TaskStepKey(taskID: 0, stepID: stepID)])
    }

    // MARK: - Clear Clears All Streaming State

    func testClearClearsAllStreamingState() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "content")
        manager.appendThinking(stepID: stepID, taskID: 0, content: "thinking")
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.5)

        manager.clear(stepID: stepID, taskID: 0)

        XCTAssertNil(manager.preview(stepID: stepID, taskID: 0))
        XCTAssertFalse(manager.isStreaming(messageID: messageID))
        XCTAssertNil(manager.streamingThinking(stepID: stepID, taskID: 0))
        XCTAssertNil(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)])
        XCTAssertNil(manager.streamingMessageIDs[TaskStepKey(taskID: 0, stepID: stepID)])
    }

    // MARK: - ClearAll Clears All Streaming State

    func testClearAllClearsAllStreamingState() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        let messageID1 = UUID()
        let messageID2 = UUID()

        manager.beginStreaming(stepID: stepID1, taskID: 0, messageID: messageID1, role: .productManager)
        manager.beginStreaming(stepID: stepID2, taskID: 0, messageID: messageID2, role: .softwareEngineer)
        manager.appendThinking(stepID: stepID1, taskID: 0, content: "think1")
        manager.appendThinking(stepID: stepID2, taskID: 0, content: "think2")
        manager.updateProcessingProgress(stepID: stepID1, taskID: 0, progress: 0.3)
        manager.updateProcessingProgress(stepID: stepID2, taskID: 0, progress: 0.7)

        manager.clearAll()

        XCTAssertTrue(manager.previews.isEmpty)
        XCTAssertTrue(manager.streamingMessageIDs.isEmpty)
        XCTAssertTrue(manager.thinkingPreviews.isEmpty)
        XCTAssertTrue(manager.processingProgress.isEmpty)
        XCTAssertFalse(manager.isStreaming(messageID: messageID1))
        XCTAssertFalse(manager.isStreaming(messageID: messageID2))
    }

    // MARK: - Multiple Steps Streaming Simultaneously

    func testMultipleStepsStreamingSimultaneously() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        let stepID3 = "step_3"
        let messageID1 = UUID()
        let messageID2 = UUID()
        let messageID3 = UUID()

        // Begin streaming for 3 steps
        manager.beginStreaming(stepID: stepID1, taskID: 0, messageID: messageID1, role: .productManager)
        manager.beginStreaming(stepID: stepID2, taskID: 0, messageID: messageID2, role: .softwareEngineer)
        manager.beginStreaming(stepID: stepID3, taskID: 0, messageID: messageID3, role: .techLead)

        // Append content independently
        manager.append(stepID: stepID1, taskID: 0, messageID: messageID1, role: .productManager, content: "Requirements: ")
        manager.append(stepID: stepID2, taskID: 0, messageID: messageID2, role: .softwareEngineer, content: "Code: ")
        manager.append(stepID: stepID3, taskID: 0, messageID: messageID3, role: .techLead, content: "Plan: ")
        manager.append(stepID: stepID1, taskID: 0, messageID: messageID1, role: .productManager, content: "feature X")
        manager.append(stepID: stepID2, taskID: 0, messageID: messageID2, role: .softwareEngineer, content: "func main()")

        // Append thinking independently
        manager.appendThinking(stepID: stepID1, taskID: 0, content: "Analyzing requirements")
        manager.appendThinking(stepID: stepID2, taskID: 0, content: "Writing implementation")

        // Update processing progress independently
        manager.updateProcessingProgress(stepID: stepID3, taskID: 0, progress: 0.5)

        // Verify independent state
        XCTAssertTrue(manager.isStreaming(messageID: messageID1))
        XCTAssertTrue(manager.isStreaming(messageID: messageID2))
        XCTAssertTrue(manager.isStreaming(messageID: messageID3))

        XCTAssertEqual(manager.streamingContent(stepID: stepID1, taskID: 0), "Requirements: feature X")
        XCTAssertEqual(manager.streamingContent(stepID: stepID2, taskID: 0), "Code: func main()")
        XCTAssertEqual(manager.streamingContent(stepID: stepID3, taskID: 0), "Plan: ")

        XCTAssertEqual(manager.streamingThinking(stepID: stepID1, taskID: 0), "Analyzing requirements")
        XCTAssertEqual(manager.streamingThinking(stepID: stepID2, taskID: 0), "Writing implementation")
        XCTAssertNil(manager.streamingThinking(stepID: stepID3, taskID: 0))

        XCTAssertNil(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID1)])
        XCTAssertNil(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID2)])
        XCTAssertEqual(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID3)], 0.5)

        // Commit step 1 — others unaffected
        manager.commit(stepID: stepID1, taskID: 0)

        XCTAssertFalse(manager.isStreaming(messageID: messageID1))
        XCTAssertTrue(manager.isStreaming(messageID: messageID2))
        XCTAssertTrue(manager.isStreaming(messageID: messageID3))
        XCTAssertNil(manager.streamingContent(stepID: stepID1, taskID: 0))
        XCTAssertEqual(manager.streamingContent(stepID: stepID2, taskID: 0), "Code: func main()")

        // Clear step 2 — step 3 unaffected
        manager.clear(stepID: stepID2, taskID: 0)

        XCTAssertFalse(manager.isStreaming(messageID: messageID2))
        XCTAssertTrue(manager.isStreaming(messageID: messageID3))
        XCTAssertEqual(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID3)], 0.5)
    }

    // MARK: - Full Inline Streaming Lifecycle

    func testFullInlineStreamingLifecycle() {
        let stepID = "test_step"
        let messageID = UUID()

        // Phase 1: Begin streaming (pre-create message)
        manager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)
        XCTAssertTrue(manager.isStreaming(messageID: messageID))
        XCTAssertEqual(manager.streamingContent(stepID: stepID, taskID: 0), "")
        XCTAssertNil(manager.streamingThinking(stepID: stepID, taskID: 0))

        // Phase 2: Processing progress (prompt processing)
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.0)
        XCTAssertEqual(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)], 0.0)
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 0.5)
        XCTAssertEqual(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)], 0.5)
        manager.updateProcessingProgress(stepID: stepID, taskID: 0, progress: 1.0)
        XCTAssertEqual(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)], 1.0)
        manager.clearProcessingProgress(stepID: stepID, taskID: 0)
        XCTAssertNil(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)])

        // Phase 3: Thinking starts streaming
        manager.appendThinking(stepID: stepID, taskID: 0, content: "I need to ")
        manager.appendThinking(stepID: stepID, taskID: 0, content: "analyze the code...")
        XCTAssertEqual(manager.streamingThinking(stepID: stepID, taskID: 0), "I need to analyze the code...")

        // Phase 4: Content starts streaming
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Here is ")
        manager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "the implementation.")
        XCTAssertEqual(manager.streamingContent(stepID: stepID, taskID: 0), "Here is the implementation.")

        // Phase 5: Commit (streaming ends) — everything transient is gone
        manager.commit(stepID: stepID, taskID: 0)
        XCTAssertFalse(manager.isStreaming(messageID: messageID))
        XCTAssertNil(manager.streamingContent(stepID: stepID, taskID: 0))
        XCTAssertNil(manager.streamingThinking(stepID: stepID, taskID: 0))
        XCTAssertNil(manager.processingProgress[TaskStepKey(taskID: 0, stepID: stepID)])
    }
}
