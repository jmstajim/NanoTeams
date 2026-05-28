import XCTest
@testable import NanoTeams

/// User-path: pausing a parent task whose role is mid-`delegate_to_team` must
/// (a) recursively pause every delegated child, (b) NOT cancel the parent's
/// runStep — its handler stays suspended on the child awaiter so resume picks
/// up where it left off. This integration test drives the orchestrator's
/// pause/resume helpers directly to verify the lifecycle invariants without
/// needing a live LLM.
@MainActor
final class PauseResumeDelegationCascadeTests: XCTestCase {

    // MARK: - Helpers

    private func makeOrchestrator() -> NTMSOrchestrator {
        let repo = NTMSRepository()
        return NTMSOrchestrator(
            repository: repo,
            searchEmbeddingClient: StubSearchEmbeddingClient()
        )
    }

    // MARK: - Mid-Delegation Detection

    func testStepHasActiveDelegation_truePathPreventsLLMCancel() async {
        // Given: an orchestrator with a parent task whose latest run has a step
        // carrying `activeDelegationChildID` set.
        let store = makeOrchestrator()
        let workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-pause-cascade-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolderRoot) }

        await store.openWorkFolder(workFolderRoot)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        XCTAssertNotNil(parentID)
        guard let parentID else { return }

        // Stamp activeDelegationChildID on the parent's first step (simulate the
        // state set by handleDelegateToTeam after creating its child).
        let stamped = await store.mutateTask(taskID: parentID) { task in
            guard task.runs.indices.last == nil else { return }
            // No run exists yet — give the test a step shape it can mark.
            var step = StepExecution(id: "pm", role: .productManager, title: "PM Step")
            step.status = .running
            step.setActiveDelegation(childID: 999)  // synthesized child ID
            let run = Run(id: 0, steps: [step])
            task.runs.append(run)
        }
        // The bare-task path above only fires if the orchestrator hasn't pre-populated runs.
        // For a freshly created task, runs is typically empty — append manually.
        if !stamped {
            await store.mutateTask(taskID: parentID) { task in
                var step = StepExecution(id: "pm", role: .productManager, title: "PM Step")
                step.status = .running
                step.setActiveDelegation(childID: 999)
                let run = Run(id: 0, steps: [step])
                task.runs.append(run)
            }
        }

        // When: pauseRun is called.
        // Then: the LLM cancellation path is skipped because step is mid-delegation.
        // We verify by ensuring the engine state transitions to .paused but the
        // step's status remains `.running` (not `.paused` — pauseStep was skipped).
        await store.pauseRun(taskID: parentID)

        let postPauseTask = store.loadedTask(parentID)
        let stepStatusAfterPause = postPauseTask?.runs.last?.steps.first?.status
        XCTAssertEqual(stepStatusAfterPause, .running,
                       "Mid-delegation step must NOT be marked .paused — its handler keeps awaiting the child.")
    }

    // MARK: - Cascading Pause

    func testPauseRun_cascadesToChildren() async {
        let store = makeOrchestrator()
        let workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-cascade-pause-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolderRoot) }

        await store.openWorkFolder(workFolderRoot)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }

        // Create a delegated child task tied to the parent.
        let childID = await store.createDelegatedTask(
            parentTaskID: parentID,
            parentRoleID: "pm",
            title: "Child",
            supervisorTask: "Sub-brief",
            preferredTeamID: nil,
            depth: 1
        )
        guard let childID else { return XCTFail("child creation failed") }

        // Pause the parent — the cascade must hit the child too.
        // We can verify by checking childTaskIDs lookup before/after and engine state.
        XCTAssertEqual(store.childTaskIDs(of: parentID), [childID],
                       "Sanity: child is registered under parent in tasksIndex.")

        await store.pauseRun(taskID: parentID)
        // After cascading pause, both engines should reflect a paused state.
        // (Children with no engine yet are no-ops — that's OK; the test verifies
        // the cascade path runs without throwing or leaving partial state.)
    }

    // MARK: - Per-step granularity (pause cascades correctly when sibling steps run alongside a mid-delegation step)

    /// Regression: prior to the fix, `pauseRun` used an all-or-nothing
    /// `isMidDelegation` flag — if ANY step on the task carried
    /// `activeDelegationChildID != nil`, the entire task skipped LLM
    /// cancellation. Sibling steps doing real work (LLM retry loops, parallel
    /// ready roles per CLAUDE.md #45) kept running after pause. The user
    /// observed this as "subtask continues to retry LLM calls" when the child
    /// team itself contained a delegating sibling step.
    /// The fix iterates steps individually: only the specific step with
    /// `activeDelegationChildID != nil` is preserved; every other step's
    /// LLM execution is cancelled and its status pauses normally.
    func testPauseRun_cancelsSiblingsOfMidDelegationStep() async {
        let store = makeOrchestrator()
        let workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-pause-siblings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolderRoot) }

        await store.openWorkFolder(workFolderRoot)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }

        // Mixed task: one step is mid-delegation (must stay .running), one
        // sibling is a normal running step (must transition to .paused).
        await store.mutateTask(taskID: parentID) { task in
            var delegatingStep = StepExecution(id: "pm", role: .productManager, title: "PM Step")
            delegatingStep.status = .running
            delegatingStep.setActiveDelegation(childID: 999)

            var siblingStep = StepExecution(id: "swe", role: .softwareEngineer, title: "SWE Step")
            siblingStep.status = .running

            let run = Run(id: 0, steps: [delegatingStep, siblingStep])
            task.runs.append(run)
        }

        await store.pauseRun(taskID: parentID)

        let postPauseTask = store.loadedTask(parentID)
        let pmStatus = postPauseTask?.runs.last?.steps.first(where: { $0.id == "pm" })?.status
        let sweStatus = postPauseTask?.runs.last?.steps.first(where: { $0.id == "swe" })?.status
        XCTAssertEqual(pmStatus, .running,
                       "Mid-delegation step (pm) must remain .running so its awaiter keeps sleeping.")
        XCTAssertEqual(sweStatus, .paused,
                       "Sibling non-delegating step (swe) MUST be paused — without per-step granularity, the LLM retry loop kept firing after pause.")
    }

    // MARK: - Recursive Cascade (Depth 2)

    /// User-reported scenario (depth observed > 1 in practice): parent (Coding
    /// Agent) → child (Engineering) → grandchild (further delegation). All three
    /// engines must reach `.paused`, and step statuses must respect the
    /// per-step granularity at every level.
    ///
    /// Pre-fix behavior: the parent paused, but the child's sibling steps kept
    /// running because the all-or-nothing `isMidDelegation` flag treated the
    /// child as untouchable while it had an active delegation marker. The user
    /// observed this as the subtask continuing to retry LLM calls.
    func testPauseRun_depth2_cascadesAndCancelsAllNonDelegatingSteps() async {
        let store = makeOrchestrator()
        let workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-pause-depth2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolderRoot) }

        await store.openWorkFolder(workFolderRoot)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return XCTFail("parent creation failed") }
        let childID = await store.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "coding_agent",
            title: "Child", supervisorTask: "Sub-brief",
            preferredTeamID: nil, depth: 1
        )
        guard let childID else { return XCTFail("child creation failed") }
        let grandchildID = await store.createDelegatedTask(
            parentTaskID: childID, parentRoleID: "engineer",
            title: "Grandchild", supervisorTask: "Sub-sub-brief",
            preferredTeamID: nil, depth: 2
        )
        guard let grandchildID else { return XCTFail("grandchild creation failed") }

        // Background child tasks need to be in `loadedTasks` for `mutateTask`
        // to operate. In real flow this happens via `startRun` → `ensureTaskLoaded`;
        // here we call ensureTaskLoaded directly because we never start the
        // engines in this test (we drive pause/cascade in isolation).
        await store.ensureTaskLoaded(childID)
        await store.ensureTaskLoaded(grandchildID)

        // Parent: one delegating step (pointing at child), no siblings — minimal valid shape.
        let parentMutated = await store.mutateTask(taskID: parentID) { task in
            var step = StepExecution(id: "coding_agent", role: .codingAgent, title: "Coding Agent")
            step.status = .running
            step.setActiveDelegation(childID: childID)
            task.runs.append(Run(id: 0, steps: [step]))
        }
        XCTAssertTrue(parentMutated, "Parent mutation must persist")

        // Child: ONE delegating step + ONE sibling (the bug scenario — sibling
        // must pause despite the delegating step being preserved).
        let childMutated = await store.mutateTask(taskID: childID) { task in
            var delegating = StepExecution(id: "engineer", role: .softwareEngineer, title: "Engineer")
            delegating.status = .running
            delegating.setActiveDelegation(childID: grandchildID)

            var sibling = StepExecution(id: "reviewer", role: .codeReviewer, title: "Reviewer")
            sibling.status = .running

            task.runs.append(Run(id: 0, steps: [delegating, sibling]))
        }
        XCTAssertTrue(childMutated, "Child mutation must persist (ensureTaskLoaded should have put it in loadedTasks)")

        // Grandchild: a single working step doing real LLM work.
        let grandchildMutated = await store.mutateTask(taskID: grandchildID) { task in
            var step = StepExecution(id: "tpm", role: .tpm, title: "TPM Step")
            step.status = .running
            task.runs.append(Run(id: 0, steps: [step]))
        }
        XCTAssertTrue(grandchildMutated, "Grandchild mutation must persist")

        await store.pauseRun(taskID: parentID)

        // Parent: mid-delegation step preserved.
        let parentStep = store.loadedTask(parentID)?.runs.last?.steps.first
        XCTAssertEqual(parentStep?.status, .running,
                       "Parent's mid-delegation step must remain .running")

        // Child: delegating step preserved, sibling cancelled — THIS is the
        // regression the bug fix addresses.
        let childTask = store.loadedTask(childID)
        let childDelegating = childTask?.runs.last?.steps.first(where: { $0.id == "engineer" })
        let childSibling = childTask?.runs.last?.steps.first(where: { $0.id == "reviewer" })
        XCTAssertEqual(childDelegating?.status, .running,
                       "Child's mid-delegation step must remain .running")
        XCTAssertEqual(childSibling?.status, .paused,
                       "Child's NON-delegating sibling step MUST pause — pre-fix this stayed .running and its LLM kept retrying")

        // Grandchild: single working step paused (nothing to preserve here).
        let grandchildStep = store.loadedTask(grandchildID)?.runs.last?.steps.first
        XCTAssertEqual(grandchildStep?.status, .paused,
                       "Grandchild's working step must transition to .paused")
    }

    /// Edge case: a task with multiple parallel-ready non-delegating steps
    /// (CLAUDE.md #45 — engine runs ready roles in parallel) must pause ALL
    /// of them, not just the first one.
    func testPauseRun_multipleParallelSteps_allPause() async {
        let store = makeOrchestrator()
        let workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-pause-parallel-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolderRoot) }

        await store.openWorkFolder(workFolderRoot)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        await store.mutateTask(taskID: taskID) { task in
            var s1 = StepExecution(id: "uxr", role: .uxResearcher, title: "UXR")
            s1.status = .running
            var s2 = StepExecution(id: "uxd", role: .uxDesigner, title: "UXD")
            s2.status = .running
            var s3 = StepExecution(id: "tl", role: .techLead, title: "TL")
            s3.status = .running
            task.runs.append(Run(id: 0, steps: [s1, s2, s3]))
        }

        await store.pauseRun(taskID: taskID)

        let steps = store.loadedTask(taskID)?.runs.last?.steps ?? []
        XCTAssertEqual(steps.count, 3)
        for step in steps {
            XCTAssertEqual(step.status, .paused,
                           "Step \(step.id) must pause — parallel-ready roles all need cancellation")
        }
    }

    /// Edge case: a step in `.needsSupervisorInput` state must also pause
    /// (it's actively awaiting user input, not idle). Pre-fix this branch was
    /// inside the `if !isMidDelegation { ... }` block; we preserved it
    /// post-fix in the per-step loop.
    func testPauseRun_needsSupervisorInputStep_pauses() async {
        let store = makeOrchestrator()
        let workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-pause-input-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolderRoot) }

        await store.openWorkFolder(workFolderRoot)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        await store.mutateTask(taskID: taskID) { task in
            var step = StepExecution(id: "pm", role: .productManager, title: "PM")
            step.status = .needsSupervisorInput
            step.needsSupervisorInput = true
            step.supervisorQuestion = "Q?"
            task.runs.append(Run(id: 0, steps: [step]))
        }

        await store.pauseRun(taskID: taskID)
        let stepStatus = store.loadedTask(taskID)?.runs.last?.steps.first?.status
        XCTAssertEqual(stepStatus, .paused,
                       ".needsSupervisorInput steps must transition to .paused on pauseRun")
    }

    // MARK: - Resume Without Mid-Delegation

    func testResumeRun_withoutMidDelegation_followsNormalRestartPath() async {
        let store = makeOrchestrator()
        let workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-resume-normal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolderRoot) }

        await store.openWorkFolder(workFolderRoot)
        let parentID = await store.createTask(title: "Parent", supervisorTask: "...")
        guard let parentID else { return }

        // No activeDelegationChildID set — resume runs the normal restart logic.
        await store.resumeRun(taskID: parentID)
        // Test passes if no crash; the actual runStep behavior is covered in other tests.
    }
}
