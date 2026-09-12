import XCTest

@testable import NanoTeams

/// The panel answers a SESSION, not a question.
///
/// Until 2026-09-10 Quick Capture carried one payload, taken as `pending(in:).first`. With
/// parallel roles (CLAUDE.md #45) that is not a summary of the state — it is a choice made on
/// the Supervisor's behalf about which question they are allowed to reach, and the others were
/// not merely unshown: from the panel there was no route to them at all.
@MainActor
final class SupervisorAnswerSessionTests: XCTestCase {

    private typealias P = QuickCapturePresentationPolicy

    // MARK: - Fixtures

    private func payload(_ stepID: String, taskID: Int = 7, question: String = "?")
        -> SupervisorAnswerPayload
    {
        SupervisorAnswerPayload(
            stepID: stepID, taskID: taskID, role: .softwareEngineer, roleDefinition: nil,
            question: question, messageContent: nil, thinking: nil, isChatMode: false)
    }

    private func team() -> Team {
        let roles = ["pm", "eng"].map {
            TeamRoleDefinition(
                id: $0, name: $0.uppercased(), prompt: "", toolIDs: [],
                usePlanningPhase: false, dependencies: RoleDependencies())
        }
        return Team(
            id: "t1", name: "Test Team", roles: roles, artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout())
    }

    /// Two roles parked at once — the ordinary shape of a team task, and the one the panel
    /// could not represent.
    private func taskWithTwoWaitingRoles() -> NTMSTask {
        var task = NTMSTask(id: 7, title: "T", supervisorTask: "G")
        var run = Run(id: 0, teamID: "t1")
        for (id, question) in [("pm", "Which scope?"), ("eng", "Which scheme?")] {
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: id, name: id.uppercased(), prompt: "", toolIDs: [],
                usePlanningPhase: false, dependencies: RoleDependencies()))
            step.id = id
            step.status = .needsSupervisorInput
            step.needsSupervisorInput = true
            step.supervisorQuestion = question
            run.steps.append(step)
        }
        task.runs.append(run)
        return task
    }

    // MARK: - The session itself

    func testASessionOfNoQuestionsIsNotAState() {
        XCTAssertNil(SupervisorAnswerSession(questions: [], selectedStepID: nil),
                     "an empty session would make every reader guard an index instead")
    }

    func testWithNoPickTheLeadingQuestionIsSelected() {
        let session = SupervisorAnswerSession(
            questions: [payload("a"), payload("b")], selectedStepID: nil)
        XCTAssertEqual(session?.selected.stepID, "a")
        XCTAssertEqual(session?.stepIDs, ["a", "b"])
    }

    func testAPickIsHonouredWhileItIsStillWaiting() {
        let session = SupervisorAnswerSession(
            questions: [payload("a"), payload("b")], selectedStepID: "b")
        XCTAssertEqual(session?.selected.stepID, "b")
    }

    /// The pick decays rather than pinning the panel: the question was answered from the
    /// docked composer or the Watchtower while the panel was aimed at it.
    func testAPickThatStoppedWaitingDecaysToTheLeadingQuestion() {
        let session = SupervisorAnswerSession(
            questions: [payload("a"), payload("b")], selectedStepID: "answered_elsewhere")
        XCTAssertEqual(session?.selected.stepID, "a")
    }

    func testASingleQuestionIsASessionOfOne() {
        let session = SupervisorAnswerSession(single: payload("solo"))
        XCTAssertEqual(session.stepIDs, ["solo"])
        XCTAssertEqual(session.selected.stepID, "solo")
    }

    // MARK: - Aim

    func testAimingRePointsAnAnswerMode() {
        let mode = QuickCaptureMode.supervisorAnswer(
            session: SupervisorAnswerSession(questions: [payload("a"), payload("b")],
                                             selectedStepID: nil)!)
        XCTAssertEqual(
            P.aiming(mode, at: TaskStepKey(taskID: 7, stepID: "b")).answerSession?.selected.stepID,
            "b")
    }

    /// The aim carries its TASK, and one naming another task is ignored outright.
    ///
    /// RED: key the preference on a bare step id → `StepExecution.id` IS the role id
    /// (invariant #5), so two tasks on one team carry byte-identical ones. A pick made on task
    /// A does not decay on task B, it MATCHES, and the panel opens aimed at a role the
    /// Supervisor never picked there.
    func testAnAimBelongingToAnotherTaskIsIgnoredRatherThanMatched() {
        let mode = QuickCaptureMode.supervisorAnswer(
            session: SupervisorAnswerSession(questions: [payload("a"), payload("b")],
                                             selectedStepID: nil)!)
        XCTAssertEqual(
            P.aiming(mode, at: TaskStepKey(taskID: 99, stepID: "b")).answerSession?.selected.stepID,
            "a",
            "the same role id on another task must not select this task's question")
    }

    func testAimingLeavesEveryOtherModeAlone() {
        for mode in [QuickCaptureMode.overlay,
                     .taskWorking(roleName: "R", isChatMode: false),
                     .taskInitializing(isChatMode: true)] {
            XCTAssertEqual(
                P.renderIdentity(of: P.aiming(mode, at: TaskStepKey(taskID: 7, stepID: "b"))),
                P.renderIdentity(of: mode),
                "aiming is answer-mode business and must not disturb the other surfaces")
        }
    }

    /// The composer and the panel resolve the same stale pick the same way, because they run
    /// the same rule — `aiming` delegates to the session's init, which delegates to
    /// `SupervisorAnswerFocus.resolve`.
    func testAimingAtAQuestionThatIsGoneFallsBackRatherThanFailing() {
        let mode = QuickCaptureMode.supervisorAnswer(
            session: SupervisorAnswerSession(questions: [payload("a")], selectedStepID: nil)!)
        XCTAssertEqual(
            P.aiming(mode, at: TaskStepKey(taskID: 7, stepID: "vanished"))
                .answerSession?.selected.stepID,
            "a")
    }

    // MARK: - Render identity

    /// RED: fold only the selected payload → tapping a chip changes nothing the panel compares,
    /// the hosting view is left alone, and the question the user asked for never appears.
    func testTheSelectionIsFoldedIntoTheRebuildDecision() {
        let questions = [payload("a"), payload("b")]
        let first = SupervisorAnswerSession(questions: questions, selectedStepID: "a")!
        let second = SupervisorAnswerSession(questions: questions, selectedStepID: "b")!
        XCTAssertNotEqual(
            P.renderIdentity(of: .supervisorAnswer(session: first)),
            P.renderIdentity(of: .supervisorAnswer(session: second)))
    }

    /// RED: fold only the selection → a second role parking a question adds a chip the panel
    /// never draws, so the switcher silently lags the state it is switching between.
    func testTheROWIsFoldedIntoTheRebuildDecision() {
        let alone = SupervisorAnswerSession(questions: [payload("a")], selectedStepID: "a")!
        let joined = SupervisorAnswerSession(
            questions: [payload("a"), payload("b")], selectedStepID: "a")!
        XCTAssertNotEqual(
            P.renderIdentity(of: .supervisorAnswer(session: alone)),
            P.renderIdentity(of: .supervisorAnswer(session: joined)),
            "the same selected question in a longer row is a different panel")
    }

    /// The ids are joined inside one unit-separated field, so a row of two must not be able to
    /// wear the identity of a differently-split row of one.
    func testTwoRowsCannotSmearIntoOneIdentity() {
        let split = SupervisorAnswerSession(
            questions: [payload("a"), payload("b")], selectedStepID: "a")!
        let fused = SupervisorAnswerSession(questions: [payload("ab")], selectedStepID: "ab")!
        XCTAssertNotEqual(
            P.renderIdentity(of: .supervisorAnswer(session: split)),
            P.renderIdentity(of: .supervisorAnswer(session: fused)))
    }

    // MARK: - The coordinator

    func testEveryWaitingQuestionReachesTheSession() {
        let mode = DefaultQuickCaptureModeCoordinator().resolveMode(
            isTaskSelected: true, activeTask: taskWithTwoWaitingRoles(), engineState: nil,
            isInitializingRun: false, activeTeam: team(), forceNewTaskMode: false)
        guard let session = mode.answerSession else {
            return XCTFail("two parked roles must resolve to answer mode")
        }
        XCTAssertEqual(session.stepIDs, ["pm", "eng"],
                       "the inbox's order — oldest ask first — is the chip row's order")
        XCTAssertEqual(session.selected.stepID, "pm")
        XCTAssertEqual(session.questions.map(\.question), ["Which scope?", "Which scheme?"])
    }

    /// Each question keeps its OWN role definition. One payload for the leading role with the
    /// rest borrowing it would put the wrong name and the wrong tint on every other chip.
    func testEachQuestionCarriesItsOwnRole() {
        let mode = DefaultQuickCaptureModeCoordinator().resolveMode(
            isTaskSelected: true, activeTask: taskWithTwoWaitingRoles(), engineState: nil,
            isInitializingRun: false, activeTeam: team(), forceNewTaskMode: false)
        XCTAssertEqual(mode.answerSession?.questions.map { $0.roleDefinition?.id }, ["pm", "eng"])
    }
}
