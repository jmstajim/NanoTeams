import XCTest

@testable import NanoTeams

/// Pins `ConversationLogRenderCoalescer` — one render slot per task, with turns
/// landing mid-render collapsing into ONE owed follow-up.
///
/// It used to also cover `ConversationLogWritePolicy`, a generation-stamped
/// stale-drop on the WRITE. That mechanism was unreachable from the day this
/// coalescer landed (`begin` is the only entry, `finish` runs strictly after the
/// write, both on the main actor), so it was deleted along with its tests —
/// keeping it would have left a mechanism that reads as live because it has
/// tests, which is CLAUDE.md #57 exactly.
final class ConversationLogRenderCoalescerTests: XCTestCase {

    // MARK: - Render coalescing (2026-08-21)

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { ConversationLogRenderCoalescer._testReset() }
    }

    /// The state machine that turned O(turns²) into O(renders x run): one render
    /// slot per task, turns landing mid-render collapse into ONE owed follow-up.
    @MainActor
    func testCoalescer_midRenderTurnsCollapseIntoOneFollowUp() {
        XCTAssertTrue(ConversationLogRenderCoalescer.begin(7), "fresh task owns the slot")
        XCTAssertFalse(ConversationLogRenderCoalescer.begin(7), "second turn mid-render is refused")
        XCTAssertFalse(ConversationLogRenderCoalescer.begin(7), "third turn too")
        XCTAssertTrue(ConversationLogRenderCoalescer.finish(7), "one follow-up owed, not three")
        XCTAssertFalse(ConversationLogRenderCoalescer.finish(7), "the debt is paid once")
    }

    @MainActor
    func testCoalescer_cleanRenderOwesNoFollowUp() {
        XCTAssertTrue(ConversationLogRenderCoalescer.begin(7))
        XCTAssertFalse(ConversationLogRenderCoalescer.finish(7))
        XCTAssertTrue(ConversationLogRenderCoalescer.begin(7), "slot is free again")
    }

    @MainActor
    func testCoalescer_tasksAreIndependent() {
        XCTAssertTrue(ConversationLogRenderCoalescer.begin(1))
        XCTAssertTrue(ConversationLogRenderCoalescer.begin(2), "task 2 has its own slot")
        XCTAssertFalse(ConversationLogRenderCoalescer.begin(1))
        XCTAssertFalse(ConversationLogRenderCoalescer.finish(2), "task 1's dirt is not task 2's")
        XCTAssertTrue(ConversationLogRenderCoalescer.finish(1))
    }
}
