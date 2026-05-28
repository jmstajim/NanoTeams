import XCTest
@testable import NanoTeams

/// Pin: `StreamingPreviewManager.hasStreamActivity` lifecycle. The flag
/// drives the UI's "Waiting" → "Generating" status flip when tokens flow
/// into invisible buffers (tool-call args, harmony envelopes). Without
/// this flag the activity feed shows "Waiting" while the model actively
/// emits tokens.
@MainActor
final class StreamingPreviewManagerActivityTests: XCTestCase {

    // MARK: - hasStreamActivity getter

    func testHasReceivedStreamActivity_unset_returnsFalse() {
        let manager = StreamingPreviewManager()
        XCTAssertFalse(manager.hasReceivedStreamActivity(for: "step1"),
                       "Unmarked step must report no activity — drives 'Waiting' indicator")
    }

    func testMarkStreamActivity_thenHasReceivedReturnsTrue() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "step1")
        XCTAssertTrue(manager.hasReceivedStreamActivity(for: "step1"))
    }

    func testMarkStreamActivity_isolatedPerStep() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "stepA")
        XCTAssertTrue(manager.hasReceivedStreamActivity(for: "stepA"))
        XCTAssertFalse(manager.hasReceivedStreamActivity(for: "stepB"),
                       "Activity flag must be per-step — concurrent role steps would otherwise cross-contaminate")
    }

    func testMarkStreamActivity_idempotent() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "step1")
        manager.markStreamActivity(stepID: "step1")
        manager.markStreamActivity(stepID: "step1")
        XCTAssertTrue(manager.hasReceivedStreamActivity(for: "step1"),
                      "Repeat marks are safe no-ops — caller fires on every delta without checking")
    }

    // MARK: - Lifecycle: commit / clear / clearAll

    func testCommit_clearsActivityFlag() {
        let manager = StreamingPreviewManager()
        let messageID = UUID()
        manager.beginStreaming(stepID: "step1", messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: "step1", messageID: messageID, role: .softwareEngineer, content: "hello")
        manager.markStreamActivity(stepID: "step1")
        XCTAssertTrue(manager.hasReceivedStreamActivity(for: "step1"))

        _ = manager.commit(stepID: "step1")

        XCTAssertFalse(manager.hasReceivedStreamActivity(for: "step1"),
                       "commit must clear hasStreamActivity along with previews/thinking/progress — next stream on this step starts clean")
    }

    func testClear_clearsActivityFlag() {
        let manager = StreamingPreviewManager()
        let messageID = UUID()
        manager.beginStreaming(stepID: "step1", messageID: messageID, role: .softwareEngineer)
        manager.markStreamActivity(stepID: "step1")
        XCTAssertTrue(manager.hasReceivedStreamActivity(for: "step1"))

        manager.clear(stepID: "step1")

        XCTAssertFalse(manager.hasReceivedStreamActivity(for: "step1"),
                       "clear must remove the activity flag")
    }

    func testClearAll_clearsAllActivityFlags() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "stepA")
        manager.markStreamActivity(stepID: "stepB")
        manager.markStreamActivity(stepID: "stepC")

        manager.clearAll()

        XCTAssertFalse(manager.hasReceivedStreamActivity(for: "stepA"))
        XCTAssertFalse(manager.hasReceivedStreamActivity(for: "stepB"))
        XCTAssertFalse(manager.hasReceivedStreamActivity(for: "stepC"))
    }

    /// Marking activity on a step that has no other state must still flip
    /// the flag. This matters because the FIRST stream delta might arrive
    /// before any preview / thinking buffer is initialized — the indicator
    /// needs to flip immediately regardless.
    func testMarkStreamActivity_worksWithoutPriorBeginStreaming() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "step1")
        XCTAssertTrue(manager.hasReceivedStreamActivity(for: "step1"),
                      "Activity flag must work even before a preview is created — UI may need to flip status before the first content delta lands")
    }

    /// `clear` must short-circuit only when ALL state is empty. Pre-fix,
    /// the guard didn't include `hasStreamActivity`, so an activity-only
    /// step would fail the guard and the flag would never be removed.
    func testClear_emptyExceptForActivity_stillClearsFlag() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "step1")
        manager.clear(stepID: "step1")
        XCTAssertFalse(manager.hasReceivedStreamActivity(for: "step1"),
                       "clear must clear the activity flag even when no other state was set for the step")
    }
}
