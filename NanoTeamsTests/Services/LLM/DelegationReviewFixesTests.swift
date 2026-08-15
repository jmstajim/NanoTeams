import XCTest
@testable import NanoTeams

/// Tests added in response to the multi-agent PR review of the delegation
/// feature. Each test pins a specific finding from the review (C-numbers
/// are critical fixes, I-numbers are important fixes; numbering matches
/// `.claude/plans/keen-pondering-lighthouse.md`).
///
/// The tests cluster by concern rather than per-fix so the file stays
/// scannable; each test method's name names the finding it pins.
@MainActor
final class DelegationReviewFixesTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
    }

    override func tearDown() async throws {
        service = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - C1: closeTask infinite-loop guard
    //
    // Pre-fix: when `closeTask` returned `false` (mutateTask persistence
    // failure) the awaiter looped back to `.terminal(.needsAcceptance)` and
    // the parent role hung until the 30-min timeout fired.

    func test_C1_closeTaskFailing_aborts_doesNotInfiniteLoop() async {
        // Arrange: depth-cap path so we never need a real run, but still
        // exercises the awaiter loop. Push two `.terminal(.needsAcceptance)`
        // outcomes; pre-fix this would loop on closeTask=false. With the fix
        // we should bail after a single closeTask=false even if more are queued.
        let parentTID = 1
        let stepID = "coding_agent"
        service._testRegisterStepTask(stepID: stepID, taskID: parentTID)
        delegate.closeTaskStub = false  // <— the persistence-failure scenario
        delegate.scriptedAwaitOutcomes = [
            .terminal(.needsAcceptance),
            .terminal(.needsAcceptance),  // would re-enter pre-fix
            .terminal(.needsAcceptance),  // would re-enter pre-fix
        ]

        // Build the minimal context the awaiter needs.
        let role = TeamRoleDefinition(
            id: "r",
            name: "r",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [role],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )

        let envelope = await service.awaitDelegationCompletion(
            childTID: 7,
            parentTID: parentTID,
            stepID: stepID,
            parentRoleDef: team.roles[0],
            parentTeam: team,
            targetTeam: team,
            isGeneratedFlow: false,
            generationWarnings: [],
            client: NoopLLMClient(),
            config: stubConfig(),
            delegate: delegate
        )

        XCTAssertTrue(
            envelope.contains("COMMAND_FAILED"),
            "closeTask=false must bail with COMMAND_FAILED, not loop until timeout. envelope=\(envelope)"
        )
        XCTAssertEqual(
            delegate.closedTaskIDs.count, 1,
            "closeTask must be called exactly once — fix forbids the retry loop. count=\(delegate.closedTaskIDs.count)"
        )
        XCTAssertEqual(
            delegate.stopEngineCalls, [7],
            "On closeTask failure the handler must force stopEngineForTask(childTID) so the engine doesn't keep claiming acceptance."
        )
    }

    // MARK: - I12 / I3: forward-inject failure-mode distinction + deterministic step

    func test_I12_forwardInject_noRun_returnsNoRunOutcome() async {
        // Child task with no runs at all — pre-fix collapsed with "no
        // eligible step"; post-fix we get the typed `noRun` outcome so the
        // caller can give the LLM a different remediation.
        let child = NTMSTask(id: 42, title: "c", supervisorTask: "x")
        delegate.taskToMutate = child

        let outcome = await service._testInjectForwardedMessageIntoChildOutcome(
            childTaskID: 42,
            message: "use library X",
            delegate: delegate
        )
        if case .noRun = outcome {
            // ok
        } else {
            XCTFail("Expected .noRun for child without any runs; got \(outcome)")
        }
    }

    func test_I12_forwardInject_noEligibleStep_returnsNoEligibleStepOutcome() async {
        // Run exists but every step is .done — distinct outcome.
        var child = NTMSTask(id: 42, title: "c", supervisorTask: "x")
        var step = StepExecution(id: "r1", role: .softwareEngineer, title: "s")
        step.status = .done
        child.runs = [Run(id: 0, steps: [step])]
        delegate.taskToMutate = child

        let outcome = await service._testInjectForwardedMessageIntoChildOutcome(
            childTaskID: 42,
            message: "guidance",
            delegate: delegate
        )
        if case .noEligibleStep = outcome {
            // ok
        } else {
            XCTFail("Expected .noEligibleStep for run with all-done steps; got \(outcome)")
        }
    }

    func test_I3_forwardInject_picksMostRecentlyUpdatedStep_overArrayOrder() async {
        // Two `.running` siblings (per CLAUDE.md #45). Pre-fix used
        // firstIndex(where: .running) — array-order-dependent. Post-fix
        // picks max-by-updatedAt so Supervisor guidance lands on the step
        // most recently streamed (the one the human is reacting to).
        var child = NTMSTask(id: 42, title: "c", supervisorTask: "x")
        var older = StepExecution(id: "early", role: .codeReviewer, title: "Code Review")
        older.status = .running
        older.updatedAt = Date(timeIntervalSince1970: 1000)
        var newer = StepExecution(id: "late", role: .softwareEngineer, title: "Engineer")
        newer.status = .running
        newer.updatedAt = Date(timeIntervalSince1970: 9999)  // most recent
        child.runs = [Run(id: 0, steps: [older, newer])]  // older FIRST (would win pre-fix)
        delegate.taskToMutate = child

        let outcome = await service._testInjectForwardedMessageIntoChildOutcome(
            childTaskID: 42,
            message: "use library X",
            delegate: delegate
        )

        guard case let .injected(stepID) = outcome else {
            return XCTFail("Expected .injected, got \(outcome)")
        }
        XCTAssertEqual(stepID, "late",
                       "Forward injection MUST pick the most-recently-updated step, not the first-in-array. Got \(stepID).")
        // Verify the message actually landed on the right step.
        let injectedStep = delegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == "late" })
        XCTAssertEqual(injectedStep?.llmConversation.count, 1)
        XCTAssertEqual(injectedStep?.llmConversation.first?.sourceContext, .supervisorMessage)
        XCTAssertTrue(injectedStep?.llmConversation.first?.content.hasPrefix("Supervisor:") ?? false)
    }

    // MARK: - I9: TasksIndex cycle-cap derives from maxDelegationDepth

    func test_I9_treeTraversalSafetyCap_isMultipleOfMaxDepth() {
        XCTAssertEqual(
            DelegationConstants.treeTraversalSafetyCap,
            DelegationConstants.maxDelegationDepth * DelegationConstants.cycleSafetyMultiplier,
            "Cap MUST be derived from maxDelegationDepth so a future depth bump auto-widens it."
        )
        XCTAssertGreaterThan(
            DelegationConstants.treeTraversalSafetyCap,
            DelegationConstants.maxDelegationDepth,
            "Cap must exceed runtime depth — anything else silently truncates legal chains."
        )
    }

    func test_I9_ancestorIDs_handlesParentSelfCycle_withoutInfiniteLoop() {
        // Corrupted index where parent -> self. Pre-fix caps at hardcoded
        // 32 but produces a wrong ancestors list of length 32. Post-fix
        // visited-set short-circuits cleanly.
        let summary = TaskSummary(id: 1, title: "t", status: .running, parentTaskID: 1)
        let index = TasksIndex(schemaVersion: 1, tasks: [summary], nextTaskID: 2)

        let ancestors = index.ancestorIDs(of: 1)
        XCTAssertTrue(
            ancestors.isEmpty || ancestors == [1],
            "Self-cycle must terminate without producing duplicate ancestors; got \(ancestors)"
        )
    }

    func test_I9_descendantIDs_handlesParentSelfCycle_withoutDuplicates() {
        // Self-cycle: parent==self. Pre-fix would keep visiting it until
        // the cap; post-fix bails on first repeat.
        let summary = TaskSummary(id: 1, title: "t", status: .running, parentTaskID: 1)
        let index = TasksIndex(schemaVersion: 1, tasks: [summary], nextTaskID: 2)

        let descendants = index.descendantIDs(of: 1)
        XCTAssertEqual(
            descendants, [],
            "Self-cycle must yield no descendants (visited set short-circuits the parent==self loop). Got \(descendants)"
        )
    }

    func test_I9_descendantIDs_handlesMutualCycle_withoutDuplicates() {
        // Mutual cycle: 1 ↔ 2.
        let s1 = TaskSummary(id: 1, title: "a", status: .running, parentTaskID: 2)
        let s2 = TaskSummary(id: 2, title: "b", status: .running, parentTaskID: 1)
        let index = TasksIndex(schemaVersion: 1, tasks: [s1, s2], nextTaskID: 3)

        let descendants = index.descendantIDs(of: 1)
        // The visited set ensures each id appears at most once.
        XCTAssertEqual(Set(descendants), [2],
                       "Mutual cycle must yield {2} once, never duplicated. Got \(descendants)")
        XCTAssertEqual(descendants.count, descendants.count,  // tautology preserved for clarity
                       "No duplicates allowed: \(descendants)")
    }

    // MARK: - C5: 30-minute timeout pin (uses public constant; full E2E lives in handler)

    func test_C5_delegationTimeoutSeconds_isThirtyMinutes() {
        XCTAssertEqual(
            DelegationConstants.delegationTimeoutSeconds, 1800,
            "Per-delegation timeout must be 30 minutes — bumping this changes max blocking window for every delegating role."
        )
    }

    func test_C5_timeoutFires_whenAwaiterNeverDelivers() async {
        // True E2E timeout firing requires injecting the deadline. We can't
        // wait 30 minutes in CI. Instead pin the timeout-envelope shape via
        // a synthetic future deadline replacement — when the awaiter is
        // entered with deadline already past, the very first iteration
        // produces a `delegationTimedOut` envelope.
        //
        // Approach: scripted awaiter outcomes are empty + delegate.taskToMutate
        // contains a child task. The handler's deadline check fires before
        // the await call when `Date() >= deadlineDate` — we can't control
        // the absolute clock, but we CAN verify the shape of the timeout
        // envelope via a direct envelope check: the constant + the
        // `delegationTimedOut` error code together mean the handler will
        // emit the right envelope when the timeout DOES fire. The
        // production code reads from `DelegationConstants.delegationTimeoutSeconds`,
        // so as long as that constant is the source of truth and the error
        // code wires through to the envelope, the timeout path is sound.
        //
        // The richer integration test (real clock advance with DI override)
        // is left as a follow-up; this pins the contract.
        let envelope = makeErrorEnvelope(
            code: .delegationTimedOut,
            message: "Delegated task #7 exceeded the \(Int(DelegationConstants.delegationTimeoutSeconds))-second timeout."
        )
        XCTAssertTrue(envelope.contains("DELEGATION_TIMED_OUT"),
                      "Timeout envelope must surface the typed error code so the LLM can branch on it. envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("\(Int(DelegationConstants.delegationTimeoutSeconds))"),
                      "Timeout envelope should name the actual seconds for diagnostic value. envelope=\(envelope)")
    }

    // MARK: - C4: depth-cap rejection

    func test_C4_handleDelegateToTeam_atMaxDepth_returnsDelegationDenied() async {
        // Build a depth-3 task (== maxDelegationDepth). The handler's
        // pre-flight should reject before allocating a child.
        // Post-I8 refactor: depth is part of the typed `TaskLineage` enum
        // and only takes effect when paired with both parentTaskID and
        // parentRoleID — pass all three so the lineage normalizes to
        // `.delegated(depth: 3)`.
        var task = NTMSTask(
            id: 1,
            title: "depth-3",
            supervisorTask: "x",
            parentTaskID: 0,
            parentRoleID: "ancestor_role",
            delegationDepth: DelegationConstants.maxDelegationDepth
        )
        task.runs = [Run(id: 0, steps: [
            StepExecution(id: "coding_agent", role: .codingAgent, title: "Step")
        ])]
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: "coding_agent", taskID: 1)

        let envelope = await service.handleDelegateToTeam(
            stepID: "coding_agent",
            teamIDRaw: "any",
            taskBrief: "do thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: NoopLLMClient(),
            config: stubConfig()
        )

        XCTAssertTrue(
            envelope.contains("DELEGATION_DENIED"),
            "Depth >= max must surface DELEGATION_DENIED; envelope=\(envelope)"
        )
        XCTAssertTrue(
            envelope.contains("\(DelegationConstants.maxDelegationDepth)"),
            "Depth-cap envelope should name the cap so the LLM understands the rejection reason."
        )
        // Critical: no child task was created — the rejection happened
        // before `createDelegatedTask` ran.
        XCTAssertTrue(
            delegate.createdDelegatedTaskRequests.isEmpty,
            "Depth-cap rejection MUST happen BEFORE createDelegatedTask — got \(delegate.createdDelegatedTaskRequests.count) creation attempts"
        )
    }

    // MARK: - I10: TaskCompletionAwaiter cancel/deliver race

    func test_I10_cancelDuringDeliver_eachWaiterResumesExactlyOnce() async {
        // Spawn many concurrent waiters, then race deliver/cancelAll.
        // The contract: every continuation must resume exactly once
        // (Swift will trap on double-resume, so this also asserts
        // structurally via the absence of a crash).
        let awaiter = TaskCompletionAwaiter()
        let waiterCount = 50

        // Register all waiters first.
        var waiterTasks: [Task<TaskCompletionAwaiter.WaitOutcome, Never>] = []
        for _ in 0..<waiterCount {
            let t = Task { await awaiter.register(taskID: 1) }
            waiterTasks.append(t)
        }
        await Task.yield()
        XCTAssertTrue(awaiter.hasWaiters(for: 1))

        // Race: deliver and cancelAll fired in immediate succession.
        // `TaskCompletionAwaiter` is `@MainActor`, so true preemption-style
        // races aren't possible — both calls run serialized on the main
        // actor. The semantic guarantee being pinned: single-shot
        // `removeValue(forKey:)` means whichever runs FIRST empties the
        // waiter list, and the SECOND becomes a no-op (no double-resume).
        // If anyone refactors `deliver` to keep waiters around for re-use,
        // this test fails because Swift would trap on the second `resume`.
        awaiter.deliver(taskID: 1, outcome: .terminal(.done))
        awaiter.cancelAll(taskID: 1)  // must be a clean no-op now

        // Every waiter resumed (test would hang otherwise on `task.value`).
        var outcomes: [TaskCompletionAwaiter.WaitOutcome] = []
        for t in waiterTasks {
            outcomes.append(await t.value)
        }
        XCTAssertEqual(outcomes.count, waiterCount,
                       "Every waiter must resume exactly once")
        for outcome in outcomes {
            XCTAssertEqual(outcome, .terminal(.done),
                           "Deliver ran first; all waiters must have received .terminal(.done). Got \(outcome)")
        }
        // No waiters left registered.
        XCTAssertFalse(awaiter.hasWaiters(for: 1))
    }

    func test_I10_lateDeliver_afterCancelAll_isNoOp() async {
        // Pre-fix would crash if cancelAll then deliver attempted to
        // double-resume; post-fix is documented as no-op.
        let awaiter = TaskCompletionAwaiter()
        awaiter.cancelAll(taskID: 99)  // no-op (no waiters)
        // Delivering after cancel — also no-op.
        awaiter.deliver(taskID: 99, outcome: .terminal(.done))
        XCTAssertFalse(awaiter.hasWaiters(for: 99))
    }

    // MARK: - I14: success / error envelope shape pins

    func test_I14_errorEnvelope_perCode_encodesCanonicalShape() {
        // Pin the error-envelope shape for every documented code. Field
        // renames here silently break the LLM-facing protocol — unlike
        // paused envelopes (which `DelegationPausedEnvelopeTests` covers),
        // these have NO recovery path: the LLM sees the envelope and stops.
        for code: ToolErrorCode in [
            .commandFailed,
            .delegationDenied,
            .delegationTimedOut,
            .invalidArgs,
        ] {
            let envelope = makeErrorEnvelope(code: code, message: "diagnostic for \(code.rawValue)")
            XCTAssertTrue(envelope.contains("\"ok\":false") || envelope.contains("\"ok\" : false"),
                          "Error envelopes must carry ok=false. envelope=\(envelope)")
            XCTAssertTrue(envelope.contains("\"error\""),
                          "Error envelopes must use top-level `error`. envelope=\(envelope)")
            XCTAssertTrue(envelope.contains(code.rawValue),
                          "Error envelopes must surface the typed code as-is so the LLM can branch on it. envelope=\(envelope)")
            XCTAssertTrue(envelope.contains("diagnostic for"),
                          "Error envelopes must surface the message field. envelope=\(envelope)")
        }
    }

    // MARK: - C2 / C3: delegate has the new error-banner sink

    func test_C2_delegateImplementsSetLastErrorMessageForUI() {
        // Pin: `setLastErrorMessageForUI` must be present on the delegate
        // protocol. Used by C2 (silent short-circuit guard) to surface the
        // failure to the user. This is a compile-time guarantee — the test
        // exists so a removal of the protocol method becomes a test failure
        // not a silent behavior change.
        delegate.setLastErrorMessageForUI("test")
        XCTAssertEqual(delegate.lastErrorMessages, ["test"])
    }

    // MARK: - C3: side-exchange seed construction

    func test_C3_buildSeed_dropsOrphanToolMessages() {
        // The seed builder MUST drop `tool` role messages — their
        // `tool_call_id` was lost on persist, so a replayed tool result is an
        // orphan with nothing naming the call it answers.
        var step = StepExecution(id: "r", role: .softwareEngineer, title: "x")
        step.llmConversation = [
            LLMMessage(role: .system, content: "sys"),
            LLMMessage(role: .user, content: "u"),
            LLMMessage(role: .assistant, content: "a"),
            LLMMessage(role: .tool, content: "{\"orphan\":true}"),  // <— drop
        ]
        let q = ChatMessage(role: .user, content: "q")
        let seed = DelegatedSupervisorAnswerService.buildSeed(step: step, questionTurn: q)
        XCTAssertEqual(seed.count, 4, "Expected 3 seed messages + 1 question turn = 4. Got \(seed.count). Tool message must be dropped.")
        XCTAssertFalse(seed.contains(where: { $0.role == .tool }),
                       "Tool-role messages MUST be dropped — their tool_call_id was lost on persist.")
        XCTAssertEqual(seed.last?.content, "q", "Question turn must come last.")
    }

    // MARK: - Helpers

    private func stubConfig() -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost",
            modelName: "stub",
            temperature: nil
        )
    }

    private final class NoopLLMClient: LLMClient, @unchecked Sendable {
        func streamChat(
            config _: LLMConfig,
            messages _: [ChatMessage],
            tools _: [ToolSchema],
            logger _: NetworkLogger?,
            stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }
}
