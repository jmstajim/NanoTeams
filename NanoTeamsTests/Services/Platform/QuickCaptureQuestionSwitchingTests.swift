import XCTest

@testable import NanoTeams

/// Switching between the questions a task has parked, from the Quick Capture panel.
///
/// This is the original complaint. A team task routinely parks two roles at once (CLAUDE.md
/// #45), and the panel showed `pending(in:).first` with no route to the rest — so the second
/// question was answerable only by answering the first. The chips are the route; what these
/// tests hold is that taking it does not cost the Supervisor the reply they were writing.
@MainActor
final class QuickCaptureQuestionSwitchingTests: XCTestCase {

    private var store: NTMSOrchestrator!
    private var controller: QuickCaptureController!
    private var workFolder: URL!

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-switch-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Fixture

    /// A task whose named roles are all parked on a question.
    private func addTask(_ title: String, waiting roles: [String]) async -> Int? {
        guard let taskID = await store.createTask(title: title, supervisorTask: "do") else {
            XCTFail("task creation failed")
            return nil
        }
        await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: task.runs.first?.teamID ?? "test_team")
            for id in roles {
                var step = StepExecution.make(for: TeamRoleDefinition(
                    id: id, name: id.uppercased(), prompt: "", toolIDs: [],
                    usePlanningPhase: false, dependencies: RoleDependencies()))
                step.id = id
                step.status = .needsSupervisorInput
                step.needsSupervisorInput = true
                step.supervisorQuestion = "\(id) asks?"
                run.steps.append(step)
            }
            task.runs.append(run)
        }
        return taskID
    }

    /// A wired controller sitting in answer mode on the active task's leading question.
    private func makeController() {
        let made = QuickCaptureController(formState: QuickCaptureFormState())
        made.store = store
        made.dictation = nil
        made.isTaskSelected = true
        made._testIsPanelVisible = true
        // The ordinary arrival: resolve, then apply the transition the refresh would apply.
        made.refreshPanelIfVisible()
        controller = made
    }

    /// The Product Manager and the Engineer both parked on one task.
    private func makeTwoWaitingRoles() async -> Int? {
        store = TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        guard let taskID = await addTask("T", waiting: ["pm", "eng"]) else { return nil }
        await store.switchTask(to: taskID)
        makeController()
        return taskID
    }

    private func step(_ id: String, in taskID: Int) -> StepExecution? {
        store.loadedTask(taskID)?.runs.last?.steps.first { $0.id == id }
    }

    // MARK: - The row

    func testBothWaitingQuestionsAreReachable() async {
        guard await makeTwoWaitingRoles() != nil else { return }
        XCTAssertEqual(controller.resolveMode().answerSession?.stepIDs, ["pm", "eng"])
        XCTAssertEqual(controller.formState.pendingAnswer?.stepID, "pm")
    }

    func testTappingAChipMovesThePanelToThatQuestion() async {
        guard await makeTwoWaitingRoles() != nil else { return }
        controller.selectPendingQuestion("eng")
        XCTAssertEqual(controller.resolveMode().answerSession?.selected.stepID, "eng")
        XCTAssertEqual(controller.formState.pendingAnswer?.stepID, "eng",
                       "the panel's destination follows the chip, not just its display")
    }

    /// RED: skip the hand-off on a chip tap → the half-typed reply to the Product Manager is
    /// still in the fields the send button now reads against the Engineer.
    func testAHalfTypedReplyIsParkedUnderTheQuestionItWasWrittenFor() async {
        guard let taskID = await makeTwoWaitingRoles() else { return }
        controller.formState.answerText = "scope it to the importer"

        controller.selectPendingQuestion("eng")

        XCTAssertEqual(controller.formState.answerText, "",
                       "the Engineer's box must be empty, not holding the PM's reply")
        let parked = controller.formState.answerDraftStore
            .peek(for: .role(TaskStepKey(taskID: taskID, stepID: "pm")))
        XCTAssertEqual(parked?.text, "scope it to the importer")
    }

    func testSwitchingBackHandsTheReplyBack() async {
        guard let taskID = await makeTwoWaitingRoles() else { return }
        controller.formState.answerText = "scope it to the importer"
        controller.selectPendingQuestion("eng")
        controller.formState.answerText = "debug"

        controller.selectPendingQuestion("pm")

        XCTAssertEqual(controller.formState.answerText, "scope it to the importer")
        XCTAssertNil(
            controller.formState.answerDraftStore
                .peek(for: .role(TaskStepKey(taskID: taskID, stepID: "pm"))),
            "take-and-return: the store must not hold what a composer is holding")
        XCTAssertEqual(
            controller.formState.answerDraftStore
                .peek(for: .role(TaskStepKey(taskID: taskID, stepID: "eng")))?.text,
            "debug")
    }

    /// A half-filled questionnaire is exactly as much of the Supervisor's work as a sentence,
    /// and it is the content a chip switch used to carry into the wrong form.
    func testAHalfFilledFormIsParkedWithTheQuestionItAnswers() async {
        guard let taskID = await makeTwoWaitingRoles() else { return }
        let inquiry = SupervisorInquiry(
            headline: "Scope?",
            questions: [SupervisorInquiryQuestion(
                id: "q1", prompt: "Which?", kind: .singleChoice,
                options: [SupervisorInquiryOption(id: "a", label: "A")])])
        controller.formState.answerInquiry = SupervisorInquiryDraft(
            inquiry: inquiry,
            answer: SupervisorInquiryAnswer(byQuestionID: ["q1": .init(selectedOptionIDs: ["a"])]))

        controller.selectPendingQuestion("eng")

        XCTAssertNil(controller.formState.answerInquiry)
        XCTAssertEqual(
            controller.formState.answerDraftStore
                .peek(for: .role(TaskStepKey(taskID: taskID, stepID: "pm")))?
                .inquiry?.answer.byQuestionID["q1"]?.selectedOptionIDs,
            ["a"])
    }

    func testSelectingTheQuestionAlreadyOnScreenMovesNothing() async {
        guard await makeTwoWaitingRoles() != nil else { return }
        controller.formState.answerText = "still writing"
        controller.selectPendingQuestion("pm")
        XCTAssertEqual(controller.formState.answerText, "still writing",
                       "a no-op tap must not park and re-take the reply in the box")
    }

    // MARK: - After a submit

    /// RED: dismiss on every submit → the second question is unreachable again the moment the
    /// first is answered, which is the whole defect the row was added for.
    func testAnsweringOneOfTwoMovesToTheOther() async {
        guard let taskID = await makeTwoWaitingRoles() else { return }
        controller.formState.answerText = "narrow"

        await controller.submitAnswer()

        XCTAssertNotNil(step("pm", in: taskID)?.supervisorAnswer, "precondition: the answer landed")
        XCTAssertTrue(controller._testIsInAnswerMode,
                      "the panel stays open while another question is still waiting")
        XCTAssertEqual(controller.formState.pendingAnswer?.stepID, "eng")
        XCTAssertEqual(
            controller.formState.aimedQuestion, TaskStepKey(taskID: taskID, stepID: "eng"))
    }

    /// RED: aim at the leading question instead of the one to the RIGHT → with three waiting
    /// roles, answering the middle one sends the Supervisor back to the question they
    /// deliberately stepped over, and the row never empties. Two questions cannot tell the two
    /// rules apart, which is why this case exists beside the pair above.
    func testTheNextQuestionIsTheOneToTheRightNotTheLeader() async {
        store = TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        guard let taskID = await addTask("T", waiting: ["pm", "eng", "qa"]) else { return }
        await store.switchTask(to: taskID)
        makeController()
        controller.selectPendingQuestion("eng")
        controller.formState.answerText = "middle"

        await controller.submitAnswer()

        XCTAssertEqual(controller.formState.pendingAnswer?.stepID, "qa")
    }

    func testAnsweringTheLastQuestionLeavesAnswerMode() async {
        guard let taskID = await makeTwoWaitingRoles() else { return }
        await store.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == "eng" })
            else { return }
            task.runs[runIndex].steps[stepIndex].needsSupervisorInput = false
            task.runs[runIndex].steps[stepIndex].status = .running
        }
        controller.refreshPanelIfVisible()
        controller.formState.answerText = "narrow"

        await controller.submitAnswer()

        XCTAssertFalse(controller._testIsInAnswerMode)
        XCTAssertNil(controller.formState.aimedQuestion)
    }

    // MARK: - The aim belongs to one task, and to one round

    /// RED: hold the pick as a bare step id → `StepExecution.id` IS the role id (invariant #5),
    /// so the same team's roles carry byte-identical ids on every task. A pick made on task A
    /// does not decay on task B, it MATCHES, and the panel opens aimed at a role the Supervisor
    /// never picked there.
    func testAPickMadeOnOneTaskDoesNotAimAnother() async {
        store = TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        guard let first = await addTask("A", waiting: ["pm", "eng"]),
              let second = await addTask("B", waiting: ["pm", "eng"])
        else { return }
        await store.switchTask(to: first)
        makeController()
        controller.selectPendingQuestion("eng")
        XCTAssertEqual(controller.formState.pendingAnswer?.stepID, "eng", "precondition")

        await store.switchTask(to: second)
        controller.refreshPanelIfVisible()

        XCTAssertEqual(
            controller.resolveMode().answerSession?.selected.stepID, "pm",
            "task B opens on its own leading question, not on the role picked for task A")
        XCTAssertEqual(controller.formState.pendingAnswer?.taskID, second)
    }

    /// RED: leave the pick untouched when it stops resolving → it lies dormant while the panel
    /// shows the leader, and resurrects the moment that role asks again, yanking the panel off
    /// whatever the Supervisor is typing into.
    func testAPickThatStoppedResolvingDoesNotResurrect() async {
        guard let taskID = await makeTwoWaitingRoles() else { return }
        controller.selectPendingQuestion("eng")

        // The Engineer's question is answered from somewhere else entirely.
        await store.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == "eng" })
            else { return }
            task.runs[runIndex].steps[stepIndex].needsSupervisorInput = false
            task.runs[runIndex].steps[stepIndex].status = .running
        }
        controller.refreshPanelIfVisible()
        XCTAssertEqual(controller.formState.pendingAnswer?.stepID, "pm", "precondition")

        // …and the Engineer asks again.
        await store.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == "eng" })
            else { return }
            task.runs[runIndex].steps[stepIndex].needsSupervisorInput = true
            task.runs[runIndex].steps[stepIndex].status = .needsSupervisorInput
        }
        controller.refreshPanelIfVisible()

        XCTAssertEqual(
            controller.formState.pendingAnswer?.stepID, "pm",
            "the panel stays where it is; a pick the user made two rounds ago is not a standing order")
    }

    /// RED: use the pre-await row unconditionally → an answer submitted for a task the panel
    /// has already left re-points it at THAT task's next question, and the send button then
    /// answers a task the Supervisor is not looking at.
    ///
    /// Pins the guard by the state it reads (`store.activeTaskID` and the session's own task),
    /// not by interleaving a switch inside the `await` — which no seam here allows.
    func testAnsweringATaskThePanelHasLeftDoesNotRePointIt() async {
        store = TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        guard let first = await addTask("A", waiting: ["pm", "eng"]),
              let second = await addTask("B", waiting: ["pm", "eng"])
        else { return }
        await store.switchTask(to: first)
        makeController()
        controller.formState.answerText = "for A"
        XCTAssertEqual(controller.formState.pendingAnswer?.taskID, first, "precondition")

        // The panel is re-aimed at B without the answer mode being torn down — the shape a
        // task switch racing an in-flight submit leaves behind.
        await store.switchTask(to: second)

        await controller.submitAnswer()

        XCTAssertNil(
            controller.formState.pendingAnswer,
            """
            the submit must not aim the panel at all: the row it was measured against \
            describes a task the Supervisor has left, and re-pointing from it lands on \
            THAT task's next question under a send button reading the other one
            """)
    }

    /// RED: use the pre-await row unconditionally → an answer submitted while the panel is off
    /// screen re-arms it on the next question, so the panel comes back showing a question the
    /// Supervisor never opened it for.
    ///
    /// Off screen but still in answer mode is a real state, not a contrivance:
    /// `handlePanelHidden()` records an AppKit `orderOut` the controller did not initiate and
    /// clears `isPanelVisible` alone. (The dismissal route proper cannot be staged from a test
    /// at all — `dismissPanel` clears `pendingAnswer`, which `submitAnswer` guards on at its
    /// first line, so the race can only be entered from inside the `await`.)
    func testAnAnswerDoesNotReArmAPanelThatIsOffScreen() async {
        guard await makeTwoWaitingRoles() != nil else { return }
        controller.formState.answerText = "narrow"
        controller.handlePanelHidden()
        XCTAssertTrue(controller._testIsInAnswerMode, "precondition: answer mode survives the hide")

        await controller.submitAnswer()

        XCTAssertNil(controller.formState.pendingAnswer,
                     "a panel nobody is looking at must not be aimed at the next question")
    }

    /// The reply parked under the arriving question comes back with it, so answering one
    /// question hands the Supervisor the draft they had started for the next.
    func testTheNextQuestionArrivesWithWhateverWasParkedForIt() async {
        guard let taskID = await makeTwoWaitingRoles() else { return }
        controller.formState.answerDraftStore.save(
            AnswerDraft(text: "release, please"),
            for: .role(TaskStepKey(taskID: taskID, stepID: "eng")))
        controller.formState.answerText = "narrow"

        await controller.submitAnswer()

        XCTAssertEqual(controller.formState.answerText, "release, please")
    }
}
