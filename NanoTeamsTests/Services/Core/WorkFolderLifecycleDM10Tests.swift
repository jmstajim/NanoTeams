import XCTest

@testable import NanoTeams

/// Behavioural tests for `DEBTS.md` D-M10 items 1–11: work-folder lifecycle boundary
/// races across change requests, engine role-task launches, retried team generation,
/// `restartRun`, delegated supervisor side-exchanges, `resetWorkFolderSettings`,
/// failed queue flushes, `delegate_to_team` generation cards, mid-transition role
/// control verbs, Watchtower dismissal retirement, and same-folder reopen queue drain.
@MainActor
final class WorkFolderLifecycleDM10Tests: WorkFolderLifecycleTestCase {

    private var formState: QuickCaptureFormState!
    private var controller: QuickCaptureController!
    private var teamGenerationClient: HeldTeamGenerationClient!

    override func tearDown() async throws {
        teamGenerationClient?.release(with: .failure(URLError(.cannotConnectToHost)))
        teamGenerationClient = nil
        controller = nil
        formState = nil
        try await super.tearDown()
    }

    private func taskJSON(_ folder: URL, _ taskID: Int) -> URL {
        NTMSPaths(workFolderRoot: folder).taskJSON(taskID: taskID)
    }

    private func waitUntil(
        _ what: String, line: UInt = #line, _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("\(what) never happened", line: line)
    }

    // MARK: - 1. Approved request_changes across folder switch (D-M10.1)

    func testApprovedChangeRequestStraddlingAnOpenLeavesTheNextFolderUntouched() async throws {
        let targetID = "team_pm"
        let requesterID = "team_swe"
        let chairID = "team_tpm"
        let downstreamID = "team_uxd"
        let team = Self.makeChangeRequestTeam(
            targetID: targetID, requesterID: requesterID, chairID: chairID, downstreamID: downstreamID
        )

        await sut.openWorkFolder(folderB)
        await sut.mutateWorkFolder { $0.teams = [team]; $0.state.activeTeamID = team.id }
        let bCreated = await sut.createTask(
            title: "B task", supervisorTask: "build B", preferredTeamID: team.id, makeActive: true
        )
        let bOne = try XCTUnwrap(bCreated)
        _ = await sut.ensureTaskLoaded(bOne)
        await sut.mutateTask(taskID: bOne) { task in
            task.runs = [Self.makeChangeRequestRun(
                targetID: targetID, requesterID: requesterID, downstreamID: downstreamID
            )]
        }

        await sut.openWorkFolder(folderA)
        await sut.mutateWorkFolder { $0.teams = [team]; $0.state.activeTeamID = team.id }
        let aCreated = await sut.createTask(
            title: "A task", supervisorTask: "build A", preferredTeamID: team.id, makeActive: true
        )
        let aOne = try XCTUnwrap(aCreated)
        XCTAssertEqual(aOne, bOne, "premise: both folders number their first task the same")
        _ = await sut.ensureTaskLoaded(aOne)
        await sut.mutateTask(taskID: aOne) { task in
            task.runs = [Self.makeChangeRequestRun(
                targetID: targetID, requesterID: requesterID, downstreamID: downstreamID
            )]
        }
        let aTaskSnapshot = try XCTUnwrap(sut.loadedTask(aOne))
        sut.llmExecutionService._testRegisterStepTask(stepID: requesterID, taskID: aOne)

        let pathA = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == pathA && task.id == aOne && !(task.runs.last?.changeRequests.isEmpty ?? true)
        }
        repository.taskWriteHold = write

        let voteClient = ScriptedSingleTurnLLMClient(response: "Approve this change.\nVOTE: APPROVE")
        let call = Task {
            await sut.llmExecutionService.handleChangeRequest(
                stepID: requesterID,
                targetRoleID: targetID,
                changes: "Tighten validation",
                reasoning: "Edge cases were missed",
                requestingRole: .softwareEngineer,
                task: aTaskSnapshot,
                runIndex: 0,
                stepIndex: 0,
                client: voteClient,
                config: LLMConfig()
            )
        }
        try await waitHeld(write, "recordChangeRequest write in folder A")

        await sut.openWorkFolder(folderB)
        _ = await sut.ensureTaskLoaded(bOne)
        sut.llmExecutionService._testRegisterStepTask(stepID: downstreamID, taskID: bOne)
        let bBefore = try Data(contentsOf: taskJSON(folderB, bOne))

        write.release()
        let reply = await call.value

        XCTAssertFalse(reply.succeeded, "superseded change request must report failure; got: \(reply.text)")
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, bOne)), bBefore,
                       "the superseded change request mutated folder B's task.json")
        XCTAssertEqual(sut.loadedTask(bOne)?.runs.last?.roleStatuses[targetID], .done,
                       "folder B's target role was flipped to .revisionRequested")
        XCTAssertTrue(sut.llmExecutionService.isExecutionLive(stepID: downstreamID, taskID: bOne),
                      "folder B's running downstream step was cancelled by holdDownstreamForRevision")
    }

    // MARK: - 2. Engine role-task start across folder switch (D-M10.2)

    func testEngineRoleTaskStraddlingAnOpenStartsNothingInTheNextFolder() async throws {
        let roleID = "worker"
        let team = Team(
            id: "single_worker_team",
            name: "Single Worker",
            roles: [TeamRoleDefinition(
                id: roleID, name: "Worker", prompt: "work", toolIDs: [],
                usePlanningPhase: false, dependencies: RoleDependencies(),
                systemRoleID: Role.softwareEngineer.baseID
            )],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )

        await sut.openWorkFolder(folderB)
        await sut.mutateWorkFolder { $0.teams = [team]; $0.state.activeTeamID = team.id }
        let bCreated = await sut.createTask(
            title: "B one", supervisorTask: "b", preferredTeamID: team.id, makeActive: true
        )
        let bOne = try XCTUnwrap(bCreated)
        _ = await sut.ensureTaskLoaded(bOne)
        await sut.mutateTask(taskID: bOne) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: roleID, role: .softwareEngineer, title: "Worker", status: .paused)],
                roleStatuses: [roleID: .idle]
            )]
        }

        await sut.openWorkFolder(folderA)
        await sut.mutateWorkFolder { $0.teams = [team]; $0.state.activeTeamID = team.id }
        let aCreated = await sut.createTask(
            title: "A one", supervisorTask: "a", preferredTeamID: team.id, makeActive: true
        )
        let aOne = try XCTUnwrap(aCreated)
        XCTAssertEqual(aOne, bOne)
        _ = await sut.ensureTaskLoaded(aOne)
        await sut.mutateTask(taskID: aOne) { task in
            task.runs = [Run(id: 0, steps: [], roleStatuses: [roleID: .idle])]
        }

        let pathA = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == pathA && task.id == aOne && !(task.runs.last?.steps.isEmpty ?? true)
        }
        repository.taskWriteHold = write

        let engine = sut.engineForTask(aOne)
        _ = await engine.startRoles(roleIDs: [roleID])
        let roleTask = try XCTUnwrap(engine.roleTasks[roleID])
        try await waitHeld(write, "findOrCreateStep write in folder A")

        await sut.openWorkFolder(folderB)
        _ = await sut.ensureTaskLoaded(bOne)
        let bBefore = try Data(contentsOf: taskJSON(folderB, bOne))

        write.release()
        await roleTask.value

        XCTAssertFalse(sut.llmExecutionService.isStepRunning(stepID: roleID, taskID: bOne),
                       "superseded engine role-task started a step execution in folder B")
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, bOne)), bBefore,
                       "superseded engine role-task mutated folder B's task.json")
        XCTAssertEqual(sut.loadedTask(bOne)?.runs.last?.steps.first?.status, .paused,
                       "folder B's step status was altered by folder A's engine")
        await sut.runStep(stepID: "missing-step", taskID: bOne)
    }

    // MARK: - 3. Retried team generation reservation across folder switch (D-M10.3)

    func testRetriedTeamGenerationStraddlingAnOpenDoesNotBlockTheNextFoldersTask() async throws {
        teamGenerationClient = HeldTeamGenerationClient()
        sut = TestOrchestrator.make(repository: repository, teamGenerationClient: teamGenerationClient)

        await sut.openWorkFolder(folderB)
        let bCreated = await sut.createTask(title: "B one", supervisorTask: "b", makeActive: true)
        let bOne = try XCTUnwrap(bCreated)

        await sut.openWorkFolder(folderA)
        await sut.mutateWorkFolder { project in
            guard !project.teams.contains(where: { $0.isGeneratedPlaceholder }) else { return }
            project.teams.append(TeamTemplateFactory.generatedTeam())
        }
        let template = try XCTUnwrap(sut.workFolder?.teams.first { $0.isGeneratedPlaceholder })
        let aCreated = await sut.createTask(
            title: "A gen", supervisorTask: "build calculator", preferredTeamID: template.id, makeActive: true
        )
        let aOne = try XCTUnwrap(aCreated)
        XCTAssertEqual(aOne, bOne)
        _ = await sut.ensureTaskLoaded(aOne)
        await sut.mutateTask(taskID: aOne) { task in
            task.runs = [Run(id: 0)]
        }

        let client = try XCTUnwrap(teamGenerationClient)
        let retryTask = Task { await sut.retryTeamGeneration(taskID: aOne) }
        try await waitUntil("retryTeamGeneration reached LLM client") { client.requested }
        XCTAssertTrue(sut.isGeneratingTeam(taskID: aOne), "premise: retry reserved generation in folder A")

        await sut.openWorkFolder(folderB)
        _ = await sut.ensureTaskLoaded(bOne)

        XCTAssertFalse(sut.isGeneratingTeam(taskID: bOne),
                       "folder A's retry reservation leaked into folder B for the same task ID")
        await sut.startRun(taskID: bOne)
        XCTAssertEqual(sut.loadedTask(bOne)?.runs.count, 1,
                       "folder B's task of the same ID was blocked from starting a run")

        client.release(with: .failure(URLError(.cancelled)))
        await retryTask.value
        sut.stopAllEngines()
    }

    // MARK: - 4. restartRun across folder switch (D-M10.4)

    func testRestartRunStraddlingAnOpenStartsNothingInTheNextFolder() async throws {
        await sut.openWorkFolder(folderB)
        let bCreated = await sut.createTask(title: "B one", supervisorTask: "b", makeActive: true)
        let bOne = try XCTUnwrap(bCreated)

        await sut.openWorkFolder(folderA)
        let aCreated = await sut.createTask(title: "A one", supervisorTask: "a", makeActive: true)
        let aOne = try XCTUnwrap(aCreated)
        XCTAssertEqual(aOne, bOne)
        _ = await sut.ensureTaskLoaded(aOne)
        await sut.mutateTask(taskID: aOne) { task in
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .running)]
            task.runs = [run]
        }
        sut.engineState[aOne] = .running

        let pathA = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == pathA && task.id == aOne
                && task.runs.last?.steps.contains { $0.status == .paused } == true
        }
        repository.taskWriteHold = write

        let restart = Task { await sut.restartRun(taskID: aOne) }
        try await waitHeld(write, "restartRun's pause write in folder A")

        await sut.openWorkFolder(folderB)
        _ = await sut.ensureTaskLoaded(bOne)
        let bBefore = try Data(contentsOf: taskJSON(folderB, bOne))

        write.release()
        await restart.value
        await sut.drainRunStartLaunches()

        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, bOne)), bBefore,
                       "restartRun begun in folder A materialized a run on folder B's task")
        XCTAssertEqual(sut.loadedTask(bOne)?.runs.count ?? 0, 0,
                       "restartRun started a run in folder B")
        XCTAssertTrue(sut.taskEngines.isEmpty, "restartRun created an engine in folder B")

        // Within the current folder, `restartRun` proceeds through to `startRun`.
        await sut.restartRun(taskID: bOne)
        XCTAssertEqual(sut.loadedTask(bOne)?.runs.count, 1)
        sut.stopAllEngines()
    }

    // MARK: - 5. Delegated supervisor side-exchange cancellation & folder switch (D-M10.5)

    func testDelegatedSupervisorAnswerCancelledOrStraddlingAnOpenDeliversNothing() async throws {
        await sut.openWorkFolder(folderA)
        let parentCreated = await sut.createTask(title: "Parent", supervisorTask: "p", makeActive: true)
        let parentID = try XCTUnwrap(parentCreated)
        let parentTeam = try XCTUnwrap(sut.workFolder?.teams.first)
        let parentRoleID = try XCTUnwrap(parentTeam.roles.first { !$0.isSupervisor }?.id)
        let childCreated = await sut.createDelegatedTask(
            parentTaskID: parentID,
            parentRoleID: parentRoleID,
            title: "Child",
            supervisorTask: "c",
            preferredTeamID: parentTeam.id,
            depth: 1
        )
        let childID = try XCTUnwrap(childCreated)
        _ = await sut.ensureTaskLoaded(parentID)
        _ = await sut.ensureTaskLoaded(childID)

        await sut.mutateTask(taskID: parentID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: parentRoleID, role: .codingAgent, title: "Parent", status: .running)],
                roleStatuses: [parentRoleID: .working]
            )]
        }
        await sut.mutateTask(taskID: childID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "child_worker", role: .softwareEngineer, title: "Child",
                    status: .needsSupervisorInput, needsSupervisorInput: true,
                    supervisorQuestion: "Which port?"
                )],
                roleStatuses: ["child_worker": .working]
            )]
        }

        let streamHold = HeldAncillaryStreamClient(partialChunk: "Use port 8080")
        let answering = Task {
            await DelegatedSupervisorAnswerService.handleChildQuestion(
                childTID: childID,
                parentTaskID: parentID,
                parentRoleID: parentRoleID,
                parentTeam: parentTeam,
                targetTeamName: parentTeam.name,
                client: streamHold,
                globalConfig: LLMConfig(),
                delegate: sut
            )
        }
        try await waitUntil("ancillary stream started") { streamHold.started }

        answering.cancel()
        streamHold.finishNormally()
        let delivered = await answering.value

        XCTAssertFalse(delivered, "cancelled parent exchange must not report delivery")
        XCTAssertNil(sut.loadedTask(childID)?.runs.last?.steps.first?.supervisorAnswer,
                     "cancelled parent exchange delivered a truncated answer to the child step")
    }

    // MARK: - 6. resetWorkFolderSettings transitions folder lifecycle (D-M10.6)

    func testResetWorkFolderSettingsEndsTheFolderLifecycle() async throws {
        await sut.openWorkFolder(folderA)
        let aCreated = await sut.createTask(title: "A one", supervisorTask: "a", makeActive: true)
        let aOne = try XCTUnwrap(aCreated)
        sut.llmExecutionService._testRegisterStepTask(stepID: "worker", taskID: aOne)
        let lifecycleBeforeReset = sut.currentFolderLifecycle

        await sut.resetWorkFolderSettings()

        XCTAssertFalse(sut.isCurrentFolderLifecycle(lifecycleBeforeReset),
                       "resetWorkFolderSettings must end the previous folder lifecycle")
        XCTAssertFalse(sut.isFolderTransitionInProgress,
                       "resetWorkFolderSettings must commit the new folder lifecycle")
        XCTAssertFalse(sut.llmExecutionService.isExecutionLive(stepID: "worker", taskID: aOne),
                       "resetWorkFolderSettings must cancel in-flight step executions")

        let postResetCreated = await sut.createTask(title: "Fresh #1", supervisorTask: "fresh", makeActive: true)
        let freshOne = try XCTUnwrap(postResetCreated)
        let verdict = await sut.performAutovisorAction(
            .controlTask(taskID: freshOne, verb: .delete),
            within: lifecycleBeforeReset
        )
        XCTAssertEqual(verdict, AutovisorActionResult.failure(DeferredCallReplies.folderChanged),
                       "an action holding the pre-reset lifecycle must refuse to touch the reset folder")
        XCTAssertNotNil(sut.loadedTask(freshOne), "pre-reset action deleted the new task #1")
    }

    // MARK: - 7. Failed/straddling queue flush across folder switch (D-M10.7)

    func testQueueFlushStraddlingAnOpenNeitherRequeuesNorBannersInTheNextFolder() async throws {
        await sut.openWorkFolder(folderB)
        let bCreated = await sut.createTask(title: "B one", supervisorTask: "b", makeActive: true)
        let bOne = try XCTUnwrap(bCreated)

        await sut.openWorkFolder(folderA)
        let aCreated = await sut.createTask(title: "A one", supervisorTask: "a", makeActive: true)
        let aOne = try XCTUnwrap(aCreated)
        XCTAssertEqual(aOne, bOne)
        let roleID = try XCTUnwrap(sut.workFolder?.teams.first?.roles.first { !$0.isSupervisor }?.id)
        _ = await sut.ensureTaskLoaded(aOne)
        await sut.mutateTask(taskID: aOne) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: roleID, role: .softwareEngineer, title: "Worker",
                    status: .needsSupervisorInput, needsSupervisorInput: true,
                    supervisorQuestion: "Proceed?"
                )],
                roleStatuses: [roleID: .working]
            )]
        }
        sut.engineState[aOne] = .needsSupervisorInput
        sut.configuration.embedFilesInPrompt = true

        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState
        controller = QuickCaptureController(formState: formState, storage: InMemoryConfigurationStorage())
        controller.store = sut

        let binURL = folderA.appendingPathComponent("binary.bin")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: binURL)
        let missingAttachment = try StagedAttachment(
            url: binURL,
            stagedRelativePath: "binary.bin",
            isProjectReference: true
        )
        let msg = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "yes proceed", attachments: [missingAttachment], clippedTexts: [], targetRoleID: nil
        ))
        formState.appendQueuedMessage(msg, for: aOne)

        let pathA = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == pathA && task.id == aOne
                && task.runs.last?.steps.first?.supervisorAnswer != nil
        }
        repository.taskWriteHold = write

        controller.tryFlushQueuedMessages()
        try await waitHeld(write, "flushQueuedChatMessage's answerSupervisorQuestion write in A")

        await sut.openWorkFolder(folderB)
        sut.lastErrorMessage = nil

        write.release()
        await controller._testAwaitPendingFlushes()

        XCTAssertTrue(formState.queuedMessages(for: bOne).isEmpty,
                      "superseded flush re-queued folder A's message into folder B")
        XCTAssertNil(sut.lastErrorMessage,
                     "superseded flush surfaced an error banner in folder B's session")
    }

    // MARK: - 8. delegate_to_team create_team card on cancellation & recovery (D-M10.8)

    func testDelegateToTeamCancellationAndRecoveryCloseCreateTeamCardWithoutBanner() async throws {
        await sut.openWorkFolder(folderA)
        let roleID = "coding_agent"
        var parentRole = TeamRoleDefinition(
            id: roleID, name: "Coding Agent", prompt: "code",
            toolIDs: [ToolNames.delegateToTeam], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: Role.codingAgent.baseID
        )
        parentRole.allowDelegationToGeneratedTeams = true
        let team = Team(
            id: "delegating_team", name: "Delegating Team",
            roles: [parentRole], artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        await sut.mutateWorkFolder { $0.teams.append(team); $0.state.activeTeamID = team.id }
        let created = await sut.createTask(
            title: "Parent", supervisorTask: "delegate", preferredTeamID: team.id, makeActive: true
        )
        let taskID = try XCTUnwrap(created)
        _ = await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: roleID, role: .codingAgent, title: "Coding Agent", status: .running)],
                roleStatuses: [roleID: .working]
            )]
        }
        let initialTask = try XCTUnwrap(sut.loadedTask(taskID))
        let llmService = sut.llmExecutionService
        llmService._testRegisterStepTask(stepID: roleID, taskID: taskID)
        sut.lastErrorMessage = nil

        // Simulate user Pause during team generation (`cancelStepExecution` cancels the
        // running step Task and awaits it BEFORE clearing `executionStates[key]`, so
        // `stillLive()` remains true while `streamChat` throws `CancellationError`).
        let cancellingClient = CancellingOnStreamLLMClient {}
        _ = await llmService.handleDelegateToTeam(
            stepID: roleID,
            teamIDRaw: DelegationConstants.generatedTeamSentinel,
            taskBrief: "Build helper",
            initiatingRole: .codingAgent,
            task: initialTask,
            runIndex: 0,
            stepIndex: 0,
            client: cancellingClient,
            config: LLMConfig()
        )

        let cardAfterCancel = try XCTUnwrap(
            sut.loadedTask(taskID)?.runs.last?.steps.first?.toolCalls.first { $0.name == ToolNames.createTeam }
        )
        XCTAssertFalse(cardAfterCancel.isGeneratingTeam,
                       "cancelled delegate_to_team left create_team card stuck in status:generating")
        XCTAssertEqual(cardAfterCancel.isError, true)
        XCTAssertNil(sut.lastErrorMessage,
                     "Pause/cancellation during delegate_to_team team generation must not surface an error banner")

        // Also verify StatusRecoveryService closes a stranded generating card on a non-running step.
        var strandedTask = try XCTUnwrap(sut.loadedTask(taskID))
        strandedTask.runs[0].steps[0].status = .paused
        strandedTask.runs[0].steps[0].toolCalls = [StepToolCall(
            id: UUID(),
            name: ToolNames.createTeam,
            argumentsJSON: "{}",
            resultJSON: TeamGenerationEnvelopes.makeGeneratingEnvelope(),
            isError: false
        )]
        let recovered = StatusRecoveryService.recoverStaleStatuses(in: &strandedTask, team: team)
        XCTAssertTrue(recovered, "StatusRecoveryService must recover a stranded generating create_team card")
        let recoveredCard = try XCTUnwrap(strandedTask.runs[0].steps[0].toolCalls.first)
        XCTAssertFalse(recoveredCard.isGeneratingTeam,
                       "StatusRecoveryService left create_team card in status:generating")
        XCTAssertEqual(recoveredCard.isError, true)
    }

    // MARK: - 9. restartRole & correctRole during folder transition (D-M10.9)

    func testRestartRoleAndCorrectRoleDuringFolderTransitionRefuseCleanly() async throws {
        await sut.openWorkFolder(folderA)
        let created = await sut.createTask(title: "A one", supervisorTask: "a", makeActive: true)
        let aOne = try XCTUnwrap(created)
        let roleID = try XCTUnwrap(sut.workFolder?.teams.first?.roles.first { !$0.isSupervisor }?.id)
        _ = await sut.ensureTaskLoaded(aOne)
        await sut.mutateTask(taskID: aOne) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .done)],
                roleStatuses: [roleID: .done]
            )]
        }

        let (reopen, reopenRead) = try await startReadingOpen(of: folderA)
        XCTAssertTrue(sut.isFolderTransitionInProgress)

        sut.lastErrorMessage = nil
        await sut.restartRole(taskID: aOne, roleID: roleID, comment: nil)
        XCTAssertTrue(sut.taskEngines.isEmpty,
                      "restartRole during folder transition created a .pending engine")
        XCTAssertTrue(sut.lastErrorMessage?.lowercased().contains("switching work folders") == true,
                      "restartRole must report folder transition; got: \(String(describing: sut.lastErrorMessage))")

        sut.lastErrorMessage = nil
        await sut.correctRole(taskID: aOne, roleID: roleID, comment: "fix")
        XCTAssertTrue(sut.lastErrorMessage?.lowercased().contains("switching work folders") == true,
                      "correctRole must report folder transition instead of 'requires the task to be paused'; got: \(String(describing: sut.lastErrorMessage))")

        reopenRead.release()
        await reopen.value
    }

    // MARK: - 10. Watchtower dismissal retired for ended-lifecycle answer (D-M10.10)

    func testAnswerAcrossTheNextOpensCommitRetiresWatchtowerDismissalInOriginFolder() async throws {
        let (aOne, _) = try await sameIDTasks()
        let aFolderID = try XCTUnwrap(sut.snapshot?.projection.id)
        let roleID = try XCTUnwrap(sut.workFolder?.teams.first?.roles.first { !$0.isSupervisor }?.id)
        await sut.mutateTask(taskID: aOne) { task in
            let step = StepExecution(
                id: roleID, role: .softwareEngineer, title: "Work", status: .paused,
                needsSupervisorInput: true, supervisorQuestion: "Which one?"
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: [roleID: .working])]
        }
        let step = try XCTUnwrap(sut.loadedTask(aOne)?.runs.last?.steps.first)
        let dismissKey = try XCTUnwrap(SupervisorQuestionInbox.dismissKey(forStep: step, taskID: aOne))
        sut.configuration.dismissNotification(workFolderID: aFolderID, key: dismissKey)
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: aFolderID, key: dismissKey),
                      "premise: Watchtower banner is dismissed in folder A")

        let pathA = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == pathA && task.id == aOne
                && task.runs.last?.steps.first?.supervisorAnswer != nil
        }
        repository.taskWriteHold = write

        let answering = Task {
            await sut.answerSupervisorQuestion(stepID: roleID, taskID: aOne, answer: "the first")
        }
        try await waitHeld(write, "answerSupervisorQuestion write in folder A")

        await sut.openWorkFolder(folderB)
        write.release()
        _ = await answering.value

        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: aFolderID, key: dismissKey),
                       "answerSupervisorQuestion retired in folder A must clear folder A's Watchtower dismissal even if folder B committed during the write")
    }

    // MARK: - 11. Queued message frozen during same-folder reopen is delivered on commit (D-M10.11)

    func testQueuedMessageFrozenDuringSameFolderReopenIsDeliveredOnCommit() async throws {
        await sut.openWorkFolder(folderA)
        let aWaitingCreated = await sut.createTask(title: "Waiting background", supervisorTask: "w", makeActive: false)
        let aWaiting = try XCTUnwrap(aWaitingCreated)
        let aIdleCreated = await sut.createTask(title: "Active idle", supervisorTask: "idle", makeActive: true)
        _ = try XCTUnwrap(aIdleCreated)

        let roleID = try XCTUnwrap(sut.workFolder?.teams.first?.roles.first { !$0.isSupervisor }?.id)
        _ = await sut.ensureTaskLoaded(aWaiting)
        await sut.mutateTask(taskID: aWaiting) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: roleID, role: .softwareEngineer, title: "Worker",
                    status: .paused, needsSupervisorInput: true,
                    supervisorQuestion: "Ready to ship?"
                )],
                roleStatuses: [roleID: .working]
            )]
        }

        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState
        controller = QuickCaptureController(formState: formState, storage: InMemoryConfigurationStorage())
        controller.store = sut
        formState.appendQueuedMessage(try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "ship it now", attachments: [], clippedTexts: [], targetRoleID: nil
        )), for: aWaiting)

        let (reopen, reopenRead) = try await startReadingOpen(of: folderA)
        controller.handleEngineStateChanged()
        XCTAssertTrue(formState.hasQueuedMessage(for: aWaiting),
                      "premise: message stays frozen while same-folder reopen is reading")

        reopenRead.release()
        await reopen.value
        await controller._testAwaitPendingFlushes()

        XCTAssertFalse(formState.hasQueuedMessage(for: aWaiting),
                       "reopen commit must flush the frozen queue without waiting for an unrelated engine event")
        XCTAssertEqual(sut.loadedTask(aWaiting)?.runs.last?.steps.first?.supervisorAnswer, "ship it now",
                       "the flushed message must be delivered to the waiting background task")
    }

    // MARK: - Helpers

    private static func makeChangeRequestTeam(
        targetID: String, requesterID: String, chairID: String, downstreamID: String
    ) -> Team {
        let roles = [
            TeamRoleDefinition(
                id: targetID, name: "Product Manager", prompt: "pm", toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(producesArtifacts: ["Spec"]),
                systemRoleID: "productManager"
            ),
            TeamRoleDefinition(
                id: requesterID, name: "Software Engineer", prompt: "swe",
                toolIDs: [ToolNames.requestChanges], usePlanningPhase: false,
                dependencies: RoleDependencies(
                    requiredArtifacts: ["Spec"], producesArtifacts: ["Impl"]
                ),
                systemRoleID: "softwareEngineer"
            ),
            TeamRoleDefinition(
                id: chairID, name: "TPM", prompt: "tpm", toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(
                    requiredArtifacts: ["Impl"], producesArtifacts: ["Notes"]
                ),
                systemRoleID: "tpm"
            ),
            TeamRoleDefinition(
                id: downstreamID, name: "UX Designer", prompt: "uxd", toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(
                    requiredArtifacts: ["Spec"], producesArtifacts: ["Design"]
                ),
                systemRoleID: "uxDesigner"
            ),
        ]
        return Team(
            id: "cr_team", name: "CR Team", roles: roles, artifacts: [],
            settings: TeamSettings(limits: TeamLimits(maxMeetingTurns: 2)),
            graphLayout: TeamGraphLayout()
        )
    }

    private static func makeChangeRequestRun(
        targetID: String, requesterID: String, downstreamID: String
    ) -> Run {
        let steps = [
            StepExecution(id: requesterID, role: .softwareEngineer, title: "SWE", status: .running),
            StepExecution(
                id: targetID, role: .productManager, title: "PM",
                expectedArtifacts: ["Spec"], status: .done,
                completedAt: MonotonicClock.shared.now(),
                artifacts: [Artifact(name: "Spec", mimeType: "text/markdown", relativePath: "spec.md")]
            ),
            StepExecution(id: downstreamID, role: .uxDesigner, title: "UXD", status: .running),
        ]
        return Run(
            id: 0, steps: steps,
            roleStatuses: [requesterID: .working, targetID: .done, downstreamID: .working]
        )
    }
}

// MARK: - Test LLM Clients

private final class ScriptedSingleTurnLLMClient: LLMClient, @unchecked Sendable {
    private let response: String
    init(response: String) { self.response = response }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let text = response
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: text))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

private final class HeldAncillaryStreamClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private let partialChunk: String
    private var _started = false
    private var continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?

    init(partialChunk: String) { self.partialChunk = partialChunk }

    var started: Bool { lock.withLock { _started } }

    func finishNormally() {
        let cont = lock.withLock { () -> AsyncThrowingStream<StreamEvent, Error>.Continuation? in
            defer { continuation = nil }
            return continuation
        }
        cont?.finish()
    }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let chunk = partialChunk
        return AsyncThrowingStream { cont in
            cont.yield(StreamEvent(contentDelta: chunk))
            self.lock.withLock {
                self._started = true
                self.continuation = cont
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

private final class CancellingOnStreamLLMClient: LLMClient, @unchecked Sendable {
    private let onStream: @MainActor () -> Void
    init(onStream: @escaping @MainActor () -> Void) { self.onStream = onStream }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let hook = onStream
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                hook()
                continuation.finish(throwing: CancellationError())
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
