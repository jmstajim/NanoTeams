import XCTest

@testable import NanoTeams

/// `[ Ask as form ]` pressed from the Quick Capture panel.
///
/// The panel is the surface with no second route to a waiting question, so the button has to
/// leave it in the same state an ANSWER leaves it: the step unparked, the fields released, and
/// the panel moved on to whatever is still waiting. Both paths run the same
/// `advanceAfterQuestionResolved` for exactly that reason.
@MainActor
final class QuickCaptureQuestionnaireRequestTests: XCTestCase {

    private var store: NTMSOrchestrator!
    private var controller: QuickCaptureController!
    private var workFolder: URL!

    private let stepID = "plain_step"
    /// The ask the fixture parked on — the panel carries it so the button can exist.
    private var askCallID: UUID!

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-request-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        controller = nil
        store = nil
        askCallID = nil
        if let workFolder { try? FileManager.default.removeItem(at: workFolder) }
        workFolder = nil
        QuickCaptureController.shared._testReset()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private var form: SupervisorInquiry {
        SupervisorInquiry(
            headline: "A few decisions first.",
            questions: [
                SupervisorInquiryQuestion(
                    id: "scheme", prompt: "Which scheme?", kind: .singleChoice,
                    options: [
                        SupervisorInquiryOption(id: "debug", label: "Debug"),
                        SupervisorInquiryOption(id: "release", label: "Release"),
                    ])
            ])
    }

    /// A task parked on a PLAIN ask, with the panel sitting in answer mode on it.
    private func makeParked(inquiry: SupervisorInquiry? = nil) async -> Int? {
        store = TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        guard let taskID = await store.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("task creation failed")
            return nil
        }
        let question = inquiry?.headline ?? "Which way should the screen go?"
        let askCall = StepToolCall(
            name: inquiry == nil ? ToolNames.askSupervisor : ToolNames.askSupervisorForm,
            argumentsJSON: "{\"question\": \"\(question)\"}",
            resultJSON: nil,
            isError: false)
        askCallID = askCall.id
        await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: task.runs.first?.teamID ?? "test_team")
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: "eng", name: "Engineer", prompt: "", toolIDs: [],
                usePlanningPhase: false, dependencies: RoleDependencies()))
            step.id = self.stepID
            step.status = .needsSupervisorInput
            step.needsSupervisorInput = true
            step.supervisorQuestion = question
            step.supervisorInquiry = inquiry
            step.toolCalls = [askCall]
            run.steps.append(step)
            task.runs.append(run)
        }

        let made = QuickCaptureController(formState: QuickCaptureFormState())
        made.store = store
        made.dictation = nil
        made.isTaskSelected = true
        made._testEnterAnswerMode(.supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: stepID, taskID: taskID, role: .softwareEngineer, roleDefinition: nil,
            question: question, inquiry: inquiry, askCallID: askCall.id,
            messageContent: nil, thinking: nil, isChatMode: false)))
        controller = made
        return taskID
    }

    private func step(in taskID: Int) -> StepExecution? {
        store.loadedTask(taskID)?.runs.last?.steps.first { $0.id == stepID }
    }

    // MARK: - The request

    func testRequest_unparksTheStepWithTheDirective() async {
        guard let taskID = await makeParked() else { return }

        await controller.requestQuestionnaire()

        XCTAssertEqual(step(in: taskID)?.supervisorAnswer, SupervisorQuestionnaireRequest.directive)
        XCTAssertEqual(step(in: taskID)?.needsSupervisorInput, false)
        XCTAssertEqual(
            step(in: taskID)?.lastSupervisorAskResolution, .questionnaireRequest,
            "the app sent it, so the record must not read as the Supervisor's answer")
    }

    /// Whatever the Supervisor had already typed narrows the form the role is about to write,
    /// so it rides along rather than being discarded with the field.
    func testRequest_carriesTheTypedTextAsTheNote() async {
        guard let taskID = await makeParked() else { return }
        controller.formState.answerText = "  дай три варианта дизайна  "

        await controller.requestQuestionnaire()

        let answer = step(in: taskID)?.supervisorAnswer ?? ""
        XCTAssertTrue(answer.hasPrefix(SupervisorQuestionnaireRequest.directive))
        XCTAssertTrue(answer.hasSuffix("дай три варианта дизайна"), answer)
    }

    /// Same release an answer performs: the draft is discarded and the fields are cleared, so
    /// the next question does not open on top of a reply written for this one.
    func testRequest_clearsTheAnswerFields() async {
        guard await makeParked() != nil else { return }
        controller.formState.answerText = "half-written reply"

        await controller.requestQuestionnaire()

        XCTAssertTrue(controller.formState.answerText.isEmpty)
        XCTAssertFalse(controller.formState.isInAnswerMode, "nothing else is waiting → dismissed")
    }

    // MARK: - Corner cases

    /// The button is not offered on a form, and the controller refuses one anyway: the
    /// directive would otherwise be read back with the grammar written for a model's reply.
    func testRequest_isRefused_whenTheStepIsParkedOnAForm() async {
        guard let taskID = await makeParked(inquiry: form) else { return }

        await controller.requestQuestionnaire()

        XCTAssertNil(step(in: taskID)?.supervisorAnswer)
        XCTAssertEqual(step(in: taskID)?.needsSupervisorInput, true)
        XCTAssertTrue(
            controller.formState.isInAnswerMode, "the panel stays on the question it refused")
    }

    /// Not in answer mode at all — the panel has no question in hand, so there is nothing to
    /// send and nothing to clear.
    func testRequest_isANoOp_whenThePanelHoldsNoQuestion() async {
        store = TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        let made = QuickCaptureController(formState: QuickCaptureFormState())
        made.store = store
        made.dictation = nil
        controller = made

        await controller.requestQuestionnaire()

        XCTAssertFalse(controller.formState.isInAnswerMode)
    }
}
