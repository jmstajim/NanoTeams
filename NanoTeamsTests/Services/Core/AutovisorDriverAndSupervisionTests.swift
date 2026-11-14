import XCTest
@testable import NanoTeams

@MainActor
final class AutovisorDriverAndSupervisionTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let sampleAgent = AgentIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        label: "Claude Code"
    )

    // MARK: - 1. AutovisorPolicy supervision & setup rules by driver and origin

    func testAutovisorPolicy_supervisionAndSetupRules_respectDriverAndOrigin() {
        let onAct = AutovisorActivation(onTaskNeedsSupervisor: true)
        let offAct = AutovisorActivation(onTaskNeedsSupervisor: false)

        // Built-in driver: supervises top-level non-manager tasks regardless of origin when
        // `autovisorEnabled && activation.onTaskNeedsSupervisor`.
        XCTAssertTrue(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: nil, autovisorEnabled: true,
            activation: onAct, autovisorTaskID: 1,
            driver: .builtInModel, origin: nil
        ))
        XCTAssertFalse(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: nil, autovisorEnabled: true,
            activation: offAct, autovisorTaskID: 1,
            driver: .builtInModel, origin: nil
        ))
        // When driver is builtInModel, activation.onTaskNeedsSupervisor dictates supervision
        // for ALL tasks, so agent tasks fall back to auto-answer / human path when trigger is off.
        XCTAssertFalse(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: nil, autovisorEnabled: true,
            activation: offAct, autovisorTaskID: 1,
            driver: .builtInModel, origin: .externalAgent(sampleAgent)
        ), "Agent tasks under builtInModel must NOT be supervised when onTaskNeedsSupervisor == false")
        XCTAssertTrue(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: nil, autovisorEnabled: true,
            activation: onAct, autovisorTaskID: 1,
            driver: .builtInModel, origin: .externalAgent(sampleAgent)
        ), "Agent tasks under builtInModel ARE supervised when onTaskNeedsSupervisor == true")
        XCTAssertTrue(AutovisorPolicy.supervisesTopLevelTasks(
            autovisorEnabled: true, activation: onAct, driver: .builtInModel
        ))

        // External driver: supervises ONLY top-level tasks with `.externalAgent` origin,
        // without consulting `activation.onTaskNeedsSupervisor`. Human tasks (`origin == nil`)
        // and built-in tasks (`origin == .builtInAutovisor`) are NOT supervised by the external agent.
        XCTAssertTrue(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: nil, autovisorEnabled: true,
            activation: offAct, autovisorTaskID: 1,
            driver: .externalAgent, origin: .externalAgent(sampleAgent)
        ))
        XCTAssertFalse(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: nil, autovisorEnabled: true,
            activation: onAct, autovisorTaskID: 1,
            driver: .externalAgent, origin: nil
        ))
        XCTAssertFalse(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: nil, autovisorEnabled: true,
            activation: onAct, autovisorTaskID: 1,
            driver: .externalAgent, origin: .builtInAutovisor
        ))
        XCTAssertFalse(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: 99, autovisorEnabled: true,
            activation: onAct, autovisorTaskID: 1,
            driver: .externalAgent, origin: .externalAgent(sampleAgent)
        ))
        XCTAssertFalse(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: nil, autovisorEnabled: false,
            activation: onAct, autovisorTaskID: 1,
            driver: .externalAgent, origin: .externalAgent(sampleAgent)
        ))

        // Folder-level preview (`supervisesTopLevelTasks`) is ALWAYS false when driver == .externalAgent:
        // ordinary human tasks in the folder are not under the external agent.
        XCTAssertFalse(AutovisorPolicy.supervisesTopLevelTasks(
            autovisorEnabled: true, activation: onAct, driver: .externalAgent
        ))

        // Setup routing under `.externalAgent`: does not require a built-in manager task or goal.
        XCTAssertTrue(AutovisorPolicy.showsSetupPane(
            taskExists: false, enabled: false, driver: .externalAgent
        ))
        XCTAssertFalse(AutovisorPolicy.showsSetupPane(
            taskExists: false, enabled: true, driver: .externalAgent
        ))
        XCTAssertFalse(AutovisorPolicy.requiresSetupBeforeEnabling(
            taskExists: false, goalIsUnset: true, driver: .externalAgent
        ))
    }

    func testAutovisorPolicy_builtInModelDriver_respectsActivationTriggerForAgentTasks() {
        let offAct = AutovisorActivation(onTaskNeedsSupervisor: false)
        let onAct = AutovisorActivation(onTaskNeedsSupervisor: true)

        // When driver is builtInModel, activation.onTaskNeedsSupervisor dictates supervision
        // for ALL tasks, so agent tasks fall back to auto-answer / human path when trigger is off.
        XCTAssertFalse(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: nil, autovisorEnabled: true,
            activation: offAct, autovisorTaskID: 1,
            driver: .builtInModel, origin: .externalAgent(sampleAgent)
        ), "Agent tasks under builtInModel must NOT be supervised when onTaskNeedsSupervisor == false")

        XCTAssertTrue(AutovisorPolicy.supervisesTask(
            taskID: 2, parentTaskID: nil, autovisorEnabled: true,
            activation: onAct, autovisorTaskID: 1,
            driver: .builtInModel, origin: .externalAgent(sampleAgent)
        ), "Agent tasks under builtInModel ARE supervised when onTaskNeedsSupervisor == true")
    }

    func testApprovalHumanPresent_whenAutovisorDisabled_returnsTrueForAgentTasks() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder {
            $0.settings.autovisorEnabled = true
            $0.settings.autovisorDriver = .externalAgent
        }
        sut.configuration.bashMode = .manual

        let rawTaskID = await sut.createTask(
            title: "Agent Task",
            supervisorTask: "Task brief",
            makeActive: true,
            origin: .externalAgent(sampleAgent)
        )
        let taskID = try XCTUnwrap(rawTaskID)
        await sut.ensureTaskLoaded(taskID)
        let task = try XCTUnwrap(sut.loadedTask(taskID))

        // When autovisor is enabled: human is NOT present
        XCTAssertFalse(sut.llmExecutionService.approvalHumanPresent(task: task, supervisorMode: .manual))

        // Turn Autovisor OFF: approval cards return to human (autovisor.md:39)
        await sut.mutateWorkFolder {
            $0.settings.autovisorEnabled = false
        }
        XCTAssertTrue(
            sut.llmExecutionService.approvalHumanPresent(task: task, supervisorMode: .manual),
            "When Autovisor is disabled, humanPresent must be true so approval cards return to the human"
        )
    }

    private final class StubAutoAnswerClient: LLMClient, @unchecked Sendable {
        func streamChat(
            config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
            logger: NetworkLogger?, stepID: String?, roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { c in c.yield(StreamEvent(contentDelta: "Proceed.")); c.finish() }
        }
        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    // MARK: - 2. Human vs external task under external driver: questions, bash approval, loop park

    func testExternalDriver_humanTaskHasHumanApproverAndAutoAnswer_whileAgentTaskParksWithNoApprover() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder {
            $0.settings.autovisorEnabled = true
            $0.settings.autovisorDriver = .externalAgent
            $0.settings.autovisorActivation.onTaskNeedsSupervisor = true
        }

        let rawHumanID = await sut.createTask(
            title: "Human Task", supervisorTask: "Brief", makeActive: false, origin: nil
        )
        let humanID = try XCTUnwrap(rawHumanID)
        let rawAgentID = await sut.createTask(
            title: "Agent Task", supervisorTask: "Brief", makeActive: false,
            origin: .externalAgent(sampleAgent)
        )
        let agentID = try XCTUnwrap(rawAgentID)
        await sut.ensureTaskLoaded(humanID)
        await sut.ensureTaskLoaded(agentID)
        let humanTask = try XCTUnwrap(sut.loadedTask(humanID))
        let agentTask = try XCTUnwrap(sut.loadedTask(agentID))

        // 1) `isUnderAutovisor` and `approvalHumanPresent`:
        // Human task is NOT under Autovisor -> human IS present for manual supervisor mode (bash approval card visible).
        XCTAssertFalse(sut.llmExecutionService.isUnderAutovisor(task: humanTask))
        XCTAssertTrue(sut.llmExecutionService.approvalHumanPresent(task: humanTask, supervisorMode: .manual))
        let humanBashAvail = ApprovalGatedAvailability.forBash(
            mode: .manual,
            humanPresent: sut.llmExecutionService.approvalHumanPresent(task: humanTask, supervisorMode: .manual)
        )
        XCTAssertEqual(humanBashAvail, .available)

        // Agent task IS under Autovisor -> human is NOT present even if team is `.manual`.
        XCTAssertTrue(sut.llmExecutionService.isUnderAutovisor(task: agentTask))
        XCTAssertFalse(sut.llmExecutionService.approvalHumanPresent(task: agentTask, supervisorMode: .manual))
        let agentBashAvail = ApprovalGatedAvailability.forBash(
            mode: .manual,
            humanPresent: sut.llmExecutionService.approvalHumanPresent(task: agentTask, supervisorMode: .manual)
        )
        XCTAssertEqual(agentBashAvail, .withheld(.noApprover))

        // 2) `handleSupervisorAutoAnswer`:
        // Agent task returns `nil` (parks for external agent) even on `.autonomous`.
        var wire: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        outcome.supervisorQuestion = "Which database?"
        outcome.shouldStopForSupervisor = true
        let stubClient = StubAutoAnswerClient()
        let config = LLMConfig()
        let agentAutoAnswer = await sut.llmExecutionService.handleSupervisorAutoAnswer(
            outcome: outcome,
            stepID: "swe",
            supervisorMode: .autonomous,
            task: agentTask,
            runIndex: 0,
            stepIndex: 0,
            client: stubClient,
            config: config,
            conversationMessages: &wire
        )
        XCTAssertNil(agentAutoAnswer, "Agent task must suppress auto-answer and park for the external agent")

        // 3) `canParkForSupervisor` in `handleStreamLoopBreak`:
        // Agent task on an autonomous chat-mode team parks on thinking-loop terminal instead of finishing gracefully.
        var chatTeam = TeamTemplateFactory.codingAssistant()
        chatTeam.settings.supervisorMode = .autonomous
        let roleID = chatTeam.nonSupervisorRoles.first?.id ?? "assistant"
        await sut.mutateWorkFolder { $0.teams.append(chatTeam) }
        await sut.mutateTask(taskID: agentID) {
            $0.preferredTeamID = chatTeam.id
            $0.runs = [Run(
                id: 0,
                steps: [StepExecution(id: roleID, role: .custom(id: roleID), title: "Assistant", status: .running)],
                roleStatuses: [roleID: .working]
            )]
        }
        let refreshedAgentTask = try XCTUnwrap(sut.loadedTask(agentID))
        sut.llmExecutionService._testSetThinkingLoopBreakCount(
            stepID: roleID,
            taskID: agentID,
            count: LLMConstants.maxThinkingLoopBreaks - 1
        )
        defer { sut.llmExecutionService.clearRunningTask(stepID: roleID, taskID: agentID) }

        let loopSignal = LoopSignal.withinMessage(diagnostic: "repeated paragraph")
        let stop = await sut.llmExecutionService._testHandleStreamLoopBreak(
            stepID: roleID,
            signal: loopSignal,
            task: refreshedAgentTask,
            supervisorMode: .autonomous,
            allowedToolNames: [ToolNames.askSupervisor],
            conversationMessages: &wire
        )
        if case .continueLoop = stop {
            // Expected loop-top handoff
        } else {
            XCTFail("Expected .continueLoop handoff for agent task loop break, got \(stop)")
        }
        XCTAssertTrue(
            sut.llmExecutionService._testParkForEventsRequested(stepID: roleID, taskID: agentID),
            "External agent task on autonomous chat-mode team must park for supervisor instead of finishing gracefully"
        )
        XCTAssertFalse(
            sut.llmExecutionService._testFinishRequested(stepID: roleID, taskID: agentID),
            "External agent task must not set finishRequested on thinking-loop terminal"
        )
    }

    // MARK: - 2b. The auto-answer and approval paths, behaviourally (F6 C3, 2026-11-12)

    /// Seeds a running step on `taskID` and asks the auto-answer seam the step's own question, the
    /// way the tool loop does — `nil` is "parks", `.continueLoop` is "answered itself".
    private func askOwnQuestion(taskID: Int, mode: SupervisorMode) async throws -> (stop: LLMStepStop?, wire: [ChatMessage]) {
        await sut.mutateTask(taskID: taskID) {
            $0.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .running)],
                roleStatuses: ["swe": .working]
            )]
        }
        let task = try XCTUnwrap(sut.loadedTask(taskID))
        var wire: [ChatMessage] = []
        var outcome = LLMExecutionService.ToolResultsOutcome()
        outcome.supervisorQuestion = "Which database?"
        outcome.shouldStopForSupervisor = true
        let stop = await sut.llmExecutionService.handleSupervisorAutoAnswer(
            outcome: outcome, stepID: "swe", supervisorMode: mode, task: task,
            runIndex: 0, stepIndex: 0, client: StubAutoAnswerClient(), config: LLMConfig(),
            conversationMessages: &wire)
        return (stop, wire)
    }

    private func isContinueLoop(_ stop: LLMStepStop?) -> Bool {
        if case .continueLoop? = stop { return true }
        return false
    }

    /// §4 п.4 through the genuine seam, where the predicate test above only reads `supervisesTask`:
    /// under the built-in driver with the needs-supervisor trigger OFF, an agent's task is not the
    /// manager's — on an autonomous team it answers itself, on a manual one it parks for a person,
    /// and a person approves its cards. The trigger ON is the contrast: the manager has it.
    func testBuiltInDriver_triggerOff_agentTaskAnswersItselfOrWaitsForAPerson() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder {
            $0.settings.autovisorEnabled = true
            $0.settings.autovisorDriver = .builtInModel
            $0.settings.autovisorActivation.onTaskNeedsSupervisor = false
        }
        let created = await sut.createTask(
            title: "Agent", supervisorTask: "b", makeActive: false, origin: .externalAgent(sampleAgent))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)

        let autonomous = try await askOwnQuestion(taskID: taskID, mode: .autonomous)
        XCTAssertTrue(isContinueLoop(autonomous.stop), "the autonomous team answers its own question")
        XCTAssertFalse(autonomous.wire.isEmpty, "the answer reached the wire")

        let manual = try await askOwnQuestion(taskID: taskID, mode: .manual)
        XCTAssertNil(manual.stop, "a manual team parks for a person")
        let task = try XCTUnwrap(sut.loadedTask(taskID))
        XCTAssertTrue(sut.llmExecutionService.approvalHumanPresent(task: task, supervisorMode: .manual),
                      "a person approves its cards")

        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskNeedsSupervisor = true }
        let supervised = try await askOwnQuestion(taskID: taskID, mode: .autonomous)
        XCTAssertNil(supervised.stop, "anti-vacuum: with the trigger on, the manager has the question")
    }

    /// §4 п.6, second test: a child an agent's task delegated, on an AUTONOMOUS team, still answers
    /// its own questions — the child inherits the root's absence of a person for approvals only.
    func testDelegatedChildOfAnAgentTask_onAnAutonomousTeam_stillAnswersItself() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder {
            $0.settings.autovisorEnabled = true
            $0.settings.autovisorDriver = .externalAgent
        }
        let parent = await sut.createTask(
            title: "Agent parent", supervisorTask: "b", makeActive: false, origin: .externalAgent(sampleAgent))
        let parentID = try XCTUnwrap(parent)
        let child = await sut.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "software_engineer", title: "Child",
            supervisorTask: "b", preferredTeamID: nil, depth: 1)
        let childID = try XCTUnwrap(child)
        await sut.ensureTaskLoaded(childID)
        let childTask = try XCTUnwrap(sut.loadedTask(childID))
        XCTAssertNil(childTask.origin, "anti-vacuum: the child has no origin of its own")

        XCTAssertFalse(sut.llmExecutionService.isUnderAutovisor(task: childTask))
        XCTAssertTrue(sut.llmExecutionService.underAutovisorForApproval(task: childTask))
        XCTAssertFalse(sut.llmExecutionService.approvalHumanPresent(task: childTask, supervisorMode: .manual),
                       "its cards have no person behind them, like its root's")
        let asked = try await askOwnQuestion(taskID: childID, mode: .autonomous)
        XCTAssertTrue(isContinueLoop(asked.stop), "the autonomous child team answers itself")
    }

    /// §4 п.6, third test: a child of a PERSON's task is unchanged under either driver — the built-in
    /// one with the needs-supervisor trigger on included: a person approves its cards, and an
    /// autonomous child team answers itself.
    func testDelegatedChildOfAPersonsTask_isUnchangedUnderEitherDriver() async throws {
        await sut.openWorkFolder(tempDir)
        let parent = await sut.createTask(title: "Person parent", supervisorTask: "b", makeActive: false, origin: nil)
        let parentID = try XCTUnwrap(parent)
        let child = await sut.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "software_engineer", title: "Child",
            supervisorTask: "b", preferredTeamID: nil, depth: 1)
        let childID = try XCTUnwrap(child)
        await sut.ensureTaskLoaded(childID)

        for driver in [AutovisorDriver.externalAgent, .builtInModel] {
            await sut.mutateWorkFolder {
                $0.settings.autovisorEnabled = true
                $0.settings.autovisorDriver = driver
                $0.settings.autovisorActivation.onTaskNeedsSupervisor = true
            }
            let childTask = try XCTUnwrap(sut.loadedTask(childID))
            XCTAssertFalse(sut.llmExecutionService.isUnderAutovisor(task: childTask), "\(driver)")
            XCTAssertFalse(sut.llmExecutionService.underAutovisorForApproval(task: childTask), "\(driver)")
            XCTAssertTrue(sut.llmExecutionService.approvalHumanPresent(task: childTask, supervisorMode: .manual),
                          "\(driver): a person approves")
            let asked = try await askOwnQuestion(taskID: childID, mode: .autonomous)
            XCTAssertTrue(isContinueLoop(asked.stop), "\(driver): the autonomous child answers itself")
        }
    }

    // MARK: - 3. Dormancy of built-in manager across all entry points

    func testDormancy_allEntryPointsRefuseBuiltInManagerWhenExternalDriver() async throws {
        await sut.openWorkFolder(tempDir)
        let rawMgrID = await sut.createTask(
            title: "Autovisor", supervisorTask: "Goal", makeActive: false
        )
        let mgrID = try XCTUnwrap(rawMgrID)
        await sut.ensureTaskLoaded(mgrID)
        let pastDue = Date(timeIntervalSinceNow: -120)
        await sut.mutateTask(taskID: mgrID) { task in
            task.recurrence = TaskRecurrence(
                rule: .interval(seconds: 600),
                isEnabled: true,
                nextFireAt: pastDue
            )
            task.runs = [Run(
                id: 0,
                steps: [
                    StepExecution(
                        id: AutovisorConstants.managerRoleSystemID,
                        role: .custom(id: AutovisorConstants.managerRoleSystemID),
                        title: "Manager",
                        status: .needsSupervisorInput,
                        needsSupervisorInput: true,
                        supervisorQuestion: AutovisorConstants.idleParkQuestion
                    )
                ],
                roleStatuses: [AutovisorConstants.managerRoleSystemID: .working]
            )]
        }
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = mgrID
            $0.settings.autovisorEnabled = true
            $0.settings.autovisorDriver = .externalAgent
        }

        let lifecycle = sut.currentFolderLifecycle

        // 1) `ensureAutovisorTask` is a no-op under `.externalAgent`
        await sut.ensureAutovisorTask(lifecycle: lifecycle)
        XCTAssertNil(sut.taskEngines[mgrID], "ensureAutovisorTask must not start an engine when driver is .externalAgent")

        // 2) `startAutovisorPass` (both non-force and force) refuses under `.externalAgent`
        await sut.startAutovisorPass(taskID: mgrID, force: false)
        XCTAssertNil(sut.taskEngines[mgrID])
        await sut.startAutovisorPass(taskID: mgrID, force: true)
        XCTAssertNil(sut.taskEngines[mgrID])

        // 3) `engineForTask`, `wakeEngine`, `restartRole`, `holdDownstreamForRevision`, `startRun`, `resumeRun`
        _ = sut.engineForTask(mgrID)
        XCTAssertNil(sut.taskEngines[mgrID], "engineForTask must not register an engine for dormant manager")
        XCTAssertFalse(sut.wakeEngine(taskID: mgrID))
        await sut.restartRole(taskID: mgrID, roleID: AutovisorConstants.managerRoleSystemID, comment: "retry")
        XCTAssertNil(sut.taskEngines[mgrID])
        await sut.holdDownstreamForRevision(
            taskID: mgrID,
            runningRoleIDs: [AutovisorConstants.managerRoleSystemID],
            requesterRoleID: "other",
            within: lifecycle
        )
        XCTAssertNil(sut.taskEngines[mgrID])
        await sut.startRun(taskID: mgrID)
        XCTAssertEqual(sut.loadedTask(mgrID)?.runs.count, 1, "startRun must not create a new run on dormant manager")
        await sut.resumeRun(taskID: mgrID)
        XCTAssertNil(sut.taskEngines[mgrID])

        // 4) `wakeAutovisorForEvents` and `seedAutovisorNotifiedKeysForPassStart`
        let rawWorkerID = await sut.createTask(
            title: "Worker", supervisorTask: "Work", makeActive: false
        )
        let workerID = try XCTUnwrap(rawWorkerID)
        await sut.ensureTaskLoaded(workerID)
        await sut.mutateTask(taskID: workerID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .failed)],
                roleStatuses: ["swe": .failed]
            )]
        }
        sut.seedAutovisorNotifiedKeysForPassStart()
        XCTAssertTrue(sut.autovisorNotifiedAttentionKeys.isEmpty)
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.isEmpty)
        await sut.wakeAutovisorForEvents(includeStuck: true, within: lifecycle)
        XCTAssertNil(sut.taskEngines[mgrID])

        // 5) `fireRecurrence` via `evaluateDueRecurrences` disables manager recurrence without firing
        await sut.evaluateDueRecurrences(now: Date(), within: lifecycle)
        await sut.ensureTaskLoaded(mgrID)
        XCTAssertEqual(sut.loadedTask(mgrID)?.recurrence?.isEnabled, false)
        XCTAssertEqual(sut.loadedTask(mgrID)?.runs.count, 1)

        // 6) `sendMessageToAutovisor` refuses while dormant
        XCTAssertFalse(sut.sendMessageToAutovisor("Hello dormant manager"))

        // 7) Pre-queued message on manager task is skipped by `tryFlushQueuedMessages`, and
        // `answerSupervisorQuestion` refuses delivery to dormant manager so messages remain queued.
        let formState = try XCTUnwrap(sut.messageQueue.activeFormState)
        let msg = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "Keep me queued", attachments: [], clippedTexts: [],
            targetRoleID: AutovisorConstants.managerRoleSystemID
        ))
        formState.appendQueuedMessage(msg, for: mgrID)
        sut.engineState[mgrID] = .needsSupervisorInput
        sut.messageQueue.tryFlushQueuedMessages(formState: formState)
        await sut.messageQueue._testAwaitPendingFlushes()
        XCTAssertEqual(formState.queuedMessages(for: mgrID).map(\.text), ["Keep me queued"])

        let delivered = await sut.answerSupervisorQuestion(
            stepID: AutovisorConstants.managerRoleSystemID,
            taskID: mgrID,
            answer: "Direct answer",
            within: lifecycle
        )
        XCTAssertFalse(delivered, "answerSupervisorQuestion must not deliver into dormant manager")
    }

    // MARK: - 3b. A dormant manager's action is refused before anything is loaded

    /// The driver gate is the first thing a built-in manager's action meets: before the self-guard,
    /// before the target is read from disk, before the not-found check. A refused action leaves no
    /// trace — no task loaded (the load can persist a recovered status and raise a banner) and no
    /// task created — and it reads the same whatever its target, the manager's own task included.
    func testDormantManagerAction_isRefusedBeforeItsTargetIsLoaded_withOneRegisteredText() async throws {
        await sut.openWorkFolder(tempDir)
        let rawMgrID = await sut.createTask(title: "Autovisor", supervisorTask: "Goal", makeActive: false)
        let mgrID = try XCTUnwrap(rawMgrID)
        let rawTargetID = await sut.createTask(title: "Target", supervisorTask: "Work", makeActive: false)
        let targetID = try XCTUnwrap(rawTargetID)
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = mgrID
            $0.settings.autovisorDriver = .externalAgent
        }
        // On disk only from here on, so a load would show.
        sut.evictLoadedTask(targetID)
        XCTAssertNil(sut.loadedTask(targetID))
        let tasksBefore = sut.snapshot?.tasksIndex.tasks.count
        let errorsBefore = sut.errorSurfaceCount
        let lifecycle = sut.currentFolderLifecycle

        let onTarget = await sut.performAutovisorAction(
            .controlTask(taskID: targetID, verb: .rename(title: "Blocked")), as: .builtInManager, within: lifecycle)
        let onOwnTask = await sut.performAutovisorAction(
            .controlTask(taskID: mgrID, verb: .pause), as: .builtInManager, within: lifecycle)
        let onMissingTask = await sut.performAutovisorAction(
            .controlTask(taskID: 9_999, verb: .pause), as: .builtInManager, within: lifecycle)
        let folderLevel = await sut.performAutovisorAction(
            .createManagedTask(title: "New", brief: "Brief", teamID: nil), as: .builtInManager, within: lifecycle)

        for result in [onTarget, onOwnTask, onMissingTask, folderLevel] {
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.message, onTarget.message, "every action of a dormant manager gets the one refusal")
        }
        XCTAssertEqual(onTarget.message, AutovisorReply.drivenByExternalAgent.text)
        XCTAssertNotEqual(
            onOwnTask.message, AutovisorReply.ownTask(taskID: mgrID).text,
            "the driver gate comes before the self-guard")
        XCTAssertNil(sut.loadedTask(targetID), "a refused action must not read its target from disk")
        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "a refused action must raise no banner")
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, tasksBefore, "a refused creation creates nothing")
        let versionedTexts = RuntimePromptRegistry.entries
            .filter { $0.audience == .localModel }
            .map { $0.render() }
        XCTAssertTrue(
            versionedTexts.contains(onTarget.message),
            "the refusal the manager's local model reads must be a registered runtime text")
    }

    // MARK: - 4. Driver switch mid-pass & lossless round-trip

    func testSetAutovisorDriver_switchesCleanlyMidPass_blocksBuiltInActions_andRestoresBuiltIn() async throws {
        await sut.openWorkFolder(tempDir)
        let rawMgrID = await sut.createTask(
            title: "Autovisor", supervisorTask: "Real folder goal", makeActive: false
        )
        let mgrID = try XCTUnwrap(rawMgrID)
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { task in
            task.recurrence = TaskRecurrence(rule: .interval(seconds: 600), isEnabled: true)
            task.runs = [Run(
                id: 0,
                steps: [
                    StepExecution(
                        id: AutovisorConstants.managerRoleSystemID,
                        role: .custom(id: AutovisorConstants.managerRoleSystemID),
                        title: "Manager",
                        status: .running
                    )
                ],
                roleStatuses: [AutovisorConstants.managerRoleSystemID: .working]
            )]
        }
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = mgrID
            $0.settings.autovisorGoal = "Real folder goal"
            $0.settings.autovisorEnabled = true
            $0.settings.autovisorDriver = .builtInModel
        }
        sut.engineState[mgrID] = .running

        let rawTargetID = await sut.createTask(
            title: "Target", supervisorTask: "Work", makeActive: false
        )
        let targetID = try XCTUnwrap(rawTargetID)
        await sut.ensureTaskLoaded(targetID)

        // Switch driver to `.externalAgent` while the manager is `.running`:
        // must pause the manager step, tear down its engine, disable its recurrence,
        // and refuse subsequent `.builtInManager` actions.
        await sut.setAutovisorDriver(.externalAgent)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorDriver, .externalAgent)
        XCTAssertNil(sut.taskEngines[mgrID])
        XCTAssertEqual(sut.loadedTask(mgrID)?.recurrence?.isEnabled, false)
        XCTAssertEqual(
            sut.loadedTask(mgrID)?.runs.last?.steps.first?.status,
            .paused,
            "Switching driver to .externalAgent must await pauseRun so the running manager step settles to .paused"
        )

        let builtInActionAfterSwitch = await sut.performAutovisorAction(
            .controlTask(taskID: targetID, verb: .rename(title: "Blocked")),
            as: .builtInManager,
            within: sut.currentFolderLifecycle
        )
        XCTAssertFalse(builtInActionAfterSwitch.ok, "Built-in manager actions must be refused after switching to .externalAgent")
        XCTAssertEqual(builtInActionAfterSwitch.message, AutovisorReply.drivenByExternalAgent.text)
        XCTAssertEqual(sut.loadedTask(targetID)?.title, "Target")

        // Switch back to `.builtInModel`: recurrence is re-enabled and built-in actions work again.
        await sut.setAutovisorDriver(.builtInModel)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorDriver, .builtInModel)
        XCTAssertEqual(sut.loadedTask(mgrID)?.recurrence?.isEnabled, true)

        let builtInActionAfterRestore = await sut.performAutovisorAction(
            .controlTask(taskID: targetID, verb: .rename(title: "Allowed Again")),
            as: .builtInManager,
            within: sut.currentFolderLifecycle
        )
        XCTAssertTrue(builtInActionAfterRestore.ok)
        XCTAssertEqual(sut.loadedTask(targetID)?.title, "Allowed Again")
    }

    // MARK: - 5. External sleep timer from last activity & readiness signal

    func testExternalSleepTimerAndReadinessSignal() async throws {
        // Readiness evaluation across all 5 states
        XCTAssertEqual(
            ExternalAutovisorReadiness.evaluate(
                hasRealWorkFolder: true,
                isFolderTransitionInProgress: true,
                isFolderInUseByAnotherProcess: false,
                autovisorEnabled: true,
                driver: .externalAgent
            ).state,
            .folderTransition
        )
        XCTAssertEqual(
            ExternalAutovisorReadiness.evaluate(
                hasRealWorkFolder: false,
                isFolderTransitionInProgress: false,
                isFolderInUseByAnotherProcess: false,
                autovisorEnabled: true,
                driver: .externalAgent
            ).state,
            .noWorkFolder
        )
        XCTAssertEqual(
            ExternalAutovisorReadiness.evaluate(
                hasRealWorkFolder: true,
                isFolderTransitionInProgress: false,
                isFolderInUseByAnotherProcess: false,
                autovisorEnabled: false,
                driver: .externalAgent
            ).state,
            .autovisorDisabled
        )
        XCTAssertEqual(
            ExternalAutovisorReadiness.evaluate(
                hasRealWorkFolder: true,
                isFolderTransitionInProgress: false,
                isFolderInUseByAnotherProcess: false,
                autovisorEnabled: true,
                driver: .builtInModel
            ).state,
            .builtInDriver
        )
        let ready = ExternalAutovisorReadiness.evaluate(
            hasRealWorkFolder: true,
            isFolderTransitionInProgress: false,
            isFolderInUseByAnotherProcess: false,
            autovisorEnabled: true,
            driver: .externalAgent
        )
        XCTAssertEqual(ready.state, .ready)
        XCTAssertTrue(ready.allowsWrites)
        XCTAssertNil(ready.reason)
        XCTAssertNil(ready.whatThePersonMustDo)

        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder {
            $0.settings.autovisorEnabled = true
            $0.settings.autovisorDriver = .externalAgent
            $0.settings.autovisorActivation.autoDisableEnabled = true
            $0.settings.autovisorActivation.autoDisableAfterSeconds = 1800
        }
        XCTAssertEqual(sut.externalAutovisorReadiness.state, .ready)

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        sut.rearmAutovisorAutoDisable(now: t0)
        XCTAssertEqual(sut.autovisorAutoDisableAt, t0.addingTimeInterval(1800))

        // Authenticated external activity pushes the sleep-timer deadline forward from `t1`.
        let t1 = t0.addingTimeInterval(600)
        sut.noteExternalAutovisorActivity(now: t1)
        XCTAssertEqual(sut.lastExternalAutovisorActivityAt, t1)
        XCTAssertEqual(sut.autovisorAutoDisableAt, t1.addingTimeInterval(1800))

        // Readiness signal wakes a suspended waiter when driver changes.
        let waiterTask = Task { @MainActor in
            await sut.externalAutovisorReadinessSignal.wait()
        }
        await Task.yield()
        XCTAssertEqual(sut.externalAutovisorReadinessSignal.waiterCount, 1)

        await sut.setAutovisorDriver(.builtInModel)
        let wakeReason = await waiterTask.value
        XCTAssertEqual(wakeReason, .driverChanged)
        XCTAssertEqual(sut.externalAutovisorReadinessSignal.waiterCount, 0)
    }

    // MARK: - 6. Auto-off under the external driver: a wait in progress is the agent at work

    // Found in a live External Autovisor session on 2026-11-08. Activity was noted only when a
    // call STARTED and the minute tick never asked whether a wait was parked, so with auto-off at
    // its 60-second floor and a wait of up to an hour, the timer turned the Autovisor off under a
    // parked wait — which woke it with `not_ready`, and the instructions tell the agent to stop
    // polling on that. And the "while tasks still needed it" banner read the BUILT-IN manager's
    // id, nil under this driver, so the person was never told the agent's tasks were waiting.

    private func openFolderWithAutoOff(driver: AutovisorDriver, seconds: TimeInterval = 60) async {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder {
            $0.settings.autovisorEnabled = true
            $0.settings.autovisorDriver = driver
            $0.settings.autovisorActivation.autoDisableEnabled = true
            $0.settings.autovisorActivation.autoDisableAfterSeconds = seconds
        }
    }

    /// Parks a wait of `sampleAgent` in the open folder and returns once it is parked.
    private func parkAWait() async -> Task<AutovisorWaitResult, Never> {
        let wait = Task { @MainActor in
            await self.sut.autovisorEventFeed.waitForEvents(agentID: self.sampleAgent.id, timeoutSeconds: 30)
        }
        for _ in 0..<200 where sut.autovisorEventFeed.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "premise: the wait is parked")
        return wait
    }

    /// One of the agent's tasks — or the person's, with `origin: nil` — parked on a question.
    private func createTaskWaitingOnAQuestion(origin: TaskOrigin?) async throws -> Int {
        let created = await sut.createTask(
            title: "Waiting", supervisorTask: "Brief", makeActive: false, origin: origin)
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "eng", role: .softwareEngineer, title: "Engineer", status: .needsSupervisorInput,
                    needsSupervisorInput: true, supervisorQuestion: "Which database?")],
                roleStatuses: ["eng": .working])]
        }
        return taskID
    }

    func testExternalDriver_aWaitInProgressAtTheDeadline_reArmsInsteadOfTurningOff() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        sut.noteExternalAutovisorActivity(now: t0)
        XCTAssertEqual(sut.autovisorAutoDisableAt, t0.addingTimeInterval(60), "premise: armed from the call")
        let wait = await parkAWait()

        let tick = t0.addingTimeInterval(3_000)
        await sut.evaluateAutovisorAutoDisable(now: tick)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, true, "the agent is waiting — that is it supervising")
        XCTAssertEqual(sut.lastExternalAutovisorActivityAt, tick, "the parked wait is activity now")
        XCTAssertEqual(sut.autovisorAutoDisableAt, tick.addingTimeInterval(60), "re-armed from the tick")
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "the wait was left alone")

        wait.cancel()
        let result = await wait.value
        XCTAssertNil(result.stopReason, "nothing ended the wait but its own cancellation")
    }

    /// Without a wait the timer does what it always did.
    func testExternalDriver_withNoWaitInProgress_theDeadlineStillTurnsItOff() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        sut.autovisorAutoDisableAt = deadline

        await sut.evaluateAutovisorAutoDisable(now: deadline)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false)
    }

    /// A long call counts from its END: the time the agent spent inside it is not inactivity.
    func testExternalDriver_aCallThatEnds_countsTheDeadlineFromItsEnd() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.waitForEvents,
            args: ["timeout_seconds": 1],
            agent: sampleAgent,
            now: t0)

        XCTAssertFalse(result.isError, result.outputJSON)
        let ended = try XCTUnwrap(sut.lastExternalAutovisorActivityAt)
        XCTAssertGreaterThanOrEqual(ended.timeIntervalSince(t0), 0.9, "the wait ran its second; its end is the activity")
        XCTAssertLessThan(ended.timeIntervalSince(t0), 30)
        XCTAssertEqual(sut.autovisorAutoDisableAt, ended.addingTimeInterval(60))
    }

    /// The end of a call that began in another folder is not activity in this one.
    func testExternalDriver_aCallWhoseFolderChanged_notesNoActivityInTheNextFolder() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        let secondDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NTMSAutoOffFolderB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondDir) }

        let call = Task { @MainActor in
            await self.sut.executeExternalAutovisorTool(
                name: ExternalAutovisorToolNames.waitForEvents,
                args: ["timeout_seconds": 30],
                agent: self.sampleAgent,
                now: Date(timeIntervalSince1970: 1_700_000_000))
        }
        for _ in 0..<200 where sut.autovisorEventFeed.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "premise: the call's wait is parked")
        await sut.openWorkFolder(secondDir)
        _ = await call.value

        XCTAssertNil(sut.lastExternalAutovisorActivityAt, "folder B saw no call of its own")
    }

    // MARK: Turning it back on

    // Review of 2026-11-08 (older than the branch): the external count resumed from the agent's
    // last call — written by every call, refused ones too, and cleared only by a folder switch.
    // After auto-off the agent is told to stop polling and goes quiet, so by the time the person
    // turns the Autovisor back on that call is usually longer ago than the whole timer: the
    // deadline was already behind, and the next minute tick turned it off again before the agent
    // had been told it could go on.

    /// Turning the Autovisor on starts the count at that moment: before it, nothing waited on the
    /// agent, so the quiet since its last call is not inactivity.
    func testExternalDriver_enablingAfterALongQuiet_countsFromTheEnable() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        sut.noteExternalAutovisorActivity(now: Date().addingTimeInterval(-3_600))
        await sut.setAutovisorEnabled(false)

        let before = Date()
        await sut.setAutovisorEnabled(true)
        let after = Date()

        let deadline = try XCTUnwrap(sut.autovisorAutoDisableAt)
        XCTAssertGreaterThanOrEqual(deadline, before.addingTimeInterval(60), "counted from the enable, not from an hour-old call")
        XCTAssertLessThanOrEqual(deadline, after.addingTimeInterval(60))

        await sut.evaluateAutovisorAutoDisable(now: after)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, true, "the tick right after the enable leaves it on")

        await sut.evaluateAutovisorAutoDisable(now: deadline)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false, "and the timer runs from the enable")
    }

    /// The later of the two: an activity later than the enable — the end of a call whose clock
    /// runs a beat ahead — is still where the count starts.
    func testExternalDriver_enablingBeforeALaterActivity_keepsTheLater() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        await sut.setAutovisorEnabled(false)
        let later = Date().addingTimeInterval(600)
        sut.noteExternalAutovisorActivity(now: later)

        await sut.setAutovisorEnabled(true)

        XCTAssertEqual(sut.autovisorAutoDisableAt, later.addingTimeInterval(60))
        XCTAssertEqual(sut.lastExternalAutovisorActivityAt, later)
    }

    /// Handing a running Autovisor to the external agent starts the agent's count at the switch,
    /// whatever its last call — refused while the built-in model drove — said.
    func testSwitchingToTheExternalDriverAfterALongQuiet_countsFromTheSwitch() async throws {
        await openFolderWithAutoOff(driver: .builtInModel)
        sut.noteExternalAutovisorActivity(now: Date().addingTimeInterval(-3_600))

        let before = Date()
        await sut.setAutovisorDriver(.externalAgent)
        let after = Date()

        let deadline = try XCTUnwrap(sut.autovisorAutoDisableAt)
        XCTAssertGreaterThanOrEqual(deadline, before.addingTimeInterval(60), "counted from the switch")
        XCTAssertLessThanOrEqual(deadline, after.addingTimeInterval(60))
        await sut.evaluateAutovisorAutoDisable(now: after)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, true)
    }

    /// Re-selecting the driver the folder already has is no switch: the count goes on.
    func testReselectingTheExternalDriver_leavesTheCountAlone() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        let lastCall = Date().addingTimeInterval(-30)
        sut.noteExternalAutovisorActivity(now: lastCall)

        await sut.setAutovisorDriver(.externalAgent)

        XCTAssertEqual(sut.autovisorAutoDisableAt, lastCall.addingTimeInterval(60))
        XCTAssertEqual(sut.lastExternalAutovisorActivityAt, lastCall)
    }

    /// Turning it OFF starts nothing: the deadline is cleared, and the agent's last call stays
    /// where it was.
    func testExternalDriver_disablingLeavesTheAgentsLastCallAlone() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        let lastCall = Date().addingTimeInterval(-30)
        sut.noteExternalAutovisorActivity(now: lastCall)

        await sut.setAutovisorEnabled(false)

        XCTAssertNil(sut.autovisorAutoDisableAt)
        XCTAssertEqual(sut.lastExternalAutovisorActivityAt, lastCall)
    }

    /// The built-in manager's timer is a sleep timer from ENABLE, not an inactivity timer: an
    /// external wait parked in its folder holds nothing off.
    func testBuiltInDriver_aWaitInProgressDoesNotHoldOffTheTimer() async throws {
        await openFolderWithAutoOff(driver: .builtInModel)
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        sut.autovisorAutoDisableAt = deadline
        let wait = await parkAWait()

        await sut.evaluateAutovisorAutoDisable(now: deadline)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false)
        let result = await wait.value
        XCTAssertEqual(result.stopReason, .notReady, "turning off ends the wait, as it always did")
    }

    // MARK: Banner

    func testExternalDriver_autoOffBanner_saysTheAgentsTasksStillNeededIt() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        _ = try await createTaskWaitingOnAQuestion(origin: .externalAgent(sampleAgent))
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        sut.autovisorAutoDisableAt = deadline

        await sut.evaluateAutovisorAutoDisable(now: deadline)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false)
        XCTAssertTrue(
            sut.lastInfoMessage?.contains("still needed") ?? false,
            "the agent's task was waiting on a question: \(sut.lastInfoMessage ?? "nil")")
    }

    /// Under this driver the agent supervises only its own tasks; the person's are theirs.
    func testExternalDriver_autoOffBanner_staysQuietAboutThePersonsOwnTasks() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        _ = try await createTaskWaitingOnAQuestion(origin: nil)
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        sut.autovisorAutoDisableAt = deadline

        await sut.evaluateAutovisorAutoDisable(now: deadline)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false)
        XCTAssertFalse(sut.lastInfoMessage?.contains("still needed") ?? true, sut.lastInfoMessage ?? "nil")
        XCTAssertTrue(sut.lastInfoMessage?.contains("Autovisor turned off") ?? false, sut.lastInfoMessage ?? "nil")
    }

    // Review of 2026-11-08: the external banner kept its own list of what asks something of the
    // agent — a question, a failure, a review, a gate, a stall — and it had no pause, while the
    // feed wakes the agent for every pause and `wait_for_events` says `timed_out`,
    // `iteration_limit` and `recovered` each need the agent's remedy. A task stopped at its
    // iteration limit, waiting for the agent's `control_task resume`, read as nothing pending.
    // The banner now reads the conditions the feed reports.

    /// One of the agent's tasks, its run paused for `cause` — stamped `timedOutAt` too when the
    /// run timeout made the pause, as the watchdog does.
    private func createAgentTask(pausedBy cause: Run.PauseCause) async throws -> Int {
        let created = await sut.createTask(
            title: "Paused", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(sampleAgent))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            var run = Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .paused)],
                roleStatuses: ["eng": .working])
            run.pauseCause = cause
            if cause == .runTimedOut { run.timedOutAt = MonotonicClock.shared.now() }
            task.runs = [run]
        }
        return taskID
    }

    /// The tick at the deadline, with nothing waiting: the Autovisor turns off and the banner says
    /// which way.
    private func turnOffAtTheDeadline() async -> String {
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        sut.autovisorAutoDisableAt = deadline
        await sut.evaluateAutovisorAutoDisable(now: deadline)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false, "premise: the timer turned it off")
        return sut.lastInfoMessage ?? "nil"
    }

    func testExternalDriver_autoOffBanner_countsAnIterationLimitPause() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        _ = try await createAgentTask(pausedBy: .iterationLimit)

        let message = await turnOffAtTheDeadline()

        XCTAssertTrue(message.contains("still needed"), "the task waits for the agent to resume it: \(message)")
    }

    func testExternalDriver_autoOffBanner_countsARunTimeoutPause() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        _ = try await createAgentTask(pausedBy: .runTimedOut)

        let message = await turnOffAtTheDeadline()

        XCTAssertTrue(message.contains("still needed"), message)
    }

    /// A run a quit interrupted waits for the agent too — it is the one told `recovered`.
    func testExternalDriver_autoOffBanner_countsAPauseARelaunchMade() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        _ = try await createAgentTask(pausedBy: .recovered)

        let message = await turnOffAtTheDeadline()

        XCTAssertTrue(message.contains("still needed"), message)
    }

    /// A Pause somebody pressed on purpose — the person's, or the agent's own — is theirs to lift.
    func testExternalDriver_autoOffBanner_staysQuietAboutAPauseByThePerson() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        _ = try await createAgentTask(pausedBy: .requested)

        let message = await turnOffAtTheDeadline()

        XCTAssertFalse(message.contains("still needed"), message)
        XCTAssertTrue(message.contains("Autovisor turned off"), message)
    }

    /// A closed task is reported to the agent, but it asks nothing of it.
    func testExternalDriver_autoOffBanner_staysQuietAboutAClosedTask() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        let created = await sut.createTask(
            title: "Closed", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(sampleAgent))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .done)],
                roleStatuses: ["eng": .accepted])]
            task.closedAt = MonotonicClock.shared.now()
        }
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first { $0.id == taskID }?.status, .done, "premise: closed")

        let message = await turnOffAtTheDeadline()

        XCTAssertFalse(message.contains("still needed"), message)
    }

    /// A stall counts as the agent hears of it: the feed's stuck episode, recorded by the minute
    /// tick, is what `wait_for_events` reports and what the banner reads.
    func testExternalDriver_autoOffBanner_countsAStallTheFeedReports() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        let created = await sut.createTask(
            title: "Stalled", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(sampleAgent))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .running)],
                roleStatuses: ["eng": .working])]
        }
        sut.autovisorEventFeed.recordStuckTasks([taskID])

        let message = await turnOffAtTheDeadline()

        XCTAssertTrue(message.contains("still needed"), message)
    }

    /// A manager task left over from the built-in driver must not make the external banner count
    /// the person's tasks through the BUILT-IN activation rules.
    func testExternalDriver_aLeftoverManagerDoesNotMakeThePersonsTasksCount() async throws {
        await openFolderWithAutoOff(driver: .externalAgent)
        let manager = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)
        let managerID = try XCTUnwrap(manager)
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = managerID }
        // Loaded, so the disable's write to the manager's recurrence lands and the banner shows.
        await sut.ensureTaskLoaded(managerID)
        _ = try await createTaskWaitingOnAQuestion(origin: nil)
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        sut.autovisorAutoDisableAt = deadline

        await sut.evaluateAutovisorAutoDisable(now: deadline)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false)
        XCTAssertTrue(sut.lastInfoMessage?.contains("Autovisor turned off") ?? false, sut.lastInfoMessage ?? "nil")
        XCTAssertFalse(sut.lastInfoMessage?.contains("still needed") ?? true, sut.lastInfoMessage ?? "nil")
    }
}
