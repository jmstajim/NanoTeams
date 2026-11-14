import XCTest
import os

@testable import NanoTeams

/// One rule, asked at the seams where an action can outlive the folder it began in: an action
/// captures its folder lifecycle once, when it begins, and asks THAT lifecycle after every
/// suspension before it writes, starts or reports anything. A folder transition — an open, a
/// close, a reset — ends the lifecycle at its first line, before anything suspends, and the
/// next folder's lifecycle begins only at its commit; in between the process still describes the
/// folder being left, and nothing may start or write there.
///
/// `NTMSTask.id` is sequential per folder, so the folder that commits almost always has a task
/// with the id the straddling action holds: the harm in every test below is an action begun in A
/// acting on B's task of the same number, or on A while B is read.
///
/// The seams, one section each: run control (a start's claim, a resume, a step's start, a team
/// generation's continuation, the person's create-and-start, a forced Autovisor pass), the
/// queued-message flush, the poll loop, the stale-status sweep, the flush-then-write verbs, the
/// engine mirror at the commit, the role and task verbs that write and then follow up by task id,
/// and a Pause straddling an open. The Autovisor's actions carry their pass's lifecycle explicitly
/// (`performAutovisorAction(_:within:)`).
@MainActor
final class WorkFolderLifecycleSeamTests: WorkFolderLifecycleTestCase {

    private var formState: QuickCaptureFormState!
    private var controller: QuickCaptureController!
    private var teamGenerationClient: HeldTeamGenerationClient!
    /// What a verb run by `runAcrossTheNextOpensCommit` answered, for the verbs that answer.
    private var verbVerdict: Bool?

    override func tearDown() async throws {
        teamGenerationClient?.release(with: .failure(URLError(.cannotConnectToHost)))
        teamGenerationClient = nil
        verbVerdict = nil
        controller = nil
        formState = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A task of the open folder with a paused run whose role is still working — what a resume
    /// restarts. Loaded, so its run is written.
    private func pausedRunTask(title: String, makeActive: Bool) async throws -> Int {
        let created = await sut.createTask(title: title, supervisorTask: "x", makeActive: makeActive)
        let taskID = try XCTUnwrap(created)
        _ = await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .paused)]
            task.runs = [run]
        }
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.steps.first?.status, .paused, "premise: \(title) is paused")
        return taskID
    }

    /// A task of the open folder whose run has one step `.running`, loaded.
    private func runningRunTask(title: String, makeActive: Bool, stepIDs: [String] = ["worker"]) async throws -> Int {
        let created = await sut.createTask(title: title, supervisorTask: "x", makeActive: makeActive)
        let taskID = try XCTUnwrap(created)
        _ = await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, roleStatuses: Dictionary(uniqueKeysWithValues: stepIDs.map { ($0, .working) }))
            run.steps = stepIDs.map { StepExecution(id: $0, role: .softwareEngineer, title: $0, status: .running) }
            task.runs = [run]
        }
        return taskID
    }

    private func taskJSON(_ folder: URL, _ taskID: Int) -> URL {
        NTMSPaths(workFolderRoot: folder).taskJSON(taskID: taskID)
    }

    /// Waits until `condition` holds, or fails.
    private func waitUntil(
        _ what: String, line: UInt = #line, _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("\(what) never happened", line: line)
    }

    /// Lets a just-spawned task run up to its first real suspension — here, a flush waiting on the
    /// held pointer write — so the verb begins while its folder is still the current one.
    private func letItReachItsFlush() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: - Run control

    /// Play on a task of the folder still described, while the next folder is READ, starts
    /// nothing: no run is materialized in the folder being left, no engine is created, no claim
    /// is held, and nothing of it reaches the folder that commits — B's task of the same id is
    /// not written and has no engine state.
    ///
    /// RED until the run-start claim carried its folder lifecycle: the boundary empties the claim
    /// set, so a start claimed after it passed every re-check of its launch — not cancelled, a
    /// task of that id loaded, its generation unmoved — and its engine outlived the switch,
    /// resolving the id against B's task once B committed.
    func testAStartBegunWhileTheNextFolderIsReadStartsNothing() async throws {
        let (aOne, bTaskJSON) = try await sameIDTasks()
        let aTaskJSON = taskJSON(folderA, aOne)
        let aBefore = try Data(contentsOf: aTaskJSON)
        let bBefore = try Data(contentsOf: bTaskJSON)
        let (openB, readB) = try await startReadingOpen(of: folderB)

        await sut.startRun(taskID: aOne)

        XCTAssertTrue(sut.taskEngines.isEmpty, "a start begun mid-open created an engine")
        XCTAssertFalse(sut.engineState.isInitializingRun(aOne), "a start begun mid-open holds its claim")
        XCTAssertEqual(try Data(contentsOf: aTaskJSON), aBefore, "a run was materialized in the folder being left")
        readB.release()
        await openB.value
        XCTAssertEqual(try Data(contentsOf: bTaskJSON), bBefore, "B's task of that id was written")
        XCTAssertNil(sut.taskEngineStates[aOne], "an engine state of the start survived into B")
        XCTAssertTrue(sut.taskEngines.isEmpty)
    }

    /// A resume of a paused task of the folder still described, while the next folder is READ,
    /// restarts nothing: no step is marked running or executed, no engine is created, and B's
    /// task of the same id is untouched.
    ///
    /// RED until `resumeRun` carried the lifecycle it began in: it checked nothing, so it restarted
    /// the step in the folder being left and created an engine after the boundary had stopped
    /// every engine — one that resolved its id against B's task from the commit on.
    func testAResumeBegunWhileTheNextFolderIsReadRestartsNothing() async throws {
        await sut.openWorkFolder(folderB)
        let bCreated = await sut.createTask(title: "B one", supervisorTask: "b", makeActive: true)
        let bOne = try XCTUnwrap(bCreated)
        await sut.openWorkFolder(folderA)
        let aOne = try await pausedRunTask(title: "A one", makeActive: true)
        XCTAssertEqual(aOne, bOne, "premise: both folders number their first task the same")
        let aBefore = try Data(contentsOf: taskJSON(folderA, aOne))
        let bBefore = try Data(contentsOf: taskJSON(folderB, bOne))
        let (openB, readB) = try await startReadingOpen(of: folderB)

        await sut.resumeRun(taskID: aOne)

        XCTAssertTrue(sut.taskEngines.isEmpty, "a resume begun mid-open created an engine")
        XCTAssertFalse(sut.llmExecutionService.isStepRunning(stepID: "worker", taskID: aOne),
                       "a resume begun mid-open started its step")
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderA, aOne)), aBefore,
                       "a resume begun mid-open wrote the folder being left")
        readB.release()
        await openB.value
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, bOne)), bBefore, "B's task of that id was written")
        XCTAssertNil(sut.taskEngineStates[aOne])
    }

    /// An Autovisor wake begun while the next folder is READ — the folder still described has
    /// the Autovisor on and a condition the manager has not seen — starts no pass and writes
    /// nothing of the wake's bookkeeping.
    ///
    /// RED until the wake asked a lifecycle: it read the folder still described, found the
    /// condition fresh, and started the manager's pass there — claimed after the boundary, a
    /// start no boundary would abandon.
    func testAnAutovisorWakeBegunWhileTheNextFolderIsReadStartsNoPass() async throws {
        await sut.openWorkFolder(folderA)
        let managerID = try await handMadeManager()
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskCreated = true }
        let created = await sut.createTask(title: "new work", supervisorTask: "x", makeActive: false)
        _ = try XCTUnwrap(created)
        sut.autovisorSeenTaskIDs = []
        sut.autovisorLastPassAttentionKeys = []
        let managerJSON = taskJSON(folderA, managerID)
        let before = try Data(contentsOf: managerJSON)
        let (openB, readB) = try await startReadingOpen(of: folderB)

        await sut.wakeAutovisorForEvents()

        XCTAssertTrue(sut.taskEngines.isEmpty, "the wake started the manager's pass")
        XCTAssertFalse(sut.engineState.isInitializingRun(managerID))
        XCTAssertEqual(try Data(contentsOf: managerJSON), before, "the wake materialized a pass in the folder being left")
        XCTAssertTrue(sut.autovisorSeenTaskIDs.isEmpty, "the wake wrote its seen-set for the folder being left")
        readB.release()
        await openB.value
        XCTAssertTrue(sut.taskEngines.isEmpty)
    }

    /// "Run now" on A's live manager pass — a forced pass, which pauses the live pass before it
    /// starts a fresh one — held inside that Pause's write while the open of B commits, B's task
    /// of the manager's id idle: resumed, the forced pass starts nothing — B's task gets no run and
    /// no engine, nothing is claimed — and announces no restart in B's session.
    ///
    /// RED until the forced pass carried the lifecycle it began in past its suspensions: it
    /// started the run once the Pause returned, and the start's claim, taken after B's commit,
    /// named B's lifecycle — so it materialized a run on B's task of that id and started its
    /// engine.
    func testAForcedAutovisorPassWhosePauseStraddlesAnOpenStartsNothingInTheNextFolder() async throws {
        await sut.openWorkFolder(folderB)
        let bCreated = await sut.createTask(title: "B one", supervisorTask: "x", makeActive: false)
        let bOne = try XCTUnwrap(bCreated)
        await sut.openWorkFolder(folderA)
        let managerID = try await handMadeManager()
        XCTAssertEqual(managerID, bOne, "premise: A's manager has the id of B's task")
        _ = await sut.ensureTaskLoaded(managerID)
        await sut.mutateTask(taskID: managerID) { task in
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .running)]
            task.runs = [run]
        }
        sut.engineState[managerID] = .running
        let path = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == path && task.id == managerID
                && task.runs.last?.steps.contains { $0.status == .paused } == true
        }
        repository.taskWriteHold = write
        let pass = Task { await sut.startAutovisorPass(taskID: managerID, force: true) }
        try await waitHeld(write, "the forced pass's Pause of the live pass")
        await sut.openWorkFolder(folderB)
        let bBefore = try Data(contentsOf: taskJSON(folderB, bOne))
        sut.lastInfoMessage = nil
        write.release()
        await pass.value
        await sut.drainRunStartLaunches()

        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, bOne)), bBefore, "the forced pass materialized a run on B's task")
        XCTAssertEqual(sut.loadedTask(bOne)?.runs.count ?? 0, 0, "the forced pass started a run of B's")
        XCTAssertTrue(sut.taskEngines.isEmpty, "the forced pass started an engine in B")
        XCTAssertFalse(sut.engineState.isInitializingRun(bOne), "the forced pass holds a claim in B")
        XCTAssertNil(sut.lastInfoMessage, "the forced pass announced a restart in B's session")
        XCTAssertFalse(sut.forcingRunTaskIDs.contains(managerID), "the forced pass kept its slot")
    }

    /// The person's create-and-start (Quick Capture) whose attachments write straddles the next
    /// open — B commits while the write is held — creates its task in A, where it was asked, and
    /// starts nothing: B's active task is not switched, no claim is taken, nothing is
    /// materialized in B, no engine runs, and the person is told. While B only READS, the same
    /// create leaves A's task unstarted.
    ///
    /// RED until the create carried its lifecycle past the attachments write: `switchTask`
    /// promoted B's task of the same id (writing B's active pointer), the claim was taken in a
    /// lifecycle no boundary would end, B's task got a run and the launch started an engine.
    func testACreateAndStartWhoseAttachmentsStraddleTheNextOpenStartsNothing() async throws {
        for committed in [true, false] {
            let (a, b) = try freshFolders("create-and-start-\(committed)")
            await sut.openWorkFolder(b)
            let bOneCreated = await sut.createTask(title: "B one", supervisorTask: "x", makeActive: false)
            let bOne = try XCTUnwrap(bOneCreated)
            let bTwoCreated = await sut.createTask(title: "B two", supervisorTask: "x", makeActive: true)
            let bTwo = try XCTUnwrap(bTwoCreated)
            await sut.openWorkFolder(a)
            let path = a.path
            let write = TaskWriteHold { written, task in
                written.path == path && task.clippedTexts.texts.contains("hold-me")
            }
            repository.taskWriteHold = write
            let request = TaskCreationRequest(
                title: "late", rawSupervisorTask: "x", preferredTeamID: nil,
                clippedTexts: ["hold-me"], stagedAttachments: [])
            let creating = Task { await sut.createPreparedTaskAndStart(request: request) }
            try await waitHeld(write, "committed \(committed): the create's attachments write")
            var openB: Task<Void, Never>?
            var readB: OpenReadHold?
            if committed {
                await sut.openWorkFolder(b)
            } else {
                readB = holdReads(of: b)
                openB = try await startOpen(of: b)
            }
            let bOneBefore = try Data(contentsOf: taskJSON(b, bOne))
            let errorsBefore = sut.errorSurfaceCount
            write.release()
            let created = await creating.value
            if let created { await sut.runStartTask(for: created)?.value }

            XCTAssertNil(created, "committed \(committed): the create reported a started task")
            XCTAssertTrue(sut.taskEngines.isEmpty, "committed \(committed): an engine was started")
            XCTAssertGreaterThan(sut.errorSurfaceCount, errorsBefore, "committed \(committed): the person was not told")
            let aTask = try NTMSRepository().loadTask(at: a, taskID: bOne)
            XCTAssertEqual(aTask.title, "late", "committed \(committed): premise — the task was created in A")
            XCTAssertTrue(aTask.runs.isEmpty, "committed \(committed): A's new task was started")
            readB?.release()
            await openB?.value
            XCTAssertEqual(sut.activeTaskID, bTwo, "committed \(committed): B's active task was switched")
            XCTAssertEqual(createdState(b).state?.activeTaskID, bTwo, "committed \(committed): B's active pointer was written")
            XCTAssertEqual(try Data(contentsOf: taskJSON(b, bOne)), bOneBefore,
                           "committed \(committed): B's task of the new task's id was written")
            XCTAssertNil(sut.taskEngineStates[bOne], "committed \(committed)")
        }
    }

    /// A Generated-Team start whose generation — the LLM call — straddles an open: B commits while
    /// the call is out, B holding an idle, loaded task with the generating task's id. Whatever the
    /// call returns, nothing lands in B: no write to B's task, no banner, no wake; the generation's
    /// slot is released, and B's task of that id can be started.
    ///
    /// RED until the generation carried the lifecycle it was spawned in: the continuation's only
    /// stop was its own cancellation, which no stop verb of the boundary reached, so on success it
    /// rewrote B's task and posted "could not be applied", and on failure it rewrote B's task,
    /// posted the failure and woke the Autovisor — all in B's session.
    func testAGeneratedTeamWhoseGenerationStraddlesAnOpenWritesNothingThere() async throws {
        for succeeds in [true, false] {
            let (a, b) = try freshFolders("generation-\(succeeds)")
            teamGenerationClient?.release(with: .failure(URLError(.cannotConnectToHost)))
            teamGenerationClient = HeldTeamGenerationClient()
            sut = TestOrchestrator.make(repository: repository, teamGenerationClient: teamGenerationClient)
            await sut.openWorkFolder(b)
            let bOneCreated = await sut.createTask(title: "B one", supervisorTask: "x", makeActive: false)
            let bOne = try XCTUnwrap(bOneCreated)
            let bTwoCreated = await sut.createTask(title: "B two", supervisorTask: "x", makeActive: true)
            _ = try XCTUnwrap(bTwoCreated)
            await sut.openWorkFolder(a)
            await sut.mutateWorkFolder { project in
                guard !project.teams.contains(where: { $0.isGeneratedPlaceholder }) else { return }
                project.teams.append(TeamTemplateFactory.generatedTeam())
            }
            let template = try XCTUnwrap(sut.workFolder?.teams.first { $0.isGeneratedPlaceholder })
            let created = await sut.createTask(title: "Gen", supervisorTask: "build a calculator", preferredTeamID: template.id)
            let genID = try XCTUnwrap(created)
            XCTAssertEqual(genID, bOne, "succeeds \(succeeds): premise — the generating task has the id of B's idle task")
            await sut.startRun(taskID: genID)
            XCTAssertTrue(sut.isGeneratingTeam(taskID: genID), "succeeds \(succeeds): premise — generation is in flight")
            let client = try XCTUnwrap(teamGenerationClient)
            try await waitUntil("succeeds \(succeeds): the generation's request") { client.requested }
            let genTask = try XCTUnwrap(sut.teamGenerationTasks[genID])

            await sut.openWorkFolder(b)
            XCTAssertTrue(genTask.isCancelled, "succeeds \(succeeds): the boundary did not cancel the generation task")
            XCTAssertFalse(sut.isGeneratingTeam(taskID: genID),
                           "succeeds \(succeeds): isGeneratingTeam stayed true across the boundary before client release")
            _ = await sut.ensureTaskLoaded(bOne)
            let bBefore = try Data(contentsOf: taskJSON(b, bOne))
            let errorsBefore = sut.errorSurfaceCount
            let infoBefore = sut.lastInfoMessage
            client.release(with: succeeds ? .success(Self.createTeamEvents()) : .failure(URLError(.badServerResponse)))
            await genTask.value

            XCTAssertEqual(try Data(contentsOf: taskJSON(b, bOne)), bBefore, "succeeds \(succeeds): B's task was written")
            XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "succeeds \(succeeds): a banner landed in B's session")
            XCTAssertEqual(sut.lastInfoMessage, infoBefore, "succeeds \(succeeds): an info banner landed in B's session")
            XCTAssertTrue(sut.taskEngines.isEmpty, "succeeds \(succeeds): an engine was started")
            await sut.startRun(taskID: bOne)
            XCTAssertEqual(sut.loadedTask(bOne)?.runs.count, 1, "succeeds \(succeeds): B's task of that id cannot be started")
            sut.stopAllEngines()
        }
    }

    /// A `create_team` call the held client returns on release — a warning-free team.
    private static func createTeamEvents() -> [StreamEvent] {
        let json = """
        {"name":"Generated Calculator","description":"generated","roles":[{"name":"Engineer",\
        "prompt":"do the work","produces_artifacts":["Code"],"requires_artifacts":["Supervisor Task"],\
        "tools":["\(ToolNames.readFile)","\(ToolNames.writeFile)"]}],\
        "artifacts":[{"name":"Code","description":"the code"}],"supervisor_requires":["Code"]}
        """
        return [StreamEvent(toolCallDeltas: [
            StreamEvent.ToolCallDelta(index: 0, id: "call_1", name: ToolNames.createTeam, argumentsDelta: json)
        ])]
    }

    // MARK: - The queued-message flush

    /// The flush of the Supervisor message queue fired while the next folder is READ — the
    /// boundary's own engine-state change is what fires it — wakes nothing: the queued message's
    /// task (a paused task of the folder being left) is not resumed, nothing is written there,
    /// and nothing reaches B; B's commit then drops the folder-scoped queue.
    ///
    /// RED until the flush froze during a transition: the boundary emptied the engine mirror, so
    /// the queued task read as engineless and took the resume arm — a resume that checked nothing
    /// restarted its step and created an engine after the boundary.
    func testAQueuedMessageFlushedWhileTheNextFolderIsReadWakesNothing() async throws {
        await sut.openWorkFolder(folderB)
        let bCreated = await sut.createTask(title: "B one", supervisorTask: "b", makeActive: true)
        let bOne = try XCTUnwrap(bCreated)
        await sut.openWorkFolder(folderA)
        let aOne = try await pausedRunTask(title: "A one", makeActive: true)
        XCTAssertEqual(aOne, bOne, "premise: both folders number their first task the same")
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState
        controller = QuickCaptureController(formState: formState, storage: InMemoryConfigurationStorage())
        controller.store = sut
        formState.appendQueuedMessage(try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "keep going", attachments: [], clippedTexts: [], targetRoleID: nil)), for: aOne)
        let aBefore = try Data(contentsOf: taskJSON(folderA, aOne))
        let bBefore = try Data(contentsOf: taskJSON(folderB, bOne))
        let (openB, readB) = try await startReadingOpen(of: folderB)

        controller.handleEngineStateChanged()
        for _ in 0..<5 { await Task.yield() }

        XCTAssertFalse(controller.pendingResumeForQueueFlush.contains(aOne),
                       "the flush woke a task while the next folder was read")
        XCTAssertTrue(sut.taskEngines.isEmpty, "the flush's wake created an engine")
        XCTAssertFalse(sut.llmExecutionService.isStepRunning(stepID: "worker", taskID: aOne))
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderA, aOne)), aBefore, "the wake wrote the folder being left")
        readB.release()
        await openB.value
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, bOne)), bBefore, "B's task of that id was written")
        XCTAssertNil(sut.taskEngineStates[aOne])
        XCTAssertFalse(formState.hasQueuedMessage(for: aOne), "B's commit kept the folder being left's queue")
    }

    /// A REOPEN of the same folder freezes the flush through its read too, and its commit keeps
    /// the queue — same folder, same task-id namespace: the message is still for that task.
    ///
    /// RED until the flush froze during a transition: the flush fired by the reopen's boundary
    /// woke the queued task while the reopen still read.
    func testAQueuedMessageSurvivesAReopenOfItsFolderWithNoWakeDuringTheRead() async throws {
        await sut.openWorkFolder(folderA)
        let aOne = try await pausedRunTask(title: "A one", makeActive: true)
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState
        controller = QuickCaptureController(formState: formState, storage: InMemoryConfigurationStorage())
        controller.store = sut
        formState.appendQueuedMessage(try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "still relevant", attachments: [], clippedTexts: [], targetRoleID: nil)), for: aOne)
        let aBefore = try Data(contentsOf: taskJSON(folderA, aOne))
        let (reopen, reopenRead) = try await startReadingOpen(of: folderA)

        controller.handleEngineStateChanged()
        for _ in 0..<5 { await Task.yield() }

        XCTAssertFalse(controller.pendingResumeForQueueFlush.contains(aOne),
                       "the flush woke a task while its folder was reopened")
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderA, aOne)), aBefore,
                       "the flush wrote the task while its folder was reopened")
        reopenRead.release()
        await reopen.value
        XCTAssertTrue(formState.hasQueuedMessage(for: aOne), "a reopen of the same folder dropped the queue")
    }

    /// Wakes dispatched by `tryFlushQueuedMessages` (`.resume`, `.start`, `.needsSupervisorInput`)
    /// before a real folder open starts — and overtaken by `openWorkFolder`'s synchronous
    /// `beginFolderTransition()` before their `Task` bodies run — refund their stamped attempts to
    /// the right maps and write nothing to disk (D-M11 п.5 & чтение-2).
    func testDispatchedQueueWakesOvertakenByARealOpenRefundTheirStampsAndWriteNothing() async throws {
        await sut.openWorkFolder(folderA)
        let failedCreated = await sut.createTask(title: "failed", supervisorTask: "f", makeActive: false)
        let failedID = try XCTUnwrap(failedCreated)
        let doneChatCreated = await sut.createTask(title: "chat", supervisorTask: "c", makeActive: false)
        let doneChatID = try XCTUnwrap(doneChatCreated)
        let waitingCreated = await sut.createTask(title: "waiting", supervisorTask: "w", makeActive: true)
        let waitingID = try XCTUnwrap(waitingCreated)
        _ = await sut.ensureTaskLoaded(waitingID)
        await sut.mutateTask(taskID: waitingID) { task in
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(
                id: "worker", role: .softwareEngineer, title: "Work", status: .needsSupervisorInput,
                needsSupervisorInput: true, supervisorQuestion: "Which option?")]
            task.runs = [run]
        }
        let waitingBefore = try Data(contentsOf: taskJSON(folderA, waitingID))
        let failedBefore = try Data(contentsOf: taskJSON(folderA, failedID))
        let doneBefore = try Data(contentsOf: taskJSON(folderA, doneChatID))

        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState
        controller = QuickCaptureController(formState: formState, storage: InMemoryConfigurationStorage())
        controller.store = sut
        let mFailed = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "retry failed", attachments: [], clippedTexts: [], targetRoleID: nil))
        let mStart = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "start chat", attachments: [], clippedTexts: [], targetRoleID: nil))
        let mAnswer = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "answer waiting", attachments: [], clippedTexts: [], targetRoleID: nil))
        formState.appendQueuedMessage(mFailed, for: failedID)
        formState.appendQueuedMessage(mStart, for: doneChatID)
        formState.appendQueuedMessage(mAnswer, for: waitingID)
        sut.engineState[failedID] = .failed
        sut.engineState[doneChatID] = .done
        sut.engineState[waitingID] = .needsSupervisorInput

        controller.tryFlushQueuedMessages()
        XCTAssertEqual(controller.failedResumeAttemptedMessageIDs[failedID], [mFailed.id],
                       "premise: failed-resume attempt stamped")
        XCTAssertTrue(controller._testHasChatStartAttempted(taskID: doneChatID),
                      "premise: chat-start attempt stamped")
        // `openWorkFolder` runs `beginFolderTransition()` synchronously before its first suspension,
        // so the three queued Tasks run during `folderB`'s off-main read with an ended lifecycle.
        await sut.openWorkFolder(folderB)
        await controller._testAwaitPendingFlushes()
        try await waitUntil("dispatched wakes drain") { self.controller.pendingResumeForQueueFlush.isEmpty }

        XCTAssertNil(controller.failedResumeAttemptedMessageIDs[failedID],
                     "superseded .resume wake must refund failedResumeAttemptedMessageIDs")
        XCTAssertFalse(controller._testHasChatStartAttempted(taskID: doneChatID),
                       "superseded .start wake must refund chatStartAttemptedMessageIDs")
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderA, waitingID)), waitingBefore,
                       "superseded .needsSupervisorInput wake must not write the waiting task")
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderA, failedID)), failedBefore)
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderA, doneChatID)), doneBefore)
    }

    // MARK: - The poll loop

    /// A poll tick suspended inside the auto-off write — the Autovisor of A switched off by its
    /// sleep timer — while the open of B commits (held at its first step after its read, its own
    /// reconcile not yet run): resumed, the tick does nothing more — no "auto-off timer ended"
    /// banner about A in B's session, and no fire of B's recurrence whose slot B missed while it
    /// was closed.
    ///
    /// RED until the loop carried its open's lifecycle into every evaluator: the tick checked
    /// cancellation once, then awaited its evaluators in turn with no re-check, and the next
    /// evaluator captured the lifecycle of the folder now described — B's: it fired B's missed slot
    /// (a run appended, `lastFiredAt` stamped — a phantom fire) and the auto-off announced itself.
    func testAPollTickStraddlingAnOpenDoesNothingInTheNextFolder() async throws {
        sut = TestOrchestrator.make(repository: repository, automationTickInterval: 0.05)
        await sut.openWorkFolder(folderB)
        let created = await sut.createTask(title: "B recurring", supervisorTask: "x", makeActive: false)
        let bTask = try XCTUnwrap(created)
        _ = await sut.ensureTaskLoaded(bTask)
        let missed = Date(timeIntervalSinceNow: -7200)
        await sut.mutateTask(taskID: bTask) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: missed)
        }
        await sut.openWorkFolder(folderA)
        let managerID = try await handMadeManager()
        _ = await sut.ensureTaskLoaded(managerID)
        await sut.mutateTask(taskID: managerID) {
            $0.recurrence = TaskRecurrence(
                rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: Date(timeIntervalSinceNow: 3600))
        }
        let path = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == path && task.id == managerID && task.recurrence?.isEnabled == false
        }
        repository.taskWriteHold = write
        sut.autovisorAutoDisableAt = .distantPast
        try await waitHeld(write, "the auto-off's write in A")
        let holdB = holdNextOpen(at: .delegationHistory)
        let openB = Task { await sut.openWorkFolder(folderB) }
        try await waitHeld(holdB, "the open of B")
        XCTAssertEqual(sut.workFolderURL, folderB, "premise: B committed")
        sut.lastInfoMessage = nil
        write.release()
        try await waitForLiveLoops(0, "after the tick resumed")

        XCTAssertNil(sut.lastInfoMessage, "the superseded tick announced A's auto-off in B's session")
        XCTAssertEqual(sut.loadedTask(bTask)?.runs.count ?? 0, 0, "the superseded tick fired B's missed slot")
        let onDisk = try NTMSRepository().loadTask(at: folderB, taskID: bTask)
        XCTAssertTrue(onDisk.runs.isEmpty, "the superseded tick appended a run to B's task.json")
        XCTAssertNil(onDisk.recurrence?.lastFiredAt, "the superseded tick stamped B's lastFiredAt")
        await holdB.release()
        await openB.value
    }

    // MARK: - The stale-status sweep

    /// Two of A's tasks left running by a previous session, both loaded (a reopen keeps them):
    /// a reopen of A is held inside the sweep's write recovering the first, and a second reopen
    /// of A commits (held at its first step). Resumed, the superseded sweep stops at its next
    /// step — the second task is not recovered by it, and it seeds no engine state for either into
    /// the session the second reopen opens; the second reopen's own sweep then recovers both.
    ///
    /// RED until the sweep asked its open's lifecycle: it asked the folder's URL, which a reopen of
    /// the same folder never moves, so the superseded sweep ran to its end beside the reopen's own.
    func testAStatusSweepSupersededByAReopenOfItsFolderStopsAtItsNextStep() async throws {
        await sut.openWorkFolder(folderA)
        let ids = try await staleLoadedTasks(in: folderA, titles: ["s1", "s2"])
        let heldIDs = Set(ids)
        let path = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == path && heldIDs.contains(task.id)
                && task.runs.last?.steps.contains { $0.status == .paused } == true
        }
        repository.taskWriteHold = write
        let firstReopen = Task { await sut.openWorkFolder(folderA) }
        try await waitHeld(write, "the first reopen's sweep")
        let (secondReopen, holdSecond) = try await holdCommittedOpen(of: folderA)
        write.release()
        await firstReopen.value

        let recovered = try ids.filter { try diskStepStatus(folderA, $0) == .paused }
        XCTAssertEqual(recovered.count, 1, "the superseded sweep went on past its held write: \(recovered)")
        for id in ids {
            XCTAssertNil(sut.taskEngineStates[id], "the superseded sweep seeded task #\(id)'s engine state")
        }
        await holdSecond.release()
        await secondReopen.value
        XCTAssertEqual(try ids.filter { try diskStepStatus(folderA, $0) == .paused }.count, 2,
                       "anti-vacuum: the second reopen's own sweep recovers both")
    }

    /// The same sweep superseded by an open of ANOTHER folder that commits, B holding an idle,
    /// loaded task with the held task's id and a paused run: resumed, the sweep evicts nothing of
    /// B's and seeds no engine state for B's task.
    ///
    /// RED until the sweep asked its lifecycle after its write: it seeded the engine state of the
    /// task now answering to that id — B's — and evicted it, before its next URL check broke.
    func testAStatusSweepSupersededByAnOpenThatCommitsLeavesTheNextFolderAlone() async throws {
        await sut.openWorkFolder(folderB)
        let bOne = try await pausedRunTask(title: "B one", makeActive: false)
        let bTwoCreated = await sut.createTask(title: "B two", supervisorTask: "x", makeActive: true)
        _ = try XCTUnwrap(bTwoCreated)
        await sut.openWorkFolder(folderA)
        let ids = try await staleLoadedTasks(in: folderA, titles: ["s1"])
        XCTAssertEqual(ids, [bOne], "premise: A's stale task has the id of B's idle task")
        let path = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == path && task.id == bOne
                && task.runs.last?.steps.contains { $0.status == .paused } == true
        }
        repository.taskWriteHold = write
        let reopen = Task { await sut.openWorkFolder(folderA) }
        try await waitHeld(write, "the reopen's sweep")
        await sut.openWorkFolder(folderB)
        _ = await sut.ensureTaskLoaded(bOne)
        sut.engineState.removeEngine(for: bOne)
        let bBefore = try Data(contentsOf: taskJSON(folderB, bOne))
        let errorsBefore = sut.errorSurfaceCount
        write.release()
        await reopen.value

        XCTAssertNotNil(sut.loadedTask(bOne), "the superseded sweep evicted B's task")
        XCTAssertNil(sut.taskEngineStates[bOne], "the superseded sweep seeded B's task's engine state")
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, bOne)), bBefore, "the superseded sweep wrote B's task")
        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "the superseded sweep reported into B's session")
    }

    /// Non-active tasks of `folder` left `.running` by a previous session — their index rows and
    /// their one step — and loaded, so a reopen's sweep recovers them through `mutateTask`.
    private func staleLoadedTasks(in folder: URL, titles: [String]) async throws -> [Int] {
        var ids: [Int] = []
        for title in titles {
            let id = try await runningRunTask(title: title, makeActive: false)
            await sut.mutateTask(taskID: id) { $0.status = .running }
            ids.append(id)
        }
        let activeCreated = await sut.createTask(title: "active", supervisorTask: "y", makeActive: true)
        _ = try XCTUnwrap(activeCreated)
        for id in ids {
            XCTAssertNotNil(sut.loadedTask(id), "premise: #\(id) is loaded")
            XCTAssertEqual(try diskStepStatus(folder, id), .running, "premise: #\(id) is left running on disk")
        }
        return ids
    }

    private func diskStepStatus(_ folder: URL, _ taskID: Int) throws -> StepStatus? {
        try NTMSRepository().loadTask(at: folder, taskID: taskID).runs.last?.steps.first?.status
    }

    // MARK: - Flush-then-write verbs

    /// A switch to an unloaded task of A whose flush of the pending active-task write straddles
    /// the next open: committed — B's snapshot and files are untouched; still reading — A's
    /// active pointer is not written. Either way the person is told.
    ///
    /// RED until the flush answered whether the switch's lifecycle survived it: the slow path
    /// asked nothing after the flush and applied A's snapshot under B's URL — the two-folder
    /// pairing `discardWorkFolderState` exists to prevent.
    func testASwitchWhoseFlushStraddlesAnOpenChangesNothing() async throws {
        for committed in [true, false] {
            let (a, b) = try freshFolders("switch-\(committed)")
            await sut.openWorkFolder(b)
            let bCreated = await sut.createTask(title: "B one", supervisorTask: "x")
            _ = try XCTUnwrap(bCreated)
            await sut.openWorkFolder(a)
            let targetCreated = await sut.createTask(title: "A target", supervisorTask: "x", makeActive: false)
            let target = try XCTUnwrap(targetCreated)
            let activeCreated = await sut.createTask(title: "A active", supervisorTask: "x", makeActive: true)
            let aActive = try XCTUnwrap(activeCreated)
            await sut.openWorkFolder(b)
            await sut.openWorkFolder(a)
            XCTAssertNil(sut.loadedTask(target), "committed \(committed): premise — the target is not loaded")
            let released = holdPendingPointerWrite()
            let switching = Task { await sut.switchTask(to: target) }
            await letItReachItsFlush()
            var openB: Task<Void, Never>?
            var readB: OpenReadHold?
            if committed {
                await sut.openWorkFolder(b)
            } else {
                readB = holdReads(of: b)
                openB = try await startOpen(of: b)
            }
            let projection = sut.snapshot?.projection.id
            let bFiles = folderFiles(b)
            let errorsBefore = sut.errorSurfaceCount
            released.yield()
            released.finish()
            await switching.value

            XCTAssertEqual(sut.snapshot?.projection.id, projection, "committed \(committed): another folder's snapshot was applied")
            XCTAssertEqual(createdState(a).state?.activeTaskID, aActive, "committed \(committed): A's active pointer was written")
            XCTAssertGreaterThan(sut.errorSurfaceCount, errorsBefore, "committed \(committed): the person was not told")
            readB?.release()
            await openB?.value
            XCTAssertEqual(folderFiles(b), bFiles, "committed \(committed): B's files were written")
            XCTAssertEqual(sut.workFolderURL, b)
        }
    }

    /// A delete of a non-active task of A whose flush straddles the next open, B holding a task
    /// of the same id: committed — B's snapshot, index and that task are untouched, and A's task
    /// is not deleted; the person is told.
    ///
    /// RED until the flush answered whether the delete's lifecycle survived it: the delete went on
    /// through the URL it had captured and applied A's snapshot under B's URL, evicting B's task
    /// of that id.
    func testADeleteWhoseFlushStraddlesAnOpenRemovesNothing() async throws {
        await sut.openWorkFolder(folderB)
        let bOneCreated = await sut.createTask(title: "B one", supervisorTask: "x", makeActive: false)
        let bOne = try XCTUnwrap(bOneCreated)
        let bTwoCreated = await sut.createTask(title: "B two", supervisorTask: "x", makeActive: true)
        _ = try XCTUnwrap(bTwoCreated)
        await sut.openWorkFolder(folderA)
        let doomedCreated = await sut.createTask(title: "A doomed", supervisorTask: "x", makeActive: false)
        let doomed = try XCTUnwrap(doomedCreated)
        let activeCreated = await sut.createTask(title: "A active", supervisorTask: "x", makeActive: true)
        _ = try XCTUnwrap(activeCreated)
        XCTAssertEqual(doomed, bOne, "premise: the doomed task has the id of B's idle task")
        let released = holdPendingPointerWrite()
        let deleting = Task { await sut.removeTask(doomed) }
        await letItReachItsFlush()
        await sut.openWorkFolder(folderB)
        _ = await sut.ensureTaskLoaded(bOne)
        let projection = sut.snapshot?.projection.id
        let bFiles = folderFiles(folderB)
        let bBefore = try Data(contentsOf: taskJSON(folderB, bOne))
        let errorsBefore = sut.errorSurfaceCount
        released.yield()
        released.finish()
        await deleting.value

        XCTAssertEqual(sut.snapshot?.projection.id, projection, "another folder's snapshot was applied")
        XCTAssertNotNil(sut.loadedTask(bOne), "B's task of that id was evicted")
        XCTAssertEqual(folderFiles(folderB), bFiles, "B's files were written")
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, bOne)), bBefore)
        XCTAssertNotNil(createdState(folderA).index?.tasks.first { $0.id == doomed },
                        "A's task was deleted after the folder changed")
        XCTAssertGreaterThan(sut.errorSurfaceCount, errorsBefore, "the person was not told")
    }

    /// Deleting A's Autovisor — the manager's removal flushes first — while the open of B
    /// commits, B with the Autovisor on and its own manager pinned: B's Autovisor is not turned
    /// off and its manager is not unpinned.
    ///
    /// RED until the delete asked its lifecycle after its removal: it wrote "Autovisor off, no
    /// manager" into whichever folder was current once the removal returned — B's.
    func testDeletingTheAutovisorAcrossAnOpenLeavesTheNextFoldersAutovisorAlone() async throws {
        await sut.openWorkFolder(folderB)
        let bManager = try await handMadeManager()
        await sut.openWorkFolder(folderA)
        let fillerCreated = await sut.createTask(title: "filler", supervisorTask: "f", makeActive: true)
        _ = try XCTUnwrap(fillerCreated)
        let aManager = try await handMadeManager()
        XCTAssertNotEqual(aManager, bManager, "premise: B has no task with A's manager's id")
        let released = holdPendingPointerWrite()
        let deleting = Task { await sut.deleteAutovisor() }
        await letItReachItsFlush()
        await sut.openWorkFolder(folderB)
        released.yield()
        released.finish()
        await deleting.value

        let bState = createdState(folderB).state
        XCTAssertEqual(bState?.autovisorTaskID, bManager, "B's manager was unpinned")
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, true, "B's Autovisor was turned off")
        let bSettings = try AtomicJSONStore().read(ProjectSettings.self, from: NTMSPaths(workFolderRoot: folderB).settingsJSON)
        XCTAssertTrue(bSettings.autovisorEnabled, "B's Autovisor was turned off on disk")
    }

    // MARK: - The engine mirror at the commit

    /// What the folder being left leaves in the engine mirror during the next folder's read — a
    /// load seeding a paused task's state, an engine created by a person's action — does not
    /// outlive the next folder's commit: B's task of the same id has no state and no engine.
    ///
    /// RED until a different folder's commit dropped what the read left: the boundary had emptied
    /// the mirror before the read, and nothing emptied it again, so B's task answered with A's
    /// `.paused` (the board offering Resume on a task with no run) and A's engine resolved its id
    /// against B's task.
    func testWhatTheReadLeavesInTheEngineMirrorDoesNotOutliveTheNextFoldersCommit() async throws {
        await sut.openWorkFolder(folderB)
        let bOneCreated = await sut.createTask(title: "B one", supervisorTask: "x", makeActive: false)
        let bOne = try XCTUnwrap(bOneCreated)
        let bTwoCreated = await sut.createTask(title: "B two", supervisorTask: "x", makeActive: false)
        let bTwo = try XCTUnwrap(bTwoCreated)
        let bThreeCreated = await sut.createTask(title: "B three", supervisorTask: "x", makeActive: true)
        _ = try XCTUnwrap(bThreeCreated)
        await sut.openWorkFolder(folderA)
        let aPaused = try await pausedRunTask(title: "A paused", makeActive: false)
        let aOtherCreated = await sut.createTask(title: "A other", supervisorTask: "x", makeActive: false)
        let aOther = try XCTUnwrap(aOtherCreated)
        XCTAssertEqual([aPaused, aOther], [bOne, bTwo], "premise: A's ids name B's tasks too")
        await sut.openWorkFolder(folderB)
        await sut.openWorkFolder(folderA)
        XCTAssertNil(sut.loadedTask(aPaused), "premise: A's paused task is not loaded")
        let (openB, readB) = try await startReadingOpen(of: folderB)

        _ = await sut.ensureTaskLoaded(aPaused)
        XCTAssertEqual(sut.taskEngineStates[aPaused], .paused, "premise: the load seeded the paused task's state")
        _ = sut.engineForTask(aOther)
        readB.release()
        await openB.value

        XCTAssertNil(sut.taskEngineStates[bOne], "a state seeded during the read survived B's commit")
        XCTAssertNil(sut.taskEngines[bTwo], "an engine created during the read survived B's commit")
    }

    /// A paused task's engine state seeded during B's read when NO engine is live in `taskEngines`
    /// is still cleared by `retainProjections(forTaskIDs:)` on B's commit (D-M11 п.10).
    func testAPausedStateSeededDuringTheReadWithNoLiveEngineDoesNotOutliveTheCommit() async throws {
        await sut.openWorkFolder(folderB)
        let bOneCreated = await sut.createTask(title: "B one", supervisorTask: "x", makeActive: false)
        let bOne = try XCTUnwrap(bOneCreated)
        let bTwoCreated = await sut.createTask(title: "B two", supervisorTask: "x", makeActive: true)
        _ = try XCTUnwrap(bTwoCreated)
        await sut.openWorkFolder(folderA)
        let aPaused = try await pausedRunTask(title: "A paused", makeActive: false)
        let aActiveCreated = await sut.createTask(title: "A active", supervisorTask: "x", makeActive: true)
        _ = try XCTUnwrap(aActiveCreated)
        XCTAssertEqual(aPaused, bOne, "premise: A's paused task has B's idle task's id")
        await sut.openWorkFolder(folderB)
        await sut.openWorkFolder(folderA)
        XCTAssertNil(sut.loadedTask(aPaused), "premise: A's paused task is unloaded")
        let (openB, readB) = try await startReadingOpen(of: folderB)

        _ = await sut.ensureTaskLoaded(aPaused)
        XCTAssertEqual(sut.taskEngineStates[aPaused], .paused, "premise: load seeded .paused")
        XCTAssertTrue(sut.taskEngines.isEmpty, "premise: no engine is live, so only retainProjections clears the state")
        readB.release()
        await openB.value

        XCTAssertNil(sut.taskEngineStates[bOne],
                     "retainProjections must clear engine states seeded during the read when taskEngines is empty")
    }

    /// An engine created during the read of a FAILED open of B is stopped by
    /// `discardWorkFolderState()` in `openWorkFolder`'s catch block (D-M11 чтение-4).
    func testDiscardWorkFolderStateOnAFailedOpenStopsEnginesCreatedDuringItsRead() async throws {
        await sut.openWorkFolder(folderA)
        let aCreated = await sut.createTask(title: "A one", supervisorTask: "x", makeActive: true)
        let aOne = try XCTUnwrap(aCreated)
        repository.openFailurePaths = [folderB.path]
        let (openB, readB) = try await startReadingOpen(of: folderB)

        _ = sut.engineForTask(aOne)
        sut.engineState[aOne] = .paused
        XCTAssertNotNil(sut.taskEngines[aOne], "premise: engine created during the failed open's read")
        readB.release()
        await openB.value

        XCTAssertTrue(sut.taskEngines.isEmpty, "discardWorkFolderState must stop engines created during the failed open's read")
        XCTAssertNil(sut.taskEngineStates[aOne], "discardWorkFolderState must clear engine state projections")
    }

    // MARK: - Role and task verbs

    /// The non-supervisor role of the team A's task runs on.
    private func rosterRole(of taskID: Int) throws -> String {
        let task = try XCTUnwrap(sut.loadedTask(taskID))
        return try XCTUnwrap(sut.resolvedTeam(for: task).nonSupervisorRoles.first?.id)
    }

    /// A verb on A's task held inside its own write while the open of B commits — B's task of the
    /// same id given a paused run of the same role, its engine state seeded `.paused`, so a wake,
    /// a resume, a stop or a re-read of that id would SHOW there — then released. Returns B's
    /// task and its task.json from before the release.
    private func runAcrossTheNextOpensCommit(
        heldAt isTheVerbsWrite: @escaping @Sendable (NTMSTask) -> Bool,
        roleID: String, bOne: Int, bEngine: Bool = false,
        _ verb: @escaping @MainActor () async -> Void
    ) async throws -> Data {
        let path = folderA.path
        let write = TaskWriteHold { written, task in written.path == path && isTheVerbsWrite(task) }
        repository.taskWriteHold = write
        let running = Task { await verb() }
        try await waitHeld(write, "the verb's write")
        await sut.openWorkFolder(folderB)
        _ = await sut.ensureTaskLoaded(bOne)
        await sut.mutateTask(taskID: bOne) { task in
            var run = Run(id: 0, roleStatuses: [roleID: .working])
            run.steps = [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .paused)]
            task.runs = [run]
        }
        if bEngine { _ = sut.engineForTask(bOne) }
        sut.engineState[bOne] = .paused
        let before = try Data(contentsOf: taskJSON(folderB, bOne))
        sut.lastErrorMessage = nil
        write.release()
        await running.value
        return before
    }

    /// What every verb below must leave of B once released: no engine, B's task.json and engine
    /// state as they were, no banner.
    private func assertNothingOfTheNextFolderMoved(
        _ verb: String, bOne: Int, before: Data, engines: Int = 0, line: UInt = #line
    ) throws {
        XCTAssertEqual(sut.taskEngines.count, engines, "\(verb) created or stopped an engine in B", line: line)
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, bOne)), before, "\(verb) wrote B's task", line: line)
        XCTAssertEqual(sut.engineState[bOne], .paused, "\(verb) moved B's engine state", line: line)
        XCTAssertNil(sut.lastErrorMessage, "\(verb) reported into B's session", line: line)
    }

    /// Accepting a role of A, held in the accept's write while B commits: the accept stands in A,
    /// and nothing follows it in B — no engine woken for B's task of that id.
    ///
    /// RED until the accept asked the lifecycle it began in after its write: it woke the engine of
    /// the id it held, B's.
    func testAnAcceptAcrossTheNextOpensCommitWakesNothingThere() async throws {
        let (aOne, _) = try await sameIDTasks()
        let roleID = try rosterRole(of: aOne)
        await sut.mutateTask(taskID: aOne) { task in
            var run = Run(id: 0, roleStatuses: [roleID: .needsAcceptance])
            run.steps = [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .done)]
            task.runs = [run]
        }
        let before = try await runAcrossTheNextOpensCommit(
            heldAt: { $0.runs.last?.roleStatuses[roleID] == .accepted }, roleID: roleID, bOne: aOne
        ) { _ = await self.sut.acceptRole(taskID: aOne, roleID: roleID) }
        try assertNothingOfTheNextFolderMoved("the accept", bOne: aOne, before: before)
        let aDisk = try NTMSRepository().loadTask(at: folderA, taskID: aOne)
        XCTAssertEqual(aDisk.runs.last?.roleStatuses[roleID], .accepted, "anti-vacuum: the accept stands in A")
    }

    /// Requesting changes from a role of A, held in its write while B commits: nothing follows in
    /// B — the verification does not re-read B's task of that id and report it changed.
    ///
    /// RED until the request asked its lifecycle after the write: it read B's step, found no
    /// revision comment, and told the person "step state changed" in B's session.
    func testARevisionRequestAcrossTheNextOpensCommitDoesNothingThere() async throws {
        let (aOne, _) = try await sameIDTasks()
        let roleID = try rosterRole(of: aOne)
        await sut.mutateTask(taskID: aOne) { task in
            var run = Run(id: 0, roleStatuses: [roleID: .done])
            run.steps = [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .done)]
            task.runs = [run]
        }
        let before = try await runAcrossTheNextOpensCommit(
            heldAt: { $0.runs.last?.roleStatuses[roleID] == .revisionRequested }, roleID: roleID, bOne: aOne
        ) { await self.sut.requestRevision(taskID: aOne, roleID: roleID, comment: "tighten it") }
        try assertNothingOfTheNextFolderMoved("the revision request", bOne: aOne, before: before)
    }

    /// Correcting a paused role of A (mid-stream branch), held in its write while B commits:
    /// nothing follows in B — no verification against B's step, no resume of B's task.
    ///
    /// RED until the correction asked its lifecycle after the write: it read B's step and told
    /// the person the correction "could not be applied" in B's session.
    func testACorrectionAcrossTheNextOpensCommitDoesNothingThere() async throws {
        let (aOne, _) = try await sameIDTasks()
        let roleID = try rosterRole(of: aOne)
        await sut.mutateTask(taskID: aOne) { task in
            var run = Run(id: 0, roleStatuses: [roleID: .working])
            run.steps = [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .paused)]
            task.runs = [run]
        }
        sut.engineState[aOne] = .paused
        let before = try await runAcrossTheNextOpensCommit(
            heldAt: { $0.runs.last?.steps.first?.revisionComment == "use the other API" }, roleID: roleID, bOne: aOne
        ) { await self.sut.correctRole(taskID: aOne, roleID: roleID, comment: "use the other API") }
        try assertNothingOfTheNextFolderMoved("the correction", bOne: aOne, before: before)
    }

    /// Answering a parked role of A, held in the answer's write while B commits: the answer stands
    /// in A, and nothing follows in B — no resume of B's task of that id.
    ///
    /// RED until the answer asked its lifecycle after the write: it read B's engine state, found
    /// it paused, and resumed B's task — its step marked running and written.
    func testAnAnswerAcrossTheNextOpensCommitResumesNothingThere() async throws {
        let (aOne, _) = try await sameIDTasks()
        let roleID = try rosterRole(of: aOne)
        await sut.mutateTask(taskID: aOne) { task in
            var run = Run(id: 0, roleStatuses: [roleID: .working])
            run.steps = [StepExecution(
                id: roleID, role: .softwareEngineer, title: "Work", status: .paused,
                needsSupervisorInput: true, supervisorQuestion: "Which one?")]
            task.runs = [run]
        }
        sut.engineState[aOne] = .paused
        let before = try await runAcrossTheNextOpensCommit(
            heldAt: { $0.runs.last?.steps.first?.supervisorAnswer != nil }, roleID: roleID, bOne: aOne
        ) { self.verbVerdict = await self.sut.answerSupervisorQuestion(stepID: roleID, taskID: aOne, answer: "the first") }
        try assertNothingOfTheNextFolderMoved("the answer", bOne: aOne, before: before)
        XCTAssertEqual(verbVerdict, true, "the answer was applied in A, and says so")
    }

    /// Finishing an advisory role of A, held in its write while B commits: nothing follows in B —
    /// no engine woken for B's task of that id.
    ///
    /// RED until the finish asked its lifecycle after the write: it woke B's engine.
    func testAnAdvisoryFinishAcrossTheNextOpensCommitWakesNothingThere() async throws {
        let (aOne, _) = try await sameIDTasks()
        let roleID = try rosterRole(of: aOne)
        await sut.mutateTask(taskID: aOne) { task in
            var run = Run(id: 0, roleStatuses: [roleID: .working])
            run.steps = [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .running)]
            task.runs = [run]
        }
        let before = try await runAcrossTheNextOpensCommit(
            heldAt: { $0.runs.last?.roleStatuses[roleID] == .done }, roleID: roleID, bOne: aOne
        ) { self.verbVerdict = await self.sut.finishAdvisoryRoleAwaiting(taskID: aOne, roleID: roleID) }
        try assertNothingOfTheNextFolderMoved("the advisory finish", bOne: aOne, before: before)
        XCTAssertEqual(verbVerdict, true, "the role was finished in A, and the verdict says so")
    }

    /// Restarting a role of A, held in the reset's write while B commits: nothing follows in B —
    /// no verification against B's task, no engine started for that id.
    ///
    /// RED until the restart asked its lifecycle after the reset: it read B's task, found the role
    /// not reset, and told the person the restart failed in B's session.
    func testARestartAcrossTheNextOpensCommitDoesNothingThere() async throws {
        let (aOne, _) = try await sameIDTasks()
        let roleID = try rosterRole(of: aOne)
        await sut.mutateTask(taskID: aOne) { task in
            var run = Run(id: 0, roleStatuses: [roleID: .done])
            run.steps = [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .done)]
            task.runs = [run]
        }
        let before = try await runAcrossTheNextOpensCommit(
            heldAt: { $0.runs.last?.roleStatuses[roleID] == .idle && $0.runs.last?.steps.first?.status == .pending },
            roleID: roleID, bOne: aOne
        ) { await self.sut.restartRole(taskID: aOne, roleID: roleID, comment: nil) }
        try assertNothingOfTheNextFolderMoved("the restart", bOne: aOne, before: before)
    }

    /// The revision hold of an approved change request on A, held in its write while B commits:
    /// nothing follows in B — no verification against B's run, no engine notified.
    ///
    /// RED until the hold asked its lifecycle after the write: it read B's run, found the role not
    /// queued for revision, and reported a stranded hold in B's session.
    func testARevisionHoldAcrossTheNextOpensCommitDoesNothingThere() async throws {
        let (aOne, _) = try await sameIDTasks()
        let roleID = try rosterRole(of: aOne)
        await sut.mutateTask(taskID: aOne) { task in
            var run = Run(id: 0, roleStatuses: [roleID: .working])
            run.steps = [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .running)]
            task.runs = [run]
        }
        let before = try await runAcrossTheNextOpensCommit(
            heldAt: { $0.runs.last?.roleStatuses[roleID] == .revisionRequested }, roleID: roleID, bOne: aOne
        ) { await self.sut.holdDownstreamForRevision(taskID: aOne, runningRoleIDs: [roleID], requesterRoleID: "requester") }
        try assertNothingOfTheNextFolderMoved("the revision hold", bOne: aOne, before: before)
    }

    /// Closing A's task, held in the close's write while B commits — B's task of that id has an
    /// engine: nothing follows in B — that engine is not stopped.
    ///
    /// RED until the close asked its lifecycle after the write: it stopped the engine of the id it
    /// held, B's — and with it B's task's background commands.
    func testACloseAcrossTheNextOpensCommitStopsNothingThere() async throws {
        let (aOne, _) = try await sameIDTasks()
        let roleID = try rosterRole(of: aOne)
        await sut.mutateTask(taskID: aOne) { task in
            var run = Run(id: 0, roleStatuses: [roleID: .done])
            run.steps = [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .done)]
            task.runs = [run]
        }
        let before = try await runAcrossTheNextOpensCommit(
            heldAt: { $0.closedAt != nil }, roleID: roleID, bOne: aOne, bEngine: true
        ) { self.verbVerdict = await self.sut.closeTask(taskID: aOne) }
        try assertNothingOfTheNextFolderMoved("the close", bOne: aOne, before: before, engines: 1)
        XCTAssertNotNil(sut.taskEngines[aOne], "the close stopped B's engine")
        XCTAssertEqual(verbVerdict, true, "the task was closed in A, and the verdict says so")
    }

    // MARK: - Pause

    /// A Pause of A's two-step running task, held inside its first step's write while the open of
    /// B commits — B's task of the same id running both steps, one of them executing: resumed,
    /// the Pause stops there — B's executing step is not cancelled, neither of B's steps is paused,
    /// and B's engine mirror is not re-derived.
    ///
    /// RED until `pauseRun` asked the lifecycle it began in after each await: its per-step loop
    /// resolved the id again after each suspension, so it cancelled B's step, paused B's steps and
    /// re-derived B's mirror to `.paused`.
    func testAPauseStraddlingTheNextOpenPausesNothingThere() async throws {
        let stepIDs = ["worker", "reviewer"]
        await sut.openWorkFolder(folderB)
        let bCreated = await sut.createTask(title: "B one", supervisorTask: "x", makeActive: false)
        let bOne = try XCTUnwrap(bCreated)
        await sut.openWorkFolder(folderA)
        let aOne = try await runningRunTask(title: "A one", makeActive: false, stepIDs: stepIDs)
        XCTAssertEqual(aOne, bOne, "premise: both folders number their first task the same")
        sut.engineState[aOne] = .running
        let path = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == path && task.id == aOne
                && task.runs.last?.steps.contains { $0.status == .paused } == true
        }
        repository.taskWriteHold = write
        let pausing = Task { await sut.pauseRun(taskID: aOne) }
        try await waitHeld(write, "the Pause's first step write")
        await sut.openWorkFolder(folderB)
        _ = await sut.ensureTaskLoaded(bOne)
        await sut.mutateTask(taskID: bOne) { task in
            var run = Run(id: 0, roleStatuses: Dictionary(uniqueKeysWithValues: stepIDs.map { ($0, .working) }))
            run.steps = stepIDs.map { StepExecution(id: $0, role: .softwareEngineer, title: $0, status: .running) }
            task.runs = [run]
        }
        sut.engineState[bOne] = .running
        sut._testRegisterStepTask(stepID: "reviewer", taskID: bOne)
        let bBefore = try Data(contentsOf: taskJSON(folderB, bOne))
        write.release()
        _ = await pausing.value

        XCTAssertTrue(sut.llmExecutionService.isExecutionLive(stepID: "reviewer", taskID: bOne),
                      "the superseded Pause cancelled B's executing step")
        XCTAssertEqual(sut.loadedTask(bOne)?.runs.last?.steps.map(\.status), [.running, .running],
                       "the superseded Pause paused B's steps")
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, bOne)), bBefore, "the superseded Pause wrote B's task")
        XCTAssertEqual(sut.taskEngineStates[bOne], .running, "the superseded Pause re-derived B's engine mirror")
    }

    // MARK: - D-M11 behavioural guards

    /// `stopEngine(for:)` cancels an in-flight team generation task before the LLM client
    /// releases (D-M11 п.12).
    func testStopEngineCancelsInFlightTeamGenerationBeforeRelease() async throws {
        teamGenerationClient = HeldTeamGenerationClient()
        sut = TestOrchestrator.make(repository: repository, teamGenerationClient: teamGenerationClient)
        await sut.openWorkFolder(folderA)
        await sut.mutateWorkFolder { project in
            guard !project.teams.contains(where: { $0.isGeneratedPlaceholder }) else { return }
            project.teams.append(TeamTemplateFactory.generatedTeam())
        }
        let template = try XCTUnwrap(sut.workFolder?.teams.first { $0.isGeneratedPlaceholder })
        let created = await sut.createTask(title: "Gen", supervisorTask: "build a calculator", preferredTeamID: template.id)
        let genID = try XCTUnwrap(created)
        await sut.startRun(taskID: genID)
        let client = try XCTUnwrap(teamGenerationClient)
        try await waitUntil("the generation's request") { client.requested }
        let genTask = try XCTUnwrap(sut.teamGenerationTasks[genID])

        sut.stopEngine(for: genID)

        XCTAssertTrue(genTask.isCancelled, "stopEngine(for:) must cancel the in-flight team generation task before release")
        client.release(with: .failure(URLError(.cancelled)))
        await genTask.value
        XCTAssertNil(sut.teamGenerationTasks[genID], "stopEngine(for:) must clear the cancelled task handle once it unwinds")
    }

    /// `reportingError(within:)` asks the action's lifecycle after the op: an Autovisor `control_task`
    /// verb whose write straddles the open and commit of B answers `folderChanged` rather than
    /// `success` (D-M11 п.2).
    func testAnAutovisorControlVerbWhoseOpStraddlesAnOpenAnswersFolderChanged() async throws {
        let (aOne, _) = try await sameIDTasks(activeInA: false)
        _ = await sut.ensureTaskLoaded(aOne)
        await sut.mutateTask(taskID: aOne) { task in
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .running)]
            task.runs = [run]
        }
        sut.engineState[aOne] = .running
        let lifecycleA = sut.currentFolderLifecycle
        let path = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == path && task.id == aOne
                && task.runs.last?.steps.contains { $0.status == .paused } == true
        }
        repository.taskWriteHold = write
        let acting = Task {
            await self.sut.performAutovisorAction(.controlTask(taskID: aOne, verb: .pause), within: lifecycleA)
        }
        try await waitHeld(write, "the control_task pause write")
        await sut.openWorkFolder(folderB)
        write.release()
        let result = await acting.value

        XCTAssertEqual(result, AutovisorActionResult.failure(DeferredCallReplies.folderChanged),
                       "reportingError must ask the action's captured lifecycle after the op")
    }

    /// `performAutovisorAction(_:within:)` checks its lifecycle at entry: an action handed an ended
    /// lifecycle refuses with `folderChanged` before touching the folder now open (D-M11 п.4).
    func testAnAutovisorActionHandedAnEndedLifecycleAtEntryAnswersFolderChangedAndWritesNothing() async throws {
        await sut.openWorkFolder(folderA)
        let staleLifecycle = sut.currentFolderLifecycle
        await sut.openWorkFolder(folderB)

        let result = await sut.performAutovisorAction(
            .setWorkFolderContext(content: "stale context"), within: staleLifecycle)

        XCTAssertEqual(result, AutovisorActionResult.failure(DeferredCallReplies.folderChanged))
        XCTAssertNotEqual(sut.workFolder?.settings.context, "stale context",
                          "an action handed an ended lifecycle must not write into the current folder")
    }

    /// Two scheduler starts in one folder lifecycle: when the first poll loop is cancelled in the
    /// same lifecycle while suspended inside `evaluateAutovisorAutoDisable`, the cancelled loop
    /// checks `!Task.isCancelled` before `evaluateDueRecurrences` and does not run an extra due
    /// pass (D-M11 п.6).
    func testTwoSchedulerStartsInOneLifecycleRunNoExtraDuePassFromTheCancelledLoop() async throws {
        sut = TestOrchestrator.make(repository: repository, automationTickInterval: 0.03)
        await sut.openWorkFolder(folderA)
        let managerID = try await handMadeManager()
        _ = await sut.ensureTaskLoaded(managerID)
        await sut.mutateTask(taskID: managerID) {
            $0.recurrence = TaskRecurrence(
                rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: Date(timeIntervalSinceNow: 3600))
        }
        let dueCreated = await sut.createTask(title: "due once", supervisorTask: "x", makeActive: false)
        let dueTask = try XCTUnwrap(dueCreated)
        _ = await sut.ensureTaskLoaded(dueTask)

        let path = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == path && task.id == managerID && task.recurrence?.isEnabled == false
        }
        repository.taskWriteHold = write
        sut.autovisorAutoDisableAt = .distantPast
        try await waitHeld(write, "the first loop's auto-off write")

        sut.stopAutomationScheduler()
        await sut.mutateTask(taskID: dueTask) {
            $0.recurrence = TaskRecurrence(
                rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: Date(timeIntervalSinceNow: -60))
        }
        write.release()
        try await waitForLiveLoops(0, "after the cancelled first loop exits")

        XCTAssertEqual(sut.loadedTask(dueTask)?.runs.count ?? 0, 0,
                       "the cancelled first loop ran an extra evaluateDueRecurrences pass")
        XCTAssertNil(sut.loadedTask(dueTask)?.recurrence?.lastFiredAt,
                     "the cancelled first loop stamped lastFiredAt")
    }

    /// `beginFolderTransition` stops every engine synchronously before `openWorkFolder`'s first
    /// suspension (`tearDownSearchIndexCoordinator`): while the search-index teardown is held,
    /// `taskEngines` is already empty and no step can start (D-M11 п.8).
    func testBeginFolderTransitionStopsEnginesBeforeTheSearchIndexTeardownSuspends() async throws {
        await sut.openWorkFolder(folderA)
        let aOne = try await runningRunTask(title: "A one", makeActive: true)
        _ = sut.engineForTask(aOne)
        XCTAssertNotNil(sut.taskEngines[aOne], "premise: engine is live before openWorkFolder")

        let (teardownEntered, teardownEnteredCont) = AsyncStream<Void>.makeStream()
        let (releaseTeardown, releaseTeardownCont) = AsyncStream<Void>.makeStream()
        NTMSOrchestrator._testSearchIndexTeardownGate = {
            teardownEnteredCont.yield()
            for await _ in releaseTeardown { break }
        }
        let openB = Task { await self.sut.openWorkFolder(self.folderB) }
        for await _ in teardownEntered { break }

        XCTAssertTrue(sut.taskEngines.isEmpty,
                      "beginFolderTransition must stop all engines before tearDownSearchIndexCoordinator suspends")
        await sut.runStep(stepID: "worker", taskID: aOne)
        XCTAssertFalse(sut.llmExecutionService.isStepRunning(stepID: "worker", taskID: aOne),
                       "a step must not start while tearDownSearchIndexCoordinator is suspended")
        XCTAssertTrue(sut.taskEngines.isEmpty)

        NTMSOrchestrator._testSearchIndexTeardownGate = nil
        releaseTeardownCont.yield()
        releaseTeardownCont.finish()
        await openB.value
    }

    /// `deleteAutovisor` re-checks its lifecycle after `removeTask` returns `.removed` across a
    /// residency-reconcile suspension: when B commits while `reconcileChatModelResidency()` is held,
    /// B's manager stays pinned and B's Autovisor stays enabled (D-M11 п.9).
    func testDeletingTheAutovisorSuspendedInResidencyReconcileAcrossAnOpenLeavesTheNextFoldersAutovisorAlone() async throws {
        await sut.openWorkFolder(folderB)
        let bManager = try await handMadeManager()
        await sut.openWorkFolder(folderA)
        let fillerCreated = await sut.createTask(title: "filler", supervisorTask: "f", makeActive: true)
        _ = try XCTUnwrap(fillerCreated)
        let aManager = try await handMadeManager()
        XCTAssertNotEqual(aManager, bManager, "premise: B has no task with A's manager's id")

        let (reconcileEntered, reconcileEnteredCont) = AsyncStream<Void>.makeStream()
        let (releaseReconcile, releaseReconcileCont) = AsyncStream<Void>.makeStream()
        let heldOnce = OSAllocatedUnfairLock(initialState: false)
        NTMSOrchestrator._testResidencyReconcileGate = {
            let shouldHold = heldOnce.withLock { state -> Bool in
                guard !state else { return false }
                state = true
                return true
            }
            guard shouldHold else { return }
            reconcileEnteredCont.yield()
            for await _ in releaseReconcile { break }
        }
        let deleting = Task { await self.sut.deleteAutovisor() }
        for await _ in reconcileEntered { break }

        await sut.openWorkFolder(folderB)
        releaseReconcileCont.yield()
        releaseReconcileCont.finish()
        await deleting.value

        XCTAssertEqual(sut.autovisorTaskID, bManager, "B's manager was unpinned after residency reconcile resumed")
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, true,
                       "B's Autovisor was turned off after residency reconcile resumed")
    }

    /// `createTask(…, within:)` and `removeTask(_:within:)` check the caller's `lifecycle` (not
    /// `currentFolderLifecycle`): a call handed an ended lifecycle after B committed returns
    /// `.folderChanged`, creates nothing in B, and stops no engine in B (D-M11 п.20).
    func testCreateTaskHandedAnEndedLifecycleAfterTheNextFolderCommittedReturnsFolderChangedAndCreatesNothing() async throws {
        await sut.openWorkFolder(folderA)
        let staleLifecycle = sut.currentFolderLifecycle
        await sut.openWorkFolder(folderB)

        let outcome = await sut.createTask(title: "stale", supervisorTask: "x", within: staleLifecycle)
        XCTAssertEqual(outcome, .folderChanged)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 0, "createTask with an ended lifecycle created a task in B")

        let bOne = try await runningRunTask(title: "B one", makeActive: true)
        _ = sut.engineForTask(bOne)
        XCTAssertNotNil(sut.taskEngines[bOne], "premise: B's engine is live")
        let removalOutcome = await sut.removeTask(bOne, within: staleLifecycle, by: .person)
        XCTAssertEqual(removalOutcome, .folderChanged)
        XCTAssertNotNil(sut.taskEngines[bOne], "removeTask with an ended lifecycle stopped B's engine")
    }

    /// Holding `cancelStepExecution` (`StepCancelHold`) across an open and commit of B in each of
    /// `pauseRun`, `restartRole`, `holdDownstreamForRevision`, and `finishAdvisoryRoleAwaiting`:
    /// after release, neither A's nor B's task is written or reset, and B's live step execution
    /// under the same `(taskID, stepID)` stays live (D-M11 чтение-1).
    func testPauseRestartRevisionHoldAndAdvisoryFinishHeldInStepCancelAcrossAnOpenWriteAndResetNothing() async throws {
        enum Verb: CaseIterable { case pause, restart, revisionHold, advisoryFinish }
        for verb in Verb.allCases {
            let (a, b) = try freshFolders("cancel-hold-\(verb)")
            await sut.openWorkFolder(b)
            let bCreated = await sut.createTask(title: "B one", supervisorTask: "x", makeActive: true)
            let bOne = try XCTUnwrap(bCreated)
            await sut.openWorkFolder(a)
            let aCreated = await sut.createTask(title: "A one", supervisorTask: "x", makeActive: true)
            let aOne = try XCTUnwrap(aCreated)
            XCTAssertEqual(aOne, bOne, "\(verb): premise — same task id in both folders")
            let roleID = try rosterRole(of: aOne)
            await sut.mutateTask(taskID: aOne) { task in
                var run = Run(id: 0, roleStatuses: [roleID: .working])
                run.steps = [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .running)]
                task.runs = [run]
            }
            sut.engineState[aOne] = .running
            let lifecycleA = sut.currentFolderLifecycle
            let cancelHold = holdStepCancel { stepID, taskID in stepID == roleID && taskID == aOne }

            let runningVerb = Task { @MainActor in
                switch verb {
                case .pause:
                    _ = await self.sut.pauseRun(taskID: aOne)
                case .restart:
                    await self.sut.restartRole(taskID: aOne, roleID: roleID, comment: "reset me")
                case .revisionHold:
                    await self.sut.holdDownstreamForRevision(
                        taskID: aOne, runningRoleIDs: [roleID], requesterRoleID: "requester", within: lifecycleA)
                case .advisoryFinish:
                    self.verbVerdict = await self.sut.finishAdvisoryRoleAwaiting(taskID: aOne, roleID: roleID)
                }
            }
            try await waitHeld(cancelHold, "\(verb): cancelStepExecution hold")
            // A's bytes at the hold, not before the verb: a Pause records its cause on A's run
            // (`Run.pauseCause`) before it cancels anything — in A, before the transition — and
            // what this test guards is a write AFTER the hold resumes across the open of B.
            let aBefore = try Data(contentsOf: taskJSON(a, aOne))

            await sut.openWorkFolder(b)
            _ = await sut.ensureTaskLoaded(bOne)
            await sut.mutateTask(taskID: bOne) { task in
                var run = Run(id: 0, roleStatuses: [roleID: .working])
                run.steps = [StepExecution(id: roleID, role: .softwareEngineer, title: "Work", status: .running)]
                task.runs = [run]
            }
            sut.engineState[bOne] = .running
            sut._testRegisterStepTask(stepID: roleID, taskID: bOne)
            let bBefore = try Data(contentsOf: taskJSON(b, bOne))

            await cancelHold.release()
            await runningVerb.value

            XCTAssertEqual(try Data(contentsOf: taskJSON(a, aOne)), aBefore,
                           "\(verb): wrote or reset A's task after cancelStepExecution resumed across an open")
            XCTAssertEqual(try Data(contentsOf: taskJSON(b, bOne)), bBefore,
                           "\(verb): wrote or reset B's task after cancelStepExecution resumed across an open")
            XCTAssertTrue(sut.llmExecutionService.isExecutionLive(stepID: roleID, taskID: bOne),
                          "\(verb): cancelStepExecution wiped B's live step execution after resuming across an open")
            if verb == .advisoryFinish {
                XCTAssertEqual(verbVerdict, false, "advisoryFinish superseded during cancelStepExecution must return false")
            }
            sut.llmExecutionService.stepCancelHold = nil
        }
    }
}

// MARK: - Held team-generation client

/// A team-generation client whose requests wait for the test: `requested` says one arrived, and
/// `release(with:)` answers every request waiting and every one after — the scripted events, or a
/// transport failure. A request whose consumer is cancelled first simply goes unanswered: the
/// stream ends with its consumer, the way a cancelled request ends.
final class HeldTeamGenerationClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested = false
    private var outcome: Result<[StreamEvent], Error>?
    private var waiters: [CheckedContinuation<Result<[StreamEvent], Error>, Never>] = []

    var requested: Bool { lock.withLock { _requested } }

    func release(with outcome: Result<[StreamEvent], Error>) {
        let pending: [CheckedContinuation<Result<[StreamEvent], Error>, Never>] = lock.withLock {
            guard self.outcome == nil else { return [] }
            self.outcome = outcome
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: outcome) }
    }

    private func answer() async -> Result<[StreamEvent], Error> {
        await withCheckedContinuation { continuation in
            let ready: Result<[StreamEvent], Error>? = lock.withLock {
                if let outcome { return outcome }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { _requested = true }
        return AsyncThrowingStream { continuation in
            let answering = Task {
                switch await self.answer() {
                case .success(let events):
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in answering.cancel() }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
