import XCTest

@testable import NanoTeams

/// Submitting a questionnaire from the Quick Capture panel, end to end.
///
/// The card's state lives in `QuickCaptureFormState.answerInquiry` and has to travel four
/// seams to become a record: the submit gate, `answerSupervisorQuestion`'s new parameter,
/// `StepMessagingService`, and `SupervisorInquiryReply.compose`. Every one of them was optional
/// before this step, so every one of them silently drops the form if it is not passed — the
/// answer still lands, as prose the model then has to read back against its own questions.
@MainActor
final class QuickCaptureInquirySubmitTests: XCTestCase {

    private var store: NTMSOrchestrator!
    private var controller: QuickCaptureController!
    private var workFolder: URL!

    private let stepID = "inquiry_step"

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-inquiry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        controller = nil
        store = nil
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
                    ]),
                SupervisorInquiryQuestion(
                    id: "suites", prompt: "Which suites?", kind: .multiChoice,
                    options: [
                        SupervisorInquiryOption(id: "unit", label: "Unit"),
                        SupervisorInquiryOption(id: "ui", label: "UI"),
                    ]),
            ])
    }

    /// A task parked on a questionnaire, with a wired controller sitting in answer mode on it.
    private func makeParkedOnAForm() async -> Int? {
        store = TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        guard let taskID = await store.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("task creation failed")
            return nil
        }
        let inquiry = form
        await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: task.runs.first?.teamID ?? "test_team")
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: "eng", name: "Engineer", prompt: "", toolIDs: [],
                usePlanningPhase: false, dependencies: RoleDependencies()))
            step.id = self.stepID
            step.status = .needsSupervisorInput
            step.needsSupervisorInput = true
            step.supervisorQuestion = inquiry.headline
            step.supervisorInquiry = inquiry
            run.steps.append(step)
            task.runs.append(run)
        }

        let made = QuickCaptureController(formState: QuickCaptureFormState())
        made.store = store
        made.dictation = nil
        made.isTaskSelected = true
        made._testEnterAnswerMode(.supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: stepID, taskID: taskID, role: .softwareEngineer, roleDefinition: nil,
            question: inquiry.headline, inquiry: inquiry,
            messageContent: nil, thinking: nil, isChatMode: false)))
        controller = made
        return taskID
    }

    private func step(in taskID: Int) -> StepExecution? {
        store.loadedTask(taskID)?.runs.last?.steps.first { $0.id == stepID }
    }

    // MARK: - The record

    /// Ticks and nothing typed is a whole answer, and it has to arrive as STRUCTURE.
    ///
    /// RED: drop `inquiryAnswer:` from the controller's `answerSupervisorQuestion` call → the
    /// step is unblocked with an empty prose answer and no record of what was decided, and the
    /// feed re-renders a questionnaire nobody appears to have filled in.
    func testAFilledFormWithNoProseIsSubmittedAsStructure() async {
        guard let taskID = await makeParkedOnAForm() else { return }
        controller.formState.answerInquiry = SupervisorInquiryDraft(
            inquiry: form,
            answer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: ["release"]),
                "suites": .init(selectedOptionIDs: ["unit", "ui"]),
            ]))

        await controller.submitAnswer()

        let answered = step(in: taskID)
        XCTAssertEqual(
            answered?.supervisorInquiryAnswer?.byQuestionID["scheme"]?.selectedOptionIDs,
            ["release"])
        XCTAssertEqual(
            answered?.supervisorInquiryAnswer?.byQuestionID["suites"]?.selectedOptionIDs,
            ["unit", "ui"])
        XCTAssertEqual(answered?.needsSupervisorInput, false, "and the step is unblocked")
    }

    /// The prose the model receives is rendered from that structure, with the numbering it
    /// asked in — not a bare "the Supervisor answered".
    func testTheModelReceivesTheDecisionsAsNumberedPairs() async {
        guard let taskID = await makeParkedOnAForm() else { return }
        controller.formState.answerInquiry = SupervisorInquiryDraft(
            inquiry: form,
            answer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: ["release"])
            ]))

        await controller.submitAnswer()

        let sent = step(in: taskID)?.supervisorAnswer ?? ""
        XCTAssertTrue(sent.contains("Q1. Which scheme?"), sent)
        XCTAssertTrue(sent.contains("A1. Release"), sent)
    }

    /// The partial submit end to end, and the shape the user reported: one question ticked in
    /// the panel, one left alone. The tick is recorded, the untouched question is recorded as
    /// nothing at all, and the model reads the absence plus the direction beneath it.
    ///
    /// RED: fill the untouched question from `options[0]` → the panel reports a decision on
    /// the one question the Supervisor passed over, and the card draws a tick beside it.
    func testAnUntouchedQuestionIsRecordedAsNothing() async {
        guard let taskID = await makeParkedOnAForm() else { return }
        controller.formState.answerInquiry = SupervisorInquiryDraft(
            inquiry: form,
            answer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: ["release"])
            ]))

        await controller.submitAnswer()

        let recorded = step(in: taskID)?.supervisorInquiryAnswer
        XCTAssertNil(recorded?.byQuestionID["suites"],
                     "options[0] is a recommendation, not a value silence resolves to")
        XCTAssertEqual(recorded?.byQuestionID["scheme"]?.selectedOptionIDs, ["release"],
                       "and the question they DID decide is kept whole")
        let sent = step(in: taskID)?.supervisorAnswer ?? ""
        XCTAssertTrue(sent.contains(SupervisorInquiryRenderer.unansweredMarker), sent)
        XCTAssertTrue(sent.contains(SupervisorInquiryRenderer.unansweredDirection), sent)
    }

    /// Prose typed beside the form is addressed to the whole questionnaire, and it belongs on
    /// the record — the feed re-renders from the structure, not from the wire text.
    ///
    /// RED: drop the note from the composed answer → the sentence the Supervisor wrote by hand
    /// exists only inside the prose sent to the model, and the card that re-renders the answer
    /// loses it.
    func testProseTypedBesideTheFormRidesOnTheRecord() async {
        guard let taskID = await makeParkedOnAForm() else { return }
        controller.formState.answerInquiry = SupervisorInquiryDraft(
            inquiry: form,
            answer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: ["debug"])
            ]))
        controller.formState.answerText = "Keep the diff tight."

        await controller.submitAnswer()

        XCTAssertEqual(step(in: taskID)?.supervisorInquiryAnswer?.note, "Keep the diff tight.")
    }

    /// A person who decides nothing and answers in prose has still answered as a PERSON.
    ///
    /// RED: mint the submission from the card's answer instead of from the payload's
    /// questionnaire (`inquiryAnswer.map` rather than `payload.inquiry.map`) → an untouched
    /// card sends none, and their sentence is read back with the grammar written for a model's
    /// `Q2: 1, 3` reply: the leading `1.` becomes a selection of option 1, which is the
    /// recommendation they were arguing against.
    func testAFormAnsweredEntirelyInProseIsStillAHumansAnswer() async {
        guard let taskID = await makeParkedOnAForm() else { return }
        controller.formState.answerText = "1. I'd rather you used Release, actually."

        await controller.submitAnswer()

        let recorded = step(in: taskID)?.supervisorInquiryAnswer
        XCTAssertTrue(recorded?.byQuestionID.isEmpty ?? false,
                      "they ticked nothing, so nothing was decided — and `debug` in particular "
                          + "is the recommendation they were arguing against")
        XCTAssertEqual(recorded?.note, "1. I'd rather you used Release, actually.",
                       "and their sentence reaches the role verbatim")
    }

    /// The note is what they TYPED. The reply the model receives additionally carries clip and
    /// attached-file sections — and, under `embedFilesInPrompt`, whole file bodies.
    ///
    /// RED: pass `fullAnswer` as the note → `## Clipped Text` markers and file contents are
    /// persisted as something the Supervisor said, and the feed's answered card renders them
    /// raw above the decisions, beside the attachment grid that already shows the same files.
    func testTheNoteIsWhatTheyTypedNotTheReplyAssembledForTheModel() async {
        guard let taskID = await makeParkedOnAForm() else { return }
        controller.formState.answerText = "Keep the diff tight."
        controller.formState.answerClippedTexts = [Clip].minting(["let x = 1"])

        await controller.submitAnswer()

        let answered = step(in: taskID)
        XCTAssertEqual(answered?.supervisorInquiryAnswer?.note, "Keep the diff tight.")
        XCTAssertTrue(answered?.supervisorAnswer?.contains("## Clipped Text") ?? false,
                      "precondition: the model DOES receive the clip section")
    }

    /// The bucket is emptied on a successful submit — all FOUR fields, not the three that were
    /// spelled by hand at three call sites.
    ///
    /// RED: leave `answerInquiry` standing → `exitAnswerMode` parks it under the branch
    /// whose question was just answered, and the composer offers it back as an unsent reply to
    /// a question that no longer exists.
    func testASubmittedFormLeavesNothingParkedBehind() async {
        guard let taskID = await makeParkedOnAForm() else { return }
        controller.formState.answerInquiry = SupervisorInquiryDraft(
            inquiry: form,
            answer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: ["debug"])
            ]))

        await controller.submitAnswer()

        XCTAssertNil(controller.formState.answerInquiry)
        XCTAssertTrue(
            controller.formState.answerDraftStore.keys(forTask: taskID).isEmpty,
            "nothing was left in the bucket for the exit to park")
    }

    /// A plain question answered from the same panel must be untouched by any of this.
    func testAPlainQuestionStillTravelsAsProseAndRecordsNoStructure() async {
        store = TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        guard let taskID = await store.createTask(title: "T", supervisorTask: "do") else {
            return XCTFail("task creation failed")
        }
        await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: task.runs.first?.teamID ?? "test_team")
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: "eng", name: "Engineer", prompt: "", toolIDs: [],
                usePlanningPhase: false, dependencies: RoleDependencies()))
            step.id = self.stepID
            step.status = .needsSupervisorInput
            step.needsSupervisorInput = true
            step.supervisorQuestion = "Which approach?"
            run.steps.append(step)
            task.runs.append(run)
        }
        let made = QuickCaptureController(formState: QuickCaptureFormState())
        made.store = store
        made.dictation = nil
        made.isTaskSelected = true
        made._testEnterAnswerMode(.supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: stepID, taskID: taskID, role: .softwareEngineer, roleDefinition: nil,
            question: "Which approach?", messageContent: nil, thinking: nil, isChatMode: false)))
        controller = made
        controller.formState.answerText = "the second one"

        await controller.submitAnswer()

        XCTAssertEqual(step(in: taskID)?.supervisorAnswer, "the second one")
        XCTAssertNil(step(in: taskID)?.supervisorInquiryAnswer,
                     "a plain answer says nothing about a form")
    }
}
