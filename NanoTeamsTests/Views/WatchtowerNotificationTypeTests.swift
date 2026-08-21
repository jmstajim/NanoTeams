import XCTest
@testable import NanoTeams

final class WatchtowerNotificationTypeTests: XCTestCase {

    private let stepID = "test_step"

    // MARK: - supervisorInput color

    func testSupervisorInput_chatMode_returnsInfoColor() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "What next?", role: .softwareEngineer, toolCallID: nil)
        XCTAssertSameColor(sut.color(isChatMode: true), Colors.info)
    }

    func testSupervisorInput_taskMode_returnsGoldColor() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "What next?", role: .softwareEngineer, toolCallID: nil)
        XCTAssertSameColor(sut.color(isChatMode: false), Colors.gold)
    }

    func testSupervisorInput_defaultColor_returnsGold() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .productManager, toolCallID: nil)
        XCTAssertSameColor(sut.color(isChatMode: false), Colors.gold)
    }

    // MARK: - supervisorInput icon

    func testSupervisorInput_chatMode_returnsChatBubbleIcon() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer, toolCallID: nil)
        XCTAssertEqual(sut.icon(isChatMode: true), "bubble.left.and.bubble.right")
    }

    func testSupervisorInput_taskMode_returnsQuestionBubbleIcon() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer, toolCallID: nil)
        XCTAssertEqual(sut.icon(isChatMode: false), "questionmark.bubble")
    }

    // MARK: - supervisorInput title

    func testSupervisorInput_chatMode_returnsRepliedTitle() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer, toolCallID: nil)
        XCTAssertTrue(sut.title(isChatMode: true).contains("replied"))
    }

    func testSupervisorInput_taskMode_returnsNeedsInputTitle() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer, toolCallID: nil)
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
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .productManager, toolCallID: nil)
        XCTAssertTrue(sut.requiresAction)
    }

    func testFailed_doesNotRequireAction() {
        let sut = WatchtowerNotificationType.failed(stepID: stepID, role: .softwareEngineer, errorMessage: nil)
        XCTAssertFalse(sut.requiresAction)
    }

    // MARK: - dismissID

    /// Escalation path only: the engine flips the waiting flag with no tool call to
    /// name, so the question text is all there is to discriminate rounds by.
    func testDismissID_supervisorInput_escalationPath_fallsBackToQuestionText() {
        let sut = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Q", role: .softwareEngineer, toolCallID: nil)
        XCTAssertEqual(sut.dismissID, "\(stepID)::Q")
    }

    func testDismissID_supervisorInput_namesTheAskingCall() {
        let callID = UUID()
        let sut = WatchtowerNotificationType.supervisorInput(
            stepID: stepID, question: "Q", role: .softwareEngineer, toolCallID: callID)
        XCTAssertEqual(sut.dismissID, "\(stepID)::\(callID.uuidString)")
    }

    /// In chat mode every turn is an `ask_supervisor` call, so byte-identical text
    /// across rounds is ordinary. The per-call `UUID` keeps the rounds distinct where
    /// the old text-based key collided and suppressed the second one.
    func testDismissID_supervisorInput_identicalTextDistinctCalls_differ() {
        let a = WatchtowerNotificationType.supervisorInput(
            stepID: stepID, question: "Continue?", role: .softwareEngineer, toolCallID: UUID())
        let b = WatchtowerNotificationType.supervisorInput(
            stepID: stepID, question: "Continue?", role: .softwareEngineer, toolCallID: UUID())
        XCTAssertNotEqual(a.dismissID, b.dismissID)
    }

    func testDismissID_supervisorInput_differsAcrossQuestionsOnSameStep() {
        let q1 = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "First?", role: .softwareEngineer, toolCallID: nil)
        let q2 = WatchtowerNotificationType.supervisorInput(stepID: stepID, question: "Second?", role: .softwareEngineer, toolCallID: nil)
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

    // MARK: - bashApprovalNeeded

    private func bashNotif(
        stepID: String = "eng", taskID: Int = 7, command: String = "rm -rf build",
        role: Role = .softwareEngineer, at: TimeInterval = 100
    ) -> WatchtowerNotificationType {
        .bashApprovalNeeded(
            stepID: stepID, taskID: taskID, command: command, role: role,
            createdAt: Date(timeIntervalSince1970: at))
    }

    func testBashApprovalNeeded_warningColor_independentOfChatMode() {
        XCTAssertSameColor(bashNotif().color(isChatMode: false), Colors.warning)
        XCTAssertSameColor(bashNotif().color(isChatMode: true), Colors.warning)
    }

    func testBashApprovalNeeded_terminalIcon() {
        XCTAssertEqual(bashNotif().icon(isChatMode: false), "terminal")
    }

    func testBashApprovalNeeded_titleNamesRole() {
        let t = bashNotif(role: .softwareEngineer).title(isChatMode: false)
        XCTAssertTrue(t.contains(Role.softwareEngineer.displayName))
        XCTAssertTrue(t.lowercased().contains("command"))
    }

    func testBashApprovalNeeded_doesNotRequireInlineAction() {
        // Pointer to the in-task card — the banner only navigates, no inline buttons.
        XCTAssertFalse(bashNotif().requiresAction)
    }

    func testBashApprovalNeeded_countsTowardNeedsAttention() {
        // Even though requiresAction is false, a held command IS waiting on the user.
        XCTAssertTrue(bashNotif().needsAttention)
    }

    func testBashApprovalNeeded_dismissID_discriminatesByCreatedAt() {
        // A re-held command (same step/task, new createdAt) gets a fresh dismiss ID so
        // a prior dismissal can't suppress the new hold.
        let first = bashNotif(at: 100)
        let second = bashNotif(at: 200)
        XCTAssertNotEqual(first.dismissID, second.dismissID)
        XCTAssertTrue(first.dismissID.hasPrefix("bash::7::eng::"),
                      "dismiss key is task+step+createdAt scoped")
    }

    func testBashApprovalNeeded_dismissID_distinctFromSupervisorInputOnSameStep() {
        let bash = bashNotif(stepID: "eng", taskID: 7)
        let input = WatchtowerNotificationType.supervisorInput(stepID: "eng", question: "Q", role: .softwareEngineer, toolCallID: nil)
        XCTAssertNotEqual(bash.dismissID, input.dismissID)
    }
}
