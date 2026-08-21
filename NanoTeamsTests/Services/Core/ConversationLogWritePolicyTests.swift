import XCTest

@testable import NanoTeams

/// Corner cases for the conversation-log stale-drop decision — the kernel of the fix
/// that stops a slow earlier render from clobbering a newer transcript. Generations are
/// monotonic (assigned at render start on the main actor), so "write iff at least as new
/// as the last write recorded for this task".
final class ConversationLogWritePolicyTests: XCTestCase {

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


    func testFirstWrite_noPriorGeneration_writes() {
        XCTAssertTrue(ConversationLogWritePolicy.shouldWrite(generation: 1, lastWritten: nil))
    }

    func testNewerGeneration_writes() {
        XCTAssertTrue(ConversationLogWritePolicy.shouldWrite(generation: 6, lastWritten: 5))
    }

    func testOlderGeneration_dropped() {
        // The core guarantee: a stale earlier render must NOT overwrite a newer one.
        XCTAssertFalse(ConversationLogWritePolicy.shouldWrite(generation: 5, lastWritten: 6))
    }

    func testEqualGeneration_writes() {
        // Generations are unique per render, so equality shouldn't occur — but if it does,
        // re-writing identical content is harmless (idempotent), not a drop.
        XCTAssertTrue(ConversationLogWritePolicy.shouldWrite(generation: 5, lastWritten: 5))
    }

    func testZeroAndNegativeBoundaries() {
        XCTAssertTrue(ConversationLogWritePolicy.shouldWrite(generation: 0, lastWritten: nil))
        XCTAssertTrue(ConversationLogWritePolicy.shouldWrite(generation: 0, lastWritten: 0))
        XCTAssertFalse(ConversationLogWritePolicy.shouldWrite(generation: -1, lastWritten: 0))
    }

    /// Sequence sanity: across a race where writes arrive out of order, the freshest
    /// generation always lands and no older one supersedes it.
    func testOutOfOrderArrival_freshestWins() {
        var lastWritten: Int? = nil
        func apply(_ gen: Int) {
            if ConversationLogWritePolicy.shouldWrite(generation: gen, lastWritten: lastWritten) {
                lastWritten = gen
            }
        }
        // Render gen 6 lands before the slower gen 5.
        apply(6)
        apply(5)
        XCTAssertEqual(lastWritten, 6, "Freshest generation must remain the last applied.")
    }
}
