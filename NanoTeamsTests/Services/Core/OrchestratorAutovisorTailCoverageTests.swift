import XCTest

@testable import NanoTeams

// MARK: - Autovisor action failure detail (the `lastErrorMessage` snapshot defect)

/// `NTMSOrchestrator+AutovisorActions` — the arms that report WHY an action failed.
///
/// Two of them (`answer_task_question`, `create_managed_task`) were reading the
/// single-shot `lastErrorMessage` slot; the third (`finish_advisory`) is the honest
/// outcome guard that keeps a finish that did not persist from being reported as done.
///
/// The slot is consumed by the error banner on any render, and a REPEATED identical
/// error never differs from a snapshot of it. The file's own `reportingError` helper
/// documents this at length and keys on `errorSurfaceCount` / `lastSurfacedError`
/// instead; these two arms had not been converted, so each discarded the exact
/// detail it exists to deliver:
///
///  - `answer_task_question` replaced the specific "this question is no longer
///    active" reason with a generic string on the SECOND identical failure — i.e.
///    precisely when the manager is retrying and most needs to be told to stop.
///  - `create_managed_task` read the slot with no freshness check at all, so an
///    UNRELATED banner left over from an earlier failure was reported as the reason
///    creation failed (`createTask`'s no-work-folder exit sets nothing of its own).
///
/// The failures are staged by clearing `workFolderURL`, which makes `mutateTask`
/// (and `createTask`) bail before their closure runs — the same "the write did not
/// land" shape the §7 verifies elsewhere in the orchestrator exist to catch.
@MainActor
final class BOrchAutovisorActionFailureDetailTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// A distinctive fragment of the text `answerSupervisorQuestion` sets when the
    /// answer could not be applied to a real pending step — never a substring the
    /// generic fallback also contains. Computed, not a stored default (CLAUDE.md
    /// §Testing Conventions bans stored properties with defaults at class level).
    private var notActiveFragment: String { "no longer active" }
    private var genericAnswerFailure: String { "Failed to deliver answer" }

    private func openAndSeedWaitingTask() async -> Int? {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(
            title: "Worker", supervisorTask: "do x", makeActive: false
        ) else {
            XCTFail("createTask failed"); return nil
        }
        await sut.ensureTaskLoaded(id)
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "swe", role: .softwareEngineer, title: "Engineer",
                    status: .needsSupervisorInput,
                    needsSupervisorInput: true,
                    supervisorQuestion: "Which database?")],
                roleStatuses: ["swe": .working])]
        }
        return id
    }

    /// Baseline: the FIRST failure surfaces the specific reason. Holds pre- and
    /// post-fix, and exists so the repeat test below cannot pass vacuously (it
    /// proves the specific reason is what the arm produces when it works at all).
    ///
    /// RED: delete the `guard applied else { lastErrorMessage = "This question is no
    /// longer active…" }` arm in `answerSupervisorQuestion` -> there is no specific
    /// reason left to surface and the `notActiveFragment` assertion fails.
    func testAnswerTaskQuestion_firstFailure_surfacesTheSpecificReason() async {
        guard let id = await openAndSeedWaitingTask() else { return }
        sut.workFolderURL = nil   // the answer mutation can no longer land

        let r = await sut.performAutovisorAction(
            .answerTaskQuestion(taskID: id, answer: "Use SQLite."))

        XCTAssertFalse(r.ok, "an answer that never reached the step must not report success")
        XCTAssertTrue(r.message.contains(notActiveFragment),
                      "the manager must be told WHY delivery failed; got \(r.message)")
        XCTAssertNil(sut.loadedTask(id)?.runs.last?.steps.first?.supervisorAnswer,
                     "premise: the answer really did not land")
    }

    /// A CONVENTION pin on a synthetic state, not a reachable-bug regression pin —
    /// an adversarial review of this wave could not demonstrate production reaching it,
    /// and the honest reading is that it does not: `workFolderURL` has exactly one
    /// production writer (`openWorkFolder`), nothing ever assigns it nil, and the
    /// restart route this arm's own `needsSupervisorInput` guard intercepts first.
    ///
    /// The shape is still worth pinning, because it is the shape CLAUDE.md §Error
    /// Handling bans outright and the file's own `reportingError` helper documents:
    /// the manager's natural response to "could not deliver" is to try again, which
    /// produces the SAME error text — and a snapshot of the `lastErrorMessage` slot
    /// cannot tell "set again" from "never set". Where that IS reachable (the sibling
    /// `reportingError`, which suspends in `reconcileChatModelResidency` after the
    /// write) it was a real defect; here it is hardening kept for uniformity.
    ///
    /// RED: revert the arm to `let before = lastErrorMessage` /
    /// `(lastErrorMessage != before ? lastErrorMessage : nil)` -> the second call's
    /// message becomes "Failed to deliver answer to task #N." and BOTH assertions
    /// on `second.message` fail.
    func testAnswerTaskQuestion_repeatedIdenticalFailure_stillSurfacesTheSpecificReason() async {
        guard let id = await openAndSeedWaitingTask() else { return }
        sut.workFolderURL = nil

        let first = await sut.performAutovisorAction(
            .answerTaskQuestion(taskID: id, answer: "Use SQLite."))
        XCTAssertFalse(first.ok)
        XCTAssertTrue(first.message.contains(notActiveFragment),
                      "premise: the first attempt produced the specific reason")
        // The banner was NOT consumed in between — this is the pure
        // "same error twice" case, which is the one a slot snapshot cannot see.
        XCTAssertEqual(sut.lastErrorMessage, sut.lastSurfacedError,
                       "premise: nothing rendered, so the slot still holds the first failure")

        let second = await sut.performAutovisorAction(
            .answerTaskQuestion(taskID: id, answer: "Use SQLite."))

        XCTAssertFalse(second.ok)
        XCTAssertTrue(second.message.contains(notActiveFragment),
                      "a repeated identical failure must still name the reason; got \(second.message)")
        XCTAssertFalse(second.message.contains(genericAnswerFailure),
                       "the generic fallback must not replace a reason this call really surfaced")
    }

    // NOTE — the mirror failure direction (the banner is consumed by a render DURING
    // the `await`, so the slot reads back nil and the specific reason is replaced by
    // the generic string) is deliberately NOT pinned here. Staging it needs a SwiftUI
    // render to interleave inside `answerSupervisorQuestion`, and every cheap
    // approximation (clearing the slot before the call) is answered identically by
    // the pre- and post-fix code — i.e. it would be a test with no mutation that reds
    // it. The counter-keyed arm covers it by construction.

    /// Also a CONVENTION pin on a synthetic state (same review, same reason: the only
    /// nil-returning `createTask` exit that sets nothing is its no-work-folder guard,
    /// and production never nils `workFolderURL`). Kept because the SHAPE here is the
    /// worse of the two — this arm read the slot with no freshness check at all, so it
    /// is the one that can attribute a foreign banner rather than merely lose detail.
    ///
    /// `create_managed_task`: the creation failure arm read the slot with NO
    /// freshness check, so a banner belonging to something else entirely was
    /// reported as the reason the task could not be created. `createTask`'s
    /// no-work-folder exit returns nil without setting anything, which is exactly
    /// the shape that exposed it.
    ///
    /// RED: revert to `return .failure(lastErrorMessage ?? "Failed to create task.")`
    /// -> the message becomes the stale banner and both message assertions fail.
    func testCreateManagedTask_creationFailure_doesNotAttributeAStaleBanner() async {
        await sut.openWorkFolder(tempDir)
        guard let teamID = sut.snapshot?.workFolder.teams
            .first(where: { !$0.isHiddenFromPickers })?.id else {
            return XCTFail("premise: the folder bootstraps at least one selectable team")
        }
        let stale = "an earlier, unrelated failure"
        sut.lastErrorMessage = stale
        sut.workFolderURL = nil   // createTask now returns nil WITHOUT setting an error

        let r = await sut.performAutovisorAction(
            .createManagedTask(title: "Harden the parser", brief: "...", teamID: teamID))

        XCTAssertFalse(r.ok, "creation could not have succeeded with no work folder")
        XCTAssertFalse(r.message.contains(stale),
                       "a banner this call did not raise must never be reported as its cause; got \(r.message)")
        XCTAssertTrue(r.message.contains("Failed to create task"),
                      "with no error of its own the arm must fall back to the generic string; got \(r.message)")
        XCTAssertNil(r.createdTaskID, "a failed creation must not report a task id")
    }

    /// `finish_advisory`'s outcome is decided by `finishAdvisoryRoleAwaiting`, whose
    /// whole reason for returning a `Bool` (rather than being the fire-and-forget
    /// `finishAdvisoryRole` the UI uses) is that the manager must not be told a role
    /// finished when it did not. Past that guard the method goes on to CLOSE a
    /// chat-mode task, so a false success there is not cosmetic — it retires a role
    /// and a task that are both still live.
    ///
    /// RED: replace `guard await finishAdvisoryRoleAwaiting(...) else { ... }` with a
    /// discarded call -> the method proceeds and returns `.success("Finished advisory
    /// role …")`, so `r.ok` becomes true and the first two assertions fail.
    func testFinishAdvisory_finishDidNotLand_reportsFailureAndLeavesTheRoleRunning() async {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "Worker", supervisorTask: "do x") else {
            return XCTFail("createTask failed")
        }
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "Engineer",
                                      status: .running)],
                roleStatuses: ["swe": .working])]
        }
        sut.workFolderURL = nil   // the finish mutation can no longer land

        let r = await sut.performAutovisorAction(
            .manageRole(taskID: id, roleID: "swe", verb: .finishAdvisory))

        XCTAssertFalse(r.ok, "a finish that did not persist must never be reported as done")
        XCTAssertTrue(r.message.contains("Could not finish role"),
                      "the failure must say what did not happen; got \(r.message)")
        XCTAssertTrue(r.message.contains("swe"), "and name the role; got \(r.message)")
        XCTAssertEqual(sut.loadedTask(id)?.runs.last?.steps.first?.status, .running,
                       "the role must be left running, exactly as it was found")
        XCTAssertEqual(sut.loadedTask(id)?.runs.last?.roleStatuses["swe"], .working,
                       "and its role status untouched")
        XCTAssertNil(sut.loadedTask(id)?.closedAt,
                     "a failed finish must never fall through to closing the task")
    }
}

// MARK: - Role control: the §7 "did the write land?" verify arms

/// `NTMSOrchestrator+RoleControl` — three post-mutation verifies that exist because
/// `mutateTask` returning `true` means "persisted", not "the closure did anything".
/// Each one is the ONLY signal for a specific silent stranding, and none of them had
/// ever been driven.
///
/// All three are staged the same way: clear `workFolderURL` so `mutateTask` bails
/// before its closure, which is the real "the write did not land" condition these
/// verifies are written against.
@MainActor
final class BOrchRoleControlVerifyArmTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func openWithRun(_ steps: [StepExecution],
                             statuses: [String: RoleExecutionStatus]) async -> Int? {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "T", supervisorTask: "...") else {
            XCTFail("createTask failed"); return nil
        }
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0, steps: steps, roleStatuses: statuses)]
        }
        return id
    }

    private func latestRun(_ id: Int) -> Run? { sut.loadedTask(id)?.runs.last }

    /// `holdDownstreamForRevision` cancels every peer's engine task and LLM stream
    /// BEFORE the mutation that queues them for revision. If that mutation does not
    /// land, the peer is cancelled but never queued: it will never re-run and never
    /// error. The stranding banner is the only thing that says so.
    ///
    /// The complement — a PHANTOM peer (a role id with no step) is cancelled in name
    /// only and must NOT be flagged — is asserted in the same call, so the filter
    /// that separates them is pinned from both sides at once.
    ///
    /// RED (a): delete the `if !stranded.isEmpty { lastErrorMessage = ... }` block ->
    /// the banner is `mutateTask`'s "Cannot persist task ...", which contains neither
    /// "Revision hold incomplete" nor the role name; the first two assertions fail.
    /// RED (b): drop the `run.steps.contains(where:)` filter from `stranded` ->
    /// "ghostRole" appears in the message and its assertion fails.
    func testHoldDownstream_mutationDidNotLand_flagsOnlyTheRealPeerAsStranded() async {
        guard let id = await openWithRun(
            [StepExecution(id: "peerRole", role: .techLead, title: "TL", status: .running),
             StepExecution(id: "requesterRole", role: .codeReviewer, title: "CR", status: .running)],
            statuses: ["peerRole": .working, "requesterRole": .working]
        ) else { return }
        sut.workFolderURL = nil   // the queue-for-revision mutation cannot land
        sut.lastErrorMessage = nil

        await sut.holdDownstreamForRevision(
            taskID: id,
            runningRoleIDs: ["peerRole", "ghostRole", "requesterRole"],
            requesterRoleID: "requesterRole")

        guard let banner = sut.lastErrorMessage else {
            return XCTFail("a peer cancelled but not queued for revision must be surfaced, never silent")
        }
        XCTAssertTrue(banner.contains("Revision hold incomplete"),
                      "the stranding verify must be what surfaced, not the persistence error; got \(banner)")
        XCTAssertTrue(banner.contains("peerRole"),
                      "the stranded role must be named so the Supervisor can restart it; got \(banner)")
        XCTAssertFalse(banner.contains("ghostRole"),
                       "a peer with no step was never cancelled — flagging it is a false alarm; got \(banner)")
        XCTAssertFalse(banner.contains("requesterRole"),
                       "the requester is deliberately not cancelled and is not a stranding; got \(banner)")
        XCTAssertEqual(latestRun(id)?.roleStatuses["peerRole"], .working,
                       "premise: the mutation really did not land, so the stranding is real")
    }

    /// `requestRevision` flips the role AND records the feedback in one closure. If
    /// that closure never ran, waking the engine would re-run the role blind on a
    /// default comment — so the verify must refuse and say so.
    ///
    /// RED: delete the `guard persisted, ... revisionComment == raw else { ... }`
    /// block -> no banner is raised and the first assertion fails.
    func testRequestRevision_mutationDidNotLand_failsLoudlyAndChangesNothing() async {
        guard let id = await openWithRun(
            [StepExecution(id: "swe", role: .softwareEngineer, title: "Engineer", status: .done)],
            statuses: ["swe": .done]
        ) else { return }
        sut.workFolderURL = nil
        sut.lastErrorMessage = nil

        await sut.requestRevision(taskID: id, roleID: "swe", comment: "add tests")

        guard let banner = sut.lastErrorMessage else {
            return XCTFail("a revision request that did not persist must not be silent")
        }
        XCTAssertTrue(banner.contains("Could not request changes"),
                      "the §7 verify must be what surfaced, not the raw persistence error; got \(banner)")
        XCTAssertTrue(banner.contains("swe"), "the refusal must name the role; got \(banner)")
        XCTAssertEqual(latestRun(id)?.roleStatuses["swe"], .done,
                       "a revision that did not persist must leave the role settled, never half-flipped")
        XCTAssertNil(latestRun(id)?.steps.first?.revisionComment,
                     "and no feedback may be recorded")
    }

    /// `correctRole` branch B appends the Supervisor's correction and sets the
    /// artifact-completion gate, then resumes. If the append did not land, resuming
    /// would continue the role as if it had been corrected — with the correction
    /// nowhere in its conversation.
    ///
    /// RED: replace the `if applied, ... else { lastErrorMessage = ... }` with an
    /// unconditional `await resumeRun(...)` -> no banner and the first assertion fails.
    func testCorrectRole_branchB_mutationDidNotLand_failsLoudlyAndWritesNothing() async {
        guard let id = await openWithRun(
            [StepExecution(id: "swe", role: .softwareEngineer, title: "Engineer", status: .paused)],
            statuses: ["swe": .working]
        ) else { return }
        sut.engineState[id] = .paused           // correctRole hard-requires this
        sut.workFolderURL = nil
        sut.lastErrorMessage = nil

        await sut.correctRole(taskID: id, roleID: "swe", comment: "prefer SQLite")

        guard let banner = sut.lastErrorMessage else {
            return XCTFail("a correction that did not persist must not be reported as applied")
        }
        XCTAssertTrue(banner.contains("Correction could not be applied"),
                      "the verify arm must be what surfaced; got \(banner)")
        XCTAssertTrue(latestRun(id)?.steps.first?.messages.isEmpty ?? false,
                      "no correction may have been appended")
        XCTAssertNil(latestRun(id)?.steps.first?.revisionComment,
                     "and the artifact-completion gate must stay clear")
        XCTAssertEqual(latestRun(id)?.steps.first?.status, .paused,
                       "the step must be left exactly as it was found")
    }
}

// MARK: - Scheduling tail

/// `NTMSOrchestrator+Scheduling` — the recurrence fire's honest-outcome arm and the
/// eviction guard that keeps a delegation descendant of the active task in memory.
@MainActor
final class BOrchSchedulingTailTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// `startRun` is fire-and-forget with several silent early-returns, so a
    /// recurrence fire must NOT stamp `lastFiredAt` unless a run really appeared —
    /// otherwise the schedule shows "last run: now" while nothing happened, which is
    /// the failure mode the stamp guard was written against. The slot is still
    /// rescheduled so the tick does not re-fire in a loop.
    ///
    /// The no-op is staged through `startRun`'s own re-entrancy set, which is the
    /// deterministic shape of "a start that legitimately did nothing".
    ///
    /// RED (a): make the stamp unconditional (`task.recurrence?.lastFiredAt = now`)
    /// -> the `lastFiredAt` assertion fails.
    /// RED (b): delete the `guard didStart else { lastErrorMessage = ... }` block ->
    /// the banner assertion fails.
    func testFireRecurrence_startDidNothing_doesNotStampLastFiredAndSaysSo() async {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "Nightly sweep", supervisorTask: "look around") else {
            return XCTFail("createTask failed")
        }
        await sut.setTaskRecurrence(
            taskID: id, recurrence: TaskRecurrence(rule: .interval(seconds: 3600), isEnabled: true))
        guard let seeded = sut.loadedTask(id)?.recurrence?.nextFireAt else {
            return XCTFail("premise: an enabled recurrence must resolve a next slot")
        }
        XCTAssertNil(sut.loadedTask(id)?.recurrence?.lastFiredAt, "premise: never fired yet")

        // `startRun` becomes a deterministic no-op: no run, no engine, no banner.
        sut.startingRunTaskIDs.insert(id)
        defer { sut.startingRunTaskIDs.remove(id) }
        sut.lastErrorMessage = nil
        let runsBefore = sut.loadedTask(id)?.runs.count ?? -1

        // Two hours ahead of the seeded hourly slot, so the fire is unambiguously due.
        let now = seeded.addingTimeInterval(7200)
        await sut.evaluateDueRecurrences(now: now)

        XCTAssertNil(sut.loadedTask(id)?.recurrence?.lastFiredAt,
                     "a fire that produced no run must not record itself as having fired")
        guard let banner = sut.lastErrorMessage else {
            return XCTFail("a scheduled run that could not start must be surfaced")
        }
        XCTAssertTrue(banner.contains("could not start its scheduled run"), banner)
        XCTAssertTrue(banner.contains("Nightly sweep"),
                      "the banner must name the task so the user can find it; got \(banner)")
        XCTAssertEqual(sut.loadedTask(id)?.runs.count, runsBefore,
                       "premise: the fire really appended no run — otherwise `didStart` would be true "
                           + "and this test would be asserting the wrong arm")
        guard let rescheduled = sut.loadedTask(id)?.recurrence?.nextFireAt else {
            return XCTFail("the slot must still be rescheduled, or the next tick re-fires immediately")
        }
        XCTAssertGreaterThan(rescheduled, now,
                             "a failed fire must still advance the slot past `now`")
    }

    /// The active task's activity feed and graph render its delegation descendants,
    /// so the scheduler's memory housekeeping must never drop one. This is the guard
    /// that says so — and it is the only thing between a scheduler tick and a parent
    /// board that silently loses its child-team layers.
    ///
    /// RED: delete the `descendantIDs(of: activeID).contains(taskID)` guard -> the
    /// child is evicted and both assertions fail.
    func testEvictIfReclaimable_delegationDescendantOfActiveTask_isKept() async {
        await sut.openWorkFolder(tempDir)
        guard let parent = await sut.createTask(title: "Parent", supervisorTask: "p") else {
            return XCTFail("parent creation failed")
        }
        guard let child = await sut.createDelegatedTask(
            parentTaskID: parent, parentRoleID: "coding_agent",
            title: "Child", supervisorTask: "sub-brief",
            preferredTeamID: nil, depth: 1
        ) else { return XCTFail("child creation failed") }

        XCTAssertEqual(sut.activeTaskID, parent,
                       "premise: a delegated child never steals focus, so the PARENT is active")
        XCTAssertNotNil(sut.loadedTask(child),
                        "premise: createDelegatedTask leaves the child loaded")
        XCTAssertNil(sut.taskEngineStates[child], "premise: no engine, so nothing else pins it")

        let sweep = sut.evictIfReclaimable(child)

        XCTAssertNil(sweep,
                     "nothing was evicted, so no residency sweep may be spawned")
        XCTAssertNotNil(sut.loadedTask(child),
                        "a delegation descendant of the ACTIVE task must stay loaded — the parent's "
                            + "feed and graph render it")
    }

    /// The complement, which is what makes the assertion above about the DESCENDANT
    /// guard rather than about eviction being broken: an unrelated background task
    /// with the same shape IS evicted.
    ///
    /// RED: make `evictIfReclaimable` always return nil -> both assertions fail.
    func testEvictIfReclaimable_unrelatedBackgroundTask_isEvicted() async {
        await sut.openWorkFolder(tempDir)
        guard let active = await sut.createTask(title: "Active", supervisorTask: "a") else {
            return XCTFail("createTask failed")
        }
        guard let other = await sut.createTask(title: "Other", supervisorTask: "b", makeActive: false) else {
            return XCTFail("createTask failed")
        }
        await sut.ensureTaskLoaded(other)
        XCTAssertEqual(sut.activeTaskID, active, "premise: `other` is a background task")
        XCTAssertNotNil(sut.loadedTask(other), "premise: it is loaded")

        let sweep = sut.evictIfReclaimable(other)

        XCTAssertNotNil(sweep,
                        "an actual eviction de-references its models and must return a sweep")
        // `loadedTask` (not `snapshot?.loadedTasks[...]`): the latter is a DOUBLE optional,
        // and `XCTAssertNil` on `Optional(nil)` reads as non-nil and passes vacuously.
        XCTAssertNil(sut.loadedTask(other),
                     "a reclaimable background task must really be dropped from memory")
        await sweep?.value
    }
}

// MARK: - Delegation delegate hooks

/// `NTMSOrchestrator+Delegation` — two `LLMStateDelegate` hooks that had no test at
/// all. Both are small, and both are load-bearing: one decides what a delegating
/// parent (and the Autovisor's `task_status`) is told about a child's failure, the
/// other is how a delegation handler starts the child it just created.
@MainActor
final class BOrchDelegationHookTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// The whole point of this hook is that it is TASK-SCOPED. The global banner can
    /// belong to any other task in the folder, and handing it to a delegating parent
    /// (or to `task_status`) makes it act on a healthy child.
    ///
    /// RED: change the body to `return lastErrorMessage` -> the healthy-task
    /// assertion fails (it would return the unrelated banner).
    func testLastErrorMessageForTask_isTaskScoped_notTheGlobalBanner() async {
        await sut.openWorkFolder(tempDir)
        guard let healthy = await sut.createTask(title: "Healthy", supervisorTask: "h") else {
            return XCTFail("createTask failed")
        }
        await sut.mutateTask(taskID: healthy) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "E", status: .running)],
                roleStatuses: ["swe": .working])]
        }
        sut.lastErrorMessage = "a banner raised by a completely different task"

        XCTAssertNil(sut.lastErrorMessageForTask(healthy),
                     "a task with no failed step has no failure detail, whatever the global banner says")
    }

    /// The positive arm: a task whose own run carries a failed step reports THAT
    /// step's detail.
    ///
    /// RED: make the hook return nil unconditionally -> this assertion fails.
    func testLastErrorMessageForTask_failedStep_reportsItsOwnDetail() async {
        await sut.openWorkFolder(tempDir)
        guard let failed = await sut.createTask(title: "Failed", supervisorTask: "f") else {
            return XCTFail("createTask failed")
        }
        await sut.mutateTask(taskID: failed) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "swe", role: .softwareEngineer, title: "E", status: .failed,
                    messages: [StepMessage(
                        role: .softwareEngineer,
                        content: "LLM error: connection refused")])],
                roleStatuses: ["swe": .failed])]
        }

        XCTAssertEqual(sut.lastErrorMessageForTask(failed), "LLM error: connection refused",
                       "the failing step's own note is what the parent role must be handed")
    }

    /// A task id that isn't in memory must come back nil rather than a fabricated
    /// blank detail.
    func testLastErrorMessageForTask_unloadedTask_returnsNil() async {
        await sut.openWorkFolder(tempDir)
        sut.lastErrorMessage = "something else went wrong"
        XCTAssertNil(sut.lastErrorMessageForTask(99_999))
    }

    /// `startRunForTask` is the delegation handler's only way to start the child it
    /// just created; a no-op here leaves the parent blocked on `awaitTaskTerminalState`
    /// for the full 30-minute delegation timeout.
    ///
    /// The child is pinned to the "Generated Team" placeholder with an EMPTY brief, so
    /// `startRun` takes the team-generation branch and returns before any engine
    /// starts, and the spawned generation bails on the empty brief before building a
    /// request. Net effect: one run appended, nothing else.
    ///
    /// RED: make `startRunForTask` a no-op -> `runs.count` stays 0 and the assertion fails.
    func testStartRunForTask_appendsARun() async {
        await sut.openWorkFolder(tempDir)
        let placeholder = TeamTemplateFactory.generatedTeam()
        await sut.mutateWorkFolder { proj in
            if !proj.teams.contains(where: { $0.templateID == DelegationConstants.generatedTeamSentinel }) {
                proj.teams.append(placeholder)
            }
        }
        guard let genID = sut.snapshot?.workFolder.teams
            .first(where: { $0.templateID == DelegationConstants.generatedTeamSentinel })?.id else {
            return XCTFail("the generated placeholder must be present after seeding")
        }
        guard let id = await sut.createTask(
            title: "Child", supervisorTask: "", preferredTeamID: genID, makeActive: false
        ) else { return XCTFail("createTask failed") }
        await sut.ensureTaskLoaded(id)
        XCTAssertEqual(sut.loadedTask(id)?.runs.count, 0, "premise: no runs yet")

        await sut.startRunForTask(taskID: id)

        XCTAssertEqual(sut.loadedTask(id)?.runs.count, 1,
                       "the delegation start hook must really start the child's run")
    }
}

// MARK: - Engine management

/// `NTMSOrchestrator+EngineManagement` — the awaiter side-channel installed in
/// `engineForTask`, and the fast-path's fall-through.
@MainActor
final class BOrchEngineManagementTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// Captures an awaited value out of a spawned `@MainActor` Task without an
    /// `inout` capture. Nested types do NOT inherit the enclosing type's global
    /// actor, so the annotation is explicit (mirrors `DelegationInterruptTests`).
    @MainActor
    private final class OutcomeBox {
        var value: TaskCompletionAwaiter.WaitOutcome?
    }

    private func spinUntilWaiterRegistered(_ taskID: Int) async {
        var attempts = 0
        while !sut.completionAwaiter.hasWaiters(for: taskID), attempts < 100 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
    }

    /// `.needsAcceptance` is a TERMINAL outcome for a delegating parent: the handler
    /// auto-accepts and closes the child. Delivering the wrong case (or nothing) is
    /// what wedges the parent on `awaitTaskTerminalState` until the 30-minute timeout.
    ///
    /// Driven through the real `transition(to:)` -> `didSet` -> `onStateChanged`
    /// wiring rather than by calling the closure by hand, so the installation in
    /// `engineForTask` is part of what is pinned.
    ///
    /// RED: change the `.needsAcceptance` arm to deliver `.terminal(.done)` ->
    /// the outcome assertion fails.
    func testEngineTransitionToNeedsAcceptance_deliversTerminalNeedsAcceptance() async {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "T", supervisorTask: "...") else {
            return XCTFail("createTask failed")
        }
        let engine = sut.engineForTask(id)

        let box = OutcomeBox()
        let exp = expectation(description: "awaiter resumed")
        let waiter = Task { @MainActor in
            box.value = await sut.completionAwaiter.register(taskID: id)
            exp.fulfill()
        }
        await spinUntilWaiterRegistered(id)
        XCTAssertTrue(sut.completionAwaiter.hasWaiters(for: id),
                      "premise: a waiter must be registered before the transition fires")

        engine.transition(to: .needsAcceptance)

        await fulfillment(of: [exp], timeout: 2.0)
        sut.completionAwaiter.cancelAll(taskID: id)   // no-op if delivery already happened
        await waiter.value

        XCTAssertEqual(box.value, TaskCompletionAwaiter.WaitOutcome.terminal(.needsAcceptance),
                       "a child parked at Review must wake its parent with the acceptance outcome")
        XCTAssertEqual(sut.taskEngineStates[id], .needsAcceptance,
                       "and the UI-facing engine state must move with it")
    }

    /// The fast-path exists to avoid registering against a transition that already
    /// happened. Its complement matters just as much: for a task that is genuinely
    /// still working, the function must fall through and REGISTER — returning a
    /// terminal outcome there would tell a delegating parent its child had finished
    /// while the child is mid-run.
    ///
    /// RED: make the `default:` arm of the derived-status switch return
    /// `.terminal(.done)` -> no waiter is ever registered and the `hasWaiters`
    /// assertion fails.
    func testAwaitTaskTerminalState_runningTask_registersInsteadOfFastPathing() async {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "T", supervisorTask: "...") else {
            return XCTFail("createTask failed")
        }
        await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "E", status: .running)],
                roleStatuses: ["swe": .working])]
        }
        XCTAssertNil(sut.taskEngineStates[id], "premise: no engine state to fast-path on")
        XCTAssertNil(sut.loadedTask(id)?.closedAt, "premise: not closed")

        let box = OutcomeBox()
        let exp = expectation(description: "awaiter resumed")
        let waiter = Task { @MainActor in
            box.value = await sut.awaitTaskTerminalState(taskID: id)
            exp.fulfill()
        }
        await spinUntilWaiterRegistered(id)

        XCTAssertTrue(sut.completionAwaiter.hasWaiters(for: id),
                      "a task that is still running must REGISTER, never fast-path to a terminal outcome")

        sut.completionAwaiter.deliver(taskID: id, outcome: .terminal(.failed))
        await fulfillment(of: [exp], timeout: 2.0)
        await waiter.value

        XCTAssertEqual(box.value, TaskCompletionAwaiter.WaitOutcome.terminal(.failed),
                       "the outcome must be the one delivered to the registered waiter")
    }
}

// MARK: - Downloaded-model pass-throughs

/// `NTMSOrchestrator+DownloadedModels` — the two reads the Settings card asks for
/// before it enables its Remove button and before it names where the files live.
///
/// Thin, but not free: each one must reach the store with the card's OWN config.
/// The card deliberately pins the endpoint its rows came from (a provider switch
/// mid-fetch otherwise retargets a visible row at another host), and these hops are
/// where that config would be lost.
@MainActor
final class BOrchDownloadedModelReadTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var store: BOrchProbeDownloadedModelStore!

    override func setUp() async throws {
        try await super.setUp()
        store = BOrchProbeDownloadedModelStore()
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient,
            downloadedModelStore: store
        )
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    private func config(_ provider: LLMProvider, _ url: String) -> LLMConfig {
        LLMConfig(provider: provider, baseURLString: url, modelName: "m")
    }

    /// The capability drives BOTH the button's enablement and the confirmation copy
    /// ("permanently" vs "moved to the Trash"), so it must be the store's verbatim
    /// answer for the endpoint asked about — never a default.
    ///
    /// RED: hard-code `.permanent` in `downloadedModelDeletion` -> the
    /// `.movesToTrash` assertion fails.
    func testDownloadedModelDeletion_returnsTheStoreAnswerForTheGivenConfig() async {
        store.capability = .movesToTrash
        let lmStudio = config(.lmStudio, "http://127.0.0.1:1234")

        let capability = await sut.downloadedModelDeletion(config: lmStudio)

        XCTAssertEqual(capability, .movesToTrash,
                       "the provider's own answer must reach the card unchanged")
        XCTAssertEqual(store.capabilityConfigs.map(\.baseURLString), ["http://127.0.0.1:1234"],
                       "the card's own endpoint must be what the store was asked about")
        XCTAssertEqual(store.capabilityConfigs.map(\.provider), [.lmStudio])
    }

    /// The other arm of the same value: an endpoint that cannot delete must say why,
    /// verbatim, because the card shows the reason to the user.
    func testDownloadedModelDeletion_unavailableReasonIsCarriedThrough() async {
        store.capability = .unavailable(reason: "LM Studio has no delete API.")

        let capability = await sut.downloadedModelDeletion(
            config: config(.ollama, "http://127.0.0.1:11434"))

        XCTAssertEqual(capability, .unavailable(reason: "LM Studio has no delete API."))
    }

    /// `nil` means "we can't say where the files are" and must stay distinguishable
    /// from an empty string, which would render as a blank location.
    ///
    /// RED: make `downloadedModelStorageLocation` return `""` on nil -> the nil
    /// assertion fails.
    func testDownloadedModelStorageLocation_passesTheConfigAndPreservesNil() async {
        store.location = "~/.lmstudio/models"
        let first = await sut.downloadedModelStorageLocation(
            config: config(.lmStudio, "http://localhost:1234"))
        XCTAssertEqual(first, "~/.lmstudio/models")

        store.location = nil
        let second = await sut.downloadedModelStorageLocation(
            config: config(.lmStudio, "http://localhost:1234"))
        XCTAssertNil(second, "an unknown location must stay nil, not become an empty string")

        XCTAssertEqual(store.locationConfigs.map(\.baseURLString),
                       ["http://localhost:1234", "http://localhost:1234"],
                       "both reads must carry the caller's endpoint")
    }
}

/// Records what each read was asked about. File-private, so it cannot collide with
/// the same-named doubles in `DownloadedModelDeletionTests` /
/// `DownloadedModelStoreRouterTests`.
private final class BOrchProbeDownloadedModelStore: DownloadedModelStore, @unchecked Sendable {
    var capability: DownloadedModelDeletion = .permanent
    var location: String?
    private(set) var capabilityConfigs: [LLMConfig] = []
    private(set) var locationConfigs: [LLMConfig] = []

    func listDownloaded(config _: LLMConfig) async throws -> [DownloadedModel] { [] }

    func deletionCapability(config: LLMConfig) async -> DownloadedModelDeletion {
        capabilityConfigs.append(config)
        return capability
    }

    func delete(modelID _: String, config _: LLMConfig) async throws {}

    func storageLocationDescription(config: LLMConfig) async -> String? {
        locationConfigs.append(config)
        return location
    }
}
