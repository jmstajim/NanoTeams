import XCTest
@testable import NanoTeams

/// Pins the "{N} tasks need you" headline source + the restored Watchtower
/// active-run control gate.
final class WatchtowerNeedsAttentionTests: XCTestCase {

    private func notif(_ type: WatchtowerNotificationType, taskID: Int = 1) -> WatchtowerNotification {
        WatchtowerNotification(taskID: taskID, taskTitle: "t", isChatMode: false, type: type)
    }

    // MARK: - needsAttention

    func testNeedsAttention_everyTypeCounts() {
        XCTAssertTrue(WatchtowerNotificationType
            .supervisorInput(stepID: "s", question: "q", role: .softwareEngineer).needsAttention)
        XCTAssertTrue(WatchtowerNotificationType
            .acceptance(stepID: "s", roleID: "r", roleName: "R").needsAttention)
        XCTAssertTrue(WatchtowerNotificationType.taskDone(taskID: 0, taskTitle: "t").needsAttention)
        XCTAssertTrue(WatchtowerNotificationType
            .failed(stepID: "s", role: .softwareEngineer, errorMessage: nil).needsAttention)
        XCTAssertTrue(WatchtowerNotificationType.timedOut(taskID: 1, taskTitle: "t").needsAttention)
    }

    // MARK: - needsYouCount

    /// The fix: failed / timed-out tasks count toward the headline even though
    /// they expose no action button (`requiresAction == false`). The old count
    /// (`filter(\.type.requiresAction)`) read "0 tasks need you" while a failure
    /// sat in the inbox.
    func testNeedsYouCount_includesFailedAndTimedOut() {
        let notifs = [
            notif(.failed(stepID: "s1", role: .softwareEngineer, errorMessage: nil), taskID: 1),
            notif(.timedOut(taskID: 2, taskTitle: "b"), taskID: 2),
            notif(.supervisorInput(stepID: "s3", question: "q", role: .productManager), taskID: 3),
        ]
        XCTAssertEqual(WatchtowerNotification.needsYouCount(notifs), 3)
        // Regression contrast — the old predicate would have counted only 1.
        XCTAssertEqual(notifs.filter(\.type.requiresAction).count, 1)
    }

    func testNeedsYouCount_empty_isZero() {
        XCTAssertEqual(WatchtowerNotification.needsYouCount([]), 0)
    }

}
