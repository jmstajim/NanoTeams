import XCTest

@testable import NanoTeams

/// The reported bug: the manager reviews a task at Review, calls
/// `manage_role request_changes`, the role revises and submits a NEW artifact — and
/// the manager never wakes to look at it.
///
/// `AutovisorAttentionKey` is `(taskID, trigger)`, so it names the CONDITION, not the
/// occurrence (CLAUDE.md #74). The deliver-once baseline recorded `(X, .completed)`
/// when X first reached Review; the change request took X out of Review, and nothing
/// retired the key — so X's RETURN to Review read as already-delivered and
/// `hasFreshCondition` swallowed it. The per-minute poll evaluates the same gate, so
/// it could not rescue it either.
///
/// The fix records the retirement as POSITIVE EVIDENCE at the moment the level clears
/// (#92), on `upsertTaskSummary` — the one way an in-memory index row is written, and
/// the one instant at which the previous derived status is still readable. These pins
/// are deliberately about the SEAM, not the wake: `wakeAutovisorForEvents`' prune
/// cannot retire a `.completed` key at all (it serves `.levelSample` triggers only), so
/// deleting the seam hook is the RED mutation for every test here and no neighbouring
/// mechanism can keep them green.
///
/// No manager is configured in this suite on purpose. The hook schedules a wake, and a
/// wake with no `autovisorTaskID` returns at its entry guard — so what these tests
/// observe is the retirement alone, with no pass, no prune and no timing to depend on.
@MainActor
final class AutovisorReviewRetirementTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func key(
        _ taskID: Int, _ trigger: NTMSOrchestrator.AutovisorAttentionTrigger
    ) -> NTMSOrchestrator.AutovisorAttentionKey {
        NTMSOrchestrator.AutovisorAttentionKey(taskID: taskID, trigger: trigger)
    }

    private func startupTeamID() -> NTMSID {
        sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id ?? "missing"
    }

    private func indexStatus(_ taskID: Int) -> TaskStatus? {
        sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.status
    }

    /// A Startup task whose producing role finished and awaits acceptance — the shape
    /// that derives `.needsSupervisorAcceptance` ("Review") in the index.
    private func makeReviewTask(_ title: String) async -> Int {
        let taskID = await sut.createTask(title: title, supervisorTask: "do it",
                                          preferredTeamID: startupTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .needsAcceptance])]
        }
        return taskID
    }

    /// A Startup task whose role failed — derives `.failed`.
    private func makeFailedTask(_ title: String) async -> Int {
        let taskID = await sut.createTask(title: title, supervisorTask: "do it",
                                          preferredTeamID: startupTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .failed)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .failed])]
        }
        return taskID
    }

    // MARK: - the retirement itself

    func testLeavingReview_retiresCompletedKey_forThatTaskAndTriggerOnly() async {
        // The change-request half of the repro, at the seam: X leaves Review and its
        // `.completed` key must go, while a key for a DIFFERENT trigger on the same task
        // and a key for the SAME trigger on a different task both survive. Those two
        // siblings are what pin the retirement narrow on both axes; without them a hook
        // that cleared the whole set would pass.
        await sut.openWorkFolder(tempDir)
        let x = await makeReviewTask("X")
        let y = await makeReviewTask("Y")
        XCTAssertEqual(indexStatus(x), .needsSupervisorAcceptance, "premise: X starts at Review")
        XCTAssertEqual(indexStatus(y), .needsSupervisorAcceptance, "premise: Y starts at Review")
        sut.autovisorLastPassAttentionKeys = [key(x, .completed), key(x, .failed), key(y, .completed)]

        // What `requestRevision` writes: the role goes to `.revisionRequested`, which is
        // neither `isComplete` nor `.needsAcceptance`, so the task derives `.running`.
        await sut.mutateTask(taskID: x) { $0.runs[0].roleStatuses["r"] = .revisionRequested }

        XCTAssertEqual(indexStatus(x), .running,
                       "premise: the change request must take X out of Review, or the seam never fires")
        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(key(x, .completed)),
                       "X's spent Review key must be retired the moment the level clears — "
                           + "keeping it is what swallowed the wake for the revised artifact")
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(key(x, .failed)),
                      "retirement is per TRIGGER: `.failed` on the same task must survive")
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(key(y, .completed)),
                      "retirement is per TASK: Y is still at Review and keeps its key")
    }

    func testStayingAtReview_keepsCompletedKey() async {
        // Deliver-once still holds while the condition KEEPS matching: an ordinary write
        // that leaves the derived status untouched must not retire anything. Without the
        // `previous != current` half of the guard, every `mutateTask` on a task sitting in
        // Review would retire its key and the manager would re-pass on each one.
        await sut.openWorkFolder(tempDir)
        let x = await makeReviewTask("X")
        XCTAssertEqual(indexStatus(x), .needsSupervisorAcceptance, "premise: X starts at Review")
        sut.autovisorLastPassAttentionKeys = [key(x, .completed)]

        await sut.mutateTask(taskID: x) { task in
            task.runs[0].steps[0].messages.append(
                StepMessage(role: .supervisor, content: "a note that changes no status"))
        }

        XCTAssertEqual(indexStatus(x), .needsSupervisorAcceptance,
                       "premise: the write must leave X at Review, or this pins nothing")
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(key(x, .completed)),
                      "a standing condition keeps its key — deliver-once is unchanged")
    }

    func testLeavingFailed_doesNotRetireFailedKey() async {
        // The #119 boundary, and the reason the retirement is derived from a per-trigger
        // property rather than applied to every status level: `.failed`'s remedy is a
        // RESTART — an attempt, not a consumption. A role that fails again immediately
        // would wake a fresh pass per failure latency until auto-off.
        await sut.openWorkFolder(tempDir)
        let x = await makeFailedTask("X")
        XCTAssertEqual(indexStatus(x), .failed, "premise: X starts failed")
        sut.autovisorLastPassAttentionKeys = [key(x, .failed)]

        // The manager restarted the failing role: the `.failed` level goes quiet.
        await sut.mutateTask(taskID: x) { task in
            task.runs[0].steps[0].status = .running
            task.runs[0].roleStatuses["r"] = .working
        }

        XCTAssertEqual(indexStatus(x), .running, "premise: the restart must clear the `.failed` level")
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(key(x, .failed)),
                      "a cleared `.failed` key must SURVIVE — retiring it is the restart-loop regression")
    }

    func testRetirement_alsoClearsTheMidReviewInjectionKey() async {
        // Same defect, second set. `autovisorNotifiedAttentionKeys` is pruned by the same
        // level SAMPLE, so with the manager mid-review and no window mounted a
        // Review→running→Review round trip completing between two polls left the key in
        // place and `fresh` empty — nothing injected into the live conversation either.
        await sut.openWorkFolder(tempDir)
        let x = await makeReviewTask("X")
        sut.autovisorNotifiedAttentionKeys = [key(x, .completed), key(x, .failed)]

        await sut.mutateTask(taskID: x) { $0.runs[0].roleStatuses["r"] = .revisionRequested }

        XCTAssertEqual(indexStatus(x), .running, "premise: X left Review")
        XCTAssertFalse(sut.autovisorNotifiedAttentionKeys.contains(key(x, .completed)),
                       "the injection set is retired on the same edge, for the same reason")
        XCTAssertTrue(sut.autovisorNotifiedAttentionKeys.contains(key(x, .failed)),
                      "and with the same per-trigger narrowness")
    }

    // MARK: - the mid-pipeline acceptance gate

    /// A Startup-style task STALLED at a mid-pipeline gate: role `a` finished and awaits
    /// acceptance, role `b` has not started. The engine's run loop transitions to
    /// `.needsAcceptance` and returns, but `b` is `.ready`, so the task derives `.running`.
    private func makeGatedTask(_ title: String) async -> Int {
        let taskID = await sut.createTask(title: title, supervisorTask: "do it",
                                          preferredTeamID: startupTeamID(), makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .done)
            task.runs = [Run(id: 0, steps: [step],
                             roleStatuses: ["a": .needsAcceptance, "b": .ready])]
        }
        return taskID
    }

    func testGatedTask_derivesRunning_yetCarriesTheDurableFact() async {
        // The premise the whole trigger rests on, asserted on a production-shaped task
        // rather than a hand-built row: the index says "Working" while a role is parked and
        // nothing downstream can start. That is why the fact had to be a SECOND field and
        // not a different status.
        await sut.openWorkFolder(tempDir)
        let x = await makeGatedTask("X")
        let row = sut.snapshot?.tasksIndex.tasks.first { $0.id == x }
        XCTAssertEqual(row?.status, .running,
                       "a mid-pipeline gate leaves the task deriving Working — no status "
                           + "trigger can see it")
        XCTAssertEqual(row?.hasRolesAwaitingAcceptance, true,
                       "…but the durable fact records the gate, which is what the wake reads")
    }

    func testAcceptingTheGatedRole_retiresTheGateKey_thoughTheStatusNeverMoves() async {
        // The #74 pin for consecutive gates: role `a`'s gate is baselined, the manager
        // accepts it, and later role `b` will gate too — sharing the key `(X,
        // .acceptanceGate)`. Without retirement the second gate reads as already-delivered
        // and the pipeline stalls again, silently.
        //
        // The discriminating detail is that the task derives `.running` BOTH before and
        // after: only a retirement that compares the row's LEVEL — not its status — can see
        // this clear at all. RED: compare statuses instead of `levelHolds`.
        await sut.openWorkFolder(tempDir)
        let x = await makeGatedTask("X")
        sut.autovisorLastPassAttentionKeys = [key(x, .acceptanceGate), key(x, .completed)]

        await sut.mutateTask(taskID: x) { $0.runs[0].roleStatuses["a"] = .accepted }

        XCTAssertEqual(indexStatus(x), .running,
                       "premise: the status does not move — the gate fact is the only thing "
                           + "that changed")
        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(key(x, .acceptanceGate)),
                       "a consumed acceptance gate must be retired, or the NEXT role to gate "
                           + "on this task is judged already-delivered")
        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.contains(key(x, .completed)),
                      "and only that trigger — the task never was at Review")
    }

    // MARK: - both `mutateTask` branches reach the seam

    func testRetirementFires_onBothMutateTaskBranches() async {
        // `upsertTaskSummary` is the seam precisely because BOTH branches route through it:
        // the active task via `applyTaskUpdate`, background tasks via
        // `refreshBackgroundTaskInMemory`. Moving the hook up into `applyTaskUpdate` is the
        // RED mutation, and it can only be caught if this test provably exercises each
        // branch — hence the `activeTaskID` premises.
        await sut.openWorkFolder(tempDir)
        let background = await makeReviewTask("Background")
        let active = await makeReviewTask("Active")
        sut.autovisorLastPassAttentionKeys = [key(background, .completed), key(active, .completed)]

        XCTAssertNotEqual(sut.activeTaskID, background,
                          "premise: this half must run the BACKGROUND branch")
        await sut.mutateTask(taskID: background) { $0.runs[0].roleStatuses["r"] = .revisionRequested }
        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(key(background, .completed)),
                       "the background branch reaches the seam through refreshBackgroundTaskInMemory")

        await sut.switchTask(to: active)
        XCTAssertEqual(sut.activeTaskID, active,
                       "premise: this half must run the ACTIVE branch — `switchTask` goes through "
                           + "`apply(_:)` → `replaceAll`, which bypasses the seam, so without this "
                           + "assertion the test could run the background branch twice")
        await sut.mutateTask(taskID: active) { $0.runs[0].roleStatuses["r"] = .revisionRequested }
        XCTAssertFalse(sut.autovisorLastPassAttentionKeys.contains(key(active, .completed)),
                       "the active branch reaches the seam through applyTaskUpdate")
    }

    // MARK: - folder scope

    func testDiscardWorkFolderState_clearsAutovisorFolderScopedKeys() async {
        // Every id in these four sets is folder-local, so carrying them across a folder
        // switch lets folder A's task 3 answer for folder B's — the same silent-no-wake
        // symptom, and not something the prune can fix (B's task 3 sitting legitimately at
        // Review is in `stillMatchingKeys`). The guard for this class was already present
        // in this very function for `taskFacts` and the QuickCapture queue (CLAUDE.md #51).
        await sut.openWorkFolder(tempDir)
        sut.autovisorLastPassAttentionKeys = [key(3, .completed)]
        sut.autovisorNotifiedAttentionKeys = [key(3, .failed)]
        sut.autovisorLoopParkRedelivered = [key(3, .needsSupervisor)]
        sut.autovisorSeenTaskIDs = [3]

        sut.discardWorkFolderState()

        XCTAssertTrue(sut.autovisorLastPassAttentionKeys.isEmpty, "deliver-once baseline is folder-scoped")
        XCTAssertTrue(sut.autovisorNotifiedAttentionKeys.isEmpty, "injection dedup set is folder-scoped")
        XCTAssertTrue(sut.autovisorLoopParkRedelivered.isEmpty, "loop-park ledger is folder-scoped")
        XCTAssertTrue(sut.autovisorSeenTaskIDs.isEmpty, "the seen set is folder-scoped")
    }
}
