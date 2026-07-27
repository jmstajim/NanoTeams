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
/// Fix: `noteNonProductiveTurn` counts every non-productive turn — for EVERY role — and
/// at `LLMConstants.maxNonProductiveTurns` takes a role-shaped terminal. For an advisory
/// role in a chat-mode team under `supervisorMode == .autonomous` that terminal writes
/// step.done + role.done atomically and returns `.completed`. The atomic role.done write
/// is essential — bypassing `handleRoleCompleted` avoids a per-role gating mode
/// (e.g. `.afterEachRole`, the `TeamSettings.default`) routing the role to
/// `.needsAcceptance`, which would otherwise deadlock the engine into `.failed` in chat
/// mode (the engine has no `.needsAcceptance` exit path for chat teams).
///
/// Every other shape — the Autovisor manager (parks), a producing role, manual supervisor
/// mode, a non-chat advisory role, an unresolved role definition — takes its own terminal
/// rather than none. Those five used to bypass the counter entirely and loop forever;
/// each now has a test below.
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
    ///
    /// `templateID` selects the TERMINAL: `AutovisorConstants.teamTemplateID` makes
    /// `isAutovisorStep` true (it keys on the resolved team's templateID), which routes
    /// the backstop to the park instead of the `.done` finish.
    private func attachTeam(
        supervisorMode: SupervisorMode,
        role: TeamRoleDefinition,
        templateID: String? = nil
    ) {
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
            id: "t", name: "T", templateID: templateID,
            roles: [supervisor, role], artifacts: [],
            settings: settings, graphLayout: TeamGraphLayout()
        )
        mockDelegate.taskToMutate?.adoptGeneratedTeam(team)
    }

    /// Drives the backstop `n` times and returns the last stop.
    ///
    /// Each turn gets a FRESH empty `conversationMessages`, so `detectMessageLoop` sees
    /// `.noLoop` and the generic-nudge path is exercised in isolation. The
    /// `.repetitiveNonTool` path is covered separately by
    /// `testRepetitiveIdenticalTurns_stillReachTheCap`, which shares one conversation —
    /// both now feed the same counter, which is the point of making it shape-independent.
    @discardableResult
    private func runNonProductiveTurns(_ n: Int, role: TeamRoleDefinition) async -> LLMStepStop {
        var last: LLMStepStop = .continueLoop
        for _ in 1...n {
            var messages: [ChatMessage] = []
            last = await service._testHandleNoToolCalls(
                stepID: stepID,
                assistantContent: "All tasks completed.",
                sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!,
                roleDefinition: role,
                conversationMessages: &messages
            )
        }
        return last
    }

    // MARK: - Auto-Finish (positive path)

    func testAdvisoryRole_autonomousMode_finishesAtTheCap() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        // Every turn below the cap: counter increments, generic nudge fires, .continueLoop.
        for i in 1...(LLMConstants.maxNonProductiveTurns - 1) {
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
            XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), i,
                           "Turn \(i): counter should equal turn number")
        }

        // Final turn: counter hits threshold, returns .completed.
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
            XCTFail("Turn \(LLMConstants.maxNonProductiveTurns): expected .completed (auto-finish), got \(stop)")
            return
        }
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), 0,
                       "Counter must reset after auto-finish so a re-entry starts clean")
    }

    // MARK: - Autovisor manager: parks, never finishes

    /// The reported defect: the manager's review pass ended with "Advisory role
    /// auto-finished after N consecutive turns without productive tool calls" and its
    /// role written `.done`. That bypasses the manager's designed terminal — the idle
    /// park — and costs the same-conversation continuation, the idle sidebar state, and
    /// the recurrence/event supersede protections. It must PARK instead.
    func testAutovisorManager_atTheCap_parksInsteadOfFinishing() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role,
                   templateID: AutovisorConstants.teamTemplateID)

        let stop = await runNonProductiveTurns(LLMConstants.maxNonProductiveTurns, role: role)

        guard case .continueLoop = stop else {
            return XCTFail("Manager must hand off to the loop-top park, got \(stop)")
        }
        XCTAssertTrue(
            service._testParkForEventsRequested(stepID: stepID, taskID: task.id),
            "The park flag is the handoff — without it the step just loops again")
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), 0,
                       "Counter must reset so a re-entry starts clean")

        // The whole point: the role is NOT terminal, so the engine does not take its
        // chat-mode `.done` arm and the manager task stays alive.
        let run = mockDelegate.taskToMutate!.runs.last!
        XCTAssertNotEqual(run.roleStatuses[role.id], .done,
                          "Parking must not write the role terminal")
        XCTAssertNotEqual(run.steps.first(where: { $0.id == stepID })?.status, .done,
                          "Parking must not write the step terminal")
    }

    /// The park must be DISTINGUISHABLE from a healthy `wait_for_events` idle:
    /// `taskHasIdleParkStep` matches `idleParkQuestion` verbatim and the sidebar gates
    /// the manager's attention badge on `!isIdleParked`, so reusing that text would make
    /// a manager that stopped driving its loop look exactly like one resting normally.
    func testAutovisorManager_parkCarriesDiagnostic_notTheIdleParkText() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role,
                   templateID: AutovisorConstants.teamTemplateID)

        await runNonProductiveTurns(LLMConstants.maxNonProductiveTurns, role: role)

        let question = service._testParkQuestionOverride(stepID: stepID, taskID: task.id)
        XCTAssertNotNil(question, "The park must carry its own text, not fall back to idle")
        XCTAssertNotEqual(question, AutovisorConstants.idleParkQuestion,
                          "A malfunctioning pass must not read as a healthy idle")
        XCTAssertEqual(
            question,
            LLMExecutionService.noToolParkQuestion(turns: LLMConstants.maxNonProductiveTurns))
    }

    /// Every turn below the cap still nudges — the manager gets the same chances to
    /// recover as any other advisory role before the backstop fires.
    func testAutovisorManager_belowThreshold_nudgesWithoutParking() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role,
                   templateID: AutovisorConstants.teamTemplateID)

        for i in 1...(LLMConstants.maxNonProductiveTurns - 1) {
            let stop = await runNonProductiveTurns(1, role: role)
            guard case .continueLoop = stop else {
                return XCTFail("Turn \(i): expected .continueLoop, got \(stop)")
            }
            XCTAssertFalse(
                service._testParkForEventsRequested(stepID: stepID, taskID: task.id),
                "Turn \(i): must not park before the cap")
            XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), i)
        }
    }

    /// The finish arm must survive: an ORDINARY chat advisory role (Coding Assistant,
    /// Personal Assistant) still terminates `.done`. Only the manager parks.
    func testNonManagerChatAdvisory_stillFinishesDone_andDoesNotPark() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role) // no templateID → not the manager

        let stop = await runNonProductiveTurns(LLMConstants.maxNonProductiveTurns, role: role)

        guard case .completed = stop else {
            return XCTFail("Non-manager chat advisory must still auto-finish, got \(stop)")
        }
        XCTAssertFalse(
            service._testParkForEventsRequested(stepID: stepID, taskID: task.id),
            "Only the manager parks")
        XCTAssertEqual(mockDelegate.taskToMutate!.runs.last!.roleStatuses[role.id], .done)
    }

    // MARK: - Negative gates

    func testAdvisoryRole_manualMode_neverAutoFinishes_butEscalatesAtTheCap() async {
        // Manual mode must never auto-finish — but "never terminate" was a hole, not a
        // feature: the guard used to fail before the counter, so a manual-mode role
        // nudged forever with nothing watching. It now escalates to the human who is,
        // by definition of manual mode, there to answer.
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .manual, role: role)

        for i in 1...(LLMConstants.maxNonProductiveTurns - 1) {
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
                XCTFail("Turn \(i): expected a nudge below the cap, got \(stop)")
                return
            }
        }

        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "Anything else?", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: role,
            conversationMessages: &messages
        )
        guard case .needsSupervisorInput = stop else {
            XCTFail("Manual mode must escalate at the cap, not finish or loop; got \(stop)")
            return
        }
        XCTAssertFalse(
            service._testParkForEventsRequested(stepID: stepID, taskID: task.id),
            "Only the manager parks")
        XCTAssertNotEqual(
            mockDelegate.taskToMutate!.runs.last!.roleStatuses[role.id], .done,
            "Escalation must never force a role done — the human decides")
    }

    func testProducingRole_autonomousMode_neverAutoFinishes_butEscalatesAtTheCap() async {
        // Producing roles have their own self-terminate path (artifact completeness), and
        // this branch must not steal it — below the cap they keep getting the "Missing
        // deliverables" nudge. But they used to return above the counter entirely, so a
        // producing role that never submits anything looped forever. It now escalates.
        // Never `.done`: forcing that would mark the role complete with no deliverable and
        // strand every downstream role waiting on the artifact.
        let role = makeProducingRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        for i in 1...(LLMConstants.maxNonProductiveTurns - 1) {
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
                XCTFail("Turn \(i): producing role must be nudged below the cap, got \(stop)")
                return
            }
            // Last message should be the producing-role artifact nudge.
            XCTAssertTrue(
                (messages.last?.content ?? "").contains("Missing deliverables"),
                "Producing role should get artifact nudge, not advisory finish"
            )
        }

        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "Working on it.", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: role,
            conversationMessages: &messages
        )
        guard case .needsSupervisorInput = stop else {
            XCTFail("Producing role must escalate at the cap, got \(stop)")
            return
        }
        XCTAssertNotEqual(
            mockDelegate.taskToMutate!.runs.last!.roleStatuses[role.id], .done,
            "A producing role that submitted nothing must never be marked done")
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), 0,
                       "Escalation resets the counter so a post-supervisor continuation starts clean")
    }

    /// Hole 4: `handleNoToolCalls` is reachable with `roleDefinition == nil` (a role that
    /// didn't resolve against the team). Every guard used to fail on the nil, so the step
    /// fell through to the generic nudge forever with no counter and no terminal.
    func testNilRoleDefinition_escalatesAtTheCap() async {
        attachTeam(supervisorMode: .autonomous, role: makeAdvisoryRole())

        for i in 1...(LLMConstants.maxNonProductiveTurns - 1) {
            var messages: [ChatMessage] = []
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "Hmm.", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: nil,
                conversationMessages: &messages
            )
            guard case .continueLoop = stop else {
                XCTFail("Turn \(i): expected a nudge below the cap, got \(stop)")
                return
            }
            XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), i,
                           "An unresolved role definition must still be counted")
        }

        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "Hmm.", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages
        )
        guard case .needsSupervisorInput = stop else {
            XCTFail("An unresolved role definition must escalate at the cap, got \(stop)")
            return
        }
    }

    /// Hole 1, and the one that made the whole ceiling a fiction: the `.repetitiveNonTool`
    /// arm returned ABOVE the counter, so a model repeating one byte-identical reply froze
    /// it at whatever value it had and looped forever.
    ///
    /// Note this drives a SHARED conversation, unlike `runNonProductiveTurns` — the
    /// detector reads the last three text-only assistant turns, so a fresh array per turn
    /// (which every other test here uses deliberately, to isolate the counter) makes this
    /// branch unreachable.
    func testRepetitiveIdenticalTurns_stillReachTheCap() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        var shared: [ChatMessage] = []
        var sawRepetitiveNudge = false
        for i in 1...(LLMConstants.maxNonProductiveTurns - 1) {
            // The detector only inspects assistant turns; `_testHandleNoToolCalls`
            // appends only the nudge, so the test supplies the model's side.
            shared.append(ChatMessage(role: .assistant, content: "wait_for_events"))
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "wait_for_events", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: role,
                conversationMessages: &shared,
                allowedToolNames: [ToolNames.waitForEvents]
            )
            guard case .continueLoop = stop else {
                XCTFail("Turn \(i): expected a nudge below the cap, got \(stop)")
                return
            }
            if (shared.last?.content ?? "").contains("near-identical") { sawRepetitiveNudge = true }
            XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), i,
                           "Turn \(i): a repetitive turn is still a non-productive turn")
        }
        XCTAssertTrue(sawRepetitiveNudge,
                      "Sanity: the .repetitiveNonTool branch must actually have fired here")

        shared.append(ChatMessage(role: .assistant, content: "wait_for_events"))
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "wait_for_events", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: role,
            conversationMessages: &shared,
            allowedToolNames: [ToolNames.waitForEvents]
        )
        guard case .completed = stop else {
            XCTFail("A repetition loop must reach the cap and take its terminal, got \(stop)")
            return
        }
    }

    // MARK: - Counter reset on tool-call activity

    func testAdvisoryCounter_resetByToolCallExecution_avoidsPrematureFinish() async {
        // Real run pattern: model alternates between tool-driven turns and brief
        // confirmations. After an inter-turn tool call, the counter must reset so
        // a single subsequent text-only turn doesn't trigger finish on what would
        // otherwise be the capth consecutive no-tool turn cumulatively.
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        // Pre-arm one short of the threshold.
        let preArm = LLMConstants.maxNonProductiveTurns - 1
        for _ in 1...preArm {
            var messages: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "OK.", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: role,
                conversationMessages: &messages
            )
        }
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), preArm)

        // Simulate tool call execution between turns.
        service._testResetNonProductiveTurnCounter(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), 0)

        // Post-reset turn → counter = 1 again, NOT cap-and-finish.
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
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), 1,
                       "Counter should restart at 1 after the reset")
    }

    // MARK: - Critical: atomic role.done write (avoids engine deadlock)

    /// Critical regression: the auto-finish branch MUST set `roleStatuses[roleID] = .done`
    /// atomically with `step.status = .done`. If only step.done is written, the engine's
    /// `handleRoleCompleted` would route through `AcceptanceService.shouldRequestAcceptance`,
    /// which (for a per-role gating mode such as the default `.afterEachRole`) routes the
    /// role to `.needsAcceptance` — a state the engine's chat-mode `readyRoleIDs.isEmpty` arm
    /// doesn't exit cleanly, deadlocking into `.failed`. Setting role.done in the same
    /// `mutateTask` closure short-circuits `handleRoleCompleted`'s `roleStatuses[roleID]
    /// == .working` guard, leaving role.done as written.
    func testAutoFinish_writesRoleDoneAtomically_avoidingAcceptanceDeadlock() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)
        // Pre-condition: role status is `.working` (engine sets this when starting the step).
        mockDelegate.taskToMutate?.runs[0].roleStatuses[role.id] = .working

        // Drive enough consecutive no-tool turns to trip the auto-finish.
        for _ in 1...LLMConstants.maxNonProductiveTurns {
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
        XCTAssertNotNil(step?.completedAt, "Step.completedAt must be set on completion")
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
    /// count==cap-and-finish).
    func testRevisionMode_skipsAutoFinish_andDoesNotIncrementCounter() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)
        // Activate revision on the step.
        mockDelegate.taskToMutate?.runs[0].steps[0].revisionComment = "Please redo X"

        // Way past threshold without the gate. Bound derived so a cap raise can't make
        // this test vacuous.
        for i in 1...(LLMConstants.maxNonProductiveTurns + 5) {
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
            service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), 0,
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
    func testAttemptAdvisoryNoToolBackstop_mutateTaskShortCircuit_doesNotAnnounceCompletion() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        // Drive up to just under the threshold.
        let preArm = LLMConstants.maxNonProductiveTurns - 1
        for _ in 1...preArm {
            var messages: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "OK.", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: role,
                conversationMessages: &messages
            )
        }
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), preArm)

        // Simulate a race: step is removed from the task between the previous
        // turn's mutation and this turn's lookup. mutateTask will still return
        // true (it persists the modified-but-stepless task) but the closure's
        // internal `firstIndex(where: stepID)` guard short-circuits.
        mockDelegate.taskToMutate?.runs[0].steps = []

        // Final turn: threshold trips, mutateTask runs, closure short-circuits.
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
            service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id),
            LLMConstants.maxNonProductiveTurns,
            "Counter must stay at the cap (not reset) so the next iteration can re-attempt"
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

        for i in 1...(LLMConstants.maxNonProductiveTurns - 1) {
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

        // At the cap it escalates instead of finishing. Escalation is the correct terminal
        // here for the same reason the bypass is forbidden: the engine's acceptance
        // plumbing owns this role's lifecycle, so the step must be handed back rather than
        // written `.done` behind it. Before this, the guard failed BEFORE the counter, so
        // an advisory role in a non-chat team simply looped forever.
        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "OK.", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: role,
            conversationMessages: &messages
        )
        guard case .needsSupervisorInput = stop else {
            XCTFail("Non-chat advisory must escalate at the cap, never bypass to .done; got \(stop)")
            return
        }
        // The bypass path must not have written `.done` directly.
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].steps[0].status, .needsSupervisorInput)
        XCTAssertNotEqual(mockDelegate.taskToMutate!.runs.last!.roleStatuses[role.id], .done)
    }

    // MARK: - I10 regression: ask_supervisor-only turn counter treatment

    /// I10: `ask_supervisor` is auto-answered under `.autonomous` supervisor
    /// mode, so a turn whose only tool call is `ask_supervisor` is non-
    /// productive — the model can ping itself in a loop forever. The
    /// counter-treatment branch in `runOneLLMToolIteration` calls
    /// `noteNonProductiveTurn` (= increment) for these turns, NOT the
    /// reset path. We exercise the increment via the `_testIncrementAdvisoryNoToolCounter`
    /// helper since `_testHandleNoToolCalls` doesn't drive the tool-call branch.
    func testAdvisoryCounter_askSupervisorOnlyTurn_incrementsLikeNoToolTurn() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        // Each below-cap `ask_supervisor`-only turn should advance the counter via the
        // same `noteNonProductiveTurn` path that no-tool-call turns use. Drive
        // via the public auto-finish helper directly.
        for i in 1...(LLMConstants.maxNonProductiveTurns - 1) {
            let stop = await service.noteNonProductiveTurn(stepID: stepID, taskID: task.id, roleDefinition: role)
            XCTAssertNil(stop, "Below threshold — must continue, got \(String(describing: stop))")
            XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), i,
                           "Each ask_supervisor-only turn must increment the counter")
        }

        // The capth turn hits threshold — fires auto-finish.
        let final = await service.noteNonProductiveTurn(stepID: stepID, taskID: task.id, roleDefinition: role)
        if case .completed? = final { /* ok */ } else {
            XCTFail("Threshold should trip on turn \(LLMConstants.maxNonProductiveTurns) of consecutive ask_supervisor-only turns, got \(String(describing: final))")
        }
    }

    /// I10 inverse: a turn with `ask_supervisor` AND a real tool resets the
    /// counter — the real tool is productive activity. Validates the
    /// `else` branch of `isAskSupervisorOnly` in the tool-call path.
    func testAdvisoryCounter_mixedTurnWithRealTool_resetsViaPublicHelper() async {
        let role = makeAdvisoryRole()
        attachTeam(supervisorMode: .autonomous, role: role)

        // Pre-arm the counter to one short of the cap.
        let preArm = LLMConstants.maxNonProductiveTurns - 1
        for _ in 1...preArm {
            _ = await service.noteNonProductiveTurn(stepID: stepID, taskID: task.id, roleDefinition: role)
        }
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), preArm)

        // Simulate a productive (mixed) turn — this is what runOneLLMToolIteration
        // does in the !isAskSupervisorOnly branch:
        //     executionStates[stepID]?.consecutiveNonProductiveTurns = 0
        // Validate via the test helper that exposes that reset.
        service._testResetNonProductiveTurnCounter(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), 0,
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
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), -1,
                       "Sentinel: state entry is gone")

        for i in 1...(LLMConstants.maxNonProductiveTurns + 5) {
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
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), -1,
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
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), 1)

        // clearRunningTask removes the state entry entirely; the next read returns -1.
        service.clearRunningTask(stepID: stepID, taskID: task.id)
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), -1,
                       "After cleanup, state entry is removed (counter helper returns -1)")
    }

    // MARK: - finishStepGraceful (requestFinish / loop-recovery terminal)

    /// `finishStepGraceful` (the legacy `requestFinish` / `finishRequested` path).
    /// For a chat-mode advisory step it must finish directly as `.done` (step + role),
    /// the same terminal state `noteNonProductiveTurn` produces — NOT
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
        await service.parkStepForEvents(stepID: stepID, taskID: task.id)

        let step = mockDelegate.taskToMutate?.runs.last?.steps.first
        XCTAssertEqual(step?.status, .needsSupervisorInput,
                       "park must transition the step, not complete it")
        XCTAssertEqual(step?.needsSupervisorInput, true)
        XCTAssertEqual(step?.supervisorQuestion, AutovisorConstants.idleParkQuestion,
                       "the idle-park question is what the composer renders")
    }

    /// Write↔read round-trip: a park landed by the REAL write path (including its
    /// question trimming) must satisfy the sidebar's idle-park predicate. Pins the
    /// cross-file coupling directly — if `parkStepForEvents`/`setNeedsSupervisorInput`
    /// ever alter the persisted text (or the predicate's matching changes), this
    /// fails even though both sides' own unit tests still pass against themselves.
    func testParkStepForEvents_resultSatisfiesIdleParkPredicate() async {
        await service.parkStepForEvents(stepID: stepID, taskID: task.id)

        XCTAssertTrue(NTMSOrchestrator.taskHasIdleParkStep(mockDelegate.taskToMutate),
                      "a genuine park must be recognized as idle by the sidebar predicate")
    }

    /// Corner: a pass that never established a session (every call fell back to
    /// stateless) parks with no chain state — the park must still land; the
    /// continuation then replays the persisted transcript.
    func testParkStepForEvents_nilSession_stillParks() async {
        await service.parkStepForEvents(stepID: stepID, taskID: task.id)

        let step = mockDelegate.taskToMutate?.runs.last?.steps.first
        XCTAssertEqual(step?.status, .needsSupervisorInput)
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

        await service.parkStepForEvents(stepID: stepID, taskID: task.id)

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

        await service.parkStepForEvents(stepID: stepID, taskID: task.id)

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
