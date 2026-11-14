import XCTest

@testable import NanoTeams

/// Pins `openWorkFolder` across its off-main read (CLAUDE.md #38).
///
/// Since 2026-09-15 the folder is read off the main actor — the read held the main thread for
/// 165 ms at launch — so an open has a suspension between "folder B was asked for" and "B's
/// snapshot is applied". Two things must hold across it:
/// - the process never names one folder's URL beside another folder's snapshot: the URL is
///   committed with the outcome, after the read;
/// - two opens can overlap (the user picks A, then B before A's read returns), and only the
///   LATEST may apply its snapshot, report its error or run the rest of the open.
///
/// `SelectivelyFailingRepository.openReadHolds` holds a read until the test releases it — after a
/// later open's whole run, which is the order a real slow disk produces; its `openStarts` says a
/// read is under way.
@MainActor
final class WorkFolderOpenSupersessionTests: WorkFolderLifecycleTestCase {

    /// RED: assign `workFolderURL` before the read again → while B is read, the process names B
    /// beside A's snapshot, and a write through the URL in that window lands A's state in B.
    func testWhileAFolderIsRead_theProcessStillDescribesThePreviousFolder() async throws {
        await sut.openWorkFolder(folderA)
        let folderAID = sut.snapshot?.projection.id
        XCTAssertNotNil(folderAID, "anti-vacuum: A never opened, so nothing below compares folders")

        let readB = holdReads(of: folderB)
        let openB = try await startOpen(of: folderB)
        XCTAssertEqual(sut.workFolderURL, folderA, "the URL named B before B's snapshot existed")
        XCTAssertEqual(sut.snapshot?.projection.id, folderAID)
        readB.release()
        await openB.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertNotEqual(sut.snapshot?.projection.id, folderAID, "anti-vacuum: B's open never applied")
    }

    /// RED: delete the guard after the read → A's snapshot, carrying A's task, lands after B's
    /// open finished, and the process shows folder B's URL with folder A's tasks. RED as well:
    /// record the commit's lifecycle above that guard → A's read, returning after B committed,
    /// names A's ended lifecycle as the one actions begin in, and every create, toggle and
    /// scheduler pass in B is refused as a folder change until the next open.
    func testAnOpenSupersededDuringItsRead_appliesNothing() async throws {
        await sut.openWorkFolder(folderA)
        let seeded = await sut.createTask(title: "only in A", supervisorTask: "x")
        XCTAssertNotNil(seeded, "anti-vacuum: A must hold a task, or both snapshots look alike")
        await sut.openWorkFolder(folderB)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 0, "precondition: B is empty")

        try await overlapSlowOpen(of: folderA, byOpenOf: folderB)

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 0,
                       "the superseded open of A applied its snapshot over B's")
        XCTAssertNil(sut.lastErrorMessage)
        XCTAssertTrue(sut.isCurrentFolderLifecycle(sut.currentFolderLifecycle),
                      "the superseded open of A recorded its lifecycle over B's commit")
        let createdInB = await sut.createTask(title: "in B", supervisorTask: "x")
        XCTAssertNotNil(createdInB, "a create in B was refused as a folder change: \(sut.lastErrorMessage ?? "")")
    }

    /// RED: delete the guard in `catch` → A's refusal is reported against B, and
    /// `discardWorkFolderState()` wipes the snapshot B just opened. RED as well: record the failed
    /// open's lifecycle above that guard → A's late failure names A's ended lifecycle as the one
    /// actions begin in, and a create in B is refused as a folder change.
    func testASupersededOpenThatFails_reportsNothing_andDiscardsNothing() async throws {
        repository.openFailurePaths = [folderA.path]

        try await overlapSlowOpen(of: folderA, byOpenOf: folderB)

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertNotNil(sut.snapshot, "the superseded failure discarded the newer open's snapshot")
        XCTAssertNil(sut.lastErrorMessage, "a superseded open must not report its error")
        XCTAssertTrue(sut.isCurrentFolderLifecycle(sut.currentFolderLifecycle),
                      "the superseded failure recorded its lifecycle over B's commit")
        let createdInB = await sut.createTask(title: "in B", supervisorTask: "x")
        XCTAssertNotNil(createdInB, "a create in B was refused as a folder change: \(sut.lastErrorMessage ?? "")")
    }

    /// The latest open still reports its OWN failure — the guard only silences older ones — and
    /// still commits its URL, which `closeProject` / `resetAllData` read.
    func testTheLatestOpenThatFails_stillReports_andCommitsItsURL() async throws {
        repository.openFailurePaths = [folderB.path]
        await sut.openWorkFolder(folderB)
        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertNil(sut.snapshot)
        XCTAssertEqual(sut.workFolderURL, folderB)
    }

    // MARK: - After the read (2026-10-28)

    /// An open of A superseded AFTER its read — held just before its MCP step while the open of
    /// B tears down and reads — starts no MCP connection for A: nothing logs under A, and the
    /// server ends up connected for B.
    ///
    /// RED until 2026-10-28: the open re-checked its generation only after the read. A
    /// resumed with `workFolderURL` still A, `setWorkFolder(A)` ended B's shutdown and built A's
    /// connections, and B's own `setWorkFolder(B)` kept them — logging under A.
    func testAnOpenSupersededAfterItsReadStartsNoMCPConnectionForItsFolder() async throws {
        let config = try useLoggingMCP()
        let (openA, hold) = try await holdOpen(of: folderA, at: .mcpServers)
        let (openB, readB) = try await startReadingOpen(of: folderB)
        await hold.release()
        await openA.value
        readB.release()
        await openB.value

        let logA = NTMSPaths(workFolderRoot: folderA).mcpRPCLogJSONL(slug: config.slug)
        let logB = NTMSPaths(workFolderRoot: folderB).mcpRPCLogJSONL(slug: config.slug)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !FileManager.default.fileExists(atPath: logB.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: logB.path), "premise: B's open connects the server")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logA.path),
                       "the superseded open started a connection that logged under its folder")
        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertEqual(sut.configuration.lastOpenedWorkFolderPath, folderB.path)
        await sut.tearDownMCPServerManager(budget: 0)
    }

    /// An open of A superseded after its read — held just before it records the folder as the
    /// launch-time restore target, while the open of B runs to the end — does not record A.
    ///
    /// RED until 2026-10-28: A resumed and wrote itself over B, so the next launch reopened
    /// the folder the person had left.
    func testAnOpenSupersededAfterItsReadDoesNotBecomeTheRestoreTarget() async throws {
        let (openA, hold) = try await holdOpen(of: folderA, at: .restoreTarget)
        await sut.openWorkFolder(folderB)
        XCTAssertEqual(sut.configuration.lastOpenedWorkFolderPath, folderB.path, "premise: B opened")
        await hold.release()
        await openA.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertEqual(sut.configuration.lastOpenedWorkFolderPath, folderB.path,
                       "the superseded open made its folder the restore target")
    }

    /// The search index an open of A had started when an open of B began is not installed — B
    /// installs its own. The coordinator's start suspends; A's folder was still the one named
    /// while B read, so the folder check alone let A's coordinator in, and B's open then found
    /// one installed and kept it.
    ///
    /// RED until 2026-10-28: the process indexed A while showing B.
    func testASearchIndexStartedBySupersededOpenIsNotInstalled() async throws {
        sut.configuration.exploratorySearchEnabled = true
        let (openA, hold) = try await holdOpen(of: folderA, at: .searchIndexInstall)
        let (openB, readB) = try await startReadingOpen(of: folderB)
        await hold.release()
        await openA.value
        readB.release()
        await openB.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertEqual(sut.searchIndexCoordinator?.workFolderRoot.path, folderB.path,
                       "the superseded open's index is the one installed")
        await sut.tearDownSearchIndexCoordinator()
    }

    /// The Autovisor's open-time pass for A is not started once an open of B has begun: B's open
    /// stopped every engine at its start, so a pass A started after that would run on, for the
    /// folder the person left.
    ///
    /// RED until 2026-10-28: the pass started, and its engine outlived the switch.
    func testAnAutovisorPassForASupersededOpenIsNotStarted() async throws {
        await sut.openWorkFolder(folderA)
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
        await sut.openWorkFolder(folderB)
        sut.stopAllEngines()
        XCTAssertTrue(sut.taskEngines.isEmpty, "premise: nothing runs")

        let (openA, hold) = try await holdOpen(of: folderA, at: .autovisorPass)
        let (openB, readB) = try await startReadingOpen(of: folderB)
        await hold.release()
        await openA.value
        readB.release()
        await openB.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertTrue(sut.taskEngines.isEmpty, "the superseded open started the Autovisor's pass for its folder")
    }

    // MARK: - The Autovisor chain, `createTask`, and every post-read step of an open (2026-10-28)

    /// The Autovisor chain of an open superseded AFTER the manager's recurrence was written —
    /// held there while the open of B runs to the end and commits — writes nothing into B once it
    /// resumes: not the team sync, not the goal and memory defaults, not the brief; and starts no
    /// pass.
    ///
    /// RED until 2026-10-28: only the pass was asked about; the writes before it went
    /// through the CURRENT folder — B's settings.json took A's default goal and memory.
    func testAnAutovisorChainOfASupersededOpenWritesNothingIntoTheNextFolder() async throws {
        await sut.openWorkFolder(folderA)
        _ = try await handMadeManager()
        await sut.openWorkFolder(folderB)
        sut.stopAllEngines()

        let (openA, hold) = try await holdOpen(of: folderA, at: .autovisorTeamSync)
        await sut.openWorkFolder(folderB)
        let before = folderFiles(folderB)
        XCTAssertEqual(before.count, 4, "premise: B's files exist")
        await hold.release()
        await openA.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertEqual(folderFiles(folderB), before, "the superseded Autovisor chain wrote into the folder now open")
        XCTAssertTrue(sut.taskEngines.isEmpty, "the superseded open started a pass")
    }

    /// The CREATE path of a superseded open's Autovisor — A switched on with no manager yet —
    /// held after its team was ensured while the open of B runs to the end: nothing of A is
    /// created in B — no task, no pinned manager id, no recurrence.
    ///
    /// RED until 2026-10-28: A's manager task was created in B, its id pinned into B's
    /// workfolder.json.
    func testTheAutovisorCreatePathOfASupersededOpenCreatesNothingInTheNextFolder() async throws {
        await sut.openWorkFolder(folderA)
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
        await sut.openWorkFolder(folderB)

        let (openA, hold) = try await holdOpen(of: folderA, at: .autovisorTaskCreate)
        await sut.openWorkFolder(folderB)
        let before = folderFiles(folderB)
        await hold.release()
        await openA.value

        XCTAssertEqual(folderFiles(folderB), before, "the superseded create path wrote into the folder now open")
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 0, "a task was created in B")
        XCTAssertNil(sut.snapshot?.workFolder.state.autovisorTaskID)
        XCTAssertTrue(sut.taskEngines.isEmpty)
    }

    /// EVERY check of the Autovisor chain — each point where it resumes from a suspension and is
    /// about to write through the current folder — stops a superseded open: held at that point
    /// while the open of B runs to the end, A's chain writes nothing into B, loads nothing of B's,
    /// surfaces nothing and starts no pass. B is built so that each write the chain could make
    /// would SHOW: B has a task with the id A's manager has (#2, with a paused run, not loaded),
    /// its own manager (#1) whose brief is stale against B's goal, no memory, and a goal
    /// attachment whose file is gone (the brief's self-heal would rewrite B's settings.json —
    /// `.autovisorBrief`); A's manager is #2 (existing path) or not yet made (create path). A
    /// write to A's manager id with nothing loaded under it fails "task not loaded", so for
    /// `.autovisorManagerRecurrence` and `.autovisorBriefWrite` the banner is what shows here —
    /// the write itself shows in the test below, where B's task #2 IS loaded.
    ///
    /// `.autovisorTeamSync` guards a write that is a no-op once B's own open has synced its team,
    /// as it has here; it shows only in an interleaving this loop does not build —
    /// `testASupersededChainSyncsNothingIntoTheNextFoldersAutovisorTeam`.
    ///
    /// Three of the checks follow an `await` that does not suspend in today's build —
    /// `.autovisorManagerRecurrence` and `.autovisorBriefWrite` a load (`ensureTaskLoaded` reads
    /// task.json without one), `.autovisorBrief` a settings-only `mutateWorkFolder` (its one
    /// suspension is for a teams change) — so their window is the hold's alone; they are pinned
    /// for the day those callees suspend.
    ///
    /// Since 2026-10-28 each hold is also where the check is ASKED with the wrong token or
    /// not: the check reads its lifecycle after the hold returns, and B has committed by then, so
    /// a check asked with `currentFolderLifecycle` answers for B and goes on. And A — the folder
    /// the chain belongs to — is read too: at every step it holds no Autovisor manager its state
    /// does not pin (the create path pins in the create's own synchronous stretch; until 2026-10-28
    /// a chain stopped at `.autovisorTaskLoad` or at the retired `.autovisorTaskPin` left an
    /// unpinned manager in A).
    ///
    /// RED until 2026-10-28: only `.autovisorPass` was asked. Also until 2026-10-28
    /// B's task #2 had no run (`mutateTask` refuses an unloaded task), B's goal
    /// attachments were all present and no banner was counted, so deleting `.autovisorBrief`,
    /// `.autovisorManagerRecurrence` or `.autovisorBriefWrite` alone kept this test green.
    func testEveryCheckOfTheAutovisorChainStopsASupersededOpen() async throws {
        let steps: [(WorkFolderOpenStep, managerExists: Bool)] = [
            (.autovisorManagerRecurrence, true), (.autovisorTeamSync, true), (.autovisorDefaults, true),
            (.autovisorBrief, true), (.autovisorBriefLoad, true), (.autovisorBriefWrite, true), (.autovisorPass, true),
            (.autovisorTaskCreate, false), (.autovisorTaskLoad, false), (.autovisorTaskRecurrence, false),
        ]
        for (step, managerExists) in steps {
            let (a, b) = try freshFolders("\(step)")
            await sut.openWorkFolder(b)
            let bManagerCreated = await sut.createTask(title: "B manager", supervisorTask: "stale brief", makeActive: false)
            let bManager = try XCTUnwrap(bManagerCreated)
            let bTwoCreated = await sut.createTask(title: "B two", supervisorTask: "two", makeActive: false)
            let bTwo = try XCTUnwrap(bTwoCreated)
            _ = await sut.ensureTaskLoaded(bTwo)
            await sut.mutateTask(taskID: bTwo) { task in
                var run = Run(id: 0, roleStatuses: ["worker": .working])
                run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .paused)]
                task.runs = [run]
            }
            XCTAssertEqual(sut.loadedTask(bTwo)?.runs.count, 1, "\(step): premise — B's task #\(bTwo) has its paused run")
            await sut.mutateWorkFolder {
                $0.state.autovisorTaskID = bManager
                $0.settings.autovisorGoal = "B goal"
                $0.settings.autovisorGoalAttachmentPaths = ["gone.txt"]
            }
            await sut.openWorkFolder(a)
            let fillerCreated = await sut.createTask(title: "filler", supervisorTask: "f", makeActive: false)
            _ = try XCTUnwrap(fillerCreated)
            if managerExists {
                let managerID = try await handMadeManager()
                XCTAssertEqual(managerID, bTwo, "\(step): premise — A's manager has B's second task's id")
            } else {
                await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
            }
            await sut.openWorkFolder(b)
            sut.stopAllEngines()

            let (openA, hold) = try await holdOpen(of: a, at: step)
            await sut.openWorkFolder(b)
            let bPaths = NTMSPaths(workFolderRoot: b)
            func bState() -> [String: Data] {
                var state = folderFiles(b)
                for id in [bManager, bTwo] { state["task \(id)"] = try? Data(contentsOf: bPaths.taskJSON(taskID: id)) }
                return state
            }
            let before = bState()
            XCTAssertNil(sut.loadedTask(bTwo), "\(step): premise — nothing has loaded B's task #\(bTwo)")
            XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorGoalAttachmentPaths, ["gone.txt"],
                           "\(step): premise — B still names the attachment whose file is gone")
            let errorsBefore = sut.errorSurfaceCount
            await hold.release()
            await openA.value

            XCTAssertEqual(sut.workFolderURL, b, "\(step)")
            XCTAssertEqual(bState(), before, "\(step): the superseded chain wrote into the folder now open")
            XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "\(step): the superseded chain surfaced an error in B's session")
            XCTAssertNil(sut.loadedTask(bTwo), "\(step): the superseded chain loaded B's task")
            XCTAssertNil(sut.taskEngineStates[bTwo], "\(step): the superseded chain seeded B's task's engine state")
            XCTAssertTrue(sut.taskEngines.isEmpty, "\(step): the superseded chain started a pass")
            // And A — the folder the chain belongs to — holds no manager its state does not pin:
            // an unpinned "Autovisor" task is a visible task in A's list (only the PINNED id is
            // hidden), and A's next open would create a second manager beside it.
            let aDisk = createdState(a)
            let managers = aDisk.index?.tasks.filter { $0.title == "Autovisor" }.map(\.id) ?? []
            XCTAssertTrue(managers.allSatisfy { $0 == aDisk.state?.autovisorTaskID },
                          "\(step): A holds an unpinned Autovisor manager — managers \(managers), "
                              + "pinned \(String(describing: aDisk.state?.autovisorTaskID))")
        }
    }

    /// A `createTask` whose folder changed while it waited for the pending active-task write
    /// creates nothing — in neither folder — and applies nothing: the snapshot stays the folder
    /// now open. It answers `nil` and says why, the way its callers read a refusal
    /// (`lastErrorMessage`, which `errorSurfaced(since:)` counts).
    ///
    /// RED until 2026-10-28: it created the task in the folder it had captured and applied
    /// THAT folder's snapshot under the new URL — the pairing `discardWorkFolderState` exists for.
    func testACreateTaskWhoseFolderChangedDuringItsFlushCreatesAndAppliesNothing() async throws {
        await sut.openWorkFolder(folderA)
        let (release, released) = AsyncStream<Void>.makeStream()
        sut.pendingActiveTaskWrite = Task<Void, Error> { for await _ in release { break } }
        let errorsBefore = sut.errorSurfaceCount
        let creating = Task { await sut.createTask(title: "late", supervisorTask: "x") }
        await sut.openWorkFolder(folderB)
        let folderBID = sut.snapshot?.projection.id
        released.yield()
        released.finish()
        let created = await creating.value

        XCTAssertNil(created, "a task was created across a folder switch")
        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertEqual(sut.snapshot?.projection.id, folderBID, "another folder's snapshot was applied under B's URL")
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 0)
        let indexA = try? AtomicJSONStore().read(TasksIndex.self, from: NTMSPaths(workFolderRoot: folderA).tasksIndexJSON)
        XCTAssertEqual(indexA?.tasks.count ?? 0, 0, "the task was written into the folder the app left")
        XCTAssertGreaterThan(sut.errorSurfaceCount, errorsBefore, "the refusal was not surfaced")
        XCTAssertEqual(sut.lastErrorMessage, NTMSOrchestrator.createTaskFolderChangedMessage)
    }

    /// `.delegationHistory`: A's active task has a paused run. Held there while B reads, A
    /// seeds no engine state for it — B's session has no engine for A's task id.
    ///
    /// Pins that the `.delegationHistory` lifecycle check isnot skipped.
    func testAnOpenHeldBeforeItsEngineStateSeedsNothingForItsTasks() async throws {
        await sut.openWorkFolder(folderA)
        let taskIDCreated = await sut.createTask(title: "paused", supervisorTask: "x")
        let taskID = try XCTUnwrap(taskIDCreated)
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .paused)]
            task.runs = [run]
        }
        await sut.openWorkFolder(folderB)
        XCTAssertNil(sut.taskEngineStates[taskID], "premise: B has no engine for that id")

        let (openA, hold) = try await holdOpen(of: folderA, at: .delegationHistory)
        let (openB, readB) = try await startReadingOpen(of: folderB)
        await hold.release()
        await openA.value
        readB.release()
        await openB.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertNil(sut.taskEngineStates[taskID], "the superseded open seeded an engine state into B's session")
    }

    /// `.staleStatusSweep`: a task of A that is not the active one, left `.running` on disk. Held
    /// there while B reads, A rewrites nothing on disk — the task is still `.running`; A's next
    /// open recovers it.
    ///
    /// Pins that the `.staleStatusSweep` lifecycle check is not skipped.
    func testAnOpenHeldBeforeItsStatusSweepRewritesNothing() async throws {
        await sut.openWorkFolder(folderA)
        let staleCreated = await sut.createTask(title: "stale", supervisorTask: "x")
        let stale = try XCTUnwrap(staleCreated)
        await sut.mutateTask(taskID: stale) { task in
            task.status = .running
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .running)]
            task.runs = [run]
        }
        let activeCreated = await sut.createTask(title: "active", supervisorTask: "y")
        _ = try XCTUnwrap(activeCreated)
        await sut.openWorkFolder(folderB)
        let index = NTMSPaths(workFolderRoot: folderA).tasksIndexJSON
        func diskStatus() -> TaskStatus? {
            (try? AtomicJSONStore().read(TasksIndex.self, from: index))?.tasks.first { $0.id == stale }?.status
        }
        XCTAssertEqual(diskStatus(), .running, "premise: left running on disk")

        let (openA, hold) = try await holdOpen(of: folderA, at: .staleStatusSweep)
        let (openB, readB) = try await startReadingOpen(of: folderB)
        await hold.release()
        await openA.value
        readB.release()
        await openB.value

        XCTAssertEqual(diskStatus(), .running, "the superseded open swept A's statuses")
    }

    /// `.automationScheduler`: a recurring task of A whose slot passed while the app was closed.
    /// Held there while B reads — and B's open then fails — A reconciles nothing on its disk and
    /// leaves no poll loop running.
    ///
    /// Pins that the `.automationScheduler` lifecycle check is not skipped.
    func testAnOpenHeldBeforeItsSchedulerReconcilesNothingAndStartsNoLoop() async throws {
        await sut.openWorkFolder(folderA)
        let taskIDCreated = await sut.createTask(title: "recurring", supervisorTask: "x")
        let taskID = try XCTUnwrap(taskIDCreated)
        let missed = Date(timeIntervalSinceNow: -7200)
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: missed)
        }
        await sut.openWorkFolder(folderB)
        func diskNextFire() throws -> Date? {
            try NTMSRepository().loadTask(at: folderA, taskID: taskID).recurrence?.nextFireAt
        }
        let onDisk = try XCTUnwrap(try diskNextFire(), "premise: the slot is on disk")
        XCTAssertEqual(onDisk.timeIntervalSince(missed), 0, accuracy: 0.01, "premise: the slot passed on disk")

        let (openA, hold) = try await holdOpen(of: folderA, at: .automationScheduler)
        repository.openFailurePaths = [folderB.path]
        let (openB, readB) = try await startReadingOpen(of: folderB)
        await hold.release()
        await openA.value
        readB.release()
        await openB.value

        XCTAssertEqual(try diskNextFire(), onDisk, "the superseded open reconciled A's recurrence")
        XCTAssertNil(sut.automationPollTask, "the superseded open left a poll loop running")
    }

    /// `.autovisorTeam`: a folder opened for the first time. Held there while B reads, A writes no
    /// Autovisor team into its teams.json.
    ///
    /// Pins that the `.autovisorTeam` lifecycle check is not skipped.
    func testAnOpenHeldBeforeTheAutovisorTeamWritesNoTeam() async throws {
        let (openA, hold) = try await holdOpen(of: folderA, at: .autovisorTeam)
        let (openB, readB) = try await startReadingOpen(of: folderB)
        await hold.release()
        await openA.value
        readB.release()
        await openB.value

        let teams = try AtomicJSONStore().read(TeamsFile.self, from: NTMSPaths(workFolderRoot: folderA).teamsJSON)
        XCTAssertFalse(teams.teams.isEmpty, "premise: A was bootstrapped")
        XCTAssertFalse(teams.teams.contains { $0.templateID == AutovisorConstants.teamTemplateID },
                       "the superseded open wrote the Autovisor team")
    }

    /// `.autovisorTask`: A's manager exists, with a paused run nothing has loaded. Held there while
    /// B reads, A starts no pass and seeds no engine state for its manager — not even through the
    /// load the Autovisor's own first step makes, which asks only after it.
    ///
    /// Pins that the `.autovisorTask` lifecycle check is not skipped. Only since 2026-10-28: until then the paused run
    /// was never written (`handMadeManager`), a load of the manager seeded nothing, and removing the check
    /// survived every class.
    func testAnOpenHeldBeforeTheAutovisorTaskStartsAndSeedsNothing() async throws {
        await sut.openWorkFolder(folderA)
        let managerID = try await handMadeManager(pausedRun: true)
        await sut.openWorkFolder(folderB)
        sut.stopAllEngines()

        let (openA, hold) = try await holdOpen(of: folderA, at: .autovisorTask)
        XCTAssertNil(sut.loadedTask(managerID), "premise: nothing of A's open has loaded its manager")
        let (openB, readB) = try await startReadingOpen(of: folderB)
        await hold.release()
        await openA.value
        readB.release()
        await openB.value

        XCTAssertTrue(sut.taskEngines.isEmpty, "the superseded open started a pass")
        XCTAssertNil(sut.taskEngineStates[managerID], "the superseded open seeded its manager's engine state")
    }

    /// `.sleepTimer`: A has the Autovisor's auto-off timer and a bundled-update report with a
    /// banner. Held there while B reads — and B then held at its OWN `.sleepTimer`, before it
    /// arms or reports anything — A re-armed no deadline, posted no report and no banner; and the
    /// search index installed at the end is B's.
    ///
    /// Pins that the `.sleepTimer` lifecycle check is not skipped.
    func testAnOpenHeldBeforeItsSleepTimerArmsReportsAndInstallsNothing() async throws {
        sut.configuration.exploratorySearchEnabled = true
        await sut.openWorkFolder(folderA)
        _ = try await handMadeManager()
        await sut.mutateWorkFolder {
            $0.settings.autovisorActivation.autoDisableEnabled = true
            $0.settings.autovisorActivation.autoDisableAfterSeconds = 3600
        }
        await sut.openWorkFolder(folderA)
        XCTAssertNotNil(sut.autovisorAutoDisableAt, "premise: an open of A arms its auto-off deadline")
        await sut.openWorkFolder(folderB)
        XCTAssertNil(sut.autovisorAutoDisableAt, "premise: B's open clears it")
        await sut.tearDownSearchIndexCoordinator()
        let report = BundledUpdateReport(scanFailure: .taskFileUnreadable(taskID: 9, relativePath: "tasks/9/task.json", reason: "x"))
        let banner = try XCTUnwrap(report.bannerMessage)
        repository.openedBundledUpdates[folderA.path] = report

        let (openA, holdA) = try await holdOpen(of: folderA, at: .sleepTimer)
        let holdB = holdNextOpen(at: .sleepTimer)
        let readB = holdReads(of: folderB)
        let openB = try await startOpen(of: folderB)
        await holdA.release()
        await openA.value
        readB.release()
        try await waitHeld(holdB, "the open of B")

        XCTAssertNil(sut.autovisorAutoDisableAt, "the superseded open re-armed its auto-off deadline")
        XCTAssertNil(sut.bundledUpdateReport, "the superseded open posted its bundled-update report")
        XCTAssertNotEqual(sut.lastErrorMessage, banner, "the superseded open posted its banner")
        await holdB.release()
        await openB.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertEqual(sut.searchIndexCoordinator?.workFolderRoot.path, folderB.path, "the index installed is not B's")
        XCTAssertNotEqual(sut.lastErrorMessage, banner)
        await sut.tearDownSearchIndexCoordinator()
    }

    // MARK: - The writes the checks above could not show, and the token each is asked with (2026-10-28)

    /// `.autovisorTeamSync`, where its write shows: B's own Autovisor manager is off its template
    /// on disk — a tool the template does not allow, the way an older build seeded it — and B's
    /// open is held at its first step after its read, before its own team sync. A's chain, held at
    /// `.autovisorTeamSync` meanwhile, is released: it syncs nothing into B, on disk or in the
    /// snapshot B's open goes on with. B's own open then syncs the team (the write would show).
    ///
    /// Pins the `.autovisorTeamSync` lifecycle check. The loop above cannot: there B's open has run to the end,
    /// and a sync of a team B's own open just synced writes nothing.
    func testASupersededChainSyncsNothingIntoTheNextFoldersAutovisorTeam() async throws {
        await sut.openWorkFolder(folderA)
        _ = try await handMadeManager()
        await sut.openWorkFolder(folderB)
        await sut.mutateWorkFolder { projection in
            guard let team = projection.teams.firstIndex(where: { $0.templateID == AutovisorConstants.teamTemplateID }),
                  let role = projection.teams[team].roles.firstIndex(where: {
                      $0.systemRoleID == AutovisorConstants.managerRoleSystemID
                  })
            else { return }
            projection.teams[team].roles[role].toolIDs.append(ToolNames.writeFile)
        }
        let teamsB = NTMSPaths(workFolderRoot: folderB).teamsJSON
        func toolsOnDisk() throws -> [String]? {
            Self.managerTools(try AtomicJSONStore().read(TeamsFile.self, from: teamsB).teams)
        }
        XCTAssertEqual(try toolsOnDisk()?.contains(ToolNames.writeFile), true, "premise: B's manager is off its template")
        sut.stopAllEngines()

        let (openA, holdA) = try await holdOpen(of: folderA, at: .autovisorTeamSync)
        let holdB = holdNextOpen(at: .delegationHistory)
        let openB = Task { await sut.openWorkFolder(folderB) }
        try await waitHeld(holdB, "the open of B")
        XCTAssertEqual(sut.workFolderURL, folderB, "premise: B's snapshot is applied")
        let before = try Data(contentsOf: teamsB)
        await holdA.release()
        await openA.value

        XCTAssertEqual(try Data(contentsOf: teamsB), before, "the superseded chain synced B's Autovisor team on disk")
        XCTAssertEqual(Self.managerTools(sut.snapshot?.projection.teams ?? [])?.contains(ToolNames.writeFile), true,
                       "the superseded chain synced B's Autovisor team in the snapshot")
        await holdB.release()
        await openB.value
        XCTAssertEqual(try toolsOnDisk()?.contains(ToolNames.writeFile), false,
                       "anti-vacuum: B's own open syncs the team, so the chain's sync would have shown")
    }

    /// The chain's two TASK writes — the existing manager's recurrence (`.autovisorManagerRecurrence`)
    /// and its brief (`.autovisorBriefWrite`) — where they would land: B's task with the id A's
    /// manager has is B's ACTIVE task, loaded whenever B is open. Held at each while B's open runs
    /// to the end, A's chain writes nothing into that task — no recurrence, not A's goal as its
    /// brief — and surfaces nothing.
    ///
    /// Pins the `.autovisorManagerRecurrence` and `.autovisorBriefWrite` checks (the loop above, where that task is not loaded, sees
    /// only the "task not loaded" banner). Neither check follows a suspension in today's build —
    /// `ensureTaskLoaded` reads task.json without one — so each window is the hold's alone: the
    /// test pins what the chain does if that load ever suspends, as the folder's own read did.
    func testASupersededChainWritesNothingIntoTheNextFoldersTaskWithItsManagersID() async throws {
        for step: WorkFolderOpenStep in [.autovisorManagerRecurrence, .autovisorBriefWrite] {
            let (a, b) = try freshFolders("loaded-\(step)")
            await sut.openWorkFolder(b)
            let bOneCreated = await sut.createTask(title: "B one", supervisorTask: "one", makeActive: false)
            _ = try XCTUnwrap(bOneCreated)
            let bTwoCreated = await sut.createTask(title: "B two", supervisorTask: "two", makeActive: true)
            let bTwo = try XCTUnwrap(bTwoCreated)
            await sut.openWorkFolder(a)
            let fillerCreated = await sut.createTask(title: "filler", supervisorTask: "f", makeActive: false)
            _ = try XCTUnwrap(fillerCreated)
            let managerID = try await handMadeManager()
            XCTAssertEqual(managerID, bTwo, "\(step): premise — A's manager has the id of B's active task")
            await sut.openWorkFolder(b)
            sut.stopAllEngines()

            let (openA, hold) = try await holdOpen(of: a, at: step)
            await sut.openWorkFolder(b)
            XCTAssertEqual(sut.activeTaskID, bTwo, "\(step): premise — B's task #\(bTwo) is its active task")
            let taskJSON = NTMSPaths(workFolderRoot: b).taskJSON(taskID: bTwo)
            let before = try Data(contentsOf: taskJSON)
            let errorsBefore = sut.errorSurfaceCount
            await hold.release()
            await openA.value

            XCTAssertEqual(sut.workFolderURL, b, "\(step)")
            XCTAssertEqual(try Data(contentsOf: taskJSON), before, "\(step): the superseded chain wrote into B's task #\(bTwo)")
            XCTAssertNil(sut.activeTask?.recurrence, "\(step): A's manager recurrence landed on B's task")
            XCTAssertEqual(sut.activeTask?.supervisorTask, "two", "\(step): A's goal landed as B's task's brief")
            XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "\(step): the superseded chain surfaced an error")
            XCTAssertTrue(sut.taskEngines.isEmpty, "\(step): the superseded chain started a pass")
        }
    }

    /// `.autovisorPass` is asked with the OPEN'S token. A's chain is held INSIDE its last write —
    /// the manager's brief, after `.autovisorBriefWrite` answered for A — while the open of B runs
    /// to the end; resumed, A starts no pass, asks B's Autovisor for nothing and seeds no seen-set
    /// in B's session.
    ///
    /// Pins that `ensureAutovisorTask` passes its own lifecycle rather than `currentFolderLifecycle`. Until 2026-10-28 a hold AT a check could not tell
    /// which token the check was asked with — the argument was read before the gate held — so
    /// with the pass asked about the generation current when the chain got there (B's, once B
    /// began), every test above passed; this holds at a real suspension instead. Since 2026-10-28 the
    /// check reads its argument after the hold, and a hold at `.autovisorPass` shows it too.
    func testAnAutovisorPassIsAskedWithTheOpensOwnToken() async throws {
        await sut.openWorkFolder(folderA)
        let managerID = try await handMadeManager()
        await sut.mutateWorkFolder { $0.settings.autovisorGoal = "A goal" }
        await sut.openWorkFolder(folderB)
        for title in ["B one", "B two"] {
            let created = await sut.createTask(title: title, supervisorTask: "x", makeActive: false)
            _ = try XCTUnwrap(created)
        }
        sut.stopAllEngines()
        let folderAPath = folderA.path
        let write = TaskWriteHold { folder, task in
            folder.path == folderAPath && task.id == managerID && task.supervisorTask == "A goal"
        }
        repository.taskWriteHold = write

        let openA = Task { await sut.openWorkFolder(folderA) }
        for _ in 0..<600 {
            if write.isHeld { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(write.isHeld, "A's chain never reached its manager's brief")
        await sut.openWorkFolder(folderB)
        let seenBefore = sut.autovisorSeenTaskIDs
        let infoBefore = sut.lastInfoMessage
        write.release()
        await openA.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertTrue(sut.taskEngines.isEmpty, "the superseded chain started a pass")
        XCTAssertEqual(sut.autovisorSeenTaskIDs, seenBefore, "the superseded chain seeded its seen-set in B's session")
        XCTAssertEqual(sut.lastInfoMessage, infoBefore, "the superseded chain asked B's Autovisor for a pass")
    }
}

/// `openWorkFolder` across its off-main read, part two: the actions that STRADDLE the next open —
/// a run start, a create, a scheduler pass, the run-timeout watchdog, the Autovisor toggle and the
/// goal setters — and each post-read check asked with the open's own token. Same fixture, same
/// holds as `WorkFolderOpenSupersessionTests`.
///
/// Split from it on 2026-10-28: once its reads were held rather than slept the class still took
/// ~16 s alone, all of it real work — every test opens two to six folders — and a mutation batch's
/// test phase is bounded by its longest class (`slow_proposals` 16). A spec whose suites name
/// `WorkFolderOpenSupersessionTests` for one of the tests below names this class now.
@MainActor
final class WorkFolderOpenStraddleTests: WorkFolderLifecycleTestCase {

    // MARK: - A run start, a create and a scheduler that straddle the next open (2026-10-28)

    /// The Autovisor's open-time pass of A — held INSIDE its run start, in the write of the run it
    /// materialized, after every check of the open and of the chain answered — while the open of B
    /// runs to the end; B's task with the manager's id is B's active task, loaded. Resumed, the
    /// start launches nothing: B's open abandoned it at its boundary (`stopAllEngines` →
    /// `abortRunStart`), so `launchRun`'s re-check refuses it by its generation.
    ///
    /// RED until 2026-10-28: `stopAllEngines` dropped the claim and left the generation, so
    /// the inline start passed every condition of `runLaunchIsStillWanted` — not cancelled, a task
    /// of that id loaded (B's), the generation unmoved — and started an engine on B's task.
    func testAnAutovisorPassWhoseRunStartStraddlesAnOpenStartsNothingInTheNextFolder() async throws {
        await sut.openWorkFolder(folderB)
        let bOneCreated = await sut.createTask(title: "B one", supervisorTask: "one", makeActive: false)
        _ = try XCTUnwrap(bOneCreated)
        let bTwoCreated = await sut.createTask(title: "B two", supervisorTask: "two", makeActive: true)
        let bTwo = try XCTUnwrap(bTwoCreated)
        await sut.openWorkFolder(folderA)
        let fillerCreated = await sut.createTask(title: "filler", supervisorTask: "f", makeActive: false)
        _ = try XCTUnwrap(fillerCreated)
        let managerID = try await handMadeManager()
        XCTAssertEqual(managerID, bTwo, "premise: A's manager has the id of B's active task")
        await sut.openWorkFolder(folderB)
        sut.stopAllEngines()

        let write = holdRunMaterialization(in: folderA, of: managerID)
        let openA = Task { await sut.openWorkFolder(folderA) }
        try await waitHeld(write, "A's Autovisor pass")
        XCTAssertTrue(sut.engineState.isInitializingRun(managerID), "premise: the pass holds its start's claim")
        await sut.openWorkFolder(folderB)
        XCTAssertEqual(sut.activeTaskID, bTwo, "premise: B's task #\(bTwo) is its active task")
        let taskJSON = NTMSPaths(workFolderRoot: folderB).taskJSON(taskID: bTwo)
        let before = try Data(contentsOf: taskJSON)
        write.release()
        await openA.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        assertNothingStarted(bTwo, taskJSON: taskJSON, before: before)
    }

    /// Play in A — `startRun`, inline, as the toolbar calls it — held in the write of the run it
    /// materialized while the open of B runs to the end: nothing starts in B, whose first task has
    /// the same id. A's run was materialized, in A, and never launched; A's next open reads it as
    /// it reads a Pause during start (`testARunAbandonedByAnOpenReadsOnTheNextOpenLikeAPauseDuringStart`).
    ///
    /// RED until 2026-10-28: the start launched an engine on B's task #1.
    func testAPlayStartStraddlingAnOpenStartsNothingInTheNextFolder() async throws {
        let (aOne, taskJSON) = try await sameIDTasks()
        let write = holdRunMaterialization(in: folderA, of: aOne)
        let play = Task { await sut.startRun(taskID: aOne) }
        try await waitHeld(write, "Play in A")
        await sut.openWorkFolder(folderB)
        XCTAssertFalse(sut.engineState.isInitializingRun(aOne), "B's open ended the start's claim at its boundary")
        let before = try Data(contentsOf: taskJSON)
        write.release()
        await play.value

        assertNothingStarted(aOne, taskJSON: taskJSON, before: before, "Play")
        let onDisk = try NTMSRepository().loadTask(at: folderA, taskID: aOne)
        XCTAssertEqual(onDisk.runs.count, 1, "premise: A's run was materialized, in A")
        XCTAssertTrue(onDisk.runs[0].steps.isEmpty, "premise: and never launched")
    }

    /// What a run the next open abandoned looks like when its folder is opened again: exactly
    /// what a run a Pause stopped during its start looks like. Both were materialized — a run
    /// with no step yet — and never launched, and the reopen reads the two alike: the task's
    /// derived status is `.running` (a run with no step reads so, `derivedStatusFromActiveRun`),
    /// status recovery leaves it alone — it parks steps, and there is none — and no engine state
    /// is seeded for it (the half-built shape `SyncEngineStateFromRunTests` "Scenario M" pins:
    /// no phantom `.paused`), so the board offers Start, which makes a fresh run.
    func testARunAbandonedByAnOpenReadsOnTheNextOpenLikeAPauseDuringStart() async throws {
        await sut.openWorkFolder(folderA)
        var ids: [Int] = []
        for title in ["paused during start", "abandoned by an open", "active"] {
            let created = await sut.createTask(title: title, supervisorTask: "x", makeActive: title == "active")
            ids.append(try XCTUnwrap(created))
        }
        let (paused, abandoned) = (ids[0], ids[1])

        let pauseWrite = holdRunMaterialization(in: folderA, of: paused)
        let pausedStart = Task { await sut.startRun(taskID: paused) }
        try await waitHeld(pauseWrite, "the start Pause stops")
        let verdict = await sut.pauseRun(taskID: paused)
        XCTAssertTrue(verdict, "premise: Pause during start reports a stop")
        pauseWrite.release()
        await pausedStart.value

        let switchWrite = holdRunMaterialization(in: folderA, of: abandoned)
        let abandonedStart = Task { await sut.startRun(taskID: abandoned) }
        try await waitHeld(switchWrite, "the start an open abandons")
        await sut.openWorkFolder(folderB)
        switchWrite.release()
        await abandonedStart.value

        await sut.openWorkFolder(folderA)
        let repository = NTMSRepository()
        for id in [paused, abandoned] {
            let task = try repository.loadTask(at: folderA, taskID: id)
            XCTAssertEqual(task.runs.count, 1, "#\(id): premise — one materialized run")
            XCTAssertTrue(task.runs.last?.steps.isEmpty == true, "#\(id): premise — never launched")
        }
        let summaries = Dictionary(uniqueKeysWithValues: (sut.snapshot?.tasksIndex.tasks ?? []).map { ($0.id, $0) })
        XCTAssertEqual(summaries[abandoned]?.status, summaries[paused]?.status,
                       "the abandoned run reads unlike a Pause during start in the index")
        XCTAssertEqual(sut.taskEngineStates[abandoned], sut.taskEngineStates[paused],
                       "the abandoned run reads unlike a Pause during start in the engine mirror")
        XCTAssertTrue(sut.taskEngines.isEmpty)
        XCTAssertEqual(summaries[abandoned]?.status, .running, "a run with no step reads running")
        XCTAssertNil(sut.taskEngineStates[abandoned], "no engine state is fabricated for a half-built run")
    }

    /// A recurrence of A fired by the scheduler — `fireRecurrence` → `startRun`, inline — held in
    /// the write of the run it materialized while the open of B runs to the end: nothing starts in
    /// B, whose first task has the same id.
    ///
    /// RED until 2026-10-28, as the Play start.
    func testARecurrenceFireStraddlingAnOpenStartsNothingInTheNextFolder() async throws {
        let (aOne, taskJSON) = try await sameIDTasks()
        sut.stopAutomationScheduler()
        await sut.mutateTask(taskID: aOne) {
            $0.recurrence = TaskRecurrence(
                rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: Date(timeIntervalSinceNow: -60))
        }
        let write = holdRunMaterialization(in: folderA, of: aOne)
        let fire = Task { await sut.evaluateDueRecurrences(now: Date()) }
        try await waitHeld(write, "the recurrence fire in A")
        await sut.openWorkFolder(folderB)
        let before = try Data(contentsOf: taskJSON)
        let errorsBefore = sut.errorSurfaceCount
        write.release()
        await fire.value

        assertNothingStarted(aOne, taskJSON: taskJSON, before: before, "recurrence")
        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "the abandoned fire reported into B's session")
    }

    /// The same fire, released while the open of B is still READING — the folder's URL and
    /// snapshot still A's: the start is abandoned (B's open began), and the fire, asking its own
    /// lifecycle rather than the folder's URL, stops there — it neither reschedules A's slot nor
    /// reports "could not start its scheduled run" into the session B is opening.
    ///
    /// RED until 2026-10-28: the start launched an engine on A's task, in A, after B's open
    /// had stopped every engine; with that fixed alone, the fire's URL guard passed (A was still
    /// the URL) and it posted its failure banner.
    func testARecurrenceFireAbandonedByAnOpenStillReadingSaysNothing() async throws {
        let (aOne, _) = try await sameIDTasks()
        sut.stopAutomationScheduler()
        await sut.mutateTask(taskID: aOne) {
            $0.recurrence = TaskRecurrence(
                rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: Date(timeIntervalSinceNow: -60))
        }
        let slot = try XCTUnwrap(try NTMSRepository().loadTask(at: folderA, taskID: aOne).recurrence?.nextFireAt)
        let write = holdRunMaterialization(in: folderA, of: aOne)
        let fire = Task { await sut.evaluateDueRecurrences(now: Date()) }
        try await waitHeld(write, "the recurrence fire in A")
        let (openB, readB) = try await startReadingOpen(of: folderB)
        XCTAssertEqual(sut.workFolderURL, folderA, "premise: B is still reading")
        let errorsBefore = sut.errorSurfaceCount
        write.release()
        await fire.value

        XCTAssertTrue(sut.taskEngines.isEmpty, "the abandoned fire started an engine")
        XCTAssertNil(sut.taskEngineStates[aOne])
        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "the abandoned fire reported into the session being opened")
        XCTAssertEqual(try NTMSRepository().loadTask(at: folderA, taskID: aOne).recurrence?.nextFireAt, slot,
                       "the abandoned fire rescheduled A's slot")
        readB.release()
        await openB.value
        XCTAssertTrue(sut.taskEngines.isEmpty)
    }

    /// A create the person asked for (the command palette's `createTask`) whose flush returns
    /// while the open of B is still READING — the folder's URL still A — creates nothing in A,
    /// applies nothing, and says why: the create is refused on its lifecycle, which B's open ended
    /// at its first line, not on the URL, which it commits only after its read.
    ///
    /// RED until 2026-10-28: the URL guard passed, the task was created in the folder being
    /// left and A's snapshot applied mid-open.
    func testAPersonsCreateWhoseFlushReturnsWhileTheNextFolderIsReadCreatesNothingAndSaysSo() async throws {
        await sut.openWorkFolder(folderA)
        let indexBefore = createdState(folderA).index?.tasks.count
        let released = holdPendingPointerWrite()
        let errorsBefore = sut.errorSurfaceCount
        let creating = Task { await sut.createTask(title: "late", supervisorTask: "x") }
        let (openB, readB) = try await startReadingOpen(of: folderB)
        XCTAssertEqual(sut.workFolderURL, folderA, "premise: B is still reading")
        released.yield()
        released.finish()
        let created = await creating.value

        XCTAssertNil(created, "a task was created while the next folder was being read")
        XCTAssertEqual(createdState(folderA).index?.tasks.count, indexBefore, "the task was created in the folder being left")
        XCTAssertGreaterThan(sut.errorSurfaceCount, errorsBefore, "the refusal was not surfaced")
        XCTAssertEqual(sut.lastErrorMessage, NTMSOrchestrator.createTaskFolderChangedMessage)
        readB.release()
        await openB.value
        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 0)
    }

    /// A create the person asks for WHILE the open of B reads — begun in the stretch where the
    /// process still describes A (its URL, its snapshot) but A's lifecycle is over — creates
    /// nothing and says so: it belongs to the folder described, `currentFolderLifecycle` names
    /// that folder's lifecycle, and B's open has ended it.
    ///
    /// RED until 2026-10-28 by construction of `currentFolderLifecycle`: it named the LATEST
    /// open's generation — B's — so a create begun here carried B's token and A's URL, passed
    /// every check, and wrote into A while its snapshot was applied mid-open.
    func testAPersonsCreateBegunWhileTheNextFolderIsReadCreatesNothingAndSaysSo() async throws {
        await sut.openWorkFolder(folderA)
        let indexBefore = createdState(folderA).index?.tasks.count
        let (openB, readB) = try await startReadingOpen(of: folderB)
        XCTAssertEqual(sut.workFolderURL, folderA, "premise: B is still reading")
        let errorsBefore = sut.errorSurfaceCount
        let created = await sut.createTask(title: "mid-open", supervisorTask: "x")

        XCTAssertNil(created, "a task was created in the folder being left")
        XCTAssertEqual(createdState(folderA).index?.tasks.count, indexBefore)
        XCTAssertGreaterThan(sut.errorSurfaceCount, errorsBefore, "the refusal was not surfaced")
        XCTAssertEqual(sut.lastErrorMessage, NTMSOrchestrator.createTaskFolderChangedMessage)
        readB.release()
        await openB.value
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, 0)
    }

    /// Every open that ENDS — committed on success, and on failure (it commits its URL as well) —
    /// makes its own lifecycle the one actions begin in; an open superseded before it commits
    /// never does, and until the latest open commits, an action begun meanwhile belongs to a
    /// lifecycle that is over.
    func testTheFolderDescribedIsTheLifecycleOfTheOpenThatCommittedIt() async throws {
        await sut.openWorkFolder(folderA)
        XCTAssertEqual(sut.currentFolderLifecycle, WorkFolderLifecycle(generation: sut.workFolderOpenGeneration),
                       "a successful open")
        XCTAssertTrue(sut.isCurrentFolderLifecycle(sut.currentFolderLifecycle))

        let (openB, readB) = try await startReadingOpen(of: folderB)
        XCTAssertFalse(sut.isCurrentFolderLifecycle(sut.currentFolderLifecycle),
                       "an action begun while B reads belongs to A's lifecycle, which is over")
        readB.release()
        await openB.value
        XCTAssertTrue(sut.isCurrentFolderLifecycle(sut.currentFolderLifecycle), "B committed")

        repository.openFailurePaths = [folderA.path]
        await sut.openWorkFolder(folderA)
        XCTAssertNil(sut.snapshot, "premise: the open failed")
        XCTAssertEqual(sut.workFolderURL, folderA)
        XCTAssertTrue(sut.isCurrentFolderLifecycle(sut.currentFolderLifecycle), "a failed open commits too")

        repository.openFailurePaths = []
        // B's own read must not be held here: a hold on B would let A's read return first, and
        // B's later commit would overwrite whatever A recorded — the assertion below would hold
        // whatever the superseded open did. The one `startReadingOpen` put on B above is
        // released, and a released hold lets every read through; dropped anyway, so that stays
        // true whatever the hold's rule becomes.
        repository.openReadHolds[folderB.path] = nil
        try await overlapSlowOpen(of: folderA, byOpenOf: folderB)
        XCTAssertEqual(sut.workFolderURL, folderB)
        XCTAssertTrue(sut.isCurrentFolderLifecycle(sut.currentFolderLifecycle),
                      "the superseded open of A committed nothing over B's")
    }

    /// An open names the lifecycle actions begin in at its COMMIT, not at its end: held at its first
    /// step after the commit (`.delegationHistory`) — its sweep, scheduler, Autovisor chain, search
    /// index and MCP set-up still ahead — the folder it committed is current, and a create the
    /// person asks for there is created.
    ///
    /// RED: record the commit's lifecycle at the open's end instead → for the whole post-commit
    /// stretch the folder described names the previous open's lifecycle: the create is refused as
    /// a folder change, the Autovisor's open-time `create_task` is answered "the work folder
    /// changed", and a poll tick in that stretch fires nothing.
    func testAnOpenNamesTheLifecycleActionsBeginInAtItsCommitNotAtItsEnd() async throws {
        await sut.openWorkFolder(folderA)
        let (openB, holdB) = try await holdCommittedOpen(of: folderB)
        XCTAssertEqual(sut.workFolderURL, folderB, "premise: B committed")
        XCTAssertTrue(sut.isCurrentFolderLifecycle(sut.currentFolderLifecycle),
                      "the open that committed B does not name its lifecycle yet")
        let created = await sut.createTask(title: "in B", supervisorTask: "x")
        XCTAssertNotNil(created, "a create in B, after B committed, was refused: \(sut.lastErrorMessage ?? "")")
        await holdB.release()
        await openB.value
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.map(\.title), ["in B"], "anti-vacuum: the create landed in B")
    }

    /// The path the refusal exists for, with no test seam: Close Work Folder while a palette create
    /// flushes. `closeProject` CANCELS the pending pointer write — so the flush returns at once —
    /// and opens default storage, whose read is still under way when the create resumes: nothing
    /// is created in the folder closed.
    ///
    /// RED until 2026-10-28: the URL was still the closed folder's, and the task was created
    /// there and its snapshot applied mid-open.
    func testACreateCaughtByCloseProjectCreatesNothingInTheFolderClosed() async throws {
        await sut.openWorkFolder(folderA)
        let indexBefore = createdState(folderA).index?.tasks.count
        _ = holdPendingPointerWrite()
        let defaultRead = holdReads(of: NTMSOrchestrator.defaultStorageURL)
        let creating = Task { await sut.createTask(title: "late", supervisorTask: "x") }
        let closing = Task { await sut.closeProject() }
        let created = await creating.value
        defaultRead.release()
        await closing.value

        XCTAssertNil(created, "a task was created in the folder being closed")
        XCTAssertEqual(createdState(folderA).index?.tasks.count, indexBefore)
        XCTAssertFalse(sut.hasRealWorkFolder, "premise: the close opened default storage")
    }

    /// The Autovisor chain's own create — A switched on with no manager — whose flush returns while
    /// the open of B is reading, and again once B has committed: nothing is created in A, and
    /// NOTHING is surfaced in the session B opens — the refusal is the chain's own business (a
    /// superseded chain stops), never "Create it again here." about a hidden task the person never
    /// asked for.
    ///
    /// RED until 2026-10-28: with B reading, the URL guard passed and the manager was created
    /// in A — unpinned, since the chain's next check stopped it before the pin; with B committed,
    /// `createTaskFolderChangedMessage` landed in B's session.
    func testASupersededChainsCreateCreatesNothingAndSaysNothing() async throws {
        for committed in [false, true] {
            let (a, b) = try freshFolders("chain-create-\(committed)")
            await sut.openWorkFolder(a)
            await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
            await sut.openWorkFolder(b)
            let (openA, hold) = try await holdOpen(of: a, at: .autovisorTaskCreate)
            let before = createdState(a)
            let released = holdPendingPointerWrite()
            let errorsBefore = sut.errorSurfaceCount
            await hold.release()
            var openB: Task<Void, Never>?
            var readB: OpenReadHold?
            if committed {
                await sut.openWorkFolder(b)
            } else {
                readB = holdReads(of: b)
                openB = try await startOpen(of: b)
            }
            released.yield()
            released.finish()
            await openA.value
            readB?.release()
            await openB?.value

            let after = createdState(a)
            XCTAssertEqual(after.index?.tasks.map(\.id), before.index?.tasks.map(\.id),
                           "committed \(committed): the superseded chain created a task in A")
            XCTAssertNil(after.state?.autovisorTaskID, "committed \(committed)")
            XCTAssertEqual(sut.errorSurfaceCount, errorsBefore,
                           "committed \(committed): the superseded chain surfaced its create's refusal in B's session")
            XCTAssertEqual(sut.workFolderURL, b)
        }
    }

    /// The Autovisor's own `create_task` — a create no person asked for — whose flush returns while
    /// the open of B is reading, and once B has committed: nothing is created, the refusal is the
    /// tool's result (the model reads why), and nothing is surfaced in the session B opens.
    ///
    /// RED until 2026-10-28: with B reading, the task was created in A; with B committed, the
    /// person's banner ("Create it again here.") was posted about a task the Autovisor asked for.
    func testTheAutovisorsOwnCreateAcrossAnOpenTellsOnlyTheModel() async throws {
        for committed in [false, true] {
            let (a, b) = try freshFolders("tool-create-\(committed)")
            await sut.openWorkFolder(b)
            await sut.openWorkFolder(a)
            let pipeline = try XCTUnwrap(sut.snapshot?.workFolder.teams.first {
                !$0.isChatMode && !$0.isHiddenFromPickers
            }, "premise: a pipeline team to create on")
            let before = createdState(a)
            let released = holdPendingPointerWrite()
            let errorsBefore = sut.errorSurfaceCount
            let acting = Task {
                await sut.performAutovisorAction(.createManagedTask(title: "T", brief: "B", teamID: pipeline.id))
            }
            var openB: Task<Void, Never>?
            var readB: OpenReadHold?
            if committed {
                await sut.openWorkFolder(b)
            } else {
                readB = holdReads(of: b)
                openB = try await startOpen(of: b)
            }
            released.yield()
            released.finish()
            let result = await acting.value
            readB?.release()
            await openB?.value

            XCTAssertFalse(result.ok, "committed \(committed)")
            XCTAssertEqual(result.message, DeferredCallReplies.folderChanged, "committed \(committed)")
            XCTAssertNil(result.createdTaskID)
            XCTAssertEqual(createdState(a).index?.tasks.map(\.id), before.index?.tasks.map(\.id),
                           "committed \(committed): a task was created in A")
            XCTAssertEqual(sut.errorSurfaceCount, errorsBefore,
                           "committed \(committed): the Autovisor's refusal was posted to the person")
        }
    }

    /// A's open held INSIDE its scheduler's reconcile — the write rescheduling a missed slot —
    /// while the open of B runs to the end: resumed, A starts no poll loop, and the one loop alive
    /// is the one B started (the orchestrator still holds it, uncancelled).
    ///
    /// RED until 2026-10-28: A started its loop after the reconcile without asking again, and
    /// its assignment overwrote B's handle — B's loop orphaned, ticking for good in every later
    /// folder.
    func testASchedulerSupersededInItsReconcileLeavesOnlyTheNextFoldersLoop() async throws {
        let (taskID, missed) = try await missedRecurrence()
        await sut.openWorkFolder(folderB)
        let write = holdReconcile(of: taskID, missed: missed)
        let openA = Task { await sut.openWorkFolder(folderA) }
        try await waitHeld(write, "A's reconcile")
        await sut.openWorkFolder(folderB)
        let loopB = try XCTUnwrap(sut.automationPollTask, "premise: B started its loop")
        write.release()
        await openA.value

        try await waitForLiveLoops(1, "after A resumed")
        XCTAssertEqual(sut.automationPollTask, loopB, "the loop held is not B's")
        XCTAssertFalse(loopB.isCancelled, "B's loop was cancelled")
    }

    /// The same, with B's open failing: once A resumes, no poll loop is alive at all.
    ///
    /// RED until 2026-10-28: A's loop was started after B's open had stopped the scheduler,
    /// and survived B's discard.
    func testASchedulerSupersededInItsReconcileByAFailedOpenLeavesNoLoop() async throws {
        let (taskID, missed) = try await missedRecurrence()
        await sut.openWorkFolder(folderB)
        let write = holdReconcile(of: taskID, missed: missed)
        let openA = Task { await sut.openWorkFolder(folderA) }
        try await waitHeld(write, "A's reconcile")
        repository.openFailurePaths = [folderB.path]
        await sut.openWorkFolder(folderB)
        XCTAssertNil(sut.snapshot, "premise: B's open failed")
        write.release()
        await openA.value

        try await waitForLiveLoops(0, "after A resumed")
        XCTAssertNil(sut.automationPollTask, "a loop is held after a failed open")
    }

    /// Two scheduler starts in ONE lifecycle — the first held inside its reconcile's write while
    /// the second runs to its loop — leave one loop alive: the first cancels the loop it replaces
    /// when it assigns its own, so no start ever orphans a loop, whoever else started one.
    func testTwoSchedulerStartsInOneLifecycleLeaveOneLoop() async throws {
        let (taskID, missed) = try await missedRecurrence()
        sut.stopAutomationScheduler()
        try await waitForLiveLoops(0, "premise: A's open loop stopped")
        await sut.mutateTask(taskID: taskID) {
            $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: missed)
        }
        let write = holdReconcile(of: taskID, missed: missed)
        let lifecycle = sut.currentFolderLifecycle
        let first = Task { await sut.startAutomationScheduler(lifecycle: lifecycle) }
        try await waitHeld(write, "the first start's reconcile")
        await sut.startAutomationScheduler(lifecycle: lifecycle)
        let second = try XCTUnwrap(sut.automationPollTask, "premise: the second start started its loop")
        write.release()
        await first.value

        try await waitForLiveLoops(1, "after both starts")
        XCTAssertTrue(second.isCancelled, "the first start replaced the second's loop without cancelling it")
    }

    /// A reconcile whose open is superseded while the next folder is READ — the URL still its
    /// folder's — stops at its next step: of two missed slots, the one after the held write is not
    /// rescheduled on disk. The lifecycle ended at the next open's first line; a URL check would
    /// have gone on writing into the folder being left.
    func testAReconcileSupersededWhileTheNextFolderIsReadStopsAtItsNextStep() async throws {
        await sut.openWorkFolder(folderA)
        var ids: [Int] = []
        let missed = Date(timeIntervalSinceNow: -7200)
        for title in ["first", "second"] {
            let created = await sut.createTask(title: title, supervisorTask: "x", makeActive: false)
            let taskID = try XCTUnwrap(created)
            _ = await sut.ensureTaskLoaded(taskID)
            await sut.mutateTask(taskID: taskID) {
                $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: missed)
            }
            ids.append(taskID)
        }
        await sut.openWorkFolder(folderB)
        func diskSlot(_ id: Int) throws -> Date? {
            try NTMSRepository().loadTask(at: folderA, taskID: id).recurrence?.nextFireAt
        }
        let path = folderA.path
        let heldIDs = Set(ids)
        let write = TaskWriteHold { written, task in
            written.path == path && heldIDs.contains(task.id)
                && (task.recurrence?.nextFireAt).map { $0 > missed.addingTimeInterval(60) } == true
        }
        repository.taskWriteHold = write
        let openA = Task { await sut.openWorkFolder(folderA) }
        try await waitHeld(write, "A's reconcile")
        let (openB, readB) = try await startReadingOpen(of: folderB)
        XCTAssertEqual(sut.workFolderURL, folderA, "premise: B is still reading")
        write.release()
        await openA.value
        readB.release()
        await openB.value

        let rescheduled = try ids.filter { try diskSlot($0).map { $0 > missed.addingTimeInterval(60) } == true }
        XCTAssertEqual(rescheduled.count, 1, "the superseded reconcile went on to its next slot: \(rescheduled)")
    }

    /// A discarded folder keeps nothing running: `discardWorkFolderState` stops the poll loop,
    /// which reads the state it discards.
    func testDiscardingAFoldersStateStopsItsPollLoop() async throws {
        await sut.openWorkFolder(folderA)
        let loop = try XCTUnwrap(sut.automationPollTask, "premise: A's open started its loop")
        sut.discardWorkFolderState()
        XCTAssertNil(sut.automationPollTask)
        XCTAssertTrue(loop.isCancelled, "the discarded folder's loop still runs")
        try await waitForLiveLoops(0, "after the discard")
    }

    // MARK: - Each check of the open asked with the open's own token (2026-10-28)

    /// The open's post-read checks read their lifecycle AFTER the hold (the argument is an
    /// autoclosure), so a check asked with `currentFolderLifecycle` — the folder the process
    /// describes, B's once B has committed — would answer "current" and go on. Each test below
    /// holds A at one check while B COMMITS, and holds B at its own first step after its read
    /// (`.delegationHistory`), so what A would do next — on B's state, before B does it itself —
    /// shows. (Held while B only reads, as the tests above hold it, the two tokens agree:
    /// B has not committed, so the folder described is still A's, whose lifecycle has ended.)

    /// `.autovisorTaskCreate`, where it shows: A switched on with no manager, held after its
    /// team was ensured, while the open of a folder opened for the FIRST time — no Autovisor team
    /// yet — commits and is held at its first step: A resumed says nothing into B's session. A
    /// check asked with the folder now described would go on, find no Autovisor team in B's
    /// snapshot and post "Autovisor could not start — its team is missing" there. (Once B has its
    /// team, the create itself refuses: `createTask(…, within:)` asks the chain's lifecycle.)
    func testAChainHeldBeforeItsCreateSaysNothingIntoAFolderThatCommittedWithNoTeam() async throws {
        await sut.openWorkFolder(folderA)
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
        let (openA, holdA) = try await holdOpen(of: folderA, at: .autovisorTaskCreate)
        let (openB, holdB) = try await holdCommittedOpen(of: folderB)
        XCTAssertFalse(sut.snapshot?.workFolder.teams.contains { $0.templateID == AutovisorConstants.teamTemplateID } ?? true,
                       "premise: B, opened for the first time, has no Autovisor team yet")
        let errorsBefore = sut.errorSurfaceCount
        await holdA.release()
        await openA.value

        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "the superseded chain reported into B's session")
        XCTAssertNil(createdState(folderA).state?.autovisorTaskID, "the superseded chain created its manager")
        await holdB.release()
        await openB.value
    }

    /// `.delegationHistory`: A resumed seeds nothing for B's active task, which B has not
    /// seeded yet.
    func testAnOpenHeldBeforeItsEngineStateSeedsNothingOnceTheNextOpenCommitted() async throws {
        await sut.openWorkFolder(folderB)
        let bTask = try await pausedTask(active: true)
        await sut.openWorkFolder(folderA)
        let (openA, holdA) = try await holdOpen(of: folderA, at: .delegationHistory)
        let (openB, holdB) = try await holdCommittedOpen(of: folderB)
        XCTAssertEqual(sut.activeTaskID, bTask, "premise: B committed")
        XCTAssertNil(sut.taskEngineStates[bTask], "premise: B has not seeded its active task")
        await holdA.release()
        await openA.value

        XCTAssertNil(sut.taskEngineStates[bTask], "the superseded open seeded the next folder's active task")
        await holdB.release()
        await openB.value
        XCTAssertEqual(sut.taskEngineStates[bTask], .paused, "anti-vacuum: B's own open seeds it")
    }

    /// `.staleStatusSweep`, where it shows: the later open is a REOPEN of the same folder,
    /// so the sweep's own folder check cannot stop the earlier open. A's non-active task left
    /// `.running` on disk is not swept by the superseded open; the reopen sweeps it.
    func testAnOpenHeldBeforeItsStatusSweepSweepsNothingForAReopenOfItsFolder() async throws {
        await sut.openWorkFolder(folderA)
        let staleCreated = await sut.createTask(title: "stale", supervisorTask: "x")
        let stale = try XCTUnwrap(staleCreated)
        await sut.mutateTask(taskID: stale) { task in
            task.status = .running
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .running)]
            task.runs = [run]
        }
        let activeCreated = await sut.createTask(title: "active", supervisorTask: "y")
        _ = try XCTUnwrap(activeCreated)
        await sut.openWorkFolder(folderB)
        let index = NTMSPaths(workFolderRoot: folderA).tasksIndexJSON
        func diskStatus() -> TaskStatus? {
            (try? AtomicJSONStore().read(TasksIndex.self, from: index))?.tasks.first { $0.id == stale }?.status
        }
        XCTAssertEqual(diskStatus(), .running, "premise: left running on disk")

        let (openA, holdA) = try await holdOpen(of: folderA, at: .staleStatusSweep)
        let (reopen, holdReopen) = try await holdCommittedOpen(of: folderA)
        await holdA.release()
        await openA.value
        let stepsA = await holdA.visitedSteps
        XCTAssertFalse(stepsA.contains(.automationScheduler),
                       "the superseded open advanced past .staleStatusSweep: \(stepsA)")
        XCTAssertEqual(diskStatus(), .running, "the superseded open swept its folder ahead of the reopen")
        await holdReopen.release()
        await reopen.value
        XCTAssertNotEqual(diskStatus(), .running, "anti-vacuum: the reopen sweeps it")
    }

    /// `.automationScheduler`: A resumed after B's open ran to the end leaves B's poll loop
    /// running — `startAutomationScheduler` stops the loop it finds before its reconcile, so a
    /// scheduler started for a superseded open would stop B's and, its own lifecycle over, start
    /// none.
    func testAnOpenHeldBeforeItsSchedulerLeavesTheNextFoldersLoopRunning() async throws {
        let (openA, holdA) = try await holdOpen(of: folderA, at: .automationScheduler)
        await sut.openWorkFolder(folderB)
        let loopB = try XCTUnwrap(sut.automationPollTask, "premise: B started its loop")
        await holdA.release()
        await openA.value

        XCTAssertEqual(sut.automationPollTask, loopB, "the loop held is not B's")
        XCTAssertFalse(loopB.isCancelled, "the superseded open stopped B's loop")
        try await waitForLiveLoops(1, "after A resumed")
    }

    /// `.autovisorTeam`: B opened for the first time holds no Autovisor team until its own
    /// open writes one; A resumed writes none into it.
    func testAnOpenHeldBeforeTheAutovisorTeamWritesNoTeamIntoTheFolderThatCommitted() async throws {
        let (openA, holdA) = try await holdOpen(of: folderA, at: .autovisorTeam)
        let (openB, holdB) = try await holdCommittedOpen(of: folderB)
        let teamsB = NTMSPaths(workFolderRoot: folderB).teamsJSON
        func bHasTheTeam() throws -> Bool {
            try AtomicJSONStore().read(TeamsFile.self, from: teamsB).teams
                .contains { $0.templateID == AutovisorConstants.teamTemplateID }
        }
        XCTAssertFalse(try bHasTheTeam(), "premise: B's first open has not written the team yet")
        await holdA.release()
        await openA.value

        XCTAssertFalse(try bHasTheTeam(), "the superseded open wrote the Autovisor team into B")
        await holdB.release()
        await openB.value
        XCTAssertTrue(try bHasTheTeam(), "anti-vacuum: B's own open writes it")
    }

    /// `.autovisorTask`: B has the Autovisor on and a manager with a paused run, not
    /// loaded yet; A resumed neither loads it nor seeds its engine state.
    func testAnOpenHeldBeforeTheAutovisorTaskLoadsNothingOfTheFolderThatCommitted() async throws {
        await sut.openWorkFolder(folderB)
        let managerB = try await handMadeManager(pausedRun: true)
        await sut.openWorkFolder(folderA)
        sut.stopAllEngines()
        let (openA, holdA) = try await holdOpen(of: folderA, at: .autovisorTask)
        let (openB, holdB) = try await holdCommittedOpen(of: folderB)
        XCTAssertNil(sut.loadedTask(managerB), "premise: B's open has not loaded its manager")
        await holdA.release()
        await openA.value

        XCTAssertNil(sut.loadedTask(managerB), "the superseded open loaded B's manager")
        XCTAssertNil(sut.taskEngineStates[managerB], "the superseded open seeded B's manager's engine state")
        await holdB.release()
        await openB.value
        XCTAssertNotNil(sut.loadedTask(managerB), "anti-vacuum: B's own open loads it")
    }

    /// `.sleepTimer`: A's bundled-update report and its banner are not posted into B's
    /// session.
    func testAnOpenHeldBeforeItsSleepTimerPostsNothingOnceTheNextOpenCommitted() async throws {
        let report = BundledUpdateReport(
            scanFailure: .taskFileUnreadable(taskID: 9, relativePath: "tasks/9/task.json", reason: "x"))
        let banner = try XCTUnwrap(report.bannerMessage)
        repository.openedBundledUpdates[folderA.path] = report
        let (openA, holdA) = try await holdOpen(of: folderA, at: .sleepTimer)
        let (openB, holdB) = try await holdCommittedOpen(of: folderB)
        XCTAssertNil(sut.bundledUpdateReport, "premise: B's open cleared the report")
        await holdA.release()
        await openA.value

        XCTAssertNil(sut.bundledUpdateReport, "the superseded open posted its bundled-update report")
        XCTAssertNotEqual(sut.lastErrorMessage, banner, "the superseded open posted its banner")
        await holdB.release()
        await openB.value
        XCTAssertNil(sut.bundledUpdateReport?.scanFailure, "the report posted at the end is B's own")
        XCTAssertNotEqual(sut.lastErrorMessage, banner)
    }

    /// `.mcpServers`: B's open tore the MCP connections down and has not set them up yet; A
    /// resumed builds none.
    func testAnOpenHeldBeforeItsMCPSetUpBuildsNothingOnceTheNextOpenCommitted() async throws {
        _ = try useLoggingMCP()
        let (openA, holdA) = try await holdOpen(of: folderA, at: .mcpServers)
        let (openB, holdB) = try await holdCommittedOpen(of: folderB)
        XCTAssertTrue(sut.mcpServerManager?.connections.isEmpty ?? true, "premise: B's teardown left no connection")
        await holdA.release()
        await openA.value

        XCTAssertTrue(sut.mcpServerManager?.connections.isEmpty ?? true,
                      "the superseded open set up MCP connections in B's session")
        await holdB.release()
        await openB.value
        XCTAssertFalse(sut.mcpServerManager?.connections.isEmpty ?? true, "anti-vacuum: B's own open sets them up")
        await sut.tearDownMCPServerManager(budget: 0)
    }


    // MARK: - Guards a straddle reaches only through a held write, or a pass begun mid-open

    /// A's reconcile, held in the write rescheduling its first missed slot while the open of B
    /// runs to the end — B holding idle, loaded tasks with the ids of both of A's missed slots —
    /// evicts nothing of B's and loads, writes or reschedules nothing of B's: it stops at its next
    /// step.
    ///
    /// RED: drop the reconcile's guard before its evict → B's loaded task with the held id is
    /// evicted. RED as well: ask every per-iteration guard with `currentFolderLifecycle` → once B
    /// has committed each guard answers for B, and the reconcile goes on with A's ids: it evicts B's
    /// task with the held id, then rewrites B's task with the next id.
    func testAReconcileSupersededByAnOpenThatCommitsTouchesNothingOfTheNextFolder() async throws {
        await sut.openWorkFolder(folderB)
        var bIDs: [Int] = []
        for title in ["B one", "B two", "B three"] {
            let created = await sut.createTask(title: title, supervisorTask: "x", makeActive: title == "B three")
            bIDs.append(try XCTUnwrap(created))
        }
        await sut.openWorkFolder(folderA)
        let missed = Date(timeIntervalSinceNow: -7200)
        var aIDs: [Int] = []
        for title in ["first", "second"] {
            let created = await sut.createTask(title: title, supervisorTask: "x", makeActive: false)
            let taskID = try XCTUnwrap(created)
            _ = await sut.ensureTaskLoaded(taskID)
            await sut.mutateTask(taskID: taskID) {
                $0.recurrence = TaskRecurrence(rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: missed)
            }
            aIDs.append(taskID)
        }
        XCTAssertEqual(aIDs, Array(bIDs.prefix(2)), "premise: A's missed slots carry the ids of B's two idle tasks")
        await sut.openWorkFolder(folderB)
        let path = folderA.path
        let heldIDs = Set(aIDs)
        let write = TaskWriteHold { written, task in
            written.path == path && heldIDs.contains(task.id)
                && (task.recurrence?.nextFireAt).map { $0 > missed.addingTimeInterval(60) } == true
        }
        repository.taskWriteHold = write
        let openA = Task { await sut.openWorkFolder(folderA) }
        try await waitHeld(write, "A's reconcile")
        await sut.openWorkFolder(folderB)
        let bPaths = NTMSPaths(workFolderRoot: folderB)
        var before: [Int: Data] = [:]
        for id in aIDs {
            _ = await sut.ensureTaskLoaded(id)
            XCTAssertNotNil(sut.loadedTask(id), "premise: B's task #\(id) is loaded")
            before[id] = try Data(contentsOf: bPaths.taskJSON(taskID: id))
        }
        write.release()
        await openA.value

        XCTAssertEqual(sut.workFolderURL, folderB)
        for id in aIDs {
            XCTAssertNotNil(sut.loadedTask(id), "the superseded reconcile evicted B's task #\(id)")
            XCTAssertEqual(try Data(contentsOf: bPaths.taskJSON(taskID: id)), before[id],
                           "the superseded reconcile rewrote B's task #\(id)")
        }
    }

    /// A recurrence fire of A held in a write it makes on its way out — the zombie branch's disable
    /// write, the deferral branch's reschedule, the reschedule of a fire that started no run —
    /// while the open of B runs to the end, B holding an idle, loaded task with the fired task's id:
    /// the fire evicts nothing of B's and posts nothing into B's session.
    ///
    /// RED: drop the guard after the zombie branch's write, after the deferral branch's write, or
    /// after the last reschedule → B's task is evicted in each branch, and the third also posts
    /// "could not start its scheduled run" into B's session.
    func testAFireHeldInItsLastWriteTouchesNothingOfTheNextFolder() async throws {
        enum Branch: String, CaseIterable { case zombie, deferral, noRun }
        for branch in Branch.allCases {
            let (a, b) = try freshFolders("fire-\(branch.rawValue)")
            await sut.openWorkFolder(b)
            let bOneCreated = await sut.createTask(title: "B one", supervisorTask: "x", makeActive: false)
            let bOne = try XCTUnwrap(bOneCreated)
            let bTwoCreated = await sut.createTask(title: "B two", supervisorTask: "x", makeActive: true)
            _ = try XCTUnwrap(bTwoCreated)
            await sut.openWorkFolder(a)
            let firedID: Int
            if branch == .zombie {
                firedID = try await handMadeManager()
                await sut.mutateWorkFolder { $0.settings.autovisorEnabled = false }
            } else {
                let created = await sut.createTask(title: "recurring", supervisorTask: "x", makeActive: false)
                firedID = try XCTUnwrap(created)
            }
            XCTAssertEqual(firedID, bOne, "\(branch): premise — the fired task has the id of B's idle task")
            _ = await sut.ensureTaskLoaded(firedID)
            await sut.mutateTask(taskID: firedID) {
                $0.recurrence = TaskRecurrence(
                    rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: Date(timeIntervalSinceNow: -60))
            }
            sut.stopAutomationScheduler()
            let path = a.path
            let write: TaskWriteHold
            switch branch {
            case .zombie:
                write = TaskWriteHold { written, task in
                    written.path == path && task.id == firedID && task.recurrence?.isEnabled == false
                }
            case .deferral, .noRun:
                let now = Date()
                write = TaskWriteHold { written, task in
                    written.path == path && task.id == firedID
                        && (task.recurrence?.nextFireAt).map { $0 > now } == true
                }
            }
            if branch == .deferral { sut.engineState[firedID] = .running }
            if branch == .noRun { _ = sut.engineState.beginRunStart(firedID) }
            repository.taskWriteHold = write
            let fire = Task { await sut.evaluateDueRecurrences(now: Date()) }
            try await waitHeld(write, "\(branch): the fire's write in A")
            await sut.openWorkFolder(b)
            _ = await sut.ensureTaskLoaded(bOne)
            XCTAssertNotNil(sut.loadedTask(bOne), "\(branch): premise — B's task #\(bOne) is loaded")
            let errorsBefore = sut.errorSurfaceCount
            write.release()
            await fire.value

            XCTAssertEqual(sut.workFolderURL, b, "\(branch)")
            XCTAssertNotNil(sut.loadedTask(bOne), "\(branch): the superseded fire evicted B's task #\(bOne)")
            XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "\(branch): the superseded fire reported into B's session")
        }
    }

    /// A task of the open folder whose run has gone on longer than its timeout, one step still
    /// `.running` — what the run-timeout watchdog stamps and pauses.
    private func overBudgetTask(makeActive: Bool = false) async throws -> Int {
        let created = await sut.createTask(title: "slow", supervisorTask: "x", makeActive: makeActive)
        let taskID = try XCTUnwrap(created)
        _ = await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 60
            var run = Run(id: 0, roleStatuses: ["worker": .working])
            run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .running)]
            task.runs = [run]
        }
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.steps.first?.status, .running, "premise: the step runs")
        return taskID
    }

    /// The run-timeout watchdog of A, across the next open, three ways. Held in its LAST pause
    /// while B reads, it announces no timeout into the session being opened. Held in its
    /// `timedOutAt` write while B commits — B's task of the same id running — it pauses nothing of
    /// B's. And a pass run in A's lifecycle once B has begun — what the poll loop A's open started
    /// holds — with an engine state for one of A's ids, stamps, pauses and announces nothing: the
    /// folder it would act on is the one being left.
    ///
    /// RED: drop the watchdog's guard before its banner → "Task 'slow' paused — it exceeded its run
    /// timeout." lands in the session B opens. RED: drop its guard between the `timedOutAt` write
    /// and the pause → B's running step is paused, in memory and in B's task.json. RED: drop the
    /// guard at the top of its loop → the pass with an ended lifecycle stamps `timedOutAt` on A's
    /// run, in memory and in A's task.json.
    func testTheWatchdogAcrossTheNextOpenPausesAndAnnouncesNothingThere() async throws {
        // 1 — held in its last pause while B reads.
        do {
            let (a, b) = try freshFolders("watchdog-banner")
            await sut.openWorkFolder(a)
            let taskID = try await overBudgetTask()
            sut.engineState[taskID] = .running
            let path = a.path
            let write = TaskWriteHold { written, task in
                written.path == path && task.id == taskID
                    && task.runs.last?.steps.contains { $0.status == .paused } == true
            }
            repository.taskWriteHold = write
            let pass = Task { await sut.evaluateRunTimeouts(now: MonotonicClock.shared.now().addingTimeInterval(3600)) }
            try await waitHeld(write, "the watchdog's pause")
            let (openB, readB) = try await startReadingOpen(of: b)
            sut.lastInfoMessage = nil
            write.release()
            await pass.value
            XCTAssertFalse(sut.lastInfoMessage?.contains("exceeded its run timeout") == true,
                           "the superseded watchdog announced its timeout into the session being opened")
            readB.release()
            await openB.value
        }
        // 2 — held in its `timedOutAt` write while B commits, B's task of that id running.
        do {
            let (a, b) = try freshFolders("watchdog-pause")
            await sut.openWorkFolder(b)
            let bCreated = await sut.createTask(title: "B one", supervisorTask: "x", makeActive: false)
            let bOne = try XCTUnwrap(bCreated)
            await sut.openWorkFolder(a)
            let taskID = try await overBudgetTask()
            XCTAssertEqual(taskID, bOne, "premise: A's over-budget task has the id of B's task")
            sut.engineState[taskID] = .running
            let path = a.path
            let write = TaskWriteHold { written, task in
                written.path == path && task.id == taskID && task.runs.last?.timedOutAt != nil
            }
            repository.taskWriteHold = write
            let pass = Task { await sut.evaluateRunTimeouts(now: MonotonicClock.shared.now().addingTimeInterval(3600)) }
            try await waitHeld(write, "the watchdog's timedOutAt write")
            await sut.openWorkFolder(b)
            _ = await sut.ensureTaskLoaded(bOne)
            await sut.mutateTask(taskID: bOne) { task in
                var run = Run(id: 0, roleStatuses: ["worker": .working])
                run.steps = [StepExecution(id: "worker", role: .softwareEngineer, title: "Work", status: .running)]
                task.runs = [run]
            }
            sut.engineState[bOne] = .running
            let bJSON = NTMSPaths(workFolderRoot: b).taskJSON(taskID: bOne)
            let before = try Data(contentsOf: bJSON)
            write.release()
            await pass.value

            XCTAssertEqual(sut.loadedTask(bOne)?.runs.last?.steps.first?.status, .running,
                           "the superseded watchdog paused B's running step")
            XCTAssertEqual(try Data(contentsOf: bJSON), before, "the superseded watchdog wrote B's task.json")
            XCTAssertEqual(sut.taskEngineStates[bOne], .running, "the superseded watchdog re-derived B's engine mirror")
        }
        // 3 — a pass in A's lifecycle while B reads, with an engine state for one of A's ids.
        do {
            let (a, b) = try freshFolders("watchdog-mid-open")
            await sut.openWorkFolder(a)
            let loopLifecycle = sut.currentFolderLifecycle
            let taskID = try await overBudgetTask()
            let (openB, readB) = try await startReadingOpen(of: b)
            sut.engineState[taskID] = .running
            let infoBefore = sut.lastInfoMessage
            await sut.evaluateRunTimeouts(now: MonotonicClock.shared.now().addingTimeInterval(3600), within: loopLifecycle)

            XCTAssertNil(sut.loadedTask(taskID)?.runs.last?.timedOutAt, "a pass with an ended lifecycle stamped A's run")
            XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.steps.first?.status, .running,
                           "a pass with an ended lifecycle paused A's step")
            let onDisk = try NTMSRepository().loadTask(at: a, taskID: taskID)
            XCTAssertNil(onDisk.runs.last?.timedOutAt, "a pass with an ended lifecycle stamped A's task.json")
            XCTAssertEqual(sut.lastInfoMessage, infoBefore, "a pass with an ended lifecycle announced a timeout")
            readB.release()
            await openB.value
        }
    }

    /// Switching the Autovisor on while the next folder is READ — the folder described still the
    /// one being left, whose lifecycle is over — creates no manager in it and starts no pass, and
    /// writes nothing into B once B has committed. A scheduler pass in A's lifecycle — the poll
    /// loop's — fires none of A's recurrences while B is read, and none of B's once B has
    /// committed, B's task of the same id due.
    ///
    /// RED: capture the latest open's generation in `setAutovisorEnabled` → the toggle's chain runs
    /// while B reads: it creates and pins a manager in A and starts its pass. RED: make the pass ask
    /// a fresh `currentFolderLifecycle` instead of the one it was handed → once B has committed it
    /// fires B's due recurrence: a run is appended to B's task, and `lastFiredAt` is written.
    func testAToggleAndASchedulerPassBegunWhileTheNextFolderIsReadDoNothing() async throws {
        // The toggle.
        do {
            let (a, b) = try freshFolders("toggle")
            await sut.openWorkFolder(a)
            let before = createdState(a)
            let (openB, readB) = try await startReadingOpen(of: b)
            await sut.setAutovisorEnabled(true)
            XCTAssertEqual(createdState(a).index?.tasks.map(\.id), before.index?.tasks.map(\.id),
                           "the toggle created a task in the folder being left")
            XCTAssertNil(createdState(a).state?.autovisorTaskID, "the toggle pinned a manager in the folder being left")
            XCTAssertTrue(sut.taskEngines.isEmpty, "the toggle started a pass")
            readB.release()
            await openB.value
            XCTAssertEqual(createdState(b).index?.tasks.count ?? 0, 0, "a task was created in B")
            XCTAssertNil(createdState(b).state?.autovisorTaskID, "a manager was pinned in B")
        }
        // The scheduler pass.
        do {
            let (a, b) = try freshFolders("due-pass")
            await sut.openWorkFolder(a)
            let created = await sut.createTask(title: "recurring", supervisorTask: "x", makeActive: false)
            let taskID = try XCTUnwrap(created)
            _ = await sut.ensureTaskLoaded(taskID)
            let due = Date()
            await sut.mutateTask(taskID: taskID) {
                $0.recurrence = TaskRecurrence(
                    rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: due.addingTimeInterval(-60))
            }
            // Read back from disk, as the assertion below reads it: the persisted date's precision is
            // the encoder's, not the in-memory value's.
            let slot = try XCTUnwrap(try NTMSRepository().loadTask(at: a, taskID: taskID).recurrence?.nextFireAt)
            sut.stopAutomationScheduler()
            let loopLifecycle = sut.currentFolderLifecycle
            let (openB, readB) = try await startReadingOpen(of: b)
            await sut.evaluateDueRecurrences(now: due, within: loopLifecycle)

            XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, 0, "a pass with an ended lifecycle appended a run in memory")
            let onDisk = try NTMSRepository().loadTask(at: a, taskID: taskID)
            XCTAssertEqual(onDisk.runs.count, 0, "a pass with an ended lifecycle appended a run to A's task.json")
            XCTAssertNil(onDisk.recurrence?.lastFiredAt, "a pass with an ended lifecycle stamped lastFiredAt")
            XCTAssertEqual(onDisk.recurrence?.nextFireAt, slot, "a pass with an ended lifecycle rescheduled A's slot")
            XCTAssertTrue(sut.taskEngines.isEmpty)
            readB.release()
            await openB.value
        }
        // The scheduler pass once B has committed, B's task of the same id due.
        do {
            let (a, b) = try freshFolders("due-pass-committed")
            await sut.openWorkFolder(b)
            let bCreated = await sut.createTask(title: "B recurring", supervisorTask: "x", makeActive: false)
            let bTask = try XCTUnwrap(bCreated)
            await sut.openWorkFolder(a)
            let aCreated = await sut.createTask(title: "A one", supervisorTask: "x", makeActive: false)
            XCTAssertEqual(aCreated, bTask, "premise: A's task has the id of B's task")
            sut.stopAutomationScheduler()
            let loopLifecycle = sut.currentFolderLifecycle
            await sut.openWorkFolder(b)
            sut.stopAutomationScheduler()
            // Made due AFTER B's open: the open's own skip-missed pass would move a slot already due.
            _ = await sut.ensureTaskLoaded(bTask)
            let due = Date()
            await sut.mutateTask(taskID: bTask) {
                $0.recurrence = TaskRecurrence(
                    rule: .interval(seconds: 3600), isEnabled: true, nextFireAt: due.addingTimeInterval(-60))
            }
            let indexed = sut.snapshot?.tasksIndex.tasks.first { $0.id == bTask }?.nextRecurrenceFireAt
            XCTAssertTrue(indexed.map { $0 <= due } ?? false, "premise: B's task is due in the index the pass reads")
            let bJSON = NTMSPaths(workFolderRoot: b).taskJSON(taskID: bTask)
            let before = try Data(contentsOf: bJSON)
            await sut.evaluateDueRecurrences(now: due, within: loopLifecycle)

            XCTAssertEqual(try Data(contentsOf: bJSON), before, "a pass with an ended lifecycle wrote B's task.json")
            XCTAssertEqual(sut.loadedTask(bTask)?.runs.count ?? 0, 0, "a pass with an ended lifecycle started a run of B's")
            XCTAssertTrue(sut.taskEngines.isEmpty, "a pass with an ended lifecycle started an engine in B")
        }
    }

    /// `.autovisorTeamSync` held behind the REAL suspension before it — the existing manager's
    /// recurrence write — rather than at the check: A's chain, resumed once the open of B has
    /// committed (B held at its first step after its read), syncs nothing into B's Autovisor team,
    /// on disk or in the snapshot B's open goes on with.
    ///
    /// RED: read the lifecycle the check asks with BEFORE the check — `currentFolderLifecycle` taken
    /// right after the write returns, the release build's shape of a recapture — → B has committed by
    /// then, the check answers for B, and A's chain syncs B's Autovisor team. A hold AT the check
    /// cannot show this: the eager read would happen before the hold, while A was still current.
    func testAChainHeldInItsRecurrenceWriteSyncsNothingIntoTheNextFoldersTeam() async throws {
        await sut.openWorkFolder(folderA)
        let managerID = try await handMadeManager()
        await sut.openWorkFolder(folderB)
        await sut.mutateWorkFolder { projection in
            guard let team = projection.teams.firstIndex(where: { $0.templateID == AutovisorConstants.teamTemplateID }),
                  let role = projection.teams[team].roles.firstIndex(where: {
                      $0.systemRoleID == AutovisorConstants.managerRoleSystemID
                  })
            else { return }
            projection.teams[team].roles[role].toolIDs.append(ToolNames.writeFile)
        }
        let teamsB = NTMSPaths(workFolderRoot: folderB).teamsJSON
        func toolsOnDisk() throws -> [String]? {
            Self.managerTools(try AtomicJSONStore().read(TeamsFile.self, from: teamsB).teams)
        }
        XCTAssertEqual(try toolsOnDisk()?.contains(ToolNames.writeFile), true, "premise: B's manager is off its template")
        sut.stopAllEngines()

        let path = folderA.path
        let write = TaskWriteHold { written, task in
            written.path == path && task.id == managerID && task.recurrence?.isEnabled == true
        }
        repository.taskWriteHold = write
        let openA = Task { await sut.openWorkFolder(folderA) }
        try await waitHeld(write, "A's manager recurrence write")
        let holdB = holdNextOpen(at: .delegationHistory)
        let openB = Task { await sut.openWorkFolder(folderB) }
        try await waitHeld(holdB, "the open of B")
        XCTAssertEqual(sut.workFolderURL, folderB, "premise: B's snapshot is applied")
        let before = try Data(contentsOf: teamsB)
        write.release()
        await openA.value

        XCTAssertEqual(try Data(contentsOf: teamsB), before, "the superseded chain synced B's Autovisor team on disk")
        XCTAssertEqual(Self.managerTools(sut.snapshot?.projection.teams ?? [])?.contains(ToolNames.writeFile), true,
                       "the superseded chain synced B's Autovisor team in the snapshot")
        await holdB.release()
        await openB.value
        XCTAssertEqual(try toolsOnDisk()?.contains(ToolNames.writeFile), false,
                       "anti-vacuum: B's own open syncs the team, so the chain's sync would have shown")
    }

    /// An open of A held right before it installs its search index, outlived by a reopen of A
    /// that FAILS — the reopen commits A's URL and its own lifecycle, then discards: resumed, the
    /// first open installs nothing over a folder whose open failed.
    ///
    /// RED: ask the install with `currentFolderLifecycle` → the failed reopen's lifecycle is the
    /// current one and its URL is the same folder's, so every install condition holds and an index
    /// runs over a folder nothing has open, until the next open's teardown.
    func testASearchIndexOutlivedByAFailedReopenOfItsFolderIsNotInstalled() async throws {
        sut.configuration.exploratorySearchEnabled = true
        let (openA, hold) = try await holdOpen(of: folderA, at: .searchIndexInstall)
        repository.openFailurePaths = [folderA.path]
        await sut.openWorkFolder(folderA)
        XCTAssertNil(sut.snapshot, "premise: the reopen of A failed")
        XCTAssertEqual(sut.workFolderURL, folderA, "premise: the failed reopen committed A's URL")
        await hold.release()
        await openA.value

        XCTAssertNil(sut.searchIndexCoordinator,
                     "the superseded open installed its index over a folder whose open failed")
    }

    /// The three goal setters, used while the next folder is READ — the folder described still the
    /// one being left: each writes the setting the person edited, and none syncs the brief into
    /// that folder's Autovisor manager — nothing loads or rewrites the manager there.
    ///
    /// RED: capture the latest open's generation in `updateAutovisorGoal`,
    /// `setAutovisorGoalClips` or `setAutovisorGoalAttachmentPaths` → that setter's sync passes
    /// every check while B reads, loads A's manager and rewrites its task.json — and, were B to
    /// commit inside the sync's load, writes the brief onto B's task with that id.
    func testGoalSettersUsedWhileTheNextFolderIsReadSyncNoBriefIntoTheFolderBeingLeft() async throws {
        await sut.openWorkFolder(folderA)
        let managerID = try await handMadeManager()
        let managerJSON = NTMSPaths(workFolderRoot: folderA).taskJSON(taskID: managerID)
        let before = try Data(contentsOf: managerJSON)
        XCTAssertNil(sut.loadedTask(managerID), "premise: nothing has loaded A's manager")
        let (openB, readB) = try await startReadingOpen(of: folderB)

        await sut.updateAutovisorGoal("a goal typed while B reads")
        XCTAssertEqual(try Data(contentsOf: managerJSON), before, "updateAutovisorGoal synced the brief into A's manager")
        await sut.setAutovisorGoalClips(["a clip"])
        XCTAssertEqual(try Data(contentsOf: managerJSON), before, "setAutovisorGoalClips synced the brief into A's manager")
        await sut.setAutovisorGoalAttachmentPaths(["notes.md"])
        XCTAssertEqual(try Data(contentsOf: managerJSON), before,
                       "setAutovisorGoalAttachmentPaths synced the brief into A's manager")
        XCTAssertNil(sut.loadedTask(managerID), "a goal setter loaded the manager of the folder being left")
        readB.release()
        await openB.value
        XCTAssertEqual(createdState(folderB).index?.tasks.count ?? 0, 0, "a task appeared in B")
    }

    /// Exploratory Search switched on while the next folder is READ installs no index for the
    /// folder being left; the open of B installs B's own.
    ///
    /// RED: capture the latest open's generation in the setting change → its set-up passes the
    /// install check while B reads and installs an index over A, which B's own set-up then finds
    /// installed and keeps: the process indexes A while showing B.
    func testSearchSwitchedOnWhileTheNextFolderIsReadInstallsNoIndexForTheFolderBeingLeft() async throws {
        await sut.openWorkFolder(folderA)
        XCTAssertNil(sut.searchIndexCoordinator, "premise: search is off")
        let (openB, readB) = try await startReadingOpen(of: folderB)
        sut.configuration.exploratorySearchEnabled = true
        await sut.onExploratorySearchSettingChanged()
        XCTAssertNil(sut.searchIndexCoordinator, "an index was installed for the folder being left")
        readB.release()
        await openB.value

        XCTAssertEqual(sut.searchIndexCoordinator?.workFolderRoot.path, folderB.path,
                       "the index installed is not B's")
        await sut.tearDownSearchIndexCoordinator()
    }
}
