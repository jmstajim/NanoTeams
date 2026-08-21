import XCTest

@testable import NanoTeams

/// Pins the TOTAL engine wake shared by the role-control primitives.
///
/// Reported 2026-08-15: the Autovisor's `manage_role request_changes` on task #24 returned
/// `ok:true`, persisted `.revisionRequested` to disk, and the role never re-ran. The wake was
/// `taskEngines[taskID]?.notifyExternalEvent()` — a silent no-op in exactly two reachable shapes:
///
/// 1. **No engine object.** After an app restart `taskEngines` is empty (`openWorkFolder` runs
///    `stopAllEngines()`), and `ensureTaskLoaded` → `syncEngineStateFromRun` seeds only
///    `engineState[taskID]`. Same shape after `stopEngine` (`control_task stop`, `closeTask`).
/// 2. **`.pending` engine.** `TeamEngine.notifyExternalEvent()` has no `.pending` arm, and
///    `.pending` is both a fresh engine and what `stop()` leaves behind.
///
/// Nothing in the suite pinned engine resumption for ANY of these primitives before this file —
/// `RequestRevisionTests` and `AutovisorActionDispatchTests` assert only that the right bytes
/// land on disk, which is precisely why the class survived.
@MainActor
final class EngineWakeTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Fixtures

    /// The post-restart shape on a REAL team: a producing role whose step is finished, the task
    /// loaded, and NO engine object.
    ///
    /// Deliberately does not reuse `AutovisorActionDispatchTests.makeEngineFreeStartableTask()` —
    /// that helper pins the generated placeholder team and has zero runs, so it would trip
    /// `wakeEngine`'s generation guard and pin nothing about this class.
    private func makeEngineFreeReviewTask(
        stepStatus: StepStatus = .done
    ) async -> (id: Int, roleID: String, supervisorID: String)? {
        await sut.openWorkFolder(tempDir)
        guard let team = sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" }),
              let worker = team.roles.first(where: { !$0.isSupervisor }),
              let supervisor = team.roles.first(where: { $0.isSupervisor })
        else {
            XCTFail("the bundled Startup team must be present after openWorkFolder"); return nil
        }
        guard let id = await sut.createTask(
            title: "Review", supervisorTask: "ship it",
            preferredTeamID: team.id, makeActive: false
        ) else {
            XCTFail("createTask failed"); return nil
        }
        await sut.ensureTaskLoaded(id)
        let roleID = worker.id
        let teamID = team.id
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: roleID, role: .softwareEngineer, title: worker.name,
                status: stepStatus, completedAt: MonotonicClock.shared.now()
            )
            task.runs = [Run(
                id: 0, steps: [step],
                roleStatuses: [supervisor.id: .done, roleID: .done],
                teamID: teamID
            )]
        }
        XCTAssertNil(sut.taskEngines[id],
                     "premise: the post-restart shape has NO engine object — that is the whole bug")
        return (id, roleID, supervisor.id)
    }

    private func runCount(_ taskID: Int) -> Int { sut.loadedTask(taskID)?.runs.count ?? -1 }
    private func latestRun(_ taskID: Int) -> Run? { sut.loadedTask(taskID)?.runs.last }

    /// Assert the wake both CREATED and STARTED the engine. Two separate assertions on purpose:
    /// a "fix" written as `engineForTask(taskID).notifyExternalEvent()` satisfies the first and
    /// fails the second, because `.pending` is the very state that arm cannot resume.
    ///
    /// Timing-independent: `engine.start()` assigns `.running` synchronously before launching its
    /// Task, and nothing writes `.pending` again except `stop()`.
    private func assertWokeEngine(_ taskID: Int, _ message: String = "") {
        XCTAssertNotNil(sut.taskEngines[taskID],
                        "the wake must CREATE the engine after a restart. \(message)")
        XCTAssertEqual(sut.taskEngines[taskID]?.state, .running,
                       "and START it — `.pending` is the second silent no-op. \(message)")
        sut.stopEngine(for: taskID)   // keep the live loop out of the rest of the suite
    }

    // MARK: - The three converted sites, post-restart

    /// RED: revert `requestRevision`'s wake to `notifyEngineExternalEvent` → no engine is created,
    /// reproducing the reported #24 stall.
    func testRequestRevision_postRestart_createsAndStartsTheEngine() async {
        guard let f = await makeEngineFreeReviewTask() else { return }

        await sut.requestRevision(taskID: f.id, roleID: f.roleID, comment: "redo the API layer")

        XCTAssertEqual(latestRun(f.id)?.roleStatuses[f.roleID], .revisionRequested)
        XCTAssertEqual(runCount(f.id), 1,
                       "the revision REUSES the run — a new run means a startRun leaked into the wake")
        assertWokeEngine(f.id)
    }

    /// RED: revert `acceptRole`'s wake → no engine. Worse than the revision case in production:
    /// `.accepted` is `isComplete: true`, so the role leaves every attention surface while the
    /// released mid-pipeline gate lands in a dead engine.
    func testAcceptRole_postRestart_createsAndStartsTheEngine() async {
        guard let f = await makeEngineFreeReviewTask() else { return }
        await sut.mutateTask(taskID: f.id) { task in
            task.runs[0].roleStatuses[f.roleID] = .needsAcceptance
        }

        let ok = await sut.acceptRole(taskID: f.id, roleID: f.roleID)

        XCTAssertTrue(ok)
        XCTAssertEqual(latestRun(f.id)?.roleStatuses[f.roleID], .accepted)
        assertWokeEngine(f.id)
    }

    /// RED: revert `finishAdvisoryRoleAwaiting`'s wake to `taskEngines[taskID]?` → no engine.
    /// That site never even called `engineForTask`.
    func testFinishAdvisory_postRestart_createsAndStartsTheEngine() async {
        guard let f = await makeEngineFreeReviewTask(stepStatus: .running) else { return }
        await sut.mutateTask(taskID: f.id) { task in
            task.runs[0].roleStatuses[f.roleID] = .working
        }

        _ = await sut.finishAdvisoryRoleAwaiting(taskID: f.id, roleID: f.roleID)

        XCTAssertEqual(latestRun(f.id)?.roleStatuses[f.roleID], .done)
        assertWokeEngine(f.id)
    }

    // MARK: - Guards

    /// RED: drop `requestRevision`'s early `closedAt` guard → the role flips on a finished task.
    ///
    /// `closeTask` finalizes every non-terminal role to `.done`, which SATISFIES the step gate —
    /// and the Autovisor's `request_changes` arm, unlike `accept` / `finish_advisory`, carries no
    /// closed-task pre-check. Reviving is not the remedy: close also finalized every DOWNSTREAM
    /// role `.done` and `findReadyRoles` excludes `.done`, so the revision would have no consumer.
    func testRequestRevision_onClosedTask_refusesLoudlyAndLeavesTheRoleUntouched() async {
        guard let f = await makeEngineFreeReviewTask() else { return }
        _ = await sut.closeTask(taskID: f.id)
        sut.stopEngine(for: f.id)
        XCTAssertNotNil(sut.loadedTask(f.id)?.closedAt, "premise: the task is closed")
        let before = sut.errorSurfaceCount

        await sut.requestRevision(taskID: f.id, roleID: f.roleID, comment: "redo it")

        let err = sut.errorSurfaced(since: before)
        XCTAssertNotNil(err, "a refusal must reach the manager, not be a silent no-op")
        XCTAssertTrue(err?.contains("restart") ?? false,
                      "the refusal must name the primitive that DOES reopen and cascade; got \(err ?? "nil")")
        XCTAssertNotEqual(latestRun(f.id)?.roleStatuses[f.roleID], .revisionRequested,
                          "a refused request must not flip the role")
        XCTAssertNil(sut.taskEngines[f.id], "and must not resurrect the engine")
    }

    /// RED: drop the `closedAt` guard from `wakeEngine` → the helper revives a finalized run.
    ///
    /// Asserted on the primitive DIRECTLY. Routing this through `acceptRole` was the first cut
    /// and it was vacuous: `closeTask` → `finalizeRoleStatusesForClose` rewrites the
    /// `.needsAcceptance` role to `.done`, and `AcceptanceService.validateAcceptance` rejects
    /// `.done`, so the call returned before the wake and the test stayed green with the guard
    /// removed. A guard test must first prove the guard is REACHED.
    func testWakeEngine_onClosedTask_isRefused() async {
        guard let f = await makeEngineFreeReviewTask() else { return }
        _ = await sut.closeTask(taskID: f.id)
        sut.stopEngine(for: f.id)
        XCTAssertNotNil(sut.loadedTask(f.id)?.closedAt, "premise: the task is closed")

        XCTAssertFalse(sut.wakeEngine(taskID: f.id),
                       "a closed task is terminal — `closeTask` finalized every role and the run "
                           + "loop has no `closedAt` awareness")
        XCTAssertNil(sut.taskEngines[f.id])
    }

    /// The same guard through a REAL caller, so the pin also proves the route is live.
    /// `finishAdvisoryRoleAwaiting` is the one converted site with no validation of its own, so
    /// it reaches the wake on a closed task where `acceptRole` and `requestRevision` refuse
    /// earlier — which is exactly why the guard belongs in the helper, not in the callers.
    ///
    /// RED: drop the `closedAt` guard from `wakeEngine` → a closed task gains a live engine.
    func testFinishAdvisory_onClosedTask_doesNotResurrectTheEngine() async {
        guard let f = await makeEngineFreeReviewTask() else { return }
        _ = await sut.closeTask(taskID: f.id)
        sut.stopEngine(for: f.id)
        XCTAssertNotNil(sut.loadedTask(f.id)?.closedAt, "premise: the task is closed")

        _ = await sut.finishAdvisoryRoleAwaiting(taskID: f.id, roleID: f.roleID)

        XCTAssertNil(sut.taskEngines[f.id],
                     "a closed task is terminal — the wake must not revive its engine")
    }

    /// RED: drop the `startingRunTaskIDs` / `forcingRunTaskIDs` guard → the wake registers and
    /// starts an engine against the OLD run while `startRun` is suspended mid-`createNewRun`;
    /// `startRun`'s own `start()` is then swallowed by its `guard state != .running`.
    func testWakeEngine_whileStartRunIsInFlight_isRefused() async {
        guard let f = await makeEngineFreeReviewTask() else { return }
        sut.startingRunTaskIDs.insert(f.id)
        defer { sut.startingRunTaskIDs.remove(f.id) }

        XCTAssertFalse(sut.wakeEngine(taskID: f.id),
                       "a run already being created will start the engine itself")
        XCTAssertNil(sut.taskEngines[f.id], "and no engine may be registered against the old run")
    }

    /// RED: drop the `runs.last` guard → a run-less task gets an engine that immediately
    /// transitions `.failed`, which `onStateChanged` delivers as `.terminal(.failed)` to any
    /// delegating parent suspended in `awaitTaskTerminalState`.
    ///
    /// This guard is load-bearing HERE specifically: `finishAdvisoryRoleAwaiting` is the one
    /// converted caller with no run guard of its own.
    func testFinishAdvisory_runlessTask_doesNotFabricateAFailedEngine() async {
        guard let f = await makeEngineFreeReviewTask() else { return }
        await sut.mutateTask(taskID: f.id) { $0.runs = [] }
        XCTAssertEqual(runCount(f.id), 0, "premise: no run to reconcile")

        _ = await sut.finishAdvisoryRoleAwaiting(taskID: f.id, roleID: f.roleID)

        XCTAssertNil(sut.taskEngines[f.id],
                     "a run-less task must keep today's no-op, not gain a spurious .failed engine")
    }

    /// RED: drop the `team_generation_*` prefix guard → a phantom `roleStatuses` entry is written
    /// for an id no roster contains. Mirrors the backstop `restartRole` already carries.
    ///
    /// The synthetic step must EXIST and be `.done` — that is the production shape
    /// (`runTeamGeneration` injects it, and a failed generation leaves it terminal). Without it
    /// the test is vacuous: the step-existence guard below refuses first, so it stayed green
    /// with the prefix guard removed.
    func testRequestRevision_generationPlaceholderRole_isRefusedLoudly() async {
        guard let f = await makeEngineFreeReviewTask() else { return }
        let synthetic = StepExecution.teamGenerationIDPrefix + "0"
        await sut.mutateTask(taskID: f.id) { task in
            task.runs[0].steps.append(StepExecution(
                id: synthetic, role: .supervisor, title: "Generate Team",
                status: .done, completedAt: MonotonicClock.shared.now()
            ))
        }
        XCTAssertNotNil(latestRun(f.id)?.steps.first(where: { $0.id == synthetic }),
                        "premise: the synthetic step exists and is terminal, so ONLY the prefix "
                            + "guard can refuse")
        let before = sut.errorSurfaceCount

        await sut.requestRevision(taskID: f.id, roleID: synthetic, comment: "redo it")

        XCTAssertNotNil(sut.errorSurfaced(since: before),
                        "team generation is not a role — the refusal must be loud")
        XCTAssertNil(latestRun(f.id)?.roleStatuses[synthetic],
                     "and must not write a phantom role status the engine can never execute")
        XCTAssertNil(sut.taskEngines[f.id])
    }

    /// RED: make `wakeEngine` return `Void` (drop the honest-results check) → the revision is on
    /// disk and nothing says the run did not resume, i.e. the same invisible stall by another
    /// route.
    func testRequestRevision_wakeRefused_reportsInsteadOfStayingSilent() async {
        guard let f = await makeEngineFreeReviewTask() else { return }
        sut.startingRunTaskIDs.insert(f.id)
        defer { sut.startingRunTaskIDs.remove(f.id) }
        let before = sut.errorSurfaceCount

        await sut.requestRevision(taskID: f.id, roleID: f.roleID, comment: "redo it")

        XCTAssertEqual(latestRun(f.id)?.roleStatuses[f.roleID], .revisionRequested,
                       "the revision is still recorded — only the wake was refused")
        let err = sut.errorSurfaced(since: before)
        XCTAssertNotNil(err, "a refused wake must be reported, not swallowed")
        XCTAssertTrue(err?.contains("Resume") ?? false,
                      "and must tell the Supervisor what to do; got \(err ?? "nil")")
    }

    // MARK: - The sixth member: resumeRun's mid-delegation short-circuit

    /// RED: revert the mid-delegation arm to `taskEngines[taskID]?.resume()` → Resume does
    /// nothing at all.
    ///
    /// `StatusRecoveryService` never clears `step.delegation.activeChildID`, so after a crash
    /// mid-delegation the short-circuit predicate is still true while `taskEngines` is empty —
    /// and its early `return` skips the total `engineForTask` at the end of `resumeRun`. This is
    /// the worst member of the class because it has a visible button.
    func testResumeRun_midDelegationAfterRestart_startsTheEngine() async {
        guard let f = await makeEngineFreeReviewTask(stepStatus: .paused) else { return }
        await sut.mutateTask(taskID: f.id) { task in
            task.runs[0].steps[0].setActiveDelegation(childID: 999)
            task.runs[0].roleStatuses[f.roleID] = .working
        }
        XCTAssertNotNil(sut.loadedTask(f.id)?.runs.last?.steps.first?.activeDelegationChildID,
                        "premise: the persisted delegation marker survives a restart")

        await sut.resumeRun(taskID: f.id)

        XCTAssertNotNil(sut.taskEngines[f.id],
                        "Resume on a parent stuck mid-delegation must revive its engine")
        XCTAssertEqual(sut.taskEngines[f.id]?.state, .running)
        sut.stopEngine(for: f.id)
    }

    // MARK: - TeamEngine.resume() cancels the previous loop

    /// RED: drop `runTask?.cancel()` from `TeamEngine.resume()` → the surviving loop is orphaned
    /// and keeps reconciling against the same store alongside the replacement.
    ///
    /// `start()` (via `stop()`) and `pause()` both cancel; `resume()` was the one member of the
    /// trio that did not. A non-`.running` state does not prove the loop finished — only those
    /// two cancel it, so any path that writes the state directly leaves one alive.
    func testResume_cancelsTheSurvivingRunLoop() async {
        let engine = TeamEngine()
        let store = MockTeamEngineStore()
        store.activeTeam = Self.spinningTeam()
        store.activeTask = Self.spinningTask()
        engine.attach(store: store)

        engine.start()
        let orphanCandidate = engine.runTask
        XCTAssertNotNil(orphanCandidate, "premise: start() launched a loop")

        // The dangerous shape: state written WITHOUT pause()/stop(), so `runTask` stays alive.
        engine.transition(to: .paused)
        XCTAssertEqual(orphanCandidate?.isCancelled, false, "premise: the loop is still live")

        engine.resume()

        XCTAssertEqual(orphanCandidate?.isCancelled, true,
                       "resume() must cancel the surviving loop before launching a replacement")
        engine.stop()
    }

    /// A team whose only worker is `.working`, so the run loop parks in its 250 ms wait branch
    /// instead of terminating — that is what makes the orphan above genuinely alive.
    private static func spinningTeam() -> Team {
        var team = TeamTemplateFactory.startup()
        team.settings.limits.autoIterationLimit = 0   // unbounded: never self-terminate mid-test
        return team
    }

    private static func spinningTask() -> NTMSTask {
        let team = TeamTemplateFactory.startup()
        let worker = team.roles.first(where: { !$0.isSupervisor })!
        let supervisor = team.roles.first(where: { $0.isSupervisor })!
        var task = NTMSTask(id: 1, title: "spin", supervisorTask: "spin")
        task.runs = [Run(
            id: 0,
            steps: [StepExecution(id: worker.id, role: .softwareEngineer,
                                  title: worker.name, status: .running)],
            roleStatuses: [supervisor.id: .done, worker.id: .working],
            teamID: team.id
        )]
        return task
    }

    // MARK: - Characterization: the two sites deliberately NOT converted

    /// CHOICE: `answerSupervisorQuestion`'s weak else-if arm is left alone. The post-restart case
    /// is already total (recovery rewrites the step `.needsSupervisorInput → .paused`, so the
    /// mirror is `.paused` and the classifier routes to `resumeRun`). The only reachable weak
    /// case is a nil mirror, and `stopEngine` is its sole producer — i.e. a DELIBERATE
    /// `control_task stop`. The defensible alternative (route a nil mirror to `resumeRun` too) is
    /// rejected because it would make answering a question override a stop the manager just
    /// issued.
    /// FIXTURE: stop the engine, then answer; the answer must persist with no engine revived.
    /// RED: convert that arm to `wakeEngine` → the stopped task restarts.
    func testCharacterization_answerAfterStop_doesNotRestartTheTask() async {
        guard let f = await makeEngineFreeReviewTask(stepStatus: .needsSupervisorInput) else { return }
        await sut.mutateTask(taskID: f.id) { task in
            task.runs[0].steps[0].needsSupervisorInput = true
            task.runs[0].steps[0].supervisorQuestion = "which layer?"
            task.runs[0].roleStatuses[f.roleID] = .working
        }
        sut.stopEngine(for: f.id)
        XCTAssertNil(sut.taskEngineStates[f.id], "premise: control_task stop cleared the mirror")

        let ok = await sut.answerSupervisorQuestion(
            stepID: f.roleID, taskID: f.id, answer: "the API layer")

        XCTAssertTrue(ok, "the answer must still be recorded")
        XCTAssertEqual(latestRun(f.id)?.steps.first?.effectiveSupervisorAnswer, "the API layer")
        XCTAssertNil(sut.taskEngines[f.id],
                     "but a deliberate stop must not be undone by answering a question")
    }

    /// CHOICE: `holdDownstreamForRevision`'s `.pending` skip is kept. It is not a member of the
    /// no-engine class — it already calls `engineForTask` — and its `.pending` case means "a step
    /// is LIVE while no engine is": `startRevisionRoles` has no occupied-`roleTasks` guard and
    /// `resetStepForRevision` no-ops on a `.running` step, so starting here can drive a SECOND
    /// concurrent LLM execution into one step. The defensible alternative (treat `.pending`
    /// uniformly, as the other converted sites do) is rejected for exactly that reason.
    /// FIXTURE: engine-free task with a `.running` step; the registered engine must stay
    /// `.pending`.
    /// RED: convert that site to `wakeEngine` → the engine starts and the live step is re-entered.
    func testCharacterization_holdDownstreamForRevision_leavesAPendingEngineUnstarted() async {
        guard let f = await makeEngineFreeReviewTask(stepStatus: .running) else { return }
        await sut.mutateTask(taskID: f.id) { task in
            task.runs[0].roleStatuses[f.roleID] = .working
        }

        await sut.holdDownstreamForRevision(
            taskID: f.id, runningRoleIDs: [f.roleID], requesterRoleID: f.roleID)

        XCTAssertEqual(sut.taskEngines[f.id]?.state, .pending,
                       "the engine is registered by engineForTask but must NOT be started while "
                           + "the requester's step is still live")
    }
}
