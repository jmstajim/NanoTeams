import XCTest
@testable import NanoTeams

@MainActor
final class NotificationServiceTests: XCTestCase {

    var sut: NotificationService!

    override func setUp() {
        super.setUp()
        sut = NotificationService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Notification Creation Tests

    func testNotifyAcceptanceRequired_CreatesCorrectNotification() {
        let stepID = "test_step"

        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: stepID)

        XCTAssertEqual(sut.notifications.count, 1)
        let notification = sut.notifications.first!
        XCTAssertEqual(notification.type, .acceptanceRequired)
        XCTAssertEqual(notification.role, .softwareEngineer)
        XCTAssertEqual(notification.contextID, stepID)
        XCTAssertTrue(notification.requiresAction)
        XCTAssertFalse(notification.isRead)
        XCTAssertTrue(notification.message.contains("Software Engineer"))
    }

    func testNotifySupervisorQuestion_CreatesCorrectNotification() {
        let stepID = "test_step"

        sut.notifySupervisorQuestion(role: .uxDesigner, question: "What color scheme should we use?", stepID: stepID)

        XCTAssertEqual(sut.notifications.count, 1)
        let notification = sut.notifications.first!
        XCTAssertEqual(notification.type, .supervisorQuestionAsked)
        XCTAssertEqual(notification.role, .uxDesigner)
        XCTAssertEqual(notification.contextID, stepID)
        XCTAssertTrue(notification.requiresAction)
        XCTAssertTrue(notification.message.contains("Designer"))
        XCTAssertTrue(notification.message.contains("color scheme"))
    }

    func testNotifyMeetingInvitation_CreatesCorrectNotification() {
        let meetingID = UUID()

        sut.notifyMeetingInvitation(initiatedBy: .tpm, topic: "Sprint Planning", meetingID: meetingID)

        XCTAssertEqual(sut.notifications.count, 1)
        let notification = sut.notifications.first!
        XCTAssertEqual(notification.type, .meetingInvitation)
        XCTAssertEqual(notification.role, .tpm)
        XCTAssertEqual(notification.contextID, meetingID.uuidString)
        XCTAssertTrue(notification.requiresAction)
        XCTAssertTrue(notification.message.contains("Sprint Planning"))
    }

    func testNotifyRoleCompleted_CreatesCorrectNotification() {
        let stepID = "test_step"

        sut.notifyRoleCompleted(role: .productManager, stepID: stepID)

        XCTAssertEqual(sut.notifications.count, 1)
        let notification = sut.notifications.first!
        XCTAssertEqual(notification.type, .roleCompleted)
        XCTAssertEqual(notification.role, .productManager)
        XCTAssertFalse(notification.requiresAction)
        XCTAssertTrue(notification.message.contains("Product Manager"))
    }

    func testNotifyRoleFailed_CreatesCorrectNotification() {
        let stepID = "test_step"

        sut.notifyRoleFailed(role: .softwareEngineer, error: "Build failed with 5 errors", stepID: stepID)

        XCTAssertEqual(sut.notifications.count, 1)
        let notification = sut.notifications.first!
        XCTAssertEqual(notification.type, .roleFailed)
        XCTAssertEqual(notification.role, .softwareEngineer)
        XCTAssertTrue(notification.requiresAction)
        XCTAssertTrue(notification.message.contains("Software Engineer"))
        XCTAssertTrue(notification.message.contains("Build failed"))
    }

    func testNotifyRevisionCompleted_CreatesCorrectNotification() {
        let stepID = "test_step"

        sut.notifyRevisionCompleted(role: .uxDesigner, stepID: stepID)

        XCTAssertEqual(sut.notifications.count, 1)
        let notification = sut.notifications.first!
        XCTAssertEqual(notification.type, .revisionCompleted)
        XCTAssertEqual(notification.role, .uxDesigner)
        XCTAssertTrue(notification.requiresAction)
        XCTAssertTrue(notification.message.contains("re-review"))
    }

    func testNotifyTaskCompleted_CreatesCorrectNotification() {
        let taskID = 0

        sut.notifyTaskCompleted(taskTitle: "Implement Login", taskID: taskID)

        XCTAssertEqual(sut.notifications.count, 1)
        let notification = sut.notifications.first!
        XCTAssertEqual(notification.type, .taskCompleted)
        XCTAssertEqual(notification.role, .supervisor)
        XCTAssertFalse(notification.requiresAction)
        XCTAssertTrue(notification.message.contains("Implement Login"))
    }

    func testNotifyTaskFailed_CreatesCorrectNotification() {
        let taskID = 0

        sut.notifyTaskFailed(taskTitle: "Build Feature", error: "Multiple roles failed", taskID: taskID)

        XCTAssertEqual(sut.notifications.count, 1)
        let notification = sut.notifications.first!
        XCTAssertEqual(notification.type, .taskFailed)
        XCTAssertEqual(notification.role, .supervisor)
        XCTAssertTrue(notification.requiresAction)
        XCTAssertTrue(notification.message.contains("Build Feature"))
        XCTAssertTrue(notification.message.contains("Multiple roles failed"))
    }

    // MARK: - Notification Management Tests

    func testMarkAsRead_UpdatesNotification() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        let notificationID = sut.notifications.first!.id

        sut.markAsRead(notificationID)

        XCTAssertTrue(sut.notifications.first!.isRead)
    }

    func testMarkAsRead_NonExistent_DoesNothing() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        let randomID = UUID()

        sut.markAsRead(randomID)

        XCTAssertFalse(sut.notifications.first!.isRead)
    }

    func testMarkAllAsRead_UpdatesAllNotifications() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        sut.notifyRoleFailed(role: .sre, error: "Test failed", stepID: "test_step")
        sut.notifyRoleCompleted(role: .uxDesigner, stepID: "test_step")

        sut.markAllAsRead()

        XCTAssertTrue(sut.notifications.allSatisfy { $0.isRead })
    }

    func testDismiss_RemovesNotification() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        sut.notifyRoleCompleted(role: .uxDesigner, stepID: "test_step")
        let notificationToDismiss = sut.notifications.first!.id

        sut.dismiss(notificationToDismiss)

        XCTAssertEqual(sut.notifications.count, 1)
        XCTAssertFalse(sut.notifications.contains { $0.id == notificationToDismiss })
    }

    func testClearAll_RemovesAllNotifications() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        sut.notifyRoleFailed(role: .sre, error: "Test failed", stepID: "test_step")

        sut.clearAll()

        XCTAssertTrue(sut.notifications.isEmpty)
    }

    // MARK: - Computed Properties Tests

    func testUnreadCount_ReturnsCorrectCount() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        sut.notifyRoleCompleted(role: .uxDesigner, stepID: "test_step")
        sut.notifyRoleFailed(role: .sre, error: "Error", stepID: "test_step")

        XCTAssertEqual(sut.unreadCount, 3)

        sut.markAsRead(sut.notifications[0].id)

        XCTAssertEqual(sut.unreadCount, 2)
    }

    func testActionableNotifications_FiltersCorrectly() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")  // Actionable
        sut.notifyRoleCompleted(role: .uxDesigner, stepID: "test_step")  // Not actionable
        sut.notifyRoleFailed(role: .sre, error: "Error", stepID: "test_step")  // Actionable

        XCTAssertEqual(sut.actionableNotifications.count, 2)
        XCTAssertTrue(sut.actionableNotifications.allSatisfy { $0.requiresAction })
    }

    func testActionableNotifications_ExcludesRead() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        sut.notifyRoleFailed(role: .sre, error: "Error", stepID: "test_step")

        sut.markAsRead(sut.notifications[0].id)

        XCTAssertEqual(sut.actionableNotifications.count, 1)
    }

    // MARK: - Badge Properties Tests

    func testBadgeCount_EqualsActionableCount() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        sut.notifyRoleCompleted(role: .uxDesigner, stepID: "test_step")

        XCTAssertEqual(sut.badgeCount, 1)
    }

    func testShouldShowBadge_TrueWhenActionable() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")

        XCTAssertTrue(sut.shouldShowBadge)
    }

    func testShouldShowBadge_FalseWhenNoActionable() {
        sut.notifyRoleCompleted(role: .uxDesigner, stepID: "test_step")

        XCTAssertFalse(sut.shouldShowBadge)
    }

    func testBadgeText_ShowsNumber() {
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        sut.notifyRoleFailed(role: .sre, error: "Error", stepID: "test_step")

        XCTAssertEqual(sut.badgeText, "2")
    }

    func testBadgeText_ShowsNinePlusForLargeCount() {
        for i in 0..<12 {
            sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        }

        XCTAssertEqual(sut.badgeText, "9+")
    }

    // MARK: - Sorting Tests

    func testSortedByPriority_ReturnsHighPriorityFirst() {
        sut.notifyRoleCompleted(role: .uxDesigner, stepID: "test_step")  // Priority 30
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")  // Priority 100
        sut.notifyRoleFailed(role: .sre, error: "Error", stepID: "test_step")  // Priority 85

        let sorted = sut.sortedByPriority()

        XCTAssertEqual(sorted[0].type, .acceptanceRequired)
        XCTAssertEqual(sorted[1].type, .roleFailed)
        XCTAssertEqual(sorted[2].type, .roleCompleted)
    }

    // MARK: - Recent Notifications Tests

    func testRecentNotifications_FiltersOldNotifications() {
        // Create notification
        sut.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")

        // Recent notifications should include it
        let recent = sut.recentNotifications()
        XCTAssertEqual(recent.count, 1)
    }

    // MARK: - Max Notifications Limit Tests

    func testMaxNotifications_TrimsOldest() {
        // Add more than max notifications (100)
        for i in 0..<110 {
            sut.notifyRoleCompleted(role: .softwareEngineer, stepID: "test_step")
        }

        XCTAssertLessThanOrEqual(sut.notifications.count, 100)
    }

    // MARK: - Notifications Order Tests

    func testNotifications_NewestFirst() {
        sut.notifyRoleCompleted(role: .softwareEngineer, stepID: "test_step")

        // Small delay
        Thread.sleep(forTimeInterval: 0.01)

        sut.notifyAcceptanceRequired(role: .uxDesigner, stepID: "test_step")

        XCTAssertEqual(sut.notifications[0].type, .acceptanceRequired)
        XCTAssertEqual(sut.notifications[1].type, .roleCompleted)
    }

    // MARK: - NotificationType Tests

    func testNotificationType_DisplayName() {
        XCTAssertEqual(NotificationType.acceptanceRequired.displayName, "Acceptance Required")
        XCTAssertEqual(NotificationType.supervisorQuestionAsked.displayName, "Question Asked")
        XCTAssertEqual(NotificationType.meetingInvitation.displayName, "Meeting Invitation")
        XCTAssertEqual(NotificationType.roleCompleted.displayName, "Role Completed")
        XCTAssertEqual(NotificationType.roleFailed.displayName, "Role Failed")
        XCTAssertEqual(NotificationType.revisionCompleted.displayName, "Revision Ready")
        XCTAssertEqual(NotificationType.taskCompleted.displayName, "Task Completed")
        XCTAssertEqual(NotificationType.taskFailed.displayName, "Task Failed")
    }

    func testNotificationType_Icon() {
        XCTAssertEqual(NotificationType.acceptanceRequired.icon, "checkmark.circle.badge.questionmark")
        XCTAssertEqual(NotificationType.supervisorQuestionAsked.icon, "questionmark.bubble")
        XCTAssertEqual(NotificationType.meetingInvitation.icon, "person.3")
        XCTAssertEqual(NotificationType.roleCompleted.icon, "checkmark.circle")
        XCTAssertEqual(NotificationType.roleFailed.icon, "xmark.circle")
        XCTAssertEqual(NotificationType.revisionCompleted.icon, "arrow.clockwise.circle")
        XCTAssertEqual(NotificationType.taskCompleted.icon, "flag.checkered")
        XCTAssertEqual(NotificationType.taskFailed.icon, "exclamationmark.triangle")
    }

    func testNotificationType_Priority() {
        // Higher priority types should have higher numbers
        XCTAssertGreaterThan(NotificationType.acceptanceRequired.priority, NotificationType.roleCompleted.priority)
        XCTAssertGreaterThan(NotificationType.supervisorQuestionAsked.priority, NotificationType.roleCompleted.priority)
        XCTAssertGreaterThan(NotificationType.roleFailed.priority, NotificationType.taskCompleted.priority)
    }

    // MARK: - Codable Tests

    func testTeamNotification_Codable_RoundTrip() throws {
        let original = TeamNotification(
            type: .acceptanceRequired,
            role: .softwareEngineer,
            message: "Test message",
            isRead: true,
            requiresAction: true,
            contextID: UUID().uuidString
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TeamNotification.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.message, original.message)
        XCTAssertEqual(decoded.isRead, original.isRead)
        XCTAssertEqual(decoded.requiresAction, original.requiresAction)
        XCTAssertEqual(decoded.contextID, original.contextID)
    }
}
