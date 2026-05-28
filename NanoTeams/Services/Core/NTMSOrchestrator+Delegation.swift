import Foundation

/// Delegation lifecycle helpers — create child tasks, surface delegation policy
/// to handlers, drive ancillary supervisor input flow.
///
/// All read-only LLMStateDelegate hooks for delegation live here so the
/// orchestrator's main file stays focused on engine + task lifecycle.
extension NTMSOrchestrator {

    // MARK: - Child Task Lifecycle

    /// Programmatically creates a child task with parentage stamped on. Returns the
    /// new task's ID, or `nil` on persistence failure (the error is surfaced via
    /// `lastErrorMessage`).
    ///
    /// The handler is expected to call `startRunForTask(taskID:)` afterwards. For
    /// generated-team delegation, the handler also calls `mutateTask(childTID) { task.adoptGeneratedTeam(team) }`
    /// before starting the run.
    func createDelegatedTask(
        parentTaskID: Int,
        parentRoleID: String,
        title: String,
        supervisorTask: String,
        preferredTeamID: NTMSID?,
        depth: Int
    ) async -> Int? {
        guard let url = workFolderURL else { return nil }
        do {
            // Parentage is supplied at creation time so the task's storage path is
            // nested under its ancestors from the very first write — no later
            // "move on disk" step needed. The repository walks ancestors via
            // `tasksIndex.ancestorIDs(of:)` to compute the right directory.
            let (snapshot, childID) = try taskService.createTask(
                at: url,
                title: title,
                supervisorTask: supervisorTask,
                preferredTeamID: preferredTeamID,
                parentTaskID: parentTaskID,
                parentRoleID: parentRoleID,
                delegationDepth: depth
            )
            apply(snapshot)
            // CRITICAL: load the freshly-created child task into `loadedTasks`
            // BEFORE returning. Otherwise the immediate next step in
            // `handleDelegateToTeam` —
            //
            //     await delegate.mutateTask(taskID: childTID) {
            //         task.adoptGeneratedTeam(targetTeam)
            //     }
            //
            // — silently fails because `mutateTask` for a non-active task
            // requires `loadedTask(taskID) != nil`. When the mutation fails,
            // `task.generatedTeam` stays `nil` on disk; the child engine then
            // resolves its team via `TaskEngineStoreAdapter.resolvedTeam`'s
            // fallback chain, which lands on the PARENT's `activeTeam` — i.e.
            // the parent's Coding Agent template with `delegate_to_team`
            // intact. Result: child runs with parent's tools, calls
            // `delegate_to_team` itself, and we get the depth-N self-recursion
            // the user observed (`Coding Agent.Coding Agent.Coding Agent…`).
            // ensureTaskLoaded reads the just-written task.json into
            // `loadedTasks[childID]` so subsequent mutateTask calls succeed.
            await ensureTaskLoaded(childID)

            // `taskService.createTask` normalizes `preferredTeamID` to a
            // resolvable team id by falling back to the project's active
            // team when the supplied id isn't found in `workFolder.teams`.
            // For generated-team delegations the caller's id is the just-
            // synthesized team's ephemeral id — by design NOT in the project
            // (the team only lives on `task.generatedTeam`). The
            // normalization would silently rewrite child's preferredTeamID
            // to the parent's active team id, which after a missed
            // `adoptGeneratedTeam` lets `TaskEngineStoreAdapter.resolvedTeam`
            // return parent's team via its preferredTeamID branch — bypassing
            // the child-task fail-fast guard. Restoring the caller's
            // original id keeps preferredTeamID unresolvable for the
            // generated branch, so the fail-fast in the adapter actually
            // engages if `adoptGeneratedTeam` ever silently fails (defense in
            // depth alongside the post-mutation invariant in the handler).
            // Non-generated branches are unaffected because their ids ARE in
            // `workFolder.teams` — the fallback never engaged there.
            if let originalID = preferredTeamID,
               loadedTask(childID)?.preferredTeamID != originalID {
                await mutateTask(taskID: childID) { task in
                    task.preferredTeamID = originalID
                }
            }
            return childID
        } catch {
            self.lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Starts a task's run via the existing `startRun(taskID:)` orchestration.
    /// Returns immediately; completion is observed via `awaitTaskTerminalState`.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func startRunForTask(taskID: Int) async {
        await startRun(taskID: taskID)
    }

    /// Eagerly loads every transitive descendant of the given task into
    /// `snapshot.loadedTasks` via `ensureTaskLoaded(_:)`. Idempotent: skips
    /// IDs already loaded. No-op when `taskID == nil` or the index is missing.
    ///
    /// Called on work-folder open, task switch, and after task removal so the
    /// activity feed (`allLoadedTasksIncludingChildren`) and the graph
    /// (`GraphPanelView.resolveDelegationLayers`) can render the parent's
    /// delegation history after app restart, before any new run resurrects
    /// child tasks via the runtime `delegate_to_team` path.
    ///
    /// Failure aggregation: `ensureTaskLoaded` sets `lastErrorMessage` per
    /// failure, so a serial loop without aggregation would silently overwrite
    /// every prior failure — the user sees only the LAST one even when N
    /// descendants are missing. Worse, a single failure mid-loop does NOT
    /// abort (continuing is preferable to losing the rest), so without an
    /// aggregated banner the activity feed and graph would silently render an
    /// incomplete tree.
    ///
    /// We snapshot `lastErrorMessage` before the loop, suppress per-iteration
    /// updates from `ensureTaskLoaded` by restoring after each call, then
    /// emit ONE summary banner naming every failed ID at the end. A clean
    /// run leaves the pre-existing banner untouched.
    func ensureDelegationDescendantsLoaded(of taskID: Int?) async {
        guard let taskID, let index = snapshot?.tasksIndex else { return }
        let baselineBanner = lastErrorMessage
        var failedIDs: [Int] = []
        for childID in index.descendantIDs(of: taskID) {
            await ensureTaskLoaded(childID)
            // `ensureTaskLoaded` short-circuits when already loaded; failure
            // is detected by absence of the entry in `loadedTasks` AFTER the
            // call. This avoids changing the helper's signature and works
            // whether the underlying error was repository-level or recovery-
            // persistence-level.
            if loadedTask(childID) == nil {
                failedIDs.append(childID)
            }
        }
        // Restore the baseline banner regardless of outcome so a per-iteration
        // overwrite from `ensureTaskLoaded` doesn't leak the last error in
        // the success-without-failures case.
        lastErrorMessage = baselineBanner
        guard !failedIDs.isEmpty else { return }
        let list = failedIDs.map { "#\($0)" }.joined(separator: ", ")
        let plural = failedIDs.count == 1 ? "descendant" : "descendants"
        lastErrorMessage = "Could not restore \(failedIDs.count) delegated \(plural) of task #\(taskID): \(list). Activity feed and graph may be incomplete."
    }

    /// Returns the most recent error message attached to the orchestrator's
    /// banner channel. V1 limitation: errors are not partitioned per-task, so
    /// `taskID` is currently ignored — the same global string surfaces no matter
    /// which task fails. Documented in the V2 follow-up list; partitioning needs
    /// a per-task error store, not just an additional wrapper.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func lastErrorMessageForTask(_ taskID: Int) -> String? {
        _ = taskID
        return lastErrorMessage
    }

    /// Hard-stops a task's engine and all of its descendant engines
    /// (children, grandchildren, …). Used by `handleDelegateToTeam` on
    /// timeout / cancel / abort — the existing single-level
    /// `stopEngine(for:)` is internal to the orchestrator file (called
    /// from `removeTask`/`stopAllEngines` where children are walked
    /// separately); this is the public entry point exposed via the
    /// `LLMStateDelegate` protocol and MUST cascade because the
    /// delegation surface is recursive: a child team can itself have
    /// delegated to a grandchild team that's still running its own LLM
    /// loop. Without cascade, depth-2+ stops would leave grandchild
    /// engines orphaned (no awaiter wakeup, no parent to time them out).
    func stopEngineForTask(_ taskID: Int) {
        stopEngineForTask(taskID, visited: [])
    }

    /// Internal recursive variant with a `visited: Set<Int>` cycle guard
    /// — mirrors the guards on `pauseRun` / `resumeRun` /
    /// `removeTaskRecursively` against a corrupted `tasks_index.json`
    /// self-cycle.
    private func stopEngineForTask(_ taskID: Int, visited: Set<Int>) {
        if visited.contains(taskID) { return }
        var nextVisited = visited
        nextVisited.insert(taskID)
        // Top-down: stop descendants first so they don't keep producing
        // engine-state transitions that fire awaiter callbacks against
        // already-cancelling continuations.
        for child in childTaskIDs(of: taskID) {
            stopEngineForTask(child, visited: nextVisited)
        }
        stopEngine(for: taskID)
        llmExecutionService.cancelExecutions(forTaskID: taskID)
    }

    /// Protocol shim — the orchestrator's existing `answerSupervisorQuestion(stepID:taskID:...)`
    /// has a richer signature with attachment finalization that delegation doesn't need.
    /// This 3-arg form is what `DelegatedSupervisorAnswerService` calls to deliver the
    /// parent role's answer back into the child task and resume its engine. Without
    /// this resume, the child step would sit at `.needsSupervisorInput` forever after
    /// the answer is set on disk.
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    @discardableResult
    func answerSupervisorQuestion(taskID: Int, stepID: String, answer: String) async -> Bool {
        await answerSupervisorQuestion(stepID: stepID, taskID: taskID, answer: answer)
    }

    // MARK: - Delegation Interrupt (Supervisor-driven abort)

    /// Returns the active delegation child task ID if `roleID` on `taskID`
    /// has an in-flight `delegate_to_team` call. `nil` otherwise.
    func activeDelegationChildID(taskID: Int, roleID: String) -> Int? {
        guard let task = loadedTask(taskID),
              let run = task.runs.last,
              let step = run.steps.first(where: { $0.id == roleID })
        else { return nil }
        return step.activeDelegationChildID
    }

    /// Wakes a delegation handler suspended on `awaitTaskTerminalState` so it
    /// can pause the child engine and surface `text` to the parent role's
    /// next tool-loop iteration. Returns `true` if a waiter was actually
    /// woken (the parent role had an in-flight delegation AND a registered
    /// awaiter); `false` if the role wasn't mid-delegation. The handler
    /// receives `WaitOutcome.parentMessageQueued(text)` and embeds it in a
    /// `paused_by_supervisor` success envelope; the role then chooses one
    /// of `cancel_delegation` / `resume_delegation` / `forward_to_team`.
    ///
    /// This is the path that lets the Supervisor say "the team is looping,
    /// stop it" while `delegate_to_team` is still blocking the parent role.
    /// Without this hook, queued messages for a delegating role would sit
    /// unread until the child finished naturally (or hit the 30-minute
    /// timeout).
    @discardableResult
    func notifyDelegationInterrupt(
        parentTaskID: Int,
        parentRoleID: String,
        text: String
    ) -> Bool {
        guard let childID = activeDelegationChildID(taskID: parentTaskID, roleID: parentRoleID),
              completionAwaiter.hasWaiters(for: childID)
        else { return false }
        completionAwaiter.deliver(taskID: childID, outcome: .parentMessageQueued(text: text))
        return true
    }

    // MARK: - Recursive Removal

    /// Returns the immediate child task IDs of `parentTaskID`, drawn from the
    /// `tasks_index.json` summary so background-only (not currently loaded)
    /// children are still discoverable.
    func childTaskIDs(of parentTaskID: Int) -> [Int] {
        guard let summaries = snapshot?.tasksIndex.tasks else { return [] }
        return summaries.compactMap { $0.parentTaskID == parentTaskID ? $0.id : nil }
    }

    /// Recursively removes a task and all its delegated children from disk and memory.
    /// Engine-stop and queue cleanup happen per-level. Awaiter continuations for any
    /// in-flight `delegate_to_team` handler are released via `cancelAll`.
    func removeTaskRecursively(_ taskID: Int) async {
        await removeTaskRecursively(taskID, visited: [])
    }

    /// Internal recursive variant with a visited-set cycle guard. Mirrors the
    /// guards on `pauseRun` / `resumeRun` / `removeTask` against a corrupted
    /// `tasks_index.json` self-cycle.
    private func removeTaskRecursively(_ taskID: Int, visited: Set<Int>) async {
        if visited.contains(taskID) { return }
        var nextVisited = visited
        nextVisited.insert(taskID)
        // Bottom-up traversal so children are gone before their parent's record is dropped
        // — keeps `childTaskIDs` lookups consistent at every recursion level.
        let children = childTaskIDs(of: taskID)
        for child in children {
            await removeTaskRecursively(child, visited: nextVisited)
        }
        await removeTask(taskID)
    }
}
