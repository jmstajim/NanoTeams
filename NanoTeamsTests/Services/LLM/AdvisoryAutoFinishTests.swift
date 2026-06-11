import XCTest

@testable import NanoTeams

/// Regression guards for the advisory-role auto-finish path in
/// `LLMExecutionService.handleNoToolCalls`.
///
/// Symptom this fix addresses: a single advisory chat-mode role (e.g. Personal
/// Assistant, Coding Assistant) under autonomous supervisor mode completes its task,
/// calls `ask_supervisor` to confirm, gets a text auto-answer, then loops forever
/// emitting plain-text confirmations — `handleNoToolCalls` keeps re-pinging it because
/// advisory roles have no `producesArtifacts` to self-terminate on.
///
/// Fix: in `handleNoToolCalls`, after 3 consecutive no-tool-call turns by an advisory
/// role under `supervisorMode == .autonomous`, write step.done + role.done atomically
/// and return `.completed`. The atomic role.done write is essential — bypassing
/// `handleRoleCompleted` avoids `acceptanceMode == .finalOnly` routing the role to
/// `.needsAcceptance`, which would otherwise deadlock the engine into `.failed` in
/// chat mode (the engine has no `.needsAcceptance` exit path for chat teams).
/// Manual mode is untouched — the gate explicitly checks `team.settings.supervisorMode`.
@MainActor
final class AdvisoryAutoFinishTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)

        // step.id == role.id mirrors production (`StepExecution.make(for:)` uses roleID
        // as stepID); `effectiveRoleID` returns `step.id`. Tests asserting
        // roleStatuses[role.id] depend on this alignment.
        let step = StepExecution(id: "coding_assistant", role: .softwareEngineer, title: "Chat", status: .running)
        stepID = step.id
        let run = Run(id: 0, steps: [step])
        task = NTMSTask(id: 0, title: "Test", supervisorTask: "do work", runs: [run])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() {
        mockDelegate = nil
        service = nil
        task = nil
        stepID = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Advisory role: has input dependency, no output artifacts. Mirrors `codingAssistant`
    /// and `assistant` template shape (`completionType == .advisory`).
    private func makeAdvisoryRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "coding_assistant",
            name: "Coding Assistant",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"],
                producesArtifacts: []
            ),
            isSystemRole: true,
            systemRoleID: "codingAssistant"
        )
    }

    /// Producing role for the negative test — must NOT auto-finish even after many
    /// no-tool-call turns under autonomous mode (the artifact-missing nudge owns this case).
    private func makeProducingRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "swe", name: "SWE", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Engineering Notes"]
            ),
            isSystemRole: true,
            systemRoleID: "softwareEngineer"
        )
    }

    /// Attaches a generated team to `task` with the given supervisor mode. `resolveTeam`
    /// prefers `task.generatedTeam`, so this is the lightest way to drive the gate
    /// without populating `delegate.snapshot.workFolder`.
    private func attachTeam(supervisorMode: SupervisorMode, role: TeamRoleDefinition) {
        var settings = TeamSettings()
        settings.supervisorMode = supervisorMode
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
        let team = Team(
            id: "t", name: "T", roles: [supervisor, role], artifacts: [],
            settings: settings, graphLayout: TeamGraphLayout()
        )
        mockDelegate.taskToMutate?.adoptGeneratedTeam(team)
    }

    // MARK: - Auto-Finish (positive path)

    func testAdvisoryRole_autonomousMode_finishesAfter3ConsecutiveNoToolTurns() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        // First 2 turns: counter increments, generic nudge fires, .continueLoop.
        for i in 1...2 {
            var messages: [ChatMessage] = []
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID,
                assistantContent: "All tasks completed.",
                sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!,
                roleDefinition: role,
                conversationMessages: &messages
            )
            guard case .continueLoop = stop else {
                XCTFail("Turn \(i): expected .continueLoop, got \(stop)")
                return
            }
            XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), i,
                           "Turn \(i): counter should equal turn number")
        }

        // 3rd turn: counter hits threshold, returns .completed.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "All tasks completed.",
            sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!,
            roleDefinition: role,
            conversationMessages: &messages
        )
        guard case .completed = stop else {
            XCTFail("3rd turn: expected .completed (auto-finish), got \(stop)")
            return
        }
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 0,
                       "Counter must reset after auto-finish so a re-entry starts clean")
    }

    // MARK: - Negative gates

    func testAdvisoryRole_manualMode_doesNotAutoFinish() async {
        // Default supervisorMode is .manual — interactive UI default. Even after 10
        // no-tool-call turns the role keeps getting nudged, never auto-finishes.
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .manual, role: role)

        for _ in 1...10 {
            var messages: [ChatMessage] = []
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID,
                assistantContent: "Anything else?",
                sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!,
                roleDefinition: role,
                conversationMessages: &messages
            )
            guard case .continueLoop = stop else {
                XCTFail("Manual mode must never auto-finish, got \(stop)")
                return
            }
        }
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 0,
                       "Counter should never increment in manual mode")
    }

    func testProducingRole_autonomousMode_doesNotAutoFinish() async {
        // Producing roles already have a self-terminate path (artifact completeness).
        // The advisory branch must not steal them — they should still get the
        // "Missing deliverables" nudge.
        let role = makeProducingRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        for _ in 1...5 {
            var messages: [ChatMessage] = []
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID,
                assistantContent: "Working on it.",
                sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!,
                roleDefinition: role,
                conversationMessages: &messages
            )
            guard case .continueLoop = stop else {
                XCTFail("Producing role must never auto-finish, got \(stop)")
                return
            }
            // Last message should be the producing-role artifact nudge.
            XCTAssertTrue(
                (messages.last?.content ?? "").contains("Missing deliverables"),
                "Producing role should get artifact nudge, not advisory finish"
            )
        }
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 0,
                       "Producing role should never bump the advisory counter")
    }

    // MARK: - Counter reset on tool-call activity

    func testAdvisoryCounter_resetByToolCallExecution_avoidsPrematureFinish() async {
        // Real run pattern: model alternates between tool-driven turns and brief
        // confirmations. After an inter-turn tool call, the counter must reset so
        // a single subsequent text-only turn doesn't trigger finish on what would
        // otherwise be the 3rd consecutive no-tool turn cumulatively.
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        // Pre-arm with 2 no-tool turns (one short of threshold).
        for _ in 1...2 {
            var messages: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "OK.", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: role,
                conversationMessages: &messages
            )
        }
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 2)

        // Simulate tool call execution between turns.
        service._testResetAdvisoryNoToolCounter(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 0)

        // Post-reset turn → counter = 1 again, NOT 3-and-finish.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "Continuing.", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: role,
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("Post-reset turn must continue loop, got \(stop)")
            return
        }
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 1,
                       "Counter should restart at 1 after the reset")
    }

    // MARK: - Critical: atomic role.done write (avoids engine deadlock)

    /// Critical regression: the auto-finish branch MUST set `roleStatuses[roleID] = .done`
    /// atomically with `step.status = .done`. If only step.done is written, the engine's
    /// `handleRoleCompleted` would route through `AcceptanceService.shouldRequestAcceptance`,
    /// which (for default `.finalOnly` + `isLastRole == true`) routes the role to
    /// `.needsAcceptance` — a state the engine's chat-mode `readyRoleIDs.isEmpty` arm
    /// doesn't exit cleanly, deadlocking into `.failed`. Setting role.done in the same
    /// `mutateTask` closure short-circuits `handleRoleCompleted`'s `roleStatuses[roleID]
    /// == .working` guard, leaving role.done as written.
    func testAutoFinish_writesRoleDoneAtomically_avoidingAcceptanceDeadlock() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)
        // Pre-condition: role status is `.working` (engine sets this when starting the step).
        mockDelegate.taskToMutate?.runs[0].roleStatuses[role.id] = .working

        // Drive 3 consecutive no-tool turns to trip the auto-finish.
        for _ in 1...3 {
            var messages: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "All set.", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: role,
                conversationMessages: &messages
            )
        }

        // Both step and role must be .done. Step.done alone is insufficient — see
        // class doc-comment for why.
        let step = mockDelegate.taskToMutate?.runs[0].steps[0]
        XCTAssertEqual(step?.status, .done, "Step must be .done after auto-finish")
        XCTAssertNotNil(step?.completedAt, "Step.completedAt must be set so isLastRoleToComplete works")
        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs[0].roleStatuses[role.id], .done,
            "Role must be .done — NOT .needsAcceptance (would deadlock chat-mode engine)"
        )
    }

    // MARK: - Revision-mode gate

    /// The auto-finish branch is gated on `!isStepInRevision(stepID:)`. During revision,
    /// the Supervisor is already driving the model via the revision flow — auto-finishing
    /// would short-circuit explicit feedback iteration. The counter must NOT increment
    /// during revision either (otherwise a single post-revision no-tool turn could trip
    /// count==3-and-finish).
    func testRevisionMode_skipsAutoFinish_andDoesNotIncrementCounter() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)
        // Activate revision on the step.
        mockDelegate.taskToMutate?.runs[0].steps[0].revisionComment = "Please redo X"

        // Drive 5 consecutive no-tool turns — would be way past threshold without the gate.
        for i in 1...5 {
            var messages: [ChatMessage] = []
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "OK.", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: role,
                conversationMessages: &messages
            )
            guard case .continueLoop = stop else {
                XCTFail("Turn \(i) under revision must continue loop (not auto-finish), got \(stop)")
                return
            }
        }
        XCTAssertEqual(
            service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 0,
            "Counter must not increment during revision — guard fails before increment"
        )
        // Step status is unchanged from initial `.running`.
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].steps[0].status, .running)
    }

    // MARK: - C4 regression: mutateTask closure short-circuit must NOT announce completion

    /// CLAUDE.md §7: `mutateTask` returning `true` only proves persistence.
    /// The closure's `firstIndex(where: stepID)` guard can short-circuit when
    /// the step has been removed from the task (e.g. between revision flow
    /// and step lookup, or during a restart race) — in that case `mutateTask`
    /// still returns `true` (it wrote back an unchanged task). Pre-fix this
    /// case incorrectly posted an "Advisory role auto-finished" message and
    /// returned `.completed`, lying about state that didn't change.
    /// Post-fix: didApply captured-flag detects the short-circuit and we
    /// return `nil` without announcing.
    func testAttemptAdvisoryAutoFinish_mutateTaskShortCircuit_doesNotAnnounceCompletion() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        // Drive 2 turns — counter at 2, just under threshold.
        for _ in 1...2 {
            var messages: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "OK.", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: role,
                conversationMessages: &messages
            )
        }
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 2)

        // Simulate a race: step is removed from the task between the previous
        // turn's mutation and this turn's lookup. mutateTask will still return
        // true (it persists the modified-but-stepless task) but the closure's
        // internal `firstIndex(where: stepID)` guard short-circuits.
        mockDelegate.taskToMutate?.runs[0].steps = []

        // 3rd turn: threshold trips, mutateTask runs, closure short-circuits.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "OK.", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: role,
            conversationMessages: &messages
        )
        guard case .continueLoop = stop else {
            XCTFail("Closure short-circuit must NOT report .completed (was \(stop)) — that would lie about state")
            return
        }
        // Counter must NOT be reset (would mask the threshold breach on retry).
        XCTAssertEqual(
            service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 3,
            "Counter must stay at 3 (not reset) so the next iteration can re-attempt"
        )
        // No "auto-finished" assistant message must have been appended to the
        // step (mockDelegate would have been re-mutated). Empty steps array
        // proves nothing changed.
        XCTAssertTrue(
            mockDelegate.taskToMutate?.runs[0].steps.isEmpty ?? false,
            "Steps array must remain empty — the auto-finish branch must not have re-added the step"
        )
    }

    // MARK: - I6 regression: bypass is gated to chat-mode teams only

    /// I6: the direct-write bypass for `step.status = .done` + `roleStatuses[id] = .done`
    /// is only safe in chat-mode teams (whose engine has no `.needsAcceptance`
    /// exit path). Non-chat teams MUST route through `handleRoleCompleted`
    /// so the acceptance/checkpointing plumbing fires.
    func testAdvisoryAutoFinish_nonChatModeTeam_doesNotBypassHandleRoleCompleted() async {
        let role = makeAdvisoryRole()
        // Build a team with a Supervisor that REQUIRES an artifact — that
        // makes `team.supervisorRequiredArtifacts` non-empty, and therefore
        // `team.isChatMode == false`.
        var settings = TeamSettings()
        settings.supervisorMode = .autonomous
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Final Deliverable"],
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
        let team = Team(
            id: "t", name: "T", roles: [supervisor, role], artifacts: [],
            settings: settings, graphLayout: TeamGraphLayout()
        )
        mockDelegate.taskToMutate?.adoptGeneratedTeam(team)
        XCTAssertFalse(team.isChatMode, "Sanity: team should be non-chat with a supervisor-required artifact")

        for i in 1...5 {
            var messages: [ChatMessage] = []
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "OK.", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: role,
                conversationMessages: &messages
            )
            guard case .continueLoop = stop else {
                XCTFail("Turn \(i): non-chat-mode advisory MUST NOT auto-finish via bypass, got \(stop)")
                return
            }
        }
        // Step must remain `.running` — the bypass path must not have written
        // `.done` directly. (handleRoleCompleted would also not fire here
        // because attemptAdvisoryAutoFinish returns nil before triggering it,
        // but the engine's normal artifact-completeness path would handle
        // the role's lifecycle in the real runtime.)
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].steps[0].status, .running)
    }

    // MARK: - I10 regression: ask_supervisor-only turn counter treatment

    /// I10: `ask_supervisor` is auto-answered under `.autonomous` supervisor
    /// mode, so a turn whose only tool call is `ask_supervisor` is non-
    /// productive — the model can ping itself in a loop forever. The
    /// counter-treatment branch in `runOneLLMToolIteration` calls
    /// `attemptAdvisoryAutoFinish` (= increment) for these turns, NOT the
    /// reset path. We exercise the increment via the `_testIncrementAdvisoryNoToolCounter`
    /// helper since `_testHandleNoToolCalls` doesn't drive the tool-call branch.
    func testAdvisoryCounter_askSupervisorOnlyTurn_incrementsLikeNoToolTurn() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        // Two `ask_supervisor`-only turns: each should advance the counter
        // via the same `attemptAdvisoryAutoFinish` path that no-tool-call turns
        // use. Drive via the public auto-finish helper directly.
        for i in 1...2 {
            let stop = await service.attemptAdvisoryAutoFinish(stepID: stepID, taskID: task.id, roleDefinition: role)
            XCTAssertNil(stop, "Below threshold — must continue, got \(String(describing: stop))")
            XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), i,
                           "Each ask_supervisor-only turn must increment the counter")
        }

        // 3rd time hits threshold — fires auto-finish.
        let final = await service.attemptAdvisoryAutoFinish(stepID: stepID, taskID: task.id, roleDefinition: role)
        if case .completed? = final { /* ok */ } else {
            XCTFail("Threshold should trip on 3rd consecutive ask_supervisor-only turn, got \(String(describing: final))")
        }
    }

    /// I10 inverse: a turn with `ask_supervisor` AND a real tool resets the
    /// counter — the real tool is productive activity. Validates the
    /// `else` branch of `isAskSupervisorOnly` in the tool-call path.
    func testAdvisoryCounter_mixedTurnWithRealTool_resetsViaPublicHelper() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        // Pre-arm counter to 2.
        for _ in 1...2 {
            _ = await service.attemptAdvisoryAutoFinish(stepID: stepID, taskID: task.id, roleDefinition: role)
        }
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 2)

        // Simulate a productive (mixed) turn — this is what runOneLLMToolIteration
        // does in the !isAskSupervisorOnly branch:
        //     executionStates[stepID]?.consecutiveAdvisoryNoToolTurns = 0
        // Validate via the test helper that exposes that reset.
        service._testResetAdvisoryNoToolCounter(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 0,
                       "Mixed turn (ask_supervisor + any real tool) must reset the counter")
    }

    // MARK: - Defensive: missing executionStates entry

    /// Silent-failure regression: pre-fix, `executionStates[stepID]?.x = …` on a missing
    /// entry was a no-op with `?? 0` reading 0 every time → counter stuck at 1 across
    /// every call → auto-finish never fires. Post-fix, the gate also checks
    /// `executionStates[stepID] != nil`, so a missing entry results in `.continueLoop`
    /// without bumping anything. State corruption surfaces as the existing nudge loop
    /// (loud) rather than silent disablement of the safety cap.
    func testMissingExecutionStateEntry_doesNotIncrementOrFinish() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)
        // Tear down the state entry that setUp created.
        service.clearRunningTask(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), -1,
                       "Sentinel: state entry is gone")

        for i in 1...10 {
            var messages: [ChatMessage] = []
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "Done.", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: role,
                conversationMessages: &messages
            )
            guard case .continueLoop = stop else {
                XCTFail("Turn \(i) without state entry must continue loop, got \(stop)")
                return
            }
        }
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), -1,
                       "Counter helper still returns sentinel — no entry was magicked into existence")
    }

    // MARK: - Cleanup

    func testAdvisoryCounter_clearedOnStateCleanup() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "Hi.", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: role,
            conversationMessages: &messages
        )
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), 1)

        // clearRunningTask removes the state entry entirely; the next read returns -1.
        service.clearRunningTask(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service._testAdvisoryNoToolCounter(stepID: stepID, taskID: task.id), -1,
                       "After cleanup, state entry is removed (counter helper returns -1)")
    }

    // MARK: - finishStepGraceful (requestFinish / loop-recovery terminal)

    /// `finishStepGraceful` (the legacy `requestFinish` / `finishRequested` path).
    /// For a chat-mode advisory step it must finish directly as `.done` (step + role),
    /// the same terminal state `attemptAdvisoryAutoFinish` produces — NOT
    /// `.needsAcceptance`, which deadlocks the engine in chat mode.
    func testFinishStepGraceful_chatModeAdvisory_finishesStepAndRoleAsDone() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        await service.finishStepGraceful(stepID: stepID, taskID: task.id)

        let run = mockDelegate.taskToMutate?.runs.last
        XCTAssertEqual(run?.steps.first?.status, .done,
                       "chat-mode graceful finish must complete the step as .done")
        XCTAssertEqual(run?.roleStatuses["coding_assistant"], .done,
                       "role must be .done so the engine's chat-mode arm reaches .done")
    }

    // MARK: - wait_for_events (idle park)
    //
    // Coverage note: the park chain is pinned piecewise — routing predicate
    // (`testWaitForEvents_isCollaborationDeferred`), dispatch→flag
    // (`CollaborationToolCallErrorRenderingTests.testAppendCollaborationResult_waitForEvents_armsParkRequested`),
    // handler→flag (below), and the park action itself
    // (`testParkStepForEvents_parksStepWithIdleQuestionAndSession`). The remaining
    // link — the loop-top `parkForEventsRequested` consumption inside `runStep`'s
    // while loop — would need a full tool-loop integration harness (scripted
    // client + registry + runtime); the existing `ScriptedLLMClient` infra stops
    // at `performStreamingCall`, so that link stays unpinned by deliberate
    // decision (mirrors the legacy `finishRequested` loop-top arm, also unpinned).

    /// `handleWaitForEvents` sets the step's `parkForEventsRequested` flag (consumed
    /// at the next tool-loop boundary, which parks the step at `.needsSupervisorInput`
    /// so a human message continues the conversation) and returns a non-error idle
    /// envelope. It must NOT arm `finishRequested` — that path completes the step,
    /// closing the conversation for good.
    func testHandleWaitForEvents_setsParkRequested_returnsIdle() async {
        let response = await service.handleWaitForEvents(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service.executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?.parkForEventsRequested, true,
                       "wait_for_events must arm the idle-park flag")
        XCTAssertEqual(service.executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?.finishRequested, false,
                       "wait_for_events must not complete the step — it parks it")
        XCTAssertTrue(response.contains("idle"), "envelope should report the idle status")
    }

    /// `parkStepForEvents` (the loop-top consumer of `parkForEventsRequested`) parks
    /// the step at `.needsSupervisorInput` with the idle-park question and preserves
    /// the live session id — the properties that let a human answer continue the
    /// SAME conversation via stateful continuation instead of a fresh pass.
    func testParkStepForEvents_parksStepWithIdleQuestionAndSession() async {
        await service.parkStepForEvents(stepID: stepID, taskID: task.id, sessionID: "resp_42")

        let step = mockDelegate.taskToMutate?.runs.last?.steps.first
        XCTAssertEqual(step?.status, .needsSupervisorInput,
                       "park must transition the step, not complete it")
        XCTAssertEqual(step?.needsSupervisorInput, true)
        XCTAssertEqual(step?.supervisorQuestion, AutovisorConstants.idleParkQuestion,
                       "the idle-park question is what the composer renders")
        XCTAssertEqual(step?.llmSessionID, "resp_42",
                       "park must preserve the session so the chat continues statefully")
    }

    /// Write↔read round-trip: a park landed by the REAL write path (including its
    /// question trimming) must satisfy the sidebar's idle-park predicate. Pins the
    /// cross-file coupling directly — if `parkStepForEvents`/`setNeedsSupervisorInput`
    /// ever alter the persisted text (or the predicate's matching changes), this
    /// fails even though both sides' own unit tests still pass against themselves.
    func testParkStepForEvents_resultSatisfiesIdleParkPredicate() async {
        await service.parkStepForEvents(stepID: stepID, taskID: task.id, sessionID: "resp_42")

        XCTAssertTrue(NTMSOrchestrator.taskHasIdleParkStep(mockDelegate.taskToMutate),
                      "a genuine park must be recognized as idle by the sidebar predicate")
    }

    /// Corner: a pass that never established a session (every call fell back to
    /// stateless) parks with `sessionID: nil` — the park must still land; the
    /// continuation then rebuilds statelessly instead of via `previous_response_id`.
    func testParkStepForEvents_nilSession_stillParks() async {
        await service.parkStepForEvents(stepID: stepID, taskID: task.id, sessionID: nil)

        let step = mockDelegate.taskToMutate?.runs.last?.steps.first
        XCTAssertEqual(step?.status, .needsSupervisorInput)
        XCTAssertNil(step?.llmSessionID,
                     "stateless park stores no session — continuation rebuilds the conversation")
        XCTAssertEqual(step?.supervisorQuestion, AutovisorConstants.idleParkQuestion)
    }

    /// Corner: the step vanished from the LATEST run between the flag check and the
    /// park (`restartRole`/recurrence appended a fresh run mid-flight). The
    /// `setNeedsSupervisorInput` closure short-circuits (`persisted == false`), and
    /// `completeStepFailure` hits the same guards — the banner is the ONLY signal,
    /// so it must fire independently (review fix A3).
    func testParkStepForEvents_stepMissingFromLatestRun_surfacesBanner() async {
        // Replace the task's runs with a run that does NOT contain `stepID`.
        let stranger = StepExecution(id: "someone_else", role: .softwareEngineer, title: "Other")
        mockDelegate.taskToMutate?.runs = [Run(id: 1, steps: [stranger])]

        await service.parkStepForEvents(stepID: stepID, taskID: task.id, sessionID: "resp_42")

        XCTAssertTrue(
            mockDelegate.lastErrorMessages.contains { $0.contains("failed to park") },
            "A short-circuited park must surface a banner — completeStepFailure no-ops on the same guards"
        )
        let strangerStep = mockDelegate.taskToMutate?.runs.last?.steps.first
        XCTAssertEqual(strangerStep?.status, .pending,
                       "The unrelated step in the latest run must not be touched")
    }

    /// Corner: a manager step that was auto-answered earlier and parks AGAIN in the
    /// same step must not leak the stale `supervisorAnswerWasAuto` onto the new
    /// question — `setNeedsSupervisorInput` resets the flag alongside the answer,
    /// so a subsequent HUMAN reply renders the checkmark, not the badge.
    func testRePark_afterAutoAnswer_resetsWasAutoFlag() async {
        await service.recordAutoSupervisorAnswer(
            stepID: stepID, taskID: task.id, question: "Q1?", answer: "auto A1")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs.last?.steps.first?.supervisorAnswerWasAuto,
                       true, "precondition: the auto answer stamped the flag")

        await service.parkStepForEvents(stepID: stepID, taskID: task.id, sessionID: "resp_43")

        let step = mockDelegate.taskToMutate?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswerWasAuto, false,
                       "A fresh question must clear the stale auto attribution")
        XCTAssertNil(step?.supervisorAnswer, "Stale answer cleared with it")
    }

    /// Corner: `wait_for_events` lands after the execution state was torn down
    /// (pause/stop cancelled the loop). The handler must return an ERROR envelope —
    /// a success envelope would claim a park that was never recorded (review fix A4).
    func testHandleWaitForEvents_missingExecutionState_returnsErrorEnvelope() async {
        service.clearRunningTask(stepID: stepID, taskID: task.id)  // removes the executionStates entry

        let response = await service.handleWaitForEvents(stepID: stepID, taskID: task.id)

        XCTAssertTrue(response.contains("Step is no longer running"),
                      "The envelope must name the real condition")
        XCTAssertTrue(response.contains("\"ok\":false"),
                      "Must be an error envelope, not a fake-success idle ack")
        XCTAssertFalse(service._testParkForEventsRequested(stepID: stepID, taskID: task.id),
                       "No flag may be armed on a dead state entry")
    }

    /// `recordAutoSupervisorAnswer` (the in-loop autonomous auto-answer — the
    /// highest-volume automated answer path) must stamp `supervisorAnswerWasAuto`
    /// so the feed renders the "Auto-answered" badge. A regression here inverts
    /// the badge for every autonomous auto-answer — the mirror image of the
    /// human-mislabeling bug the flag was introduced to fix.
    func testRecordAutoSupervisorAnswer_setsWasAutoFlag() async {
        await service.recordAutoSupervisorAnswer(
            stepID: stepID, taskID: task.id, question: "Which DB?", answer: "SQLite.")

        let step = mockDelegate.taskToMutate?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "SQLite.")
        XCTAssertEqual(step?.supervisorAnswerWasAuto, true,
                       "Auto-answer service must mark the answer as automated")
        XCTAssertEqual(step?.needsSupervisorInput, false)
    }

    /// Routing regression: `wait_for_events` MUST be dispatched to the deferred
    /// `appendCollaborationResult` path (which calls `handleWaitForEvents` →
    /// `parkForEventsRequested`). When it was missing from the routing predicate it
    /// fell through to the regular path, the flag was never set, and the manager
    /// looped on `wait_for_events` until the loop detector tripped.
    func testWaitForEvents_isCollaborationDeferred() {
        XCTAssertTrue(LLMExecutionService.isCollaborationDeferredSignal(.waitForEvents),
                      "wait_for_events must route through appendCollaborationResult")
        // Sanity: signals with their own finalizers / the regular path are NOT here.
        XCTAssertFalse(LLMExecutionService.isCollaborationDeferredSignal(.visionAnalysis(imagePath: "i", prompt: "p")))
        XCTAssertFalse(LLMExecutionService.isCollaborationDeferredSignal(nil))
    }

    // MARK: - autovisorPromptBlock (GAP4)

    /// The goal is the brief (rendered as "## Supervisor Goal"), so `autovisorPromptBlock`
    /// must emit ONLY the standing memory — never the goal (which would duplicate it).
    func testAutovisorPromptBlock_withMemory_emitsMemoryOnly_noGoal() {
        mockDelegate.snapshot = makeManagerSnapshot(goal: "Ship the parser", memory: "Reviewed 3 tasks.")
        let block = service.autovisorPromptBlock()
        XCTAssertTrue(block.contains("## Current Memory"))
        XCTAssertTrue(block.contains("Reviewed 3 tasks."))
        XCTAssertFalse(block.contains("Goal"), "the goal lives in the brief (## Supervisor Goal), never duplicated here")
        XCTAssertFalse(block.contains("Ship the parser"))
    }

    func testAutovisorPromptBlock_emptyMemory_returnsEmpty() {
        mockDelegate.snapshot = makeManagerSnapshot(goal: "Ship the parser", memory: "")
        XCTAssertEqual(service.autovisorPromptBlock(), "")
    }

    private func makeManagerSnapshot(goal: String, memory: String) -> WorkFolderContext {
        var settings = ProjectSettings.defaults
        settings.autovisorGoal = goal
        settings.autovisorMemory = memory
        return WorkFolderContext(
            projection: WorkFolderProjection(state: WorkFolderState(name: "T"), settings: settings, teams: []),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: nil
        )
    }
}
