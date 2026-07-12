import XCTest

@testable import NanoTeams

/// Pins the Watchtower Autovisor composer's clear-on-successful-queue gating
/// (`AutovisorComposerSend.evaluate`) — the load-bearing promise behind
/// `sendMessageToAutovisor`'s `Bool` return: a *failed* send (no manager task)
/// must NOT clear the user's typed message + staged attachments, and an empty
/// payload must never reach the orchestrator. Pure / Foundation-only, so no
/// orchestrator or view rendering is needed.
final class AutovisorComposerSendTests: XCTestCase {

    func testEmptyText_noAttachments_isEmpty_andNeverQueues() {
        var queueCalled = false
        let outcome = AutovisorComposerSend.evaluate(text: "   \n ", hasAttachments: false) { _ in
            queueCalled = true
            return true
        }
        XCTAssertEqual(outcome, .empty)
        XCTAssertFalse(queueCalled, "An all-whitespace, no-attachment payload must never hit the orchestrator")
    }

    func testNonEmptyText_queued_isCleared() {
        let outcome = AutovisorComposerSend.evaluate(text: "status?", hasAttachments: false) { _ in true }
        XCTAssertEqual(outcome, .cleared, "A queued message clears the composer")
    }

    func testNonEmptyText_notQueued_isKept() {
        // No manager task → orchestrator returns false → draft must be preserved.
        let outcome = AutovisorComposerSend.evaluate(text: "status?", hasAttachments: false) { _ in false }
        XCTAssertEqual(outcome, .kept, "A send that wasn't queued must NOT clear the user's draft")
    }

    func testAttachmentOnly_emptyText_queued_isCleared() {
        var seenTrimmed: String?
        let outcome = AutovisorComposerSend.evaluate(text: "", hasAttachments: true) { trimmed in
            seenTrimmed = trimmed
            return true
        }
        XCTAssertEqual(outcome, .cleared, "Attachment-only payloads are sendable")
        XCTAssertEqual(seenTrimmed, "", "Empty text is forwarded as-is alongside the attachment")
    }

    func testForwardsTrimmedText_toQueue() {
        var seenTrimmed: String?
        _ = AutovisorComposerSend.evaluate(text: "  hello world  ", hasAttachments: false) { trimmed in
            seenTrimmed = trimmed
            return true
        }
        XCTAssertEqual(seenTrimmed, "hello world", "The orchestrator receives the trimmed text")
    }

    func testAttachmentOnly_notQueued_isKept() {
        let outcome = AutovisorComposerSend.evaluate(text: "  ", hasAttachments: true) { _ in false }
        XCTAssertEqual(outcome, .kept, "An attachment-only send that fails must preserve the staged files")
    }

    func testClipOnly_emptyText_queued_isCleared() {
        var queueCalled = false
        let outcome = AutovisorComposerSend.evaluate(text: "", hasAttachments: false, hasClips: true) { _ in
            queueCalled = true
            return true
        }
        XCTAssertEqual(outcome, .cleared, "A skill/clip-only payload is sendable")
        XCTAssertTrue(queueCalled)
    }

    func testAllEmpty_noClips_isEmpty() {
        let outcome = AutovisorComposerSend.evaluate(text: "  ", hasAttachments: false, hasClips: false) { _ in true }
        XCTAssertEqual(outcome, .empty)
    }
}
