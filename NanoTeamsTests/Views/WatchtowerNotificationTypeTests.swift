import XCTest
@testable import NanoTeams

final class WatchtowerNotificationTypeTests: XCTestCase {

    private let stepID = "test_step"

    // MARK: - supervisorInput color

    func testSupervisorInput_chatMode_returnsInfoColor() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "What next?", role: .softwareEngineer)
        XCTAssertEqual(sut.color(isChatMode: true), Colors.info)
    }

    func testSupervisorInput_taskMode_returnsGoldColor() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "What next?", role: .softwareEngineer)
        XCTAssertEqual(sut.color(isChatMode: false), Colors.gold)
    }

    func testSupervisorInput_defaultColor_returnsGold() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .productManager)
        XCTAssertEqual(sut.color(isChatMode: false), Colors.gold)
    }

    // MARK: - supervisorInput icon

    func testSupervisorInput_chatMode_returnsChatBubbleIcon() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer)
        XCTAssertEqual(sut.icon(isChatMode: true), "bubble.left.and.bubble.right.fill")
    }

    func testSupervisorInput_taskMode_returnsQuestionBubbleIcon() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer)
        XCTAssertEqual(sut.icon(isChatMode: false), "questionmark.bubble.fill")
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
        XCTAssertEqual(sut.color(isChatMode: false), Colors.purple)
        XCTAssertEqual(sut.color(isChatMode: true), Colors.purple)
    }

    func testFailed_returnsErrorColor() {
        let sut = WatchtowerNotificationType.failed(stepID: stepID, role: .softwareEngineer, errorMessage: nil)
        XCTAssertEqual(sut.color(isChatMode: false), Colors.error)
    }

    func testTaskDone_returnsSuccessColor() {
        let taskID = 0
        let sut = WatchtowerNotificationType.taskDone(taskID: taskID, taskTitle: "Test")
        XCTAssertEqual(sut.color(isChatMode: false), Colors.success)
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

    func testDismissID_matchesStepID() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer)
        XCTAssertEqual(sut.dismissID, stepID)
    }

    func testTaskDone_dismissID_matchesTaskID() {
        let taskID = 0
        let sut = WatchtowerNotificationType.taskDone(taskID: taskID, taskTitle: "Done")
        XCTAssertEqual(sut.dismissID, String(taskID))
    }
}
