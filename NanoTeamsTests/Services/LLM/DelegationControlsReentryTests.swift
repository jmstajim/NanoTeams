import XCTest
@testable import NanoTeams

// File-scope immutable fixtures. Deliberately NOT `static let` on the
// `@MainActor` test class: several helpers below use them as default arguments,
// and a default-argument expression is evaluated in a nonisolated context.
// Immutable globals of `Sendable` type are safe to read from anywhere.
private let ntParentTID = 1
private let ntChildTID = 77
private let ntStepID = "coding_agent_step"
private let ntChildStepID = "child_engineer"
private let ntParentTeamID: NTMSID = "parent-team-id"
private let ntChildTeamID: NTMSID = "child-team-id"
private let ntParentTeamName = "Parent Team"
private let ntChildTeamName = "Child Team"

/// Covers the *re-entry* half of the Pause-and-Decide control plane —
/// `handleResumeDelegation` / `handleForwardToTeam` and the private
/// `makeReentryContext` they both funnel through.
///
/// `DelegationFollowupHandlersTests` already pins the hallucinated-child-id arm
/// for all three verbs plus the cancel happy path; `DelegationPausedEnvelopeTests`
/// pins the paused envelope and the `.running`-step injection shape;
/// `DelegationReviewFixesTests` pins the two typed injection failure modes and
/// the max-by-`updatedAt` tie-break. This file deliberately repeats none of
/// those. What it adds:
///
///  * every `makeReentryContext` nil arm, each asserted through the one
///    externally-visible consequence that matters — the child engine is **not**
///    resumed. A re-entry that resumed a child it could not resolve would
///    restart a team the parent can no longer await, and the parent would then
///    block for the full 30-minute timeout.
///  * the ordering contract inside `handleForwardToTeam`: context resolution
///    and message injection both happen BEFORE `resumeRun`, so a failure in
///    either must leave the child paused rather than running-without-guidance.
///  * `live ?? pending` step targeting (a `.paused` step is live; a newer
///    `.pending` sibling must not outrank an older live one).
///  * `clearActiveDelegation` on cancel preserving the append-only history.
@MainActor
final class DelegationControlsReentryTests: XCTestCase {

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

    // MARK: - resume_delegation: happy path

    /// Full re-entry: validated child id → context resolved → child engine
    /// un-paused → awaiter re-entered on the CHILD task → terminal envelope.
    ///
    /// The `team` field is the load-bearing assertion: it comes from
    /// `context.childTeam`, i.e. the team re-resolved for the *child*, not the
    /// parent team that is also in scope at that call site. Swapping the two
    /// would still compile and still return a success envelope.
    func testResumeDelegation_happyPath_resumesChildAndReEntersAwaiterOnChild() async throws {
        arrangeLiveDelegation()
        delegate.scriptedAwaitOutcomes = [.terminal(.done)]

        let envelope = await service.handleResumeDelegation(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertEqual(delegate.resumeRunCalls, [ntChildTID],
                       "resume_delegation must un-pause exactly the validated child engine")
        XCTAssertEqual(delegate.awaitedTaskIDs, [ntChildTID],
                       "The re-entered awaiter must poll the CHILD task — awaiting the parent would block forever")
        XCTAssertTrue(delegate.createdDelegatedTaskRequests.isEmpty,
                      "Re-entry must never allocate a second child task; it resumes the one already in flight")

        let dict = try parseJSON(envelope)
        XCTAssertEqual(dict["ok"] as? Bool, true,
                       "A terminal .done after resume is a normal success, not a failure. envelope=\(envelope)")
        let data = try XCTUnwrap(dict["data"] as? [String: Any])
        XCTAssertEqual(data["child_task_id"] as? Int, ntChildTID)
        XCTAssertEqual(data["team"] as? String, ntChildTeamName,
                       "Envelope must name the CHILD team resolved by makeReentryContext, not the parent team that is also in scope")
    }

    /// `makeReentryContext` prefers `childTask.generatedTeam` over the snapshot
    /// lookup. A delegation that went through the `"generated"` sentinel has no
    /// entry in `workFolder.teams` at all, so the `??` left branch is the ONLY
    /// way its resume can resolve a team.
    func testResumeDelegation_childTeamLivesInGeneratedSlot_stillResolves() async throws {
        let generated = makeTeam(id: "generated_gen_abc123", name: "Generated Child")
        // Deliberately absent from the snapshot AND `preferredTeamID` is nil —
        // only the generatedTeam slot can satisfy the lookup.
        arrangeLiveDelegation(
            childPreferredTeamID: nil,
            childGeneratedTeam: generated,
            teamsInSnapshot: [makeParentTeam()]
        )
        delegate.scriptedAwaitOutcomes = [.terminal(.done)]

        let envelope = await service.handleResumeDelegation(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertEqual(delegate.resumeRunCalls, [ntChildTID])
        let dict = try parseJSON(envelope)
        let data = try XCTUnwrap(dict["data"] as? [String: Any])
        XCTAssertEqual(data["team"] as? String, "Generated Child",
                       "A generated child's team lives only on the task; the snapshot lookup can never find it. envelope=\(envelope)")
    }

    // MARK: - resume_delegation: makeReentryContext nil arms

    /// Parentage guard: the child's recorded `parentTaskID` must match the
    /// suspended handler's parent. A mismatch means the task tree moved under
    /// us (recursive removal, reload after corruption) — re-entering would
    /// resume an engine belonging to a different tree.
    func testResumeDelegation_childRecordsADifferentParent_refusesAndDoesNotResume() async {
        arrangeLiveDelegation(childParentTaskID: 999)

        let envelope = await service.handleResumeDelegation(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"),
                      "A parentage mismatch must fail loudly, not operate on the wrong tree. envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("resume"),
                      "Diagnostic must name the verb that failed so the LLM knows which follow-up to abandon. envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty,
                      "An unresolvable re-entry MUST NOT resume the child — the parent would then be blocked on an engine it never awaits")
    }

    /// The child task fell out of memory (evicted / removed). Nothing to
    /// re-enter; the handler must say so rather than resuming blindly.
    func testResumeDelegation_childTaskNotLoaded_refusesAndDoesNotResume() async {
        arrangeLiveDelegation()
        delegate.taskToMutate = nil  // loadedTask(childTID) → nil

        let envelope = await service.handleResumeDelegation(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("\(ntChildTID)"),
                      "Diagnostic should name the child id so the user can find the orphan. envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
    }

    /// Child is loaded and correctly parented, but its team is gone: no
    /// `generatedTeam`, and `preferredTeamID` no longer matches anything in the
    /// snapshot (team deleted while the delegation was paused).
    func testResumeDelegation_childTeamDeletedFromSnapshot_refusesAndDoesNotResume() async {
        arrangeLiveDelegation(
            childPreferredTeamID: "team-that-was-deleted",
            teamsInSnapshot: [makeParentTeam()]
        )

        let envelope = await service.handleResumeDelegation(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty,
                      "Resuming a child whose roster no longer exists would start an engine that can only transition to .failed")
    }

    /// The delegating role is no longer in the parent team (renamed / deleted
    /// from the team editor while the delegation was paused).
    func testResumeDelegation_initiatingRoleMissingFromParentTeam_refuses() async {
        arrangeLiveDelegation()

        let envelope = await service.handleResumeDelegation(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            // No role in the parent team resolves this identifier under any of
            // `findRole`'s branches (id / systemRoleID / name / normalized).
            initiatingRole: .custom(id: "role_removed_from_team"),
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
    }

    /// No snapshot at all → `resolveTeam(task:)` returns nil → the context
    /// cannot be built. Exercises the FIRST guard of `makeReentryContext`.
    func testResumeDelegation_noWorkFolderSnapshot_refusesAndDoesNotResume() async {
        arrangeLiveDelegation()
        delegate.snapshot = nil

        let envelope = await service.handleResumeDelegation(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
    }

    // MARK: - resume_delegation: pre-context guards

    /// Role has no in-flight delegation at all (already cancelled / already
    /// completed). `activeDelegationChildID` returns nil, so the id can't be
    /// validated and the call must be rejected. The *mismatch* case is already
    /// pinned in `DelegationFollowupHandlersTests`; this is the nil case.
    func testResumeDelegation_noActiveDelegation_rejectsAsInvalidArgs() async {
        service._testRegisterStepTask(stepID: ntStepID, taskID: ntParentTID)
        // No `activeDelegationChildStub` entry.
        installSnapshot(teams: [makeParentTeam(), makeChildTeam()])
        delegate.taskToMutate = makeChildTask()

        let envelope = await service.handleResumeDelegation(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("INVALID_ARGS"),
                      "Resuming with no in-flight delegation must be INVALID_ARGS, not a silent resumeRun. envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
    }

    /// The liveness barrier fires before any delegation validation: an orphaned
    /// call from a torn-down step must never reach the engine.
    func testResumeDelegation_unregisteredStep_rejectedByLivenessBarrier() async {
        // Everything else is arranged for success — only the execution state is
        // missing, so the barrier is the sole reason for the rejection.
        delegate.activeDelegationChildStub["\(ntParentTID):\(ntStepID)"] = ntChildTID
        installSnapshot(teams: [makeParentTeam(), makeChildTeam()])
        delegate.taskToMutate = makeChildTask()

        let envelope = await service.handleResumeDelegation(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("no task context"),
                      "A torn-down step must be rejected by the liveness barrier. envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
        XCTAssertTrue(delegate.awaitedTaskIDs.isEmpty,
                      "A rejected re-entry must not register an awaiter — that would hang for the full timeout")
    }

    /// Orchestrator torn down (the delegate reference is weak). Every handler
    /// opens with this guard.
    func testResumeDelegation_delegateDetached_returnsCommandFailed() async {
        arrangeLiveDelegation()
        service.delegate = nil

        let envelope = await service.handleResumeDelegation(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("delegate unavailable"), "envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
    }

    // MARK: - forward_to_team: happy path

    /// The whole forward pipeline in order: validate → resolve context → inject
    /// the Supervisor turn into the child's live step → resume → re-enter the
    /// awaiter.
    func testForwardToTeam_happyPath_injectsResumesAndReEnters() async throws {
        arrangeLiveDelegation()
        delegate.scriptedAwaitOutcomes = [.terminal(.done)]

        let envelope = await service.handleForwardToTeam(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            message: "use library X instead",
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        // Injection landed on the child's live step, in the shape the child
        // team's tool loop and the activity feed both key on.
        let injected = try XCTUnwrap(
            delegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == ntChildStepID }),
            "The child's live step must still be present after the forward"
        )
        XCTAssertEqual(injected.llmConversation.count, 1,
                       "Exactly one Supervisor turn must be appended per forward_to_team call")
        let message = try XCTUnwrap(injected.llmConversation.first)
        XCTAssertEqual(message.role, .user,
                       "Injected turn MUST use the .user wire role — .supervisor is not a chat-protocol role")
        XCTAssertEqual(message.sourceContext, .supervisorMessage)
        XCTAssertTrue(message.content.hasPrefix(MessageSourceContext.supervisorMessagePrefix),
                      "Content must carry the canonical prefix so the child role can attribute the turn. content=\(message.content)")
        XCTAssertTrue(message.content.contains("use library X instead"),
                      "The forwarded text must survive verbatim")

        XCTAssertEqual(delegate.resumeRunCalls, [ntChildTID],
                       "The child engine must be un-paused after the guidance lands")
        XCTAssertEqual(delegate.awaitedTaskIDs, [ntChildTID],
                       "forward_to_team re-enters the awaiter so the parent keeps blocking on the child")

        let dict = try parseJSON(envelope)
        XCTAssertEqual(dict["ok"] as? Bool, true, "envelope=\(envelope)")
        let data = try XCTUnwrap(dict["data"] as? [String: Any])
        XCTAssertEqual(data["team"] as? String, ntChildTeamName)
    }

    // MARK: - forward_to_team: injection failures must abort BEFORE resume

    /// The child engine wedged before producing its first run. Reported with
    /// the retry-shaped diagnostic — and critically, the child is NOT resumed:
    /// resuming after a dropped message means the team runs on without the
    /// correction the Supervisor just sent.
    func testForwardToTeam_childHasNoRun_reportsWedgedDiagnostic_andDoesNotResume() async {
        arrangeLiveDelegation(childHasRun: false)

        let envelope = await service.handleForwardToTeam(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            message: "use library X",
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("no run yet"),
                      "The no-run mode must be distinguishable from no-eligible-step — its remedy is different. envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty,
                      "A dropped forward MUST NOT resume the child — the team would run on without the correction")
        XCTAssertTrue(delegate.awaitedTaskIDs.isEmpty,
                      "A failed forward must return immediately, never block on the awaiter")
    }

    /// Run exists but every step has finished: the child terminated between the
    /// pause and the forward. Distinct diagnostic, still no resume.
    func testForwardToTeam_noEligibleStep_reportsDistinctDiagnostic_andDoesNotResume() async {
        var doneStep = StepExecution(id: ntChildStepID, role: .softwareEngineer, title: "Engineer")
        doneStep.status = .done
        arrangeLiveDelegation(childSteps: [doneStep])

        let envelope = await service.handleForwardToTeam(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            message: "use library X",
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("no working/paused/pending step"),
                      "The terminated-child mode must name what it looked for. envelope=\(envelope)")
        XCTAssertFalse(envelope.contains("no run yet"),
                       "The two injection failure modes must not collapse into one message. envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
    }

    /// Ordering pin: context resolution runs BEFORE injection, so a bad
    /// parentage must leave the child's conversation untouched. If the two were
    /// swapped, a hallucinated / stale child would receive a Supervisor turn
    /// from a tree it does not belong to.
    func testForwardToTeam_parentageMismatch_refusesWithoutInjecting() async {
        arrangeLiveDelegation(childParentTaskID: 999)

        let envelope = await service.handleForwardToTeam(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            message: "use library X",
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("forward"),
                      "Diagnostic must name the failing verb. envelope=\(envelope)")
        let steps = delegate.taskToMutate?.runs.last?.steps ?? []
        XCTAssertFalse(steps.isEmpty, "Precondition: the child still has its step")
        XCTAssertTrue(steps.allSatisfy { $0.llmConversation.isEmpty },
                      "Context resolution MUST precede injection — a mis-parented child must receive nothing")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
    }

    /// Role has no in-flight delegation: reject before touching the child.
    func testForwardToTeam_noActiveDelegation_rejectsWithoutInjecting() async {
        service._testRegisterStepTask(stepID: ntStepID, taskID: ntParentTID)
        installSnapshot(teams: [makeParentTeam(), makeChildTeam()])
        delegate.taskToMutate = makeChildTask()

        let envelope = await service.handleForwardToTeam(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            message: "use library X",
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("INVALID_ARGS"), "envelope=\(envelope)")
        let steps = delegate.taskToMutate?.runs.last?.steps ?? []
        XCTAssertTrue(steps.allSatisfy { $0.llmConversation.isEmpty },
                      "An unvalidated child must never be written to")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
    }

    func testForwardToTeam_unregisteredStep_rejectedByLivenessBarrier() async {
        delegate.activeDelegationChildStub["\(ntParentTID):\(ntStepID)"] = ntChildTID
        installSnapshot(teams: [makeParentTeam(), makeChildTeam()])
        delegate.taskToMutate = makeChildTask()

        let envelope = await service.handleForwardToTeam(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            message: "use library X",
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("no task context"), "envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
    }

    func testForwardToTeam_delegateDetached_returnsCommandFailed() async {
        arrangeLiveDelegation()
        service.delegate = nil

        let envelope = await service.handleForwardToTeam(
            stepID: ntStepID,
            childTaskID: ntChildTID,
            message: "use library X",
            initiatingRole: .codingAgent,
            task: makeParentTask(),
            client: ReentryStubLLMClient(),
            config: makeConfig()
        )

        XCTAssertTrue(envelope.contains("delegate unavailable"), "envelope=\(envelope)")
        XCTAssertTrue(delegate.resumeRunCalls.isEmpty)
    }

    // MARK: - Step targeting: `live ?? pending`

    /// `.paused` is in the LIVE priority set alongside `.running` — a child
    /// paused by the Supervisor interrupt is exactly the state a forward
    /// arrives in, so excluding it would make the common case unreachable.
    func testInjectForwardedMessage_pausedStepIsLive() async {
        var paused = StepExecution(id: "paused_step", role: .softwareEngineer, title: "Engineer")
        paused.status = .paused
        var child = makeChildTask()
        child.runs = [Run(id: 0, steps: [paused])]
        delegate.taskToMutate = child

        let outcome = await service._testInjectForwardedMessageIntoChildOutcome(
            childTaskID: ntChildTID,
            message: "guidance",
            delegate: delegate
        )

        guard case let .injected(stepID) = outcome else {
            return XCTFail("A .paused step is live — forward_to_team's own precondition is a paused child. Got \(outcome)")
        }
        XCTAssertEqual(stepID, "paused_step")
    }

    /// Priority 2: a forward arriving between iterations finds only `.pending`
    /// steps. Without this fallback the guidance would be dropped with a
    /// "child has already finished" diagnostic that is simply false.
    func testInjectForwardedMessage_pendingOnlyChild_usesPendingFallback() async {
        var pending = StepExecution(id: "pending_step", role: .softwareEngineer, title: "Engineer")
        pending.status = .pending
        var child = makeChildTask()
        child.runs = [Run(id: 0, steps: [pending])]
        delegate.taskToMutate = child

        let outcome = await service._testInjectForwardedMessageIntoChildOutcome(
            childTaskID: ntChildTID,
            message: "guidance",
            delegate: delegate
        )

        guard case let .injected(stepID) = outcome else {
            return XCTFail("A run whose only step is .pending must still accept guidance. Got \(outcome)")
        }
        XCTAssertEqual(stepID, "pending_step")
    }

    /// The tie-break is `live ?? pending`, NOT "max updatedAt across all
    /// eligible statuses". A newer `.pending` sibling must not outrank an older
    /// live one: the live step is the one actually consuming the conversation,
    /// so guidance parked on a not-yet-started step would be read far later (or
    /// never, if that step is skipped).
    func testInjectForwardedMessage_liveStepWins_overNewerPendingSibling() async {
        var live = StepExecution(id: "live_step", role: .softwareEngineer, title: "Engineer")
        live.status = .running
        live.updatedAt = Date(timeIntervalSince1970: 1_000)
        var pending = StepExecution(id: "pending_step", role: .codeReviewer, title: "Reviewer")
        pending.status = .pending
        pending.updatedAt = Date(timeIntervalSince1970: 9_999)  // strictly newer
        var child = makeChildTask()
        child.runs = [Run(id: 0, steps: [live, pending])]
        delegate.taskToMutate = child

        let outcome = await service._testInjectForwardedMessageIntoChildOutcome(
            childTaskID: ntChildTID,
            message: "guidance",
            delegate: delegate
        )

        guard case let .injected(stepID) = outcome else {
            return XCTFail("Expected .injected, got \(outcome)")
        }
        XCTAssertEqual(stepID, "live_step",
                       "Live steps outrank pending ones regardless of updatedAt — updatedAt only breaks ties WITHIN a priority tier")
    }

    // MARK: - cancel_delegation: field cleanup

    /// The cancel path's other half: `clearDelegationFields` must drop the
    /// active marker (so `pauseRun` stops treating the step as mid-delegation
    /// and the next `delegate_to_team` starts clean) while PRESERVING the
    /// append-only `delegationChildIDs` history the graph's history layers read.
    func testCancelDelegation_clearsActiveMarkerButKeepsHistory() async {
        service._testRegisterStepTask(stepID: ntStepID, taskID: ntParentTID)
        delegate.activeDelegationChildStub["\(ntParentTID):\(ntStepID)"] = ntChildTID
        // The PARENT is the mutation target for cancel (no child reads happen).
        var parent = makeParentTask()
        parent.runs[0].steps[0].setActiveDelegation(childID: ntChildTID)
        delegate.taskToMutate = parent

        let envelope = await service.handleCancelDelegation(
            stepID: ntStepID,
            taskID: ntParentTID,
            childTaskID: ntChildTID,
            reason: "looping"
        )

        XCTAssertFalse(envelope.contains("INVALID_ARGS"), "envelope=\(envelope)")
        let step = delegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == ntStepID })
        XCTAssertNil(step?.activeDelegationChildID,
                     "cancel must clear the in-flight marker; a stale marker breaks pauseRun and every follow-up verb")
        XCTAssertEqual(step?.delegationChildIDs, [ntChildTID],
                       "The append-only history is the graph's delegation-history source and must survive the cancel")
    }

    func testCancelDelegation_delegateDetached_returnsCommandFailed() async {
        service._testRegisterStepTask(stepID: ntStepID, taskID: ntParentTID)
        delegate.activeDelegationChildStub["\(ntParentTID):\(ntStepID)"] = ntChildTID
        service.delegate = nil

        let envelope = await service.handleCancelDelegation(
            stepID: ntStepID,
            taskID: ntParentTID,
            childTaskID: ntChildTID,
            reason: nil
        )

        XCTAssertTrue(envelope.contains("delegate unavailable"), "envelope=\(envelope)")
        XCTAssertTrue(delegate.stopEngineCalls.isEmpty,
                      "A detached service must not reach an engine")
    }

    // MARK: - Arrangement helpers

    /// Arranges a live, validated, fully-resolvable delegation so each test can
    /// break exactly ONE precondition and attribute the failure to it.
    ///
    /// `taskToMutate` holds the CHILD deliberately: the mock's `loadedTask` is a
    /// single slot, and every delegate read the re-entry handlers perform
    /// (`loadedTask(childTID)`, `mutateTask(taskID: childTaskID)`) targets the
    /// child. The parent arrives as a plain function argument.
    private func arrangeLiveDelegation(
        childParentTaskID: Int? = ntParentTID,
        childPreferredTeamID: NTMSID? = ntChildTeamID,
        childGeneratedTeam: Team? = nil,
        childSteps: [StepExecution]? = nil,
        childHasRun: Bool = true,
        teamsInSnapshot: [Team]? = nil
    ) {
        service._testRegisterStepTask(stepID: ntStepID, taskID: ntParentTID)
        delegate.activeDelegationChildStub["\(ntParentTID):\(ntStepID)"] = ntChildTID
        installSnapshot(teams: teamsInSnapshot ?? [makeParentTeam(), makeChildTeam()])
        delegate.taskToMutate = makeChildTask(
            parentTaskID: childParentTaskID,
            preferredTeamID: childPreferredTeamID,
            generatedTeam: childGeneratedTeam,
            steps: childSteps,
            hasRun: childHasRun
        )
    }

    private func installSnapshot(teams: [Team]) {
        var state = WorkFolderState(name: "Test")
        state.activeTeamID = ntParentTeamID
        delegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: state,
                settings: .defaults,
                teams: teams
            ),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: ntParentTID,
            activeTask: nil
        )
    }

    // MARK: - Fixtures

    /// Parent team carrying the delegating role. `systemRoleID` matches
    /// `Role.codingAgent.baseID` so `findRole(byIdentifier:)` resolves it via
    /// the systemRoleID branch — the same lookup production performs.
    private func makeParentTeam() -> Team {
        let delegator = TeamRoleDefinition(
            id: ntStepID,
            name: "Coding Agent",
            prompt: "p",
            toolIDs: [ToolNames.delegateToTeam],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: [ntChildTeamID],
            allowDelegationToGeneratedTeams: true,
            systemRoleID: Role.codingAgent.baseID
        )
        let supervisor = TeamRoleDefinition(
            id: "parent_supervisor",
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            systemRoleID: "supervisor"
        )
        return Team(
            id: ntParentTeamID,
            name: ntParentTeamName,
            roles: [supervisor, delegator],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
    }

    private func makeChildTeam() -> Team {
        makeTeam(id: ntChildTeamID, name: ntChildTeamName)
    }

    private func makeTeam(id: NTMSID, name: String) -> Team {
        Team(
            id: id,
            name: name,
            roles: [],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
    }

    /// Parent task as the handlers receive it: `preferredTeamID` resolves the
    /// parent team, and the run carries no `teamID` so `TeamResolution` takes
    /// the preferred-id rung rather than the run pin.
    private func makeParentTask() -> NTMSTask {
        var task = NTMSTask(
            id: ntParentTID,
            title: "Parent",
            supervisorTask: "x",
            preferredTeamID: ntParentTeamID
        )
        task.runs = [Run(id: 0, steps: [
            StepExecution(id: ntStepID, role: .codingAgent, title: "Coding Agent", status: .running)
        ])]
        return task
    }

    private func makeChildTask(
        parentTaskID: Int? = ntParentTID,
        preferredTeamID: NTMSID? = ntChildTeamID,
        generatedTeam: Team? = nil,
        steps: [StepExecution]? = nil,
        hasRun: Bool = true
    ) -> NTMSTask {
        var task = NTMSTask(
            id: ntChildTID,
            title: "Delegated",
            supervisorTask: "brief",
            preferredTeamID: preferredTeamID,
            // `TaskLineage.from` normalizes: a non-nil parent needs a role id
            // and a depth >= 1, otherwise the lineage collapses to `.root` and
            // `parentTaskID` silently reads back as nil.
            parentTaskID: parentTaskID,
            parentRoleID: parentTaskID == nil ? nil : ntStepID,
            delegationDepth: parentTaskID == nil ? 0 : 1
        )
        if let generatedTeam {
            task.adoptGeneratedTeam(generatedTeam)
        }
        if hasRun {
            task.runs = [Run(id: 0, steps: steps ?? [makeLiveChildStep()])]
        }
        return task
    }

    private func makeLiveChildStep() -> StepExecution {
        StepExecution(
            id: ntChildStepID,
            role: .softwareEngineer,
            title: "Engineer",
            status: .running
        )
    }

    private func makeConfig() -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost",
            modelName: "stub",
            temperature: nil
        )
    }

    private func parseJSON(_ s: String) throws -> [String: Any] {
        let any = try JSONSerialization.jsonObject(with: Data(s.utf8), options: [])
        return try XCTUnwrap(any as? [String: Any])
    }

    /// Never actually streams — the awaiter is driven entirely by
    /// `MockLLMExecutionDelegate.scriptedAwaitOutcomes`, and no test here
    /// scripts `.needsSupervisorInput` (the only branch that issues a request).
    private final class ReentryStubLLMClient: LLMClient, @unchecked Sendable {
        func streamChat(
            config _: LLMConfig,
            messages _: [ChatMessage],
            tools _: [ToolSchema],
            logger _: NetworkLogger?,
            stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { continuation in continuation.finish() }
        }
        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
    }
}
