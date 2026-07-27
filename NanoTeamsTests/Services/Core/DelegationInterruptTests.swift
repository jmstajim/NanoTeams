import XCTest
@testable import NanoTeams

/// Pins the Supervisor-driven delegation-interrupt path: queueing a chat
/// message for a role that's currently mid-`delegate_to_team` must wake the
/// suspended handler with `WaitOutcome.parentMessageQueued(text)` so it can
/// pause the child engine and surface the message text in a
/// `paused_by_supervisor` success envelope on the parent role's next iteration.
///
/// This is the "team is looping, stop it" feedback loop. Without the wake
/// hook, queued messages for a delegating role would sit unread until the
/// child engine reached terminal state on its own (or hit the 30-minute
/// `delegationTimeoutSeconds` cap).
@MainActor
final class DelegationInterruptTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        TestOrchestrator.make()
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-delegation-interrupt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - activeDelegationChildID lookup

    func testActiveDelegationChildID_noStep_returnsNil() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        XCTAssertNil(
            store.activeDelegationChildID(taskID: taskID, roleID: "absent_role"),
            "Lookup must return nil when the role has no step on the latest run"
        )
    }

    func testActiveDelegationChildID_stepWithoutMarker_returnsNil() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        // Seed a step with no `activeDelegationChildID`.
        let mutated = await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [])
            run.steps.append(StepExecution(
                id: "role_a",
                role: .softwareEngineer,
                title: "Step"
            ))
            task.runs.append(run)
        }
        XCTAssertTrue(mutated)
        XCTAssertNil(
            store.activeDelegationChildID(taskID: taskID, roleID: "role_a"),
            "Lookup must return nil when the step has no in-flight delegation"
        )
    }

    func testActiveDelegationChildID_stepWithMarker_returnsChildID() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        let mutated = await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [])
            run.steps.append(StepExecution(
                id: "role_a",
                role: .softwareEngineer,
                title: "Step",
                activeDelegationChildID: 99
            ))
            task.runs.append(run)
        }
        XCTAssertTrue(mutated)
        XCTAssertEqual(
            store.activeDelegationChildID(taskID: taskID, roleID: "role_a"),
            99,
            "Lookup must return the child id stamped on the delegating step"
        )
    }

    // MARK: - notifyDelegationInterrupt

    /// Fires-and-returns-false when the role isn't mid-delegation. Caller
    /// (`QuickCaptureController.queueChatMessage`) uses the return value to
    /// decide whether to skip `tryFlushQueuedMessages` (interrupt path) or
    /// fall through to the normal queue-flush path.
    func testNotifyDelegationInterrupt_noActiveDelegation_returnsFalse() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        let result = store.notifyDelegationInterrupt(
            parentTaskID: taskID,
            parentRoleID: "absent_role",
            text: "stop"
        )
        XCTAssertFalse(result,
                       "Interrupt must be a no-op when the role has no in-flight delegation")
    }

    /// Fires-and-returns-false when there's a delegation marker but no
    /// awaiter actually registered (e.g. handler hasn't called
    /// `awaitTaskTerminalState` yet, or the engine has already torn down).
    /// Without this guard we'd silently lose the `deliver` call.
    func testNotifyDelegationInterrupt_markerSetButNoAwaiter_returnsFalse() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [])
            run.steps.append(StepExecution(
                id: "role_a",
                role: .softwareEngineer,
                title: "Step",
                activeDelegationChildID: 42
            ))
            task.runs.append(run)
        }

        // No `awaitTaskTerminalState(42)` has been called, so the awaiter
        // registry is empty for child id 42.
        XCTAssertFalse(
            store.completionAwaiter.hasWaiters(for: 42),
            "Test setup invariant: no waiter registered yet"
        )

        let result = store.notifyDelegationInterrupt(
            parentTaskID: taskID,
            parentRoleID: "role_a",
            text: "stop"
        )
        XCTAssertFalse(result,
                       "Interrupt must be a no-op when nobody is suspended on the child's awaiter")
    }

    /// Happy path: marker set, handler is suspended on the child's awaiter,
    /// interrupt wakes it with the message text. The handler's resume
    /// continuation receives `.parentMessageQueued(text:)` — translation
    /// into a `delegationInterrupted` envelope happens inside
    /// `handleDelegateToTeam`'s switch and is exercised by the integration
    /// path (covered by manual reproduction in the screenshot scenario).
    func testNotifyDelegationInterrupt_wakesSuspendedHandler() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [])
            run.steps.append(StepExecution(
                id: "role_a",
                role: .softwareEngineer,
                title: "Step",
                activeDelegationChildID: 42
            ))
            task.runs.append(run)
        }

        // Spawn a "handler" task that awaits the child's terminal state.
        // It must be detached from the test's sync flow so the interrupt
        // call below can preempt it.
        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            let outcome = await store.completionAwaiter.register(taskID: 42)
            outcomeBox.value = outcome
        }

        // Yield so the handler task gets a chance to register before we
        // try to deliver. Without this, `notifyDelegationInterrupt` could
        // run before `register` and find no waiters.
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: 42), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        XCTAssertTrue(
            store.completionAwaiter.hasWaiters(for: 42),
            "Awaiter must have registered before the interrupt fires"
        )

        let delivered = store.notifyDelegationInterrupt(
            parentTaskID: taskID,
            parentRoleID: "role_a",
            text: "team is looping, stop it"
        )
        XCTAssertTrue(delivered,
                      "Interrupt must report success when it wakes a registered awaiter")

        await handlerTask.value
        guard let outcome = outcomeBox.value else {
            return XCTFail("Handler did not resume after interrupt")
        }
        XCTAssertEqual(outcome, .parentMessageQueued(text: "team is looping, stop it"),
                       "Handler must receive the exact text the Supervisor queued, so the delegationInterrupted envelope can carry it to the parent role's next iteration")
    }

    // MARK: - Queue cleanup on successful interrupt (regression)

    /// Pin: when `queueChatMessage` successfully wakes a mid-delegation
    /// handler, the just-appended message MUST be removed from
    /// `formState.queuedChatMessages` before the controller returns.
    ///
    /// Pre-fix bug: the controller appended to the queue, called
    /// `notifyDelegationInterrupt` (which embedded the text in the
    /// `paused_by_supervisor` envelope), and returned without removing the
    /// queue entry. The role's next tool-loop iteration then consumed the
    /// same message via `injectQueuedSupervisorMessage` — delivering the
    /// Supervisor's "stop the team" guidance twice (once embedded in the
    /// envelope, once as a fresh user turn).
    func testQueueChatMessage_onSuccessfulInterrupt_removesQueueEntry() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        let childID = 99
        await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [])
            run.steps.append(StepExecution(
                id: "role_a",
                role: .softwareEngineer,
                title: "Step",
                activeDelegationChildID: childID
            ))
            task.runs.append(run)
        }

        // Spawn the handler so an awaiter is actually registered for childID.
        let outcomeBox = OutcomeBox()
        let handlerTask = Task { @MainActor in
            outcomeBox.value = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: childID),
                      "Test setup invariant: awaiter must be registered before queueing")

        // Wire a fresh controller to the store. Use a fresh formState so the
        // assertion isn't muddied by any pre-existing queue entries.
        let formState = QuickCaptureFormState()
        let controller = QuickCaptureController(formState: formState)
        controller.store = store

        let queued = controller.queueChatMessage(
            text: "team is looping, stop it",
            attachments: [],
            clippedTexts: [],
            taskID: taskID,
            targetRoleID: "role_a"
        )
        XCTAssertTrue(queued,
                      "queueChatMessage must accept a valid non-empty payload")

        XCTAssertFalse(formState.hasQueuedMessage(for: taskID),
                       "Successful delegation interrupt must remove the just-appended message — otherwise the role's next iteration's `injectQueuedSupervisorMessage` consumes it again, double-delivering the Supervisor's text (once via the paused envelope, once as a fresh user turn).")

        await handlerTask.value
        XCTAssertEqual(outcomeBox.value, .parentMessageQueued(text: "team is looping, stop it"),
                       "Awaiter must still resume with the exact text — the queue removal is a side effect, not a substitution for delivery")
    }

    /// Counter-test: when no awaiter is registered (race window between
    /// marker-set and awaiter-register, or role mid-delegation but engine
    /// torn down), `notifyDelegationInterrupt` returns false and the queue
    /// MUST retain the message — otherwise we'd silently lose the
    /// Supervisor's input.
    func testQueueChatMessage_onUnsuccessfulInterrupt_keepsQueueEntry() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        let childID = 42
        await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [])
            run.steps.append(StepExecution(
                id: "role_a",
                role: .softwareEngineer,
                title: "Step",
                activeDelegationChildID: childID
            ))
            task.runs.append(run)
        }
        // No awaiter registered for childID — `notifyDelegationInterrupt` returns false.

        let formState = QuickCaptureFormState()
        let controller = QuickCaptureController(formState: formState)
        controller.store = store

        let queued = controller.queueChatMessage(
            text: "stop",
            attachments: [],
            clippedTexts: [],
            taskID: taskID,
            targetRoleID: "role_a"
        )
        XCTAssertTrue(queued)

        XCTAssertEqual(formState.queuedMessages(for: taskID).map(\.text), ["stop"],
                       "When the interrupt path returns false (no waiter), the message must remain queued — the normal flush path will deliver it later")
    }

    // MARK: - Helpers

    /// Box for capturing an awaited value across actor boundaries without
    /// dealing with `inout` capture in `@MainActor` closures.
    @MainActor
    private final class OutcomeBox {
        var value: TaskCompletionAwaiter.WaitOutcome?
    }
}
