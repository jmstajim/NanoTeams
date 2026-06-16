import XCTest

@testable import NanoTeams

/// Corner cases for the conversation-log stale-drop decision — the kernel of the fix
/// that stops a slow earlier render from clobbering a newer transcript. Generations are
/// monotonic (assigned at render start on the main actor), so "write iff at least as new
/// as the last write recorded for this task".
final class ConversationLogWritePolicyTests: XCTestCase {

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
