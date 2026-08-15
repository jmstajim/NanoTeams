import XCTest
@testable import NanoTeams

/// Orchestrator-level invariants for the Autovisor's write hook. These drive
/// the FAILURE / guard paths of `performAutovisorAction`, which short-circuit
/// BEFORE any engine start — so they run without LM Studio. (The success paths that
/// start an engine are covered by the handler/value tests, not here.)
@MainActor
final class AutovisorOrchestratorTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// Opens the temp work folder and pins a freshly-created (non-running) task as
    /// the manager, without enabling the feature (so no engine/LLM is started).
    private func pinManager() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = mgrID }
        return mgrID
    }

    private var taskCount: Int { sut.snapshot?.tasksIndex.tasks.count ?? 0 }

    // MARK: - T1: self-guard

    func testSelfGuard_refusesActionOnOwnTask() async {
        let mgrID = await pinManager()
        let r = await sut.performAutovisorAction(.controlTask(taskID: mgrID, verb: .pause))
        XCTAssertFalse(r.ok, "the manager must never act on its own task")
        XCTAssertTrue(r.message.contains("#\(mgrID)"))
    }

    func testSelfGuard_allowsActionOnOtherTask() async {
        _ = await pinManager()
        let otherID = await sut.createTask(title: "Real", supervisorTask: "x", makeActive: false)!
        // pause on a task whose engine isn't running is a no-op → reported as success
        // (the point: it is NOT refused by the self-guard).
        let r = await sut.performAutovisorAction(.controlTask(taskID: otherID, verb: .pause))
        XCTAssertTrue(r.ok)
    }

    func testTaskTargetedAction_unknownTask_failsLoud() async {
        _ = await pinManager()
        let r = await sut.performAutovisorAction(.controlTask(taskID: 99999, verb: .pause))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("99999"))
    }

    // MARK: - Enable guard (no real work folder)

    /// Enabling the Autovisor in default storage (no work folder open) must be
    /// refused — otherwise the toggle would persist `ON` while
    /// `ensureAutovisorTask` no-ops, a dead control. The refusal returns before
    /// any engine start, so it runs without LM Studio.
    func testSetAutovisorEnabled_withoutWorkFolder_refusesAndInforms() async {
        XCTAssertFalse(sut.hasRealWorkFolder, "precondition: no real work folder open")
        sut.lastInfoMessage = nil
        await sut.setAutovisorEnabled(true)
        XCTAssertNotNil(sut.lastInfoMessage,
            "refusing to enable without a work folder must surface an info message")
        XCTAssertFalse(sut.snapshot?.workFolder.settings.autovisorEnabled ?? false,
            "the enable must NOT have persisted")
    }

    /// Disabling is always allowed (it clears a possibly-stale persisted `true`),
    /// so it must NOT be intercepted by the enable guard.
    func testSetAutovisorDisabled_withoutWorkFolder_isAllowed() async {
        XCTAssertFalse(sut.hasRealWorkFolder)
        sut.lastInfoMessage = nil
        await sut.setAutovisorEnabled(false)
        XCTAssertNil(sut.lastInfoMessage,
            "disabling is always allowed — the enable guard must not fire on disable")
    }

    /// The return value makes a refused enable observable — `AutovisorSetupView.enable`
    /// (and any future caller) can tell a real enable from a folder-closed refusal
    /// instead of silently assuming success.
    func testSetAutovisorEnabled_returnValueReflectsOutcome() async {
        XCTAssertFalse(sut.hasRealWorkFolder, "precondition: no real work folder open")
        let enabled = await sut.setAutovisorEnabled(true)
        XCTAssertFalse(enabled, "enable in default storage is refused → returns false")
        let disabled = await sut.setAutovisorEnabled(false)
        XCTAssertTrue(disabled, "disable always takes effect → returns true")
    }

    // MARK: - Setup routing (which pane `.autovisor` shows; pill intercept)

    /// Fresh orchestrator (no manager task, disabled) → the detail surface routes
    /// to the start page, and the pill's OFF→ON click routes there too rather than
    /// enabling something that doesn't exist.
    func testAutovisorShowsSetupPane_noManagerTask_isTrue() {
        XCTAssertNil(sut.autovisorTaskID, "precondition: manager never created")
        XCTAssertTrue(sut.autovisorShowsSetupPane,
            "no manager task → show setup, not a chat for a manager that doesn't exist")
        XCTAssertTrue(sut.autovisorRequiresSetupBeforeEnabling,
            "nothing to turn on yet → the pill must route to setup")
    }

    /// The created-then-disabled wiring, end to end on the orchestrator: a manager
    /// with a REAL goal that gets switched off shows the start page (so re-enabling
    /// is one screen away) while the pill keeps its one-click enable (no detour —
    /// the goal is already configured). These two must disagree here; that's exactly
    /// why the old single predicate was split.
    func testDisabledManagerWithRealGoal_showsSetupPaneButPillStillEnablesDirectly() async {
        let mgrID = await pinManager()
        await sut.mutateWorkFolder {
            $0.settings.autovisorGoal = "Keep the test suite green and report regressions."
            $0.settings.autovisorEnabled = true   // direct write: no engine, no LM Studio
        }
        XCTAssertFalse(sut.autovisorShowsSetupPane, "precondition: enabled manager shows its chat")

        let disabled = await sut.setAutovisorEnabled(false)
        XCTAssertTrue(disabled)

        XCTAssertEqual(sut.autovisorTaskID, mgrID, "disable keeps the manager task — only Delete clears it")
        XCTAssertTrue(sut.autovisorShowsSetupPane,
            "disabled → the tab shows the start page, whatever the goal says")
        XCTAssertFalse(sut.autovisorRequiresSetupBeforeEnabling,
            "a real goal is already set → the pill re-enables in one click")
    }

    // MARK: - F1: role validation

    func testManageRole_unknownRole_failsWithoutMutating() async {
        _ = await pinManager()
        let otherID = await sut.createTask(title: "Real", supervisorTask: "x", makeActive: false)!
        let r = await sut.performAutovisorAction(
            .manageRole(taskID: otherID, roleID: "ghost-role", verb: .restart(comment: nil))
        )
        XCTAssertFalse(r.ok, "a hallucinated role_id must be rejected, not silently no-op'd")
        XCTAssertTrue(r.message.contains("ghost-role"))
    }

    // MARK: - F1b: restart is destructive on a paused task

    /// Seeds `taskID` with a paused step holding `toolCalls` tool calls, and puts the
    /// engine in `.paused` — the exact shape `StatusRecoveryService` leaves behind when
    /// the app is closed mid-run.
    private func seedPausedStepWithWork(taskID: Int, roleID: String = "startup_software_engineer",
                                        toolCalls: Int = 5) async {
        let calls = (1...max(1, toolCalls)).map {
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\":\"f\($0).swift\"}",
                         resultJSON: "{\"ok\":true}")
        }
        let step = StepExecution(
            id: roleID, role: .softwareEngineer, title: "SWE", status: .paused,
            messages: [StepMessage(role: .softwareEngineer, content: "researching")],
            toolCalls: calls)
        // A background task is absent from `loadedTasks`, and `mutateTask` gates on
        // it — without this the seed is silently dropped (CLAUDE.md §7).
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [step], roleStatuses: [roleID: .idle])]
        }
        sut.engineState[taskID] = .paused
    }

    /// The 2026-07-25 incident: the manager restarted a merely-paused task and
    /// `StepExecution.reset` erased 5 tool calls of research plus the conversation.
    /// Restart must be refused there, and the refusal must name the verbs that do the
    /// job — a bare "no" costs the manager a turn to rediscover them.
    func testRestart_onPausedTaskWithWork_isRejected_andNamesTheAlternatives() async {
        _ = await pinManager()
        let otherID = await sut.createTask(title: "M3", supervisorTask: "x", makeActive: false)!
        await seedPausedStepWithWork(taskID: otherID)

        let r = await sut.performAutovisorAction(
            .manageRole(taskID: otherID, roleID: "startup_software_engineer",
                        verb: .restart(comment: "resume it")))

        XCTAssertFalse(r.ok, "restart on a paused step holding work must be refused, not performed")
        XCTAssertTrue(r.message.contains("resume"), "the refusal must name the verb that continues the run")
        XCTAssertTrue(r.message.contains("correct"), "…and the verb that steers it in place")
        XCTAssertTrue(r.message.contains("stop"), "…and the deliberate-discard escape hatch")

        let step = sut.loadedTask(otherID)?.runs.last?.steps.first
        XCTAssertEqual(step?.toolCalls.count, 5, "the work must still be on disk after the refusal")
        XCTAssertEqual(step?.status, .paused, "and the step must not have been reset")
    }

    /// The guard is about DATA LOSS, not about the paused state: a paused step that
    /// never produced anything has nothing to lose, so restart still works.
    func testRestart_onPausedTaskWithNoWork_proceeds() async {
        _ = await pinManager()
        let otherID = await sut.createTask(title: "M3", supervisorTask: "x", makeActive: false)!
        let step = StepExecution(id: "startup_software_engineer", role: .softwareEngineer,
                                 title: "SWE", status: .paused)
        await sut.ensureTaskLoaded(otherID)
        await sut.mutateTask(taskID: otherID) { task in
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["startup_software_engineer": .idle])]
        }
        sut.engineState[otherID] = .paused

        let r = await sut.performAutovisorAction(
            .manageRole(taskID: otherID, roleID: "startup_software_engineer",
                        verb: .restart(comment: "go")))

        XCTAssertTrue(r.ok, "an empty paused step has no work to protect")
    }

    /// The escape hatch, without a schema change: `control_task stop` drops the engine
    /// state, after which restart is allowed. Two explicit steps = deliberate intent.
    func testRestart_afterStop_proceeds() async {
        _ = await pinManager()
        let otherID = await sut.createTask(title: "M3", supervisorTask: "x", makeActive: false)!
        await seedPausedStepWithWork(taskID: otherID)

        let stopped = await sut.performAutovisorAction(.controlTask(taskID: otherID, verb: .stop))
        XCTAssertTrue(stopped.ok)

        let r = await sut.performAutovisorAction(
            .manageRole(taskID: otherID, roleID: "startup_software_engineer",
                        verb: .restart(comment: "start over")))
        XCTAssertTrue(r.ok, "after an explicit stop the discard is intentional and must be allowed")
    }

    /// The guard is scoped to `.paused`. A RUNNING task's restart is the documented
    /// remedy for a looping role and must not be caught by it.
    func testRestart_onRunningTaskWithWork_stillProceeds() async {
        _ = await pinManager()
        let otherID = await sut.createTask(title: "M3", supervisorTask: "x", makeActive: false)!
        await seedPausedStepWithWork(taskID: otherID)
        sut.engineState[otherID] = .running

        let r = await sut.performAutovisorAction(
            .manageRole(taskID: otherID, roleID: "startup_software_engineer",
                        verb: .restart(comment: "you are looping")))
        XCTAssertTrue(r.ok, "restart stays the remedy for a stuck RUNNING role")
    }

    func testCorrect_notPaused_fails() async {
        _ = await pinManager()
        let otherID = await sut.createTask(title: "Real", supervisorTask: "x", makeActive: false)!
        // No role exists yet (no run) → role validation fails first, which is still
        // a loud failure rather than a false "correction sent".
        let r = await sut.performAutovisorAction(
            .manageRole(taskID: otherID, roleID: "anything", verb: .correct(comment: "fix"))
        )
        XCTAssertFalse(r.ok)
    }

    // MARK: - F4: team resolution

    func testCreateManagedTask_unknownTeam_failsWithoutCreating() async {
        _ = await pinManager()
        let before = taskCount
        let r = await sut.performAutovisorAction(
            .createManagedTask(title: "T", brief: "B", teamID: "does-not-exist")
        )
        XCTAssertFalse(r.ok, "an unresolvable team_id must fail, not silently use the active team")
        XCTAssertTrue(r.message.contains("does-not-exist"))
        XCTAssertEqual(taskCount, before, "no task should be created for an unresolvable team_id")
    }

    // MARK: - Team-generation permission (runtime backstop)

    /// With `autovisorAllowTeamGeneration` off, a `team_id: "generated"` must be
    /// rejected loudly BEFORE any task/team is materialized — the runtime backstop
    /// for a model that emits the sentinel despite the schema no longer offering it.
    func testCreateManagedTask_generationDisabled_rejectsSentinelWithoutCreating() async {
        _ = await pinManager()
        await sut.setAutovisorAllowTeamGeneration(false)
        let tasksBefore = taskCount
        let teamsBefore = sut.snapshot?.workFolder.teams.count ?? 0

        let r = await sut.performAutovisorAction(
            .createManagedTask(title: "T", brief: "B",
                               teamID: DelegationConstants.generatedTeamSentinel)
        )

        XCTAssertFalse(r.ok, "generation is disabled → the sentinel must be rejected")
        XCTAssertTrue(r.message.lowercased().contains("disabled"),
                      "the failure must explain generation is disabled")
        XCTAssertEqual(taskCount, tasksBefore, "no task may be created")
        XCTAssertEqual(sut.snapshot?.workFolder.teams.count ?? 0, teamsBefore,
                       "the placeholder generated team must NOT be lazily created")
    }

    /// The setter persists the per-folder flag into `settings`.
    func testSetAutovisorAllowTeamGeneration_persists() async {
        _ = await pinManager()
        XCTAssertTrue(sut.snapshot?.workFolder.settings.autovisorAllowTeamGeneration ?? false,
                      "precondition: defaults to allowed")
        await sut.setAutovisorAllowTeamGeneration(false)
        XCTAssertFalse(sut.snapshot?.workFolder.settings.autovisorAllowTeamGeneration ?? true,
                       "the setter must persist the disable")
        await sut.setAutovisorAllowTeamGeneration(true)
        XCTAssertTrue(sut.snapshot?.workFolder.settings.autovisorAllowTeamGeneration ?? false,
                      "re-enabling must persist too")
    }

    // MARK: - Per-team block list (Settings → Autovisor → Teams)

    /// The checkbox writes through the INVERSE of what it shows: the view speaks "allowed",
    /// the store keeps a block list. Both directions must persist.
    func testSetAutovisorTeamAllowed_invertsIntoTheStoredBlockList() async {
        _ = await pinManager()
        let teamID = sut.snapshot?.workFolder.teams.first?.id ?? "t"
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorBlockedTeamIDs, [],
                       "precondition: nothing blocked by default")

        await sut.setAutovisorTeamAllowed(teamID, allowed: false)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorBlockedTeamIDs, [teamID],
                       "unchecking must ADD to the block list")

        await sut.setAutovisorTeamAllowed(teamID, allowed: true)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorBlockedTeamIDs, [],
                       "re-checking must REMOVE it")
    }

    /// Blocking the same team twice must not duplicate it, and unblocking one of two must
    /// leave the other — the read-modify-write happens inside `mutateWorkFolder`, so it
    /// composes rather than clobbering.
    func testSetAutovisorTeamAllowed_isIdempotentAndComposes() async {
        _ = await pinManager()
        let teams = sut.snapshot?.workFolder.teams.prefix(2).map(\.id) ?? []
        guard teams.count == 2 else { return XCTFail("need two teams; got \(teams)") }

        await sut.setAutovisorTeamAllowed(teams[0], allowed: false)
        await sut.setAutovisorTeamAllowed(teams[0], allowed: false)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorBlockedTeamIDs, [teams[0]],
                       "blocking twice must not duplicate")

        await sut.setAutovisorTeamAllowed(teams[1], allowed: false)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorBlockedTeamIDs,
                       [teams[0], teams[1]].sorted(),
                       "the second block must not clobber the first")

        await sut.setAutovisorTeamAllowed(teams[0], allowed: true)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorBlockedTeamIDs, [teams[1]],
                       "unblocking one must leave the other")
    }

    /// The bulk setter (used to clear orphan rows) normalizes, so a caller can't persist an
    /// unsorted or duplicated list that would then dirty the settings diff on every write.
    func testSetAutovisorBlockedTeamIDs_normalizes() async {
        _ = await pinManager()
        await sut.setAutovisorBlockedTeamIDs(["beta", " alpha ", "beta", ""])
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorBlockedTeamIDs, ["alpha", "beta"])

        await sut.setAutovisorBlockedTeamIDs([])
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorBlockedTeamIDs, [],
                       "clearing must be representable — that is how an orphan row is forgotten")
    }

    /// End to end: what the setter persists is what the tool schema stops advertising.
    func testBlockingATeam_removesItFromTheCreateManagedTaskCatalog() async {
        _ = await pinManager()
        guard let target = sut.snapshot?.workFolder.teams.first(where: { !$0.isHiddenFromPickers })
        else { return XCTFail("need a selectable team") }

        await sut.setAutovisorTeamAllowed(target.id, allowed: false)

        let settings = try! XCTUnwrap(sut.snapshot?.workFolder.settings)
        let schema = CreateManagedTaskTool.buildSchema(
            allTeams: sut.snapshot?.workFolder.teams ?? [],
            policy: AutovisorTeamPolicy(settings: settings))
        XCTAssertFalse(schema.description.contains("`\(target.id)`"),
                       "a blocked team must not be advertised to the manager")
    }

    /// A model emitting the sentinel with surrounding whitespace (`"  generated  "`)
    /// is trimmed before classification, so the disable gate must still catch it.
    func testCreateManagedTask_generationDisabled_rejectsPaddedSentinel() async {
        _ = await pinManager()
        await sut.setAutovisorAllowTeamGeneration(false)
        let before = taskCount
        let padded = "  \(DelegationConstants.generatedTeamSentinel)  "
        let r = await sut.performAutovisorAction(
            .createManagedTask(title: "T", brief: "B", teamID: padded)
        )
        XCTAssertFalse(r.ok, "a padded sentinel must still be rejected when disabled")
        XCTAssertTrue(r.message.lowercased().contains("disabled"))
        XCTAssertEqual(taskCount, before)
    }

    /// The disable gate is specific to the sentinel: an unknown team_id while
    /// generation is off must still fail as UNKNOWN (naming the raw id), not be
    /// mislabelled as "generation disabled". Guards against the gate over-firing.
    func testCreateManagedTask_generationDisabled_unknownTeam_reportsUnknownNotDisabled() async {
        _ = await pinManager()
        await sut.setAutovisorAllowTeamGeneration(false)
        let r = await sut.performAutovisorAction(
            .createManagedTask(title: "T", brief: "B", teamID: "no-such-team")
        )
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("no-such-team"),
                      "an unknown team must be reported as unknown, naming the id")
        XCTAssertFalse(r.message.lowercased().contains("disabled"),
                       "the disable gate must not swallow the unknown-team case")
    }

    // MARK: - F7: per-review creation cap

    func testCreateManagedTask_perReviewCap_blocksFurtherCreation() async {
        _ = await pinManager()
        sut.autovisorCreationsThisReview = AutovisorConstants.maxManagedTasksPerReview
        let before = taskCount
        let r = await sut.performAutovisorAction(
            .createManagedTask(title: "T", brief: "B", teamID: nil)
        )
        XCTAssertFalse(r.ok)
        XCTAssertEqual(taskCount, before, "per-review cap must block creation")
    }

    /// The per-review cap is now read from `settings.autovisorTuning`, not the
    /// constant — a lower configured cap must block sooner, and the failure names
    /// the configured value.
    func testCreateManagedTask_perReviewCap_respectsConfiguredTuning() async {
        _ = await pinManager()
        var tuning = AutovisorTuning.default
        tuning.maxManagedTasksPerReview = 2
        await sut.updateAutovisorTuning(tuning)

        sut.autovisorCreationsThisReview = 2   // already at the lowered cap this pass
        let before = taskCount
        let r = await sut.performAutovisorAction(
            .createManagedTask(title: "T", brief: "B", teamID: nil)
        )
        XCTAssertFalse(r.ok, "creation must block at the configured per-review cap (2)")
        XCTAssertTrue(r.message.contains("2"), "the failure names the configured cap")
        XCTAssertEqual(taskCount, before)
    }

    /// The concurrency cap is also read from `settings.autovisorTuning` (sibling of
    /// the per-review cap, and checked FIRST). With a configured cap of 1 and one
    /// other task already running, creation must block. Guards against the read-site
    /// silently reverting to the constant.
    func testCreateManagedTask_concurrencyCap_respectsConfiguredTuning() async {
        _ = await pinManager()
        var tuning = AutovisorTuning.default
        tuning.maxConcurrentManagedTasks = 1
        await sut.updateAutovisorTuning(tuning)

        // One non-manager task already `.running` → at the configured ceiling of 1.
        guard let runningID = await makeRunningTask() else { return }

        let before = taskCount
        let r = await sut.performAutovisorAction(
            .createManagedTask(title: "T", brief: "B", teamID: nil)
        )
        XCTAssertFalse(r.ok, "creation must block at the configured concurrency cap (1)")
        XCTAssertTrue(r.message.contains("1"), "the failure names the running count")
        XCTAssertEqual(taskCount, before, "no task created when at the concurrency ceiling")
        sut.stopEngineForTask(runningID)
    }

    // MARK: - switchTeam guard (manager is bound to its own team)

    /// `switchTeam` while the manager is the active task must be a complete no-op:
    /// neither the work folder's `activeTeamID` nor the manager's `preferredTeamID`
    /// may change. The UI hides the team menu on the Autovisor; this pins the
    /// defense-in-depth guard behind it.
    func testSwitchTeam_managerActive_isNoOp() async {
        let mgrID = await pinManager()
        await sut.switchTask(to: mgrID)
        XCTAssertEqual(sut.activeTaskID, mgrID, "premise: the manager is the active task")

        let activeTeamBefore = sut.snapshot?.workFolder.activeTeamID
        let preferredBefore = sut.activeTask?.preferredTeamID
        guard let otherTeam = (sut.snapshot?.workFolder.teams ?? [])
            .first(where: { !$0.isHiddenFromPickers && $0.id != activeTeamBefore }) else {
            return XCTFail("premise: a second selectable team exists in the default bootstrap")
        }

        await sut.switchTeam(to: otherTeam.id)

        XCTAssertEqual(sut.snapshot?.workFolder.activeTeamID, activeTeamBefore,
                       "activeTeamID must not change while the manager is active")
        XCTAssertEqual(sut.activeTask?.preferredTeamID, preferredBefore,
                       "the manager's preferredTeamID must never be rewritten")
    }

    /// Control: the guard keys on the pinned manager id only — a normal active task
    /// still switches teams as before.
    func testSwitchTeam_normalTaskActive_stillSwitches() async {
        _ = await pinManager()
        let otherID = await sut.createTask(title: "Real", supervisorTask: "x", makeActive: false)!
        await sut.switchTask(to: otherID)

        let activeTeamBefore = sut.snapshot?.workFolder.activeTeamID
        guard let otherTeam = (sut.snapshot?.workFolder.teams ?? [])
            .first(where: { !$0.isHiddenFromPickers && $0.id != activeTeamBefore }) else {
            return XCTFail("premise: a second selectable team exists in the default bootstrap")
        }

        await sut.switchTeam(to: otherTeam.id)

        XCTAssertEqual(sut.snapshot?.workFolder.activeTeamID, otherTeam.id)
        XCTAssertEqual(sut.activeTask?.preferredTeamID, otherTeam.id)
    }

    /// Pins the unwrap-before-compare subtlety in the guard: with NO active task and
    /// NO pinned manager both ids are nil, and a bare `activeTaskID == autovisorTaskID`
    /// would be `nil == nil` → true, silently blocking the switch (the production shape
    /// is HeadlessRunner, which switches teams right after open, before any task).
    func testSwitchTeam_noActiveTask_noManager_stillSwitches() async {
        await sut.openWorkFolder(tempDir)   // no pinManager, no switchTask → both ids nil
        XCTAssertNil(sut.activeTaskID, "premise: no active task")
        XCTAssertNil(sut.autovisorTaskID, "premise: no pinned manager")

        let activeTeamBefore = sut.snapshot?.workFolder.activeTeamID
        guard let otherTeam = (sut.snapshot?.workFolder.teams ?? [])
            .first(where: { !$0.isHiddenFromPickers && $0.id != activeTeamBefore }) else {
            return XCTFail("premise: a second selectable team exists in the default bootstrap")
        }

        await sut.switchTeam(to: otherTeam.id)

        XCTAssertEqual(sut.snapshot?.workFolder.activeTeamID, otherTeam.id,
                       "nil activeTaskID + nil autovisorTaskID must not trip the manager guard")
    }

    /// Symmetric direction: a normal task must never be re-teamed ONTO the Autovisor
    /// team (it would acquire the manager's tools and scratchpad write-through).
    func testSwitchTeam_ontoAutovisorTeam_isNoOp() async {
        _ = await pinManager()
        let otherID = await sut.createTask(title: "Real", supervisorTask: "x", makeActive: false)!
        await sut.switchTask(to: otherID)

        let activeTeamBefore = sut.snapshot?.workFolder.activeTeamID
        let preferredBefore = sut.activeTask?.preferredTeamID
        guard let autovisorTeam = (sut.snapshot?.workFolder.teams ?? [])
            .first(where: { $0.isManagedSingleton }) else {
            return XCTFail("premise: the Autovisor team is always seeded on open")
        }

        await sut.switchTeam(to: autovisorTeam.id)

        XCTAssertEqual(sut.snapshot?.workFolder.activeTeamID, activeTeamBefore,
                       "activeTeamID must not change when targeting the Autovisor team")
        XCTAssertEqual(sut.activeTask?.preferredTeamID, preferredBefore,
                       "a normal task must never be re-teamed onto the Autovisor team")
    }

    // MARK: - Always-present team bootstrap

    /// Opening a real work folder with the feature OFF must still seed exactly one
    /// Autovisor team (so it shows as a protected entry in Settings → Teams), and that
    /// team must NOT become the work folder's default team for new tasks.
    func testOpenWorkFolder_seedsAutovisorTeam_evenWhenDisabled() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertFalse(sut.snapshot?.workFolder.settings.autovisorEnabled ?? true,
                       "feature is off by default")
        let autovisorTeams = (sut.snapshot?.workFolder.teams ?? [])
            .filter { $0.templateID == AutovisorConstants.teamTemplateID }
        XCTAssertEqual(autovisorTeams.count, 1, "exactly one Autovisor team is always present")
        let activeID = sut.snapshot?.workFolder.activeTeamID
        XCTAssertNotNil(activeID, "a real default team must be chosen")
        XCTAssertNotEqual(activeID, autovisorTeams.first?.id,
                          "Autovisor must never be the default team for new tasks")
    }

    /// The reconcile (coordinator-normalize + mandatory-tool union-enforce) must run on
    /// EVERY open for an EXISTING team, even with the feature disabled — not only when the
    /// team is first appended. Regression for the early-return that skipped the sync.
    func testEnsureAutovisorTeam_reconcilesExistingTeam_whenDisabled() async {
        await sut.openWorkFolder(tempDir)
        // Corrupt the persisted singleton: a non-Auto coordinator + a missing mandatory tool.
        await sut.mutateWorkFolder { proj in
            guard let i = proj.teams.firstIndex(where: { $0.templateID == AutovisorConstants.teamTemplateID }) else { return }
            proj.teams[i].settings.meetingCoordinatorRoleID = proj.teams[i].roles.first { !$0.isSupervisor }?.id
            if let r = proj.teams[i].roles.firstIndex(where: { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }) {
                proj.teams[i].roles[r].toolIDs.removeAll { $0 == ToolNames.listTasks }
            }
        }

        await sut.ensureAutovisorTeam()

        let team = sut.snapshot?.workFolder.teams.first { $0.templateID == AutovisorConstants.teamTemplateID }
        XCTAssertNil(team?.settings.meetingCoordinatorRoleID, "coordinator re-normalized to Auto on open")
        let mgr = team?.roles.first { $0.systemRoleID == AutovisorConstants.managerRoleSystemID }
        XCTAssertTrue(mgr?.toolIDs.contains(ToolNames.listTasks) ?? false, "mandatory tool re-enforced on open")
    }

    /// Idempotent: a second open must not append a duplicate Autovisor team.
    func testOpenWorkFolder_autovisorTeam_isIdempotent() async {
        await sut.openWorkFolder(tempDir)
        await sut.openWorkFolder(tempDir)
        let count = (sut.snapshot?.workFolder.teams ?? [])
            .filter { $0.templateID == AutovisorConstants.teamTemplateID }.count
        XCTAssertEqual(count, 1, "reopening must not duplicate the Autovisor team")
    }

    // MARK: - T6: Watchtower exclusion

    func testAllLoadedTasks_excludesManager_includesOthers() async {
        let mgrID = await pinManager()
        let otherID = await sut.createTask(title: "Real", supervisorTask: "x", makeActive: false)!
        await sut.ensureTaskLoaded(otherID)
        await sut.ensureTaskLoaded(mgrID)
        let ids = sut.allLoadedTasks.map(\.id)
        XCTAssertTrue(ids.contains(otherID))
        XCTAssertFalse(ids.contains(mgrID), "manager is the automated Supervisor — never supervised work")
    }

    // MARK: - Wake gating

    /// Pins a manager and turns the feature on.
    private func enabledManager() async -> Int {
        let mgrID = await pinManager()
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
        return mgrID
    }

    /// Creates a NON-chat (Startup) task and drives it to the Review
    /// (`.needsSupervisorAcceptance`) state: one completed step + a role awaiting acceptance,
    /// not closed. A chat-mode task would override to `.running` and never present as Review.
    private func makeReviewStartupTask() async -> Int? {
        guard let startupID = sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id else {
            XCTFail("Startup team must be bootstrapped"); return nil
        }
        guard let taskID = await sut.createTask(title: "Build X", supervisorTask: "do X",
                                                preferredTeamID: startupID, makeActive: false) else {
            XCTFail("createTask failed"); return nil
        }
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .needsAcceptance])]
        }
        return taskID
    }

    // MARK: - manage_role accept honesty

    /// `manage_role accept` on a role genuinely awaiting acceptance succeeds.
    func testManageRoleAccept_onNeedsAcceptanceRole_succeeds() async {
        _ = await pinManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "r", verb: .accept))
        XCTAssertTrue(r.ok, "a role at .needsAcceptance must accept cleanly")
        XCTAssertTrue(r.message.contains("Accepted role"),
                      "the success result must confirm the acceptance, not return an empty message")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["r"], .accepted)
    }

    /// The reported bug: `manage_role accept` on an already-`.done` role must FAIL honestly
    /// (no false "Accepted role …" success). The manager should `control_task close` to
    /// finalize a finished task instead — accepting a done role is a no-op it shouldn't attempt.
    func testManageRoleAccept_onDoneRole_failsHonestly() async {
        _ = await pinManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[task.runs.count - 1].roleStatuses["r"] = .done
        }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "r", verb: .accept))
        XCTAssertFalse(r.ok, "accepting an already-done role must be reported as failure, not success")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["r"], .done,
                       "a rejected accept must leave the role status untouched")
    }

    /// The 2026-08-11 incident: accept on a `.done` role while the task derives Review.
    /// The pinned fact ("Role already completed") must survive as the message PREFIX and
    /// the appended remedy must name the actual way out — `control_task close`.
    func testManageRoleAccept_onDoneRoleInReview_appendsCloseRemedy() async {
        _ = await pinManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[task.runs.count - 1].roleStatuses["r"] = .done
        }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "r", verb: .accept))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.hasPrefix("Role already completed"),
                      "the original reject reason must be preserved, never replaced; got: \(r.message)")
        XCTAssertTrue(r.message.contains("control_task close"),
                      "a Review task's dead-end accept must steer the manager to close; got: \(r.message)")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["r"], .done,
                       "advice must not change the no-mutation contract of a rejected accept")
    }

    /// `.accepted` is `isComplete`, so the task still derives Review — same close remedy.
    func testManageRoleAccept_onAcceptedRoleInReview_appendsCloseRemedy() async {
        _ = await pinManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[task.runs.count - 1].roleStatuses["r"] = .accepted
        }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "r", verb: .accept))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("already accepted"), "pinned fact preserved")
        XCTAssertTrue(r.message.contains("control_task close"),
                      "an all-complete task in Review is finalized by close; got: \(r.message)")
    }

    /// A `.done` role beside a WORKING sibling: the task derives `.running`, not Review —
    /// telling the manager to close would truncate the sibling's work. Neutral advice only.
    func testManageRoleAccept_onDoneRoleBesideWorkingSibling_noCloseAdvice() async {
        _ = await pinManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done),
                StepExecution(id: "s", role: .custom(id: "s"), title: "Sibling", status: .running),
            ], roleStatuses: ["r": .done, "s": .working])]
        }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "r", verb: .accept))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.hasPrefix("Role already completed"), "reason preserved; got: \(r.message)")
        XCTAssertFalse(r.message.contains("control_task close"),
                       "close advice while a sibling works would invite truncating the run; got: \(r.message)")
        XCTAssertTrue(r.message.contains("task_status"),
                      "the neutral remedy points back at the per-role view; got: \(r.message)")
    }

    /// The trap the review caught before it shipped: a `.done` role beside a sibling at
    /// a LIVE `.needsAcceptance` gate. The task still derives Review
    /// (`onlyAcceptanceOrComplete` arm), so a bare derived-status gate would advise
    /// close — and close force-accepts the gated sibling's output unreviewed
    /// (`finalizeRoleStatusesForClose` rewrites `.needsAcceptance` → `.done`). The
    /// advice must stay neutral, exactly as the `task_status` hint stays silent in this
    /// same state — the two surfaces share `isReadyForFinalAcceptance` so they cannot
    /// disagree.
    func testManageRoleAccept_onDoneRoleBesideNeedsAcceptanceSibling_noCloseAdvice() async {
        _ = await pinManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done),
                StepExecution(id: "p", role: .custom(id: "p"), title: "Gated", status: .done),
            ], roleStatuses: ["r": .done, "p": .needsAcceptance])]
        }
        XCTAssertEqual(sut.loadedTask(taskID)?.derivedStatusFromActiveRun(), .needsSupervisorAcceptance,
                       "precondition: this shape DOES derive Review — that is the trap")
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "r", verb: .accept))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.hasPrefix("Role already completed"), "reason preserved; got: \(r.message)")
        XCTAssertFalse(r.message.contains("control_task close"),
                       "advising close would sweep p's gated output past the Supervisor; got: \(r.message)")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["p"], .needsAcceptance,
                       "the sibling's live gate must be untouched")
    }

    /// A `.failed` role's accept-rejection steers to restart (the only remedy that
    /// preserves the failure semantics), never to a forced accept or a close.
    func testManageRoleAccept_onFailedRole_advisesRestart() async {
        _ = await pinManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[task.runs.count - 1].roleStatuses["r"] = .failed
        }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "r", verb: .accept))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("manage_role restart"),
                      "a failed role's remedy is restart; got: \(r.message)")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["r"], .failed,
                       "the failure must be preserved (finalizeRoleStatusesForClose contract)")
    }

    /// Corner: accepting an already-`.accepted` role fails with the SPECIFIC reason surfaced
    /// (not the generic "Could not accept" fallback) — confirms the arm relays `acceptRole`'s
    /// `lastErrorMessage` rather than masking it.
    func testManageRoleAccept_onAlreadyAcceptedRole_failsWithSpecificReason() async {
        _ = await pinManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[task.runs.count - 1].roleStatuses["r"] = .accepted
        }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "r", verb: .accept))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("already accepted"),
                      "the arm must surface acceptRole's specific reason, not a generic fallback")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["r"], .accepted)
    }

    /// Corner: `accept` on a hallucinated role id hits the EXISTENCE guard (before `acceptRole`'s
    /// status guard) and fails loudly, naming the bad id — confirms the accept verb is covered by
    /// the up-front role-resolution check, not only the status check.
    func testManageRoleAccept_unknownRole_failsWithExistenceGuard() async {
        _ = await pinManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "ghost", verb: .accept))
        XCTAssertFalse(r.ok, "a hallucinated role id must be rejected by the existence guard")
        XCTAssertTrue(r.message.contains("ghost"), "the failure must name the bad role id")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["r"], .needsAcceptance,
                       "the real role's status must be untouched")
    }

    // MARK: - manage_role finish_advisory (producing guard + non-chat)

    /// A non-chat advisory role (required artifacts, produces none) finishes without
    /// closing — the role goes `.done`, the task stays open for the engine to complete.
    func testManageRoleFinishAdvisory_onNonChatAdvisoryRole_finishesWithoutClosing() async {
        _ = await pinManager()
        guard let startupID = sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id else {
            return XCTFail("Startup team must be bootstrapped")
        }
        // A custom advisory role added to the (non-chat) startup team so completionType == .advisory.
        let advisory = TeamRoleDefinition(
            id: "advisor", name: "Advisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Engineering Notes"])
        )
        await sut.mutateWorkFolder { proj in
            if let i = proj.teams.firstIndex(where: { $0.id == startupID }) { proj.teams[i].addRole(advisory) }
        }
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "x", preferredTeamID: startupID, makeActive: false) else {
            return XCTFail("createTask failed")
        }
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "advisor", role: .custom(id: "advisor"), title: "Advisor", status: .running),
            ], roleStatuses: ["advisor": .working])]
        }

        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "advisor", verb: .finishAdvisory))

        XCTAssertTrue(r.ok, "finishing a non-chat advisory role must succeed")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["advisor"], .done)
        XCTAssertNil(sut.loadedTask(taskID)?.closedAt, "a non-chat finish must NOT close the task")
    }

    /// Builds a non-chat (Startup) task carrying a PRODUCING role whose id ("producer")
    /// matches the run's step/status, so `completionType(forRoleID:)` resolves it.
    private func makeTaskWithProducingRole() async -> Int? {
        guard let startupID = sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id else {
            XCTFail("Startup team must be bootstrapped"); return nil
        }
        let producer = TeamRoleDefinition(
            id: "producer", name: "Producer", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Out"]))
        await sut.mutateWorkFolder { proj in
            if let i = proj.teams.firstIndex(where: { $0.id == startupID }) { proj.teams[i].addRole(producer) }
        }
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "x", preferredTeamID: startupID, makeActive: false) else {
            XCTFail("createTask failed"); return nil
        }
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "producer", role: .custom(id: "producer"), title: "Producer", status: .running),
            ], roleStatuses: ["producer": .working], teamID: startupID)]
        }
        return taskID
    }

    /// finish_advisory on a PRODUCING role is rejected at the manager seam (force-finishing
    /// one strands the pipeline). The role status is left untouched.
    func testManageRoleFinishAdvisory_onProducingRole_failsWithoutMutating() async {
        _ = await pinManager()
        guard let taskID = await makeTaskWithProducingRole() else { return }
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "producer", verb: .finishAdvisory))
        XCTAssertFalse(r.ok, "finish_advisory on a producing role must be rejected")
        XCTAssertTrue(r.message.contains("producing role"), "the failure must name the reason")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses["producer"], .working,
                       "a rejected finish must leave the role status untouched")
    }

    /// The rejected finish_advisory message must be the FRESH producing-reject reason,
    /// not a stale `lastErrorMessage` echoed from an earlier unrelated failure.
    func testManageRoleFinishAdvisory_producingReject_isNotStaleBanner() async {
        _ = await pinManager()
        guard let taskID = await makeTaskWithProducingRole() else { return }
        sut.lastErrorMessage = "OLD UNRELATED BANNER"
        let r = await sut.performAutovisorAction(.manageRole(taskID: taskID, roleID: "producer", verb: .finishAdvisory))
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.message.contains("OLD UNRELATED BANNER"),
                       "the arm must return its own reason, not echo a stale lastErrorMessage")
        XCTAssertTrue(r.message.contains("producing role"))
    }

    /// Omitted `team_id` when the folder's active team is chat-mode must fail loudly
    /// (a chat task never terminates on its own), without creating a task.
    func testCreateManagedTask_omittedTeamID_activeTeamIsChatMode_failsWithoutCreating() async {
        _ = await pinManager()
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
        // The fresh work folder's active team (Coding Assistant) is already chat-mode.
        XCTAssertTrue(sut.snapshot?.workFolder.activeTeam?.isChatMode ?? false,
                      "precondition: default active team is chat-mode")
        let before = taskCount
        let r = await sut.performAutovisorAction(.createManagedTask(title: "T", brief: "B", teamID: nil))
        XCTAssertFalse(r.ok, "omitting team_id on a chat active team must be rejected")
        XCTAssertTrue(r.message.contains("chat team"), "the failure must explain why")
        XCTAssertEqual(taskCount, before, "no task may be created")
    }

    /// An EXPLICIT chat team_id IS accepted (mark, not filter — the manager can close it),
    /// distinct from the rejected omitted-team_id-on-chat-active-team case above.
    func testCreateManagedTask_explicitChatTeamID_isAccepted() async {
        _ = await pinManager()
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
        let chatTeam = Team(id: "explicit-chat", name: "Explicit Chat", roles: [
            TeamRoleDefinition(id: "supervisor", name: "Supervisor", prompt: "", toolIDs: [],
                               usePlanningPhase: false, dependencies: RoleDependencies(), systemRoleID: "supervisor"),
            TeamRoleDefinition(id: "a", name: "A", prompt: "", toolIDs: [],
                               usePlanningPhase: false, dependencies: RoleDependencies(requiredArtifacts: ["Ctx"])),
        ], artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
        XCTAssertTrue(chatTeam.isChatMode, "precondition: the target team is chat-mode")
        await sut.mutateWorkFolder { $0.teams.append(chatTeam) }
        let before = taskCount
        let r = await sut.performAutovisorAction(.createManagedTask(title: "T", brief: "B", teamID: "explicit-chat"))
        XCTAssertTrue(r.ok, "an explicit chat team_id must be accepted")
        XCTAssertEqual(taskCount, before + 1, "a task must be created")
        if let id = r.createdTaskID { sut.stopEngineForTask(id) }  // tidy the spawned run
    }

    func testWake_disabled_doesNotStamp() async {
        _ = await pinManager()  // feature stays disabled (we never call setAutovisorEnabled)
        XCTAssertNil(sut.autovisorLastWakeAt)
        await sut.wakeAutovisorForEvents()
        XCTAssertNil(sut.autovisorLastWakeAt, "a disabled manager never wakes")
    }

    /// Bug 1 end-to-end: a task that reaches the Review (`.needsSupervisorAcceptance`) state must
    /// wake the manager via `onTaskCompleted` (which now keys on Review, not `.done`).
    func testWake_reviewTask_stampsAndStarts() async {
        let mgrID = await enabledManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.status,
                       .needsSupervisorAcceptance, "task must present as Review in the in-memory index")

        XCTAssertNil(sut.autovisorLastWakeAt)
        await sut.wakeAutovisorForEvents()
        XCTAssertNotNil(sut.autovisorLastWakeAt,
                        "a task in Review must wake the manager (onTaskCompleted on .needsSupervisorAcceptance)")
        // The wake overwrites the seen-set with every current watchable id so `onTaskCreated`
        // can't re-fire for them next tick.
        XCTAssertTrue(sut.autovisorSeenTaskIDs.contains(taskID),
                      "a successful wake must record every watchable task as seen")

        sut.stopEngineForTask(mgrID)  // tidy the spawned manager run
    }

    /// No throttle: a FRESH condition wakes the manager immediately even right after a
    /// prior pass — the event-wake debounce (`minSecondsBetweenRuns`) was removed.
    func testWake_freshCondition_wakesWithNoThrottle() async {
        let mgrID = await enabledManager()
        guard await makeReviewStartupTask() != nil else { return }  // a wake-worthy (Review) task
        let priorPass = Date(timeIntervalSince1970: 1_000_000)
        sut.autovisorLastWakeAt = priorPass  // the old debounce would have suppressed this
        await sut.wakeAutovisorForEvents()
        XCTAssertNotEqual(sut.autovisorLastWakeAt, priorPass,
                          "a fresh condition wakes immediately regardless of a recent prior pass")
        sut.stopEngineForTask(mgrID)
    }

    /// D-4 form B, localized (DEBTS.md §5): `openWorkFolder` arms the live automation
    /// poll, whose tick body runs this same wake as the level-triggered backstop. A
    /// wall-clock minute boundary landing inside a wake test's window let that
    /// backstop deliver the staged condition FIRST; the test's own wake then
    /// correctly declined re-delivery (deliver-once), and
    /// `testWake_freshCondition_wakesWithNoThrottle`'s assert read the un-moved
    /// stamp — the flake, reproduced deterministically by this interleaving. The
    /// factory now neuters the tick (`TestOrchestrator.automationTickNever`); this
    /// test keeps the interleaving pinned as CORRECT deliver-once behavior — a
    /// condition the backstop already delivered is not delivered twice.
    func testWake_afterPollBackstopAlreadyDelivered_declinesRedelivery() async {
        let mgrID = await enabledManager()
        guard await makeReviewStartupTask() != nil else { return }
        await sut.wakeAutovisorForEvents(includeStuck: true)  // the poll tick's body
        XCTAssertNotNil(sut.autovisorLastWakeAt,
                        "anti-vacuity: the backstop must have delivered the condition and started a pass")
        let priorPass = Date(timeIntervalSince1970: 1_000_000)
        sut.autovisorLastWakeAt = priorPass
        await sut.wakeAutovisorForEvents()
        XCTAssertEqual(sut.autovisorLastWakeAt, priorPass,
                       "an explicit wake for the SAME condition must decline re-delivery (deliver-once)")
        sut.stopEngineForTask(mgrID)
    }

    /// Deliver-once: a condition already in the freshness baseline (reviewed at the
    /// manager's last pass start) is NOT re-delivered — the periodic recurrence review
    /// re-surfaces it instead, so a standing unresolved condition can't tight-loop.
    func testWake_alreadyReviewedCondition_doesNotReWake() async {
        _ = await enabledManager()
        guard let taskID = await makeReviewStartupTask() else { return }
        let priorPass = Date(timeIntervalSince1970: 1_000_000)
        sut.autovisorLastWakeAt = priorPass
        sut.autovisorLastPassAttentionKeys = [
            NTMSOrchestrator.AutovisorAttentionKey(taskID: taskID, trigger: .completed)
        ]
        await sut.wakeAutovisorForEvents()
        XCTAssertEqual(sut.autovisorLastWakeAt, priorPass,
                       "an already-reviewed condition is not re-delivered — no fresh pass (deliver-once)")
    }

    /// A manager parked on `wait_for_events` (`.needsSupervisorInput`) must still be
    /// superseded by an event wake: `startAutovisorPass` stops the parked engine
    /// first, because plain `startRun`'s re-entry guard bails on that state and
    /// would silently skip the pass (events get a FRESH pass; only human messages
    /// continue the parked conversation).
    func testWake_parkedManager_supersedesParkWithFreshPass() async {
        let mgrID = await enabledManager()
        guard await makeReviewStartupTask() != nil else { return }  // wake-worthy task
        sut.engineState[mgrID] = .needsSupervisorInput  // parked on wait_for_events
        let runsBefore = sut.loadedTask(mgrID)?.runs.count ?? 0

        await sut.wakeAutovisorForEvents()

        XCTAssertNotNil(sut.autovisorLastWakeAt, "the wake must fire despite the park")
        XCTAssertGreaterThan(sut.loadedTask(mgrID)?.runs.count ?? 0, runsBefore,
                             "a fresh run must supersede the parked one")
        sut.stopEngineForTask(mgrID)
    }

    /// `onTaskNeedsSupervisor` reads the LIVE engine state (not the derived summary status) —
    /// pin that the wrapper threads `taskEngineStates` into the predicate end-to-end.
    func testWake_needsSupervisorInput_viaEngineState_stampsAndStarts() async {
        let mgrID = await enabledManager()
        let taskID = await sut.createTask(title: "Q", supervisorTask: "x", makeActive: false)!
        sut.engineState[taskID] = .needsSupervisorInput  // simulate a task blocked on the Supervisor

        XCTAssertNil(sut.autovisorLastWakeAt)
        await sut.wakeAutovisorForEvents()
        XCTAssertNotNil(sut.autovisorLastWakeAt,
                        "a task whose engine is .needsSupervisorInput must wake the manager")
        sut.stopEngineForTask(mgrID)
    }

    /// A closed (`.done`) task must NOT wake the manager AND must not start a manager run —
    /// guards against the old `.done` every-window loop reappearing.
    func testWake_doneTask_doesNotStamp() async {
        let mgrID = await enabledManager()
        guard let startupID = sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id else {
            return XCTFail("Startup team must be bootstrapped")
        }
        let taskID = await sut.createTask(title: "Done X", supervisorTask: "x",
                                          preferredTeamID: startupID, makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .done])]
            task.closedAt = MonotonicClock.shared.now()  // closed → derived .done
        }
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.status, .done)

        await sut.wakeAutovisorForEvents()
        XCTAssertNil(sut.autovisorLastWakeAt, "a closed (.done) task must not wake the manager")
        XCTAssertNotEqual(sut.taskEngineStates[mgrID], .running, "no manager run should have started")
    }

    // MARK: - Stuck push (onTaskStuck via the poll's includeStuck path)

    /// Drives a top-level task to a plain `.running` state with a single running step,
    /// so the ONLY enabled activation trigger that can match is `onTaskStuck`.
    private func makeRunningTask() async -> Int? {
        guard let startupID = sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id else {
            XCTFail("Startup team must be bootstrapped"); return nil
        }
        guard let taskID = await sut.createTask(title: "Spin", supervisorTask: "x",
                                                preferredTeamID: startupID, makeActive: false) else {
            XCTFail("createTask failed"); return nil
        }
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .running)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .working])]
        }
        sut.engineState[taskID] = .running  // computeStuckTaskIDs only inspects .running engines
        return taskID
    }

    /// End-to-end push: a hung `.running` role (its step is silent past `stuckHangSeconds`)
    /// wakes the manager via the poll's `includeStuck` path. This is the user-facing
    /// "auto-wake on stuck" — the pure predicate is pinned separately; this proves
    /// `wakeAutovisorForEvents` actually COMPUTES stuck and acts on it.
    func testWake_stuckRunningTask_viaPoll_stampsAndStarts() async {
        let mgrID = await enabledManager()
        guard await makeRunningTask() != nil else { return }

        XCTAssertNil(sut.autovisorLastWakeAt)
        // `now` well past the hang threshold relative to the step's just-now createdAt;
        // no tokens/tool calls/messages → token silence → hang.
        let future = Date().addingTimeInterval(AutovisorConstants.stuckHangSeconds + 120)
        await sut.wakeAutovisorForEvents(now: future, includeStuck: true)
        XCTAssertNotNil(sut.autovisorLastWakeAt,
                        "a hung .running task must wake the manager via the poll's stuck check")
        sut.stopEngineForTask(mgrID)
    }

    /// Attribution: the SAME hung task with `onTaskStuck` OFF must NOT wake — proves the
    /// wake above came specifically from the stuck trigger, not an incidental one.
    func testWake_stuckRunningTask_onTaskStuckOff_doesNotStamp() async {
        let mgrID = await enabledManager()
        await sut.mutateWorkFolder { $0.settings.autovisorActivation.onTaskStuck = false }
        guard await makeRunningTask() != nil else { return }

        let future = Date().addingTimeInterval(AutovisorConstants.stuckHangSeconds + 120)
        await sut.wakeAutovisorForEvents(now: future, includeStuck: true)
        XCTAssertNil(sut.autovisorLastWakeAt, "onTaskStuck off → a hung running task must not wake")
        XCTAssertNotEqual(sut.taskEngineStates[mgrID], .running, "no manager run should have started")
    }

    /// A healthy (freshly-started) `.running` task must NOT wake — the stuck path is
    /// exercised (`includeStuck: true`) and correctly finds nothing.
    func testWake_healthyRunningTask_doesNotStamp() async {
        _ = await enabledManager()
        guard await makeRunningTask() != nil else { return }

        await sut.wakeAutovisorForEvents(now: Date(), includeStuck: true)  // step createdAt ≈ now → not hung
        XCTAssertNil(sut.autovisorLastWakeAt, "a healthy running task must not wake the manager")
    }

    /// `computeStuckTaskIDs` must thread the CONFIGURED `stuckHangSeconds`, not the
    /// constant. Raising it far above the default makes a task that WOULD be hung at
    /// the default no longer hung → no wake. Proves the configured value is consumed
    /// end-to-end (the pure evaluator's threading is unit-tested separately).
    func testWake_stuckRunningTask_respectsConfiguredHangThreshold() async {
        _ = await enabledManager()
        var tuning = AutovisorTuning.default
        tuning.stuckHangSeconds = 100_000
        await sut.updateAutovisorTuning(tuning)
        guard await makeRunningTask() != nil else { return }

        // `now` past the DEFAULT threshold, but well under the configured 100_000s.
        let future = Date().addingTimeInterval(AutovisorConstants.stuckHangSeconds + 120)
        await sut.wakeAutovisorForEvents(now: future, includeStuck: true)
        XCTAssertNil(sut.autovisorLastWakeAt,
                     "with a raised hang threshold the task is not yet hung → no wake")
    }

    /// Bug 2: when the manager creates a task it must pre-mark the new id as seen so its own
    /// creation can't trip the `onTaskCreated` self-wake.
    func testCreateManagedTask_seedsSeenSet() async {
        _ = await pinManager()
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
        // The default active team (Coding Assistant) is chat-mode; omitting team_id there
        // is now rejected. Point the active team at a pipeline team so the omit-form
        // succeeds and this test exercises what it's about (seen-set seeding).
        if let startupID = sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id {
            await sut.mutateWorkFolder { $0.setActiveTeam(startupID) }
        }
        let r = await sut.performAutovisorAction(.createManagedTask(title: "T", brief: "B", teamID: nil))
        XCTAssertTrue(r.ok, "creating a managed task on a pipeline active team should succeed")
        guard let id = r.createdTaskID else { return XCTFail("expected a created task id") }
        XCTAssertTrue(sut.autovisorSeenTaskIDs.contains(id),
                      "the manager must mark its own creation as seen (no onTaskCreated self-wake)")
        sut.stopEngineForTask(id)  // tidy the spawned worker run
    }

    // MARK: - Delete (sidebar context-menu)

    func testDeleteAutovisor_removesTask_clearsID_disablesFeature() async {
        let mgrID = await pinManager()
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
        XCTAssertEqual(sut.autovisorTaskID, mgrID)
        sut.rearmAutovisorAutoDisable()
        XCTAssertNotNil(sut.autovisorAutoDisableAt, "premise: sleep timer armed before delete")
        let before = taskCount

        await sut.deleteAutovisor()

        XCTAssertNil(sut.autovisorTaskID, "delete clears the pinned manager id")
        XCTAssertNil(sut.autovisorAutoDisableAt, "delete turns the feature off → deadline cleared")
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false,
                       "delete turns the feature off")
        XCTAssertEqual(taskCount, before - 1, "delete removes the manager task from the index")
        XCTAssertFalse(sut.snapshot?.tasksIndex.tasks.contains { $0.id == mgrID } ?? true,
                       "the manager task must be gone from the index")
    }

    func testDeleteAutovisor_noManager_isNoOp() async {
        await sut.openWorkFolder(tempDir)
        let before = taskCount
        await sut.deleteAutovisor()  // autovisorTaskID is nil
        XCTAssertEqual(taskCount, before, "deleting when no manager exists is a no-op")
    }

    // MARK: - Goal ↔ brief sync (GAP1)

    /// The manager's brief (rendered as "## Supervisor Goal") IS its goal — editing
    /// the goal must sync the manager task's `supervisorTask`.
    func testUpdateAutovisorGoal_syncsManagerBrief() async {
        let mgrID = await pinManager()
        await sut.ensureTaskLoaded(mgrID)

        await sut.updateAutovisorGoal("Ship the parser")

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorGoal, "Ship the parser")
        XCTAssertEqual(sut.loadedTask(mgrID)?.supervisorTask, "Ship the parser",
                       "editing the goal must sync the manager task's brief")
    }

    /// No manager pinned → only settings update, no crash (the `if let id` guard).
    func testUpdateAutovisorGoal_noManager_onlyUpdatesSettings() async {
        await sut.openWorkFolder(tempDir)
        await sut.updateAutovisorGoal("Some goal")
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorGoal, "Some goal")
    }

    // MARK: - Default seeding + brief sync (GAP5)

    /// Empty goal/memory get the defaults, and the brief is synced to the goal —
    /// this also migrates a manager whose brief still holds the old "oversee…" text.
    func testSeedDefaults_emptyFields_seedsAndMigratesBrief() async {
        let mgrID = await pinManager()  // pinManager creates the task with brief "oversee"
        await sut.ensureTaskLoaded(mgrID)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorGoal, "")

        await sut.seedAutovisorDefaultsAndSyncBrief()

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorGoal, AutovisorConstants.defaultGoal)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorMemory, AutovisorConstants.defaultMemory)
        XCTAssertEqual(sut.loadedTask(mgrID)?.supervisorTask, AutovisorConstants.defaultGoal,
                       "the brief must be migrated/synced to the (seeded) goal")
    }

    /// A real goal/memory already set is never clobbered by the seed pass.
    func testSeedDefaults_existingGoal_notClobbered() async {
        let mgrID = await pinManager()
        await sut.ensureTaskLoaded(mgrID)
        await sut.updateAutovisorGoal("Keep docs current")
        await sut.updateAutovisorMemory("Reviewed 3 tasks.")

        await sut.seedAutovisorDefaultsAndSyncBrief()

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorGoal, "Keep docs current")
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorMemory, "Reviewed 3 tasks.")
        XCTAssertEqual(sut.loadedTask(mgrID)?.supervisorTask, "Keep docs current")
    }

    // MARK: - Idle-park gate (sidebar pulse suppression)

    /// `autovisorIsIdleParked` requires BOTH the live engine state to be parked AND
    /// the step to carry the idle-park marker. Step data alone must not suppress the
    /// sidebar pulse — e.g. a restart-recovered park keeps the step flag while the
    /// engine isn't parked (the window `taskHasIdleParkStep`'s flag-not-status
    /// semantics deliberately leaves to this gate).
    func testAutovisorIsIdleParked_gatesOnEngineStateAndStepMarker() async {
        let mgrID = await pinManager()
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { task in
            let step = StepExecution(
                id: "autovisor", role: .custom(id: "autovisor"), title: "Autovisor",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: AutovisorConstants.idleParkQuestion)
            task.runs.append(Run(id: 0, steps: [step]))
        }

        XCTAssertFalse(sut.autovisorIsIdleParked,
                       "parked step data alone (no engine state) must not suppress the pulse")

        sut.engineState[mgrID] = .running
        XCTAssertFalse(sut.autovisorIsIdleParked,
                       "a running engine is never idle-parked, whatever the step says")

        sut.engineState[mgrID] = .needsSupervisorInput
        XCTAssertTrue(sut.autovisorIsIdleParked,
                      "live parked engine + idle-park marker on the step = idle")
    }

    /// A genuine escalation question (e.g. a `StepFlowControl` cap park) shares the
    /// `.needsSupervisorInput` engine state with the idle park — through the full
    /// gate it must NOT read as idle, so the sidebar keeps the attention pulse.
    func testAutovisorIsIdleParked_realQuestion_keepsAttention() async {
        let mgrID = await pinManager()
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { task in
            let step = StepExecution(
                id: "autovisor", role: .custom(id: "autovisor"), title: "Autovisor",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Task #3 failed twice — close it or restart with a new brief?")
            task.runs.append(Run(id: 0, steps: [step]))
        }
        sut.engineState[mgrID] = .needsSupervisorInput

        XCTAssertFalse(sut.autovisorIsIdleParked,
                       "a real question must keep the attention treatment")
    }

    /// No manager pinned → the gate is inert even if some OTHER task is parked on a
    /// supervisor question (the first guard keys strictly on `autovisorTaskID`).
    func testAutovisorIsIdleParked_noManagerPinned_isFalse() async {
        await sut.openWorkFolder(tempDir)
        let otherID = await sut.createTask(title: "Real", supervisorTask: "x", makeActive: false)!
        sut.engineState[otherID] = .needsSupervisorInput

        XCTAssertFalse(sut.autovisorIsIdleParked,
                       "without a pinned manager there is nothing to be idle-parked")
    }

    /// Engine parked but the manager task NOT in memory → the documented fallback
    /// is `false` (keep the pulse). Structurally unreachable today (a live parked
    /// engine implies a loaded task), so this pins the DIRECTION of the degradation
    /// in case a future eviction/seeding change ever opens the window.
    func testAutovisorIsIdleParked_taskNotLoaded_keepsAttention() async {
        let mgrID = await pinManager()
        // Premise: `createTask(makeActive: false)` leaves the task out of memory —
        // if this ever changes, the test must be rethought, not silently pass.
        XCTAssertNil(sut.loadedTask(mgrID), "premise: manager task not loaded")
        sut.engineState[mgrID] = .needsSupervisorInput

        XCTAssertFalse(sut.autovisorIsIdleParked,
                       "unloaded task must fall back to keeping the pulse, not suppressing it")
    }

    // MARK: - Auto-off sleep timer

    func testRearm_enabledWithTimerOn_armsFromNow() async {
        _ = await enabledManager()  // the sleep timer is ON by default
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        sut.rearmAutovisorAutoDisable(now: t0)
        XCTAssertEqual(sut.autovisorAutoDisableAt,
                       t0.addingTimeInterval(AutovisorConstants.defaultAutoDisableAfterSeconds),
                       "deadline = now + configured duration, exactly")
    }

    func testRearm_featureOffOrTimerOff_clears() async {
        _ = await pinManager()  // feature OFF
        sut.autovisorAutoDisableAt = Date()
        sut.rearmAutovisorAutoDisable()
        XCTAssertNil(sut.autovisorAutoDisableAt, "feature off → cleared")

        await sut.mutateWorkFolder {
            $0.settings.autovisorEnabled = true
            $0.settings.autovisorActivation.autoDisableEnabled = false
        }
        sut.autovisorAutoDisableAt = Date()
        sut.rearmAutovisorAutoDisable()
        XCTAssertNil(sut.autovisorAutoDisableAt, "timer toggle off → cleared")
    }

    func testSetAutovisorEnabled_armsOnEnable_clearsOnDisable() async {
        let mgrID = await pinManager()

        await sut.setAutovisorEnabled(true)  // spawns the open-time pass — tidied below
        let deadline = sut.autovisorAutoDisableAt
        sut.stopEngineForTask(mgrID)
        guard let deadline else {
            return XCTFail("enabling the Autovisor must arm the sleep timer")
        }
        XCTAssertEqual(deadline.timeIntervalSinceNow,
                       AutovisorConstants.defaultAutoDisableAfterSeconds, accuracy: 5)

        await sut.setAutovisorEnabled(false)
        XCTAssertNil(sut.autovisorAutoDisableAt, "disabling clears the deadline")
    }

    func testUpdateActivation_unrelatedFieldChange_doesNotReArm() async {
        _ = await enabledManager()
        // Future sentinel — see testWake_doesNotReArmAutoOffDeadline.
        sut.rearmAutovisorAutoDisable(now: Date(timeIntervalSince1970: 4_000_000_000))
        let sentinel = sut.autovisorAutoDisableAt

        var act = sut.snapshot!.workFolder.settings.autovisorActivation
        act.onTaskFailed.toggle()
        await sut.updateAutovisorActivation(act)

        XCTAssertEqual(sut.autovisorAutoDisableAt, sentinel,
                       "flipping an unrelated wake trigger must not reset a running timer")
    }

    func testUpdateActivation_durationChange_reArmsFromNow() async {
        _ = await enabledManager()
        // Future sentinel — see testWake_doesNotReArmAutoOffDeadline.
        sut.rearmAutovisorAutoDisable(now: Date(timeIntervalSince1970: 4_000_000_000))

        var act = sut.snapshot!.workFolder.settings.autovisorActivation
        act.autoDisableAfterSeconds = 7200
        await sut.updateAutovisorActivation(act)
        guard let deadline = sut.autovisorAutoDisableAt else {
            return XCTFail("a genuine duration change must re-arm the timer")
        }
        XCTAssertEqual(deadline.timeIntervalSinceNow, 7200, accuracy: 5,
                       "re-armed from now with the new duration")

        act.autoDisableEnabled = false
        await sut.updateAutovisorActivation(act)
        XCTAssertNil(sut.autovisorAutoDisableAt, "switching the timer off clears the deadline")
    }

    func testEvaluateAutoDisable_beforeDeadline_noop() async {
        _ = await enabledManager()
        let infoBefore = sut.lastInfoMessage
        let deadline = Date().addingTimeInterval(3600)
        sut.autovisorAutoDisableAt = deadline

        await sut.evaluateAutovisorAutoDisable(now: deadline.addingTimeInterval(-1))

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, true,
                       "not yet expired → stays on")
        XCTAssertEqual(sut.autovisorAutoDisableAt, deadline, "deadline intact before expiry")
        XCTAssertEqual(sut.lastInfoMessage, infoBefore, "no banner before expiry")
    }

    func testEvaluateAutoDisable_atDeadline_disablesAndAnnounces() async {
        let mgrID = await enabledManager()
        await sut.ensureTaskLoaded(mgrID)
        await sut.setTaskRecurrence(
            taskID: mgrID,
            recurrence: TaskRecurrence(rule: .interval(seconds: 600), isEnabled: true)
        )
        let deadline = Date()
        sut.autovisorAutoDisableAt = deadline

        await sut.evaluateAutovisorAutoDisable(now: deadline)  // boundary: `>=` fires

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false,
                       "expiry disables the feature exactly like the power toggle")
        XCTAssertEqual(sut.loadedTask(mgrID)?.recurrence?.isEnabled, false,
                       "the manager's review recurrence stops firing")
        XCTAssertNil(sut.autovisorAutoDisableAt, "deadline cleared")
        XCTAssertTrue(sut.lastInfoMessage?.contains("Autovisor") ?? false,
                      "info banner announces the auto-off")
    }

    func testEvaluateAutoDisable_unarmed_noop() async {
        _ = await enabledManager()
        let infoBefore = sut.lastInfoMessage

        await sut.evaluateAutovisorAutoDisable(now: .distantFuture)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, true,
                       "no armed deadline → nothing to expire")
        XCTAssertEqual(sut.lastInfoMessage, infoBefore)
    }

    func testEvaluateAutoDisable_staleDeadlineWhileDisabled_selfHealsSilently() async {
        _ = await pinManager()  // feature OFF
        let infoBefore = sut.lastInfoMessage
        sut.autovisorAutoDisableAt = Date(timeIntervalSince1970: 1)  // long expired

        await sut.evaluateAutovisorAutoDisable()

        XCTAssertNil(sut.autovisorAutoDisableAt, "stale deadline cleared")
        XCTAssertEqual(sut.lastInfoMessage, infoBefore, "self-heal is silent")
    }

    /// The ONLY fail-unsafe regression direction in the feature: if activity
    /// (event wakes, "Run now", recurrence fires) ever re-armed the countdown,
    /// the sleep timer would silently become an inactivity timer and never fire
    /// in exactly the busy autonomous folders it exists to bound. The countdown
    /// runs from ENABLE, not from activity.
    func testWake_doesNotReArmAutoOffDeadline() async {
        let mgrID = await enabledManager()
        guard await makeReviewStartupTask() != nil else { return }  // wake-worthy task
        // FUTURE sentinel: an expired deadline could be disabled+cleared by a real
        // minute-boundary scheduler tick landing mid-test (rare but flaky).
        let sentinel = Date(timeIntervalSince1970: 4_000_000_000)
        sut.rearmAutovisorAutoDisable(now: sentinel)
        let armed = sut.autovisorAutoDisableAt

        await sut.wakeAutovisorForEvents()  // fires a real review pass

        XCTAssertNotNil(sut.autovisorLastWakeAt, "premise: the wake actually fired")
        XCTAssertEqual(sut.autovisorAutoDisableAt, armed,
                       "a wake-driven pass must not restart the sleep-timer countdown")
        sut.stopEngineForTask(mgrID)
    }

    /// When `openOrCreateWorkFolder` throws, the late re-arm never runs — only the
    /// pre-loop clear at the top of `openWorkFolder` drops the previous folder's
    /// deadline. Without it, a stale (possibly expired) deadline would linger with
    /// the poll loop stopped, and the Settings caption would show a ghost off-time.
    func testOpenWorkFolder_failedOpen_stillClearsStaleDeadline() async {
        _ = await enabledManager()
        sut.rearmAutovisorAutoDisable()
        XCTAssertNotNil(sut.autovisorAutoDisableAt, "premise: armed before the failed open")

        let fileURL = tempDir.appendingPathComponent("not-a-folder.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("x".utf8))
        await sut.openWorkFolder(fileURL)  // .nanoteams can't be created under a file → throws

        XCTAssertNil(sut.autovisorAutoDisableAt,
                     "the top-of-open clear must run even when the open throws")
    }

    /// Zombie guard: `setAutovisorEnabled(false)` writes settings.json AND the
    /// manager's task.json (recurrence off) — a failed second write leaves
    /// "recurrence enabled + feature off" on disk, which nothing else reconciles
    /// after a relaunch. `fireRecurrence` must skip the fire AND durably disable
    /// the orphaned recurrence instead of running an OFF Autovisor on schedule.
    func testEvaluateDueRecurrences_managerWhileDisabled_selfHealsInsteadOfFiring() async {
        let mgrID = await pinManager()  // feature OFF
        await sut.ensureTaskLoaded(mgrID)
        await sut.setTaskRecurrence(
            taskID: mgrID,
            recurrence: TaskRecurrence(rule: .interval(seconds: 60), isEnabled: true)
        )
        let runsBefore = sut.loadedTask(mgrID)?.runs.count ?? 0

        await sut.evaluateDueRecurrences(now: Date().addingTimeInterval(3600))  // slot long due

        // The gate evicts the (background, non-running) manager after the heal —
        // re-load and assert against the PERSISTED state, which is the point:
        // the heal must be durable, not in-memory only.
        await sut.ensureTaskLoaded(mgrID)
        XCTAssertEqual(sut.loadedTask(mgrID)?.recurrence?.isEnabled, false,
                       "the orphaned recurrence must be durably disabled, not fired")
        XCTAssertEqual(sut.loadedTask(mgrID)?.runs.count ?? -1, runsBefore,
                       "no review pass may start while the feature is off")
        XCTAssertNotEqual(sut.taskEngineStates[mgrID], .running)
    }

    /// The deadline is in-memory by design: every folder open re-arms a fresh
    /// countdown (feature on) or clears a stale one (feature off) — the
    /// "timer restarts on relaunch" semantics.
    func testOpenWorkFolder_reArmsFreshPerLaunchSemantics() async {
        let mgrID = await enabledManager()
        sut.autovisorAutoDisableAt = Date(timeIntervalSince1970: 2_000_000)  // stale sentinel

        await sut.openWorkFolder(tempDir)  // spawns the open-time pass — tidied below
        let deadline = sut.autovisorAutoDisableAt
        sut.stopEngineForTask(mgrID)
        guard let deadline else {
            return XCTFail("reopen with feature+timer on must re-arm")
        }
        XCTAssertEqual(deadline.timeIntervalSinceNow,
                       AutovisorConstants.defaultAutoDisableAfterSeconds, accuracy: 10,
                       "fresh countdown from the reopen, not the stale sentinel")

        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = false }
        sut.autovisorAutoDisableAt = Date()
        await sut.openWorkFolder(tempDir)
        XCTAssertNil(sut.autovisorAutoDisableAt,
                     "reopen with the feature off clears any stale deadline")
    }
}
