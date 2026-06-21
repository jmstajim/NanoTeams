import XCTest
@testable import NanoTeams

final class WatchtowerNotificationTypeTests: XCTestCase {

    private let stepID = "test_step"

    // MARK: - supervisorInput color

    func testSupervisorInput_chatMode_returnsInfoColor() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "What next?", role: .softwareEngineer)
        XCTAssertSameColor(sut.color(isChatMode: true), Colors.info)
    }

    func testSupervisorInput_taskMode_returnsGoldColor() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "What next?", role: .softwareEngineer)
        XCTAssertSameColor(sut.color(isChatMode: false), Colors.gold)
    }

    func testSupervisorInput_defaultColor_returnsGold() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .productManager)
        XCTAssertSameColor(sut.color(isChatMode: false), Colors.gold)
    }

    // MARK: - supervisorInput icon

    func testSupervisorInput_chatMode_returnsChatBubbleIcon() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer)
        XCTAssertEqual(sut.icon(isChatMode: true), "bubble.left.and.bubble.right")
    }

    func testSupervisorInput_taskMode_returnsQuestionBubbleIcon() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer)
        XCTAssertEqual(sut.icon(isChatMode: false), "questionmark.bubble")
    }

    // MARK: - supervisorInput title

    func testSupervisorInput_chatMode_returnsRepliedTitle() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer)
        XCTAssertTrue(sut.title(isChatMode: true).contains("replied"))
    }

    func testSupervisorInput_taskMode_returnsNeedsInputTitle() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer)
        XCTAssertTrue(sut.title(isChatMode: false).contains("needs your input"))
    }

    // MARK: - Other notification colors

    func testAcceptance_returnsPurpleColor() {
        let sut = WatchtowerNotificationType.acceptance(stepID: stepID, roleID: "eng", roleName: "Engineer")
        XCTAssertSameColor(sut.color(isChatMode: false), Colors.purple)
        XCTAssertSameColor(sut.color(isChatMode: true), Colors.purple)
    }

    func testFailed_returnsErrorColor() {
        let sut = WatchtowerNotificationType.failed(stepID: stepID, role: .softwareEngineer, errorMessage: nil)
        XCTAssertSameColor(sut.color(isChatMode: false), Colors.error)
    }

    func testTaskDone_returnsSuccessColor() {
        let taskID = 0
        let sut = WatchtowerNotificationType.taskDone(taskID: taskID, taskTitle: "Test")
        XCTAssertSameColor(sut.color(isChatMode: false), Colors.success)
    }

    // MARK: - requiresAction

    func testSupervisorInput_requiresAction() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .productManager)
        XCTAssertTrue(sut.requiresAction)
    }

    func testFailed_doesNotRequireAction() {
        let sut = WatchtowerNotificationType.failed(stepID: stepID, role: .softwareEngineer, errorMessage: nil)
        XCTAssertFalse(sut.requiresAction)
    }

    // MARK: - dismissID

    func testDismissID_supervisorInput_includesStepIDAndQuestion() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer)
        XCTAssertEqual(sut.dismissID, "\(stepID)::Q")
    }

    func testDismissID_supervisorInput_differsAcrossQuestionsOnSameStep() {
        let q1 = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "First?", role: .softwareEngineer)
        let q2 = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Second?", role: .softwareEngineer)
        XCTAssertNotEqual(q1.dismissID, q2.dismissID)
    }

    func testTaskDone_dismissID_matchesTaskID() {
        let taskID = 0
        let sut = WatchtowerNotificationType.taskDone(taskID: taskID, taskTitle: "Done")
        XCTAssertEqual(sut.dismissID, String(taskID))
    }

    // MARK: - timedOut

    func testTimedOut_returnsWarningColor() {
        let sut = WatchtowerNotificationType.timedOut(taskID: 5, taskTitle: "Nightly")
        XCTAssertSameColor(sut.color(isChatMode: false), Colors.warning)
        XCTAssertSameColor(sut.color(isChatMode: true), Colors.warning)
    }

    func testTimedOut_titleIncludesTaskTitle() {
        let sut = WatchtowerNotificationType.timedOut(taskID: 5, taskTitle: "Nightly")
        XCTAssertTrue(sut.title(isChatMode: false).contains("Nightly"))
        XCTAssertTrue(sut.title(isChatMode: false).lowercased().contains("timed out"))
    }

    func testTimedOut_doesNotRequireAction() {
        let sut = WatchtowerNotificationType.timedOut(taskID: 5, taskTitle: "Nightly")
        XCTAssertFalse(sut.requiresAction, "timed-out is informational — no required action")
    }

    func testTimedOut_dismissID_isTaskScopedAndDistinctFromTaskDone() {
        let timedOut = WatchtowerNotificationType.timedOut(taskID: 5, taskTitle: "Nightly")
        let done = WatchtowerNotificationType.taskDone(taskID: 5, taskTitle: "Nightly")
        XCTAssertEqual(timedOut.dismissID, "timeout::5")
        XCTAssertNotEqual(timedOut.dismissID, done.dismissID,
                          "timed-out and task-done on the same task must have distinct dismiss keys")
    }

    func testTimedOut_hasIcon() {
        let sut = WatchtowerNotificationType.timedOut(taskID: 5, taskTitle: "Nightly")
        XCTAssertFalse(sut.icon(isChatMode: false).isEmpty)
    }
}
