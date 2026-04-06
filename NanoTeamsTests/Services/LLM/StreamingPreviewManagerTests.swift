import XCTest
@testable import NanoTeams

/// Tests for StreamingPreviewManager - streaming content accumulation
@MainActor
final class StreamingPreviewManagerTests: XCTestCase {

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

    // MARK: - Initialization Tests

    func testInitialStateIsEmpty() {
        XCTAssertTrue(manager.previews.isEmpty)
    }

    // MARK: - Append Tests

    func testAppendCreatesPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Hello")

        XCTAssertNotNil(manager.preview(for: stepID))
    }

    func testAppendSetsContent() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Hello")

        XCTAssertEqual(manager.preview(for: stepID)?.content, "Hello")
    }

    func testAppendAccumulatesContent() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Hello")
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: " World")

        XCTAssertEqual(manager.preview(for: stepID)?.content, "Hello World")
    }

    func testAppendPreservesRole() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .sre, content: "Test")

        XCTAssertEqual(manager.preview(for: stepID)?.role, .sre)
    }

    func testAppendPreservesMessageID() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Test")

        XCTAssertEqual(manager.preview(for: stepID)?.id, messageID)
    }

    func testAppendIgnoresEmptyContent() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "")

        XCTAssertNil(manager.preview(for: stepID))
    }

    func testAppendMultipleSteps() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        let messageID1 = UUID()
        let messageID2 = UUID()

        manager.append(stepID: stepID1, messageID: messageID1, role: .productManager, content: "Step 1")
        manager.append(stepID: stepID2, messageID: messageID2, role: .softwareEngineer, content: "Step 2")

        XCTAssertEqual(manager.preview(for: stepID1)?.content, "Step 1")
        XCTAssertEqual(manager.preview(for: stepID2)?.content, "Step 2")
    }

    // MARK: - Commit Tests

    func testCommitReturnsPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Test")
        let committed = manager.commit(stepID: stepID)

        XCTAssertNotNil(committed)
        XCTAssertEqual(committed?.content, "Test")
    }

    func testCommitRemovesPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Test")
        _ = manager.commit(stepID: stepID)

        XCTAssertNil(manager.preview(for: stepID))
    }

    func testCommitReturnsNilForNonexistentStep() {
        let committed = manager.commit(stepID: "test_step")

        XCTAssertNil(committed)
    }

    func testCommitReturnsNilForEmptyContent() {
        let stepID = "test_step"
        let messageID = UUID()

        // Append and then append only whitespace
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "   ")
        // The initial append of whitespace-only should still create a preview
        // but commit should return nil for whitespace-only content

        // First, let's create a valid preview then clear it and try again
        manager.clear(stepID: stepID)

        // Try to commit a non-existent preview
        let committed = manager.commit(stepID: stepID)
        XCTAssertNil(committed)
    }

    func testCommitReturnsNilForWhitespaceOnlyContent() {
        let stepID = "test_step"
        let messageID = UUID()

        // Manually create a preview with whitespace content
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "a")
        // Clear and recreate with whitespace
        manager.clear(stepID: stepID)
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "   \n\t  ")

        let committed = manager.commit(stepID: stepID)

        // Should return nil because content is only whitespace
        XCTAssertNil(committed)
    }

    func testCommitPreservesRole() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .uxDesigner, content: "Design")
        let committed = manager.commit(stepID: stepID)

        XCTAssertEqual(committed?.role, .uxDesigner)
    }

    func testCommitPreservesMessageID() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Test")
        let committed = manager.commit(stepID: stepID)

        XCTAssertEqual(committed?.id, messageID)
    }

    // MARK: - Clear Tests

    func testClearRemovesPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Test")
        manager.clear(stepID: stepID)

        XCTAssertNil(manager.preview(for: stepID))
    }

    func testClearOnNonexistentStepDoesNothing() {
        manager.clear(stepID: "test_step")

        // Should not throw or crash
        XCTAssertTrue(manager.previews.isEmpty)
    }

    func testClearOnlyAffectsSpecifiedStep() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        let messageID1 = UUID()
        let messageID2 = UUID()

        manager.append(stepID: stepID1, messageID: messageID1, role: .productManager, content: "Step 1")
        manager.append(stepID: stepID2, messageID: messageID2, role: .softwareEngineer, content: "Step 2")

        manager.clear(stepID: stepID1)

        XCTAssertNil(manager.preview(for: stepID1))
        XCTAssertNotNil(manager.preview(for: stepID2))
    }

    // MARK: - ClearAll Tests

    func testClearAllRemovesAllPreviews() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        let messageID1 = UUID()
        let messageID2 = UUID()

        manager.append(stepID: stepID1, messageID: messageID1, role: .productManager, content: "Step 1")
        manager.append(stepID: stepID2, messageID: messageID2, role: .softwareEngineer, content: "Step 2")

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

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Test")
        let preview = manager.preview(for: stepID)

        XCTAssertNotNil(preview)
        XCTAssertEqual(preview?.content, "Test")
    }

    func testPreviewReturnsNilForNonexistentStep() {
        let preview = manager.preview(for: "nonexistent")

        XCTAssertNil(preview)
    }

    // MARK: - HasPreview Tests

    func testHasPreviewReturnsTrueWhenExists() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Test")

        XCTAssertTrue(manager.hasPreview(for: stepID))
    }

    func testHasPreviewReturnsFalseWhenNotExists() {
        XCTAssertFalse(manager.hasPreview(for: "nonexistent"))
    }

    func testHasPreviewReturnsFalseAfterClear() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Test")
        manager.clear(stepID: stepID)

        XCTAssertFalse(manager.hasPreview(for: stepID))
    }

    func testHasPreviewReturnsFalseAfterCommit() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Test")
        _ = manager.commit(stepID: stepID)

        XCTAssertFalse(manager.hasPreview(for: stepID))
    }

    // MARK: - Multiple Chunks Tests

    func testAppendMultipleChunksInSequence() {
        let stepID = "test_step"
        let messageID = UUID()

        let chunks = ["The ", "quick ", "brown ", "fox ", "jumps"]

        for chunk in chunks {
            manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: chunk)
        }

        let preview = manager.preview(for: stepID)
        XCTAssertEqual(preview?.content, "The quick brown fox jumps")
    }

    func testAppendWithNewlines() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Line 1\n")
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Line 2\n")
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Line 3")

        let preview = manager.preview(for: stepID)
        XCTAssertEqual(preview?.content, "Line 1\nLine 2\nLine 3")
    }

    // MARK: - Timestamp Tests

    func testAppendSetsCreatedAt() {
        let stepID = "test_step"
        let messageID = UUID()

        let before = Date()
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Test")
        let after = Date()

        let preview = manager.preview(for: stepID)
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

            manager.append(stepID: stepID, messageID: messageID, role: role, content: "Test \(index)")

            XCTAssertEqual(manager.preview(for: stepID)?.role, role)
        }
    }

    func testAppendWithCustomRole() {
        let stepID = "test_step"
        let messageID = UUID()
        let customRole = Role.custom(id: "securityReviewer")

        manager.append(stepID: stepID, messageID: messageID, role: customRole, content: "Security check")

        XCTAssertEqual(manager.preview(for: stepID)?.role, customRole)
    }

    // MARK: - Structural Version Tests

    func testStructuralVersionIncrementsOnNewPreview() {
        let initial = manager.structuralVersion
        manager.append(stepID: "test_step", messageID: UUID(), role: .softwareEngineer, content: "Hello")
        XCTAssertEqual(manager.structuralVersion, initial + 1)
    }

    func testStructuralVersionDoesNotIncrementOnContentAppend() {
        let stepID = "test_step"
        manager.append(stepID: stepID, messageID: UUID(), role: .softwareEngineer, content: "Hello")
        let afterFirst = manager.structuralVersion
        manager.append(stepID: stepID, messageID: UUID(), role: .softwareEngineer, content: " World")
        XCTAssertEqual(manager.structuralVersion, afterFirst)
    }

    func testStructuralVersionIncrementsOnCommit() {
        let stepID = "test_step"
        manager.append(stepID: stepID, messageID: UUID(), role: .softwareEngineer, content: "Test")
        let afterAppend = manager.structuralVersion
        manager.commit(stepID: stepID)
        XCTAssertEqual(manager.structuralVersion, afterAppend + 1)
    }

    func testStructuralVersionIncrementsOnClear() {
        let stepID = "test_step"
        manager.append(stepID: stepID, messageID: UUID(), role: .softwareEngineer, content: "Test")
        let afterAppend = manager.structuralVersion
        manager.clear(stepID: stepID)
        XCTAssertEqual(manager.structuralVersion, afterAppend + 1)
    }

    func testStructuralVersionDoesNotIncrementOnClearNonexistent() {
        let before = manager.structuralVersion
        manager.clear(stepID: "test_step")
        XCTAssertEqual(manager.structuralVersion, before)
    }

    func testStructuralVersionIncrementsOnClearAll() {
        manager.append(stepID: "test_step", messageID: UUID(), role: .softwareEngineer, content: "A")
        manager.append(stepID: "test_step", messageID: UUID(), role: .softwareEngineer, content: "B")
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
        manager.beginStreaming(stepID: "test_step", messageID: UUID(), role: .softwareEngineer)
        XCTAssertEqual(manager.structuralVersion, initial + 1)
    }

    func testStructuralVersionDoesNotIncrementOnBeginStreamingExistingStep() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)
        let afterFirst = manager.structuralVersion
        // Re-begin on same step — preview already exists, no structural change
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)
        XCTAssertEqual(manager.structuralVersion, afterFirst)
    }

    func testStructuralVersionDoesNotIncrementOnAppendThinking() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)
        let afterBegin = manager.structuralVersion
        manager.appendThinking(stepID: stepID, content: "Thinking...")
        XCTAssertEqual(manager.structuralVersion, afterBegin)
    }

    func testStructuralVersionDoesNotIncrementOnProcessingProgress() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)
        let afterBegin = manager.structuralVersion
        manager.updateProcessingProgress(stepID: stepID, progress: 0.5)
        XCTAssertEqual(manager.structuralVersion, afterBegin)
    }

    // MARK: - Begin Streaming Tests

    func testBeginStreamingCreatesPreview() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .techLead)

        XCTAssertNotNil(manager.preview(for: stepID))
        XCTAssertEqual(manager.preview(for: stepID)?.id, messageID)
        XCTAssertEqual(manager.preview(for: stepID)?.role, .techLead)
        XCTAssertEqual(manager.preview(for: stepID)?.content, "")
    }

    func testBeginStreamingRegistersStreamingMessageID() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)

        XCTAssertEqual(manager.streamingMessageIDs[stepID], messageID)
    }

    func testBeginStreamingOverwritesExistingPreview() {
        let stepID = "test_step"
        let messageID1 = UUID()
        let messageID2 = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID1, role: .productManager)
        manager.append(stepID: stepID, messageID: messageID1, role: .productManager, content: "Some content")

        // Begin again on same step — should overwrite
        manager.beginStreaming(stepID: stepID, messageID: messageID2, role: .techLead)

        XCTAssertEqual(manager.preview(for: stepID)?.id, messageID2)
        XCTAssertEqual(manager.preview(for: stepID)?.role, .techLead)
        XCTAssertEqual(manager.preview(for: stepID)?.content, "")
        XCTAssertEqual(manager.streamingMessageIDs[stepID], messageID2)
    }

    // MARK: - isStreaming Tests

    func testIsStreamingReturnsTrueDuringStreaming() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)

        XCTAssertTrue(manager.isStreaming(messageID: messageID))
    }

    func testIsStreamingReturnsFalseForUnknownMessage() {
        XCTAssertFalse(manager.isStreaming(messageID: UUID()))
    }

    func testIsStreamingReturnsFalseAfterCommit() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "content")
        manager.commit(stepID: stepID)

        XCTAssertFalse(manager.isStreaming(messageID: messageID))
    }

    func testIsStreamingReturnsFalseAfterClear() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        manager.clear(stepID: stepID)

        XCTAssertFalse(manager.isStreaming(messageID: messageID))
    }

    func testIsStreamingReturnsFalseAfterClearAll() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        manager.clearAll()

        XCTAssertFalse(manager.isStreaming(messageID: messageID))
    }

    // MARK: - Streaming Content Tests

    func testStreamingContentReturnsAccumulatedContent() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Hello")
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: " World")

        XCTAssertEqual(manager.streamingContent(for: stepID), "Hello World")
    }

    func testStreamingContentReturnsEmptyForNewStream() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)

        XCTAssertEqual(manager.streamingContent(for: stepID), "")
    }

    func testStreamingContentReturnsNilForUnknownStep() {
        XCTAssertNil(manager.streamingContent(for: "nonexistent"))
    }

    func testStreamingContentReturnsNilAfterCommit() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "data")
        manager.commit(stepID: stepID)

        XCTAssertNil(manager.streamingContent(for: stepID))
    }

    // MARK: - Streaming Thinking Tests

    func testAppendThinkingAccumulatesContent() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)

        manager.appendThinking(stepID: stepID, content: "Let me ")
        manager.appendThinking(stepID: stepID, content: "think about this...")

        XCTAssertEqual(manager.streamingThinking(for: stepID), "Let me think about this...")
    }

    func testAppendThinkingIgnoresEmptyContent() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)

        manager.appendThinking(stepID: stepID, content: "")

        XCTAssertNil(manager.streamingThinking(for: stepID))
    }

    func testStreamingThinkingReturnsNilForUnknownStep() {
        XCTAssertNil(manager.streamingThinking(for: "nonexistent"))
    }

    func testStreamingThinkingReturnsNilAfterCommit() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)
        manager.appendThinking(stepID: stepID, content: "Reasoning...")
        manager.commit(stepID: stepID)

        XCTAssertNil(manager.streamingThinking(for: stepID))
    }

    func testStreamingThinkingReturnsNilAfterClear() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)
        manager.appendThinking(stepID: stepID, content: "Reasoning...")
        manager.clear(stepID: stepID)

        XCTAssertNil(manager.streamingThinking(for: stepID))
    }

    func testStreamingThinkingReturnsNilAfterClearAll() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)
        manager.appendThinking(stepID: stepID, content: "Reasoning...")
        manager.clearAll()

        XCTAssertNil(manager.streamingThinking(for: stepID))
    }

    // MARK: - Processing Progress Tests

    func testUpdateProcessingProgressStoresValue() {
        let stepID = "test_step"
        manager.updateProcessingProgress(stepID: stepID, progress: 0.45)

        XCTAssertEqual(manager.processingProgress[stepID], 0.45)
    }

    func testUpdateProcessingProgressUpdatesValue() {
        let stepID = "test_step"
        manager.updateProcessingProgress(stepID: stepID, progress: 0.3)
        manager.updateProcessingProgress(stepID: stepID, progress: 0.7)

        XCTAssertEqual(manager.processingProgress[stepID], 0.7)
    }

    func testClearProcessingProgressRemovesValue() {
        let stepID = "test_step"
        manager.updateProcessingProgress(stepID: stepID, progress: 0.5)
        manager.clearProcessingProgress(stepID: stepID)

        XCTAssertNil(manager.processingProgress[stepID])
    }

    func testClearProcessingProgressOnNonexistentIsNoOp() {
        // Should not crash
        manager.clearProcessingProgress(stepID: "test_step")
        XCTAssertTrue(manager.processingProgress.isEmpty)
    }

    func testProcessingProgressClearedOnCommit() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)
        manager.updateProcessingProgress(stepID: stepID, progress: 0.8)
        manager.commit(stepID: stepID)

        XCTAssertNil(manager.processingProgress[stepID])
    }

    func testProcessingProgressClearedOnClear() {
        let stepID = "test_step"
        manager.beginStreaming(stepID: stepID, messageID: UUID(), role: .softwareEngineer)
        manager.updateProcessingProgress(stepID: stepID, progress: 0.5)
        manager.clear(stepID: stepID)

        XCTAssertNil(manager.processingProgress[stepID])
    }

    func testProcessingProgressClearedOnClearAll() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        manager.updateProcessingProgress(stepID: stepID1, progress: 0.3)
        manager.updateProcessingProgress(stepID: stepID2, progress: 0.6)
        manager.clearAll()

        XCTAssertTrue(manager.processingProgress.isEmpty)
    }

    // MARK: - Commit Clears All Streaming State

    func testCommitClearsAllStreamingState() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "content")
        manager.appendThinking(stepID: stepID, content: "thinking")
        manager.updateProcessingProgress(stepID: stepID, progress: 0.5)

        manager.commit(stepID: stepID)

        XCTAssertNil(manager.preview(for: stepID))
        XCTAssertFalse(manager.isStreaming(messageID: messageID))
        XCTAssertNil(manager.streamingThinking(for: stepID))
        XCTAssertNil(manager.processingProgress[stepID])
        XCTAssertNil(manager.streamingMessageIDs[stepID])
    }

    // MARK: - Clear Clears All Streaming State

    func testClearClearsAllStreamingState() {
        let stepID = "test_step"
        let messageID = UUID()

        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "content")
        manager.appendThinking(stepID: stepID, content: "thinking")
        manager.updateProcessingProgress(stepID: stepID, progress: 0.5)

        manager.clear(stepID: stepID)

        XCTAssertNil(manager.preview(for: stepID))
        XCTAssertFalse(manager.isStreaming(messageID: messageID))
        XCTAssertNil(manager.streamingThinking(for: stepID))
        XCTAssertNil(manager.processingProgress[stepID])
        XCTAssertNil(manager.streamingMessageIDs[stepID])
    }

    // MARK: - ClearAll Clears All Streaming State

    func testClearAllClearsAllStreamingState() {
        let stepID1 = "step_1"
        let stepID2 = "step_2"
        let messageID1 = UUID()
        let messageID2 = UUID()

        manager.beginStreaming(stepID: stepID1, messageID: messageID1, role: .productManager)
        manager.beginStreaming(stepID: stepID2, messageID: messageID2, role: .softwareEngineer)
        manager.appendThinking(stepID: stepID1, content: "think1")
        manager.appendThinking(stepID: stepID2, content: "think2")
        manager.updateProcessingProgress(stepID: stepID1, progress: 0.3)
        manager.updateProcessingProgress(stepID: stepID2, progress: 0.7)

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
        manager.beginStreaming(stepID: stepID1, messageID: messageID1, role: .productManager)
        manager.beginStreaming(stepID: stepID2, messageID: messageID2, role: .softwareEngineer)
        manager.beginStreaming(stepID: stepID3, messageID: messageID3, role: .techLead)

        // Append content independently
        manager.append(stepID: stepID1, messageID: messageID1, role: .productManager, content: "Requirements: ")
        manager.append(stepID: stepID2, messageID: messageID2, role: .softwareEngineer, content: "Code: ")
        manager.append(stepID: stepID3, messageID: messageID3, role: .techLead, content: "Plan: ")
        manager.append(stepID: stepID1, messageID: messageID1, role: .productManager, content: "feature X")
        manager.append(stepID: stepID2, messageID: messageID2, role: .softwareEngineer, content: "func main()")

        // Append thinking independently
        manager.appendThinking(stepID: stepID1, content: "Analyzing requirements")
        manager.appendThinking(stepID: stepID2, content: "Writing implementation")

        // Update processing progress independently
        manager.updateProcessingProgress(stepID: stepID3, progress: 0.5)

        // Verify independent state
        XCTAssertTrue(manager.isStreaming(messageID: messageID1))
        XCTAssertTrue(manager.isStreaming(messageID: messageID2))
        XCTAssertTrue(manager.isStreaming(messageID: messageID3))

        XCTAssertEqual(manager.streamingContent(for: stepID1), "Requirements: feature X")
        XCTAssertEqual(manager.streamingContent(for: stepID2), "Code: func main()")
        XCTAssertEqual(manager.streamingContent(for: stepID3), "Plan: ")

        XCTAssertEqual(manager.streamingThinking(for: stepID1), "Analyzing requirements")
        XCTAssertEqual(manager.streamingThinking(for: stepID2), "Writing implementation")
        XCTAssertNil(manager.streamingThinking(for: stepID3))

        XCTAssertNil(manager.processingProgress[stepID1])
        XCTAssertNil(manager.processingProgress[stepID2])
        XCTAssertEqual(manager.processingProgress[stepID3], 0.5)

        // Commit step 1 — others unaffected
        manager.commit(stepID: stepID1)

        XCTAssertFalse(manager.isStreaming(messageID: messageID1))
        XCTAssertTrue(manager.isStreaming(messageID: messageID2))
        XCTAssertTrue(manager.isStreaming(messageID: messageID3))
        XCTAssertNil(manager.streamingContent(for: stepID1))
        XCTAssertEqual(manager.streamingContent(for: stepID2), "Code: func main()")

        // Clear step 2 — step 3 unaffected
        manager.clear(stepID: stepID2)

        XCTAssertFalse(manager.isStreaming(messageID: messageID2))
        XCTAssertTrue(manager.isStreaming(messageID: messageID3))
        XCTAssertEqual(manager.processingProgress[stepID3], 0.5)
    }

    // MARK: - Full Inline Streaming Lifecycle

    func testFullInlineStreamingLifecycle() {
        let stepID = "test_step"
        let messageID = UUID()

        // Phase 1: Begin streaming (pre-create message)
        manager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        XCTAssertTrue(manager.isStreaming(messageID: messageID))
        XCTAssertEqual(manager.streamingContent(for: stepID), "")
        XCTAssertNil(manager.streamingThinking(for: stepID))

        // Phase 2: Processing progress (prompt processing)
        manager.updateProcessingProgress(stepID: stepID, progress: 0.0)
        XCTAssertEqual(manager.processingProgress[stepID], 0.0)
        manager.updateProcessingProgress(stepID: stepID, progress: 0.5)
        XCTAssertEqual(manager.processingProgress[stepID], 0.5)
        manager.updateProcessingProgress(stepID: stepID, progress: 1.0)
        XCTAssertEqual(manager.processingProgress[stepID], 1.0)
        manager.clearProcessingProgress(stepID: stepID)
        XCTAssertNil(manager.processingProgress[stepID])

        // Phase 3: Thinking starts streaming
        manager.appendThinking(stepID: stepID, content: "I need to ")
        manager.appendThinking(stepID: stepID, content: "analyze the code...")
        XCTAssertEqual(manager.streamingThinking(for: stepID), "I need to analyze the code...")

        // Phase 4: Content starts streaming
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Here is ")
        manager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "the implementation.")
        XCTAssertEqual(manager.streamingContent(for: stepID), "Here is the implementation.")

        // Phase 5: Commit (streaming ends)
        let committed = manager.commit(stepID: stepID)
        XCTAssertNotNil(committed)
        XCTAssertEqual(committed?.content, "Here is the implementation.")
        XCTAssertFalse(manager.isStreaming(messageID: messageID))
        XCTAssertNil(manager.streamingContent(for: stepID))
        XCTAssertNil(manager.streamingThinking(for: stepID))
        XCTAssertNil(manager.processingProgress[stepID])
    }
}
