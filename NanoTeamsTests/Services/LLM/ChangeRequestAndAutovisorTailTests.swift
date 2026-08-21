import XCTest

@testable import NanoTeams

// Tail coverage for three subjects that share a seam ("what ends a step, and who
// is allowed to end it"):
//
//  1. `LLMExecutionService+ChangeRequest.handleChangeRequest` — the HANDLER, not the
//     pure validator. `ChangeRequestServiceExtendedTests` pins
//     `ChangeRequestService.validateChangeRequest` in isolation; nothing pinned that
//     the handler ROUTES those verdicts into a `.failed` reply *without* recording a
//     change request — the exact contrast with the meeting-failure path, which DOES
//     record one as `.rejected`. Plus the two vote arms (approve / reject) end to end
//     through a real auto-created voting meeting.
//  2. `LLMExecutionService+StepLifecycle` — the two loop-top arms
//     (`finishRequested`, `parkForEventsRequested`). `AdvisoryAutoFinishTests` says in
//     so many words that these stayed unpinned "by deliberate decision" because a full
//     tool-loop harness was assumed necessary. It isn't: both arms are evaluated at the
//     TOP of the while loop, before `safetyIterations += 1` and before any LLM call, so
//     arming the flag synchronously right after `startStepExecution` (whose spawned Task
//     cannot have started yet — its first statement awaits) drives them with zero
//     network.
//  3. `NTMSOrchestrator+Autovisor.ensureAutovisorTask` — creation, idempotence, the
//     stale-pin corner, and the documented disable→enable recurrence restore.

// MARK: - Doubles

/// Emits one fixed content string and finishes. Used to drive a real (bounded)
/// voting meeting: each participant turn "votes" with the scripted text.
/// Deliberately NOT `CapturingStubLLMClient` — that one holds the connection open
/// until cancelled, which would hang the meeting turn loop.
private final class ScriptedVoteLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    /// One entry per turn, cycled. A single entry means "every participant says this"; two
    /// opposed entries are how a genuine 1-1 deadlock is produced, which is the only shape
    /// that still reaches the `.tied` arm now that 0-0 is `.noVotes`.
    private let votes: [String]
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(vote: String) { self.votes = [vote] }
    init(votes: [String]) { self.votes = votes }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let text = lock.withLock { () -> String in
            defer { _callCount += 1 }
            return votes[_callCount % votes.count]
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: text))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// Records every request and finishes immediately with no events.
///
/// Finishing (rather than hanging) is deliberate: the loop-top tests assert this
/// client was NEVER called, and a regression that skips the arm must FAIL the
/// assertion rather than deadlock the suite.
private final class RecordingSilentLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { _callCount += 1 }
        return AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

// MARK: - 1. handleChangeRequest: validation routing + vote arms

/// Drives the REAL `handleChangeRequest` entry point. The validation tests assert the
/// handler's own contract — a validation refusal must leave NO change request behind
/// and must never open a meeting — which is invisible to the pure-validator tests.
@MainActor
final class ChangeRequestHandlerFlowTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let requesterStepID = "team_swe"
    private let targetRoleID = "team_pm"
    private let taskID = 501

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: Validation refusals (no CR recorded, no meeting opened)

    func testHandler_unknownTargetRole_refusesWithoutRecordingOrMeeting() async {
        install(team: makeTeam(), task: makeTask())

        let reply = await submitChangeRequest(targetRoleID: "ghost-role")

        XCTAssertFalse(reply.succeeded, "an unresolvable target must be refused")
        XCTAssertTrue(reply.text.contains("ghost-role"), "the refusal must name the bad id; got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("not found"), "got: \(reply.text)")
        XCTAssertTrue(mockDelegate.taskToMutate?.runs[0].changeRequests.isEmpty ?? false,
                      "a VALIDATION refusal records nothing — only a failed VOTE records a rejected CR")
        XCTAssertTrue(mockDelegate.setMeetingParticipantsCalls.isEmpty,
                      "no voting meeting may be opened for a request that never validated")
    }

    func testHandler_targetIsSupervisor_isRefused() async {
        install(team: makeTeam(includeSupervisor: true), task: makeTask())

        let reply = await submitChangeRequest(targetRoleID: "team_supervisor")

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("Supervisor"),
                      "the Supervisor is the user — their work is not amendable; got: \(reply.text)")
        XCTAssertTrue(mockDelegate.taskToMutate?.runs[0].changeRequests.isEmpty ?? false)
    }

    func testHandler_targetStepStillRunning_isRefused() async {
        install(team: makeTeam(), task: makeTask(targetStepStatus: .running))

        let reply = await submitChangeRequest()

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("not completed"),
                      "changes can only be requested against completed work; got: \(reply.text)")
        XCTAssertTrue(mockDelegate.setMeetingParticipantsCalls.isEmpty)
    }

    func testHandler_targetHasNoStepInThisRun_isRefused() async {
        // The role exists in the team but never ran — there is nothing to amend.
        install(team: makeTeam(), task: makeTask(includeTargetStep: false))

        let reply = await submitChangeRequest()

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("no step in this run"), "got: \(reply.text)")
    }

    // MARK: Limits

    func testHandler_changeRequestLimitReached_isRefused() async {
        var task = makeTask()
        task.runs[0].changeRequests = [
            ChangeRequest(requestingRoleID: "softwareEngineer", targetRoleID: targetRoleID,
                          changes: "earlier", reasoning: "earlier", status: .approved),
        ]
        install(team: makeTeam(limits: TeamLimits(maxChangeRequestsPerRun: 1)), task: task)

        let reply = await submitChangeRequest()

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("Change request limit reached"),
                      "maxChangeRequestsPerRun must gate the handler; got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("1"), "the refusal names the configured cap; got: \(reply.text)")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].changeRequests.count, 1,
                       "the blocked request must not be appended alongside the existing one")
    }

    func testHandler_amendmentLimitReachedOnTarget_isRefused() async {
        var task = makeTask()
        task.runs[0].steps[1].amendments = [
            StepAmendment(requestedByRoleID: "softwareEngineer", reason: "first pass"),
        ]
        install(team: makeTeam(limits: TeamLimits(maxAmendmentsPerStep: 1)), task: task)

        let reply = await submitChangeRequest()

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("Amendment limit reached"),
                      "maxAmendmentsPerStep must gate the handler; got: \(reply.text)")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].steps[1].amendments.count, 1,
                       "the target step must keep exactly its existing amendment")
    }

    /// `0` means UNLIMITED for both caps (`if maxCR > 0` / `if maxAmend > 0`). With a run
    /// already holding 5 change requests and a target step holding 2 amendments, neither
    /// gate may fire — the request must proceed far enough to fail for a DIFFERENT reason
    /// (here: no work folder, so the voting meeting cannot run).
    func testHandler_zeroLimits_meanUnlimited_notImmediatelyBlocked() async {
        var task = makeTask()
        task.runs[0].changeRequests = (0..<5).map { i in
            ChangeRequest(requestingRoleID: "softwareEngineer", targetRoleID: targetRoleID,
                          changes: "c\(i)", reasoning: "r\(i)", status: .approved)
        }
        task.runs[0].steps[1].amendments = [
            StepAmendment(requestedByRoleID: "softwareEngineer", reason: "a1"),
            StepAmendment(requestedByRoleID: "softwareEngineer", reason: "a2"),
        ]
        install(
            team: makeTeam(limits: TeamLimits(maxChangeRequestsPerRun: 0, maxAmendmentsPerStep: 0)),
            task: task)
        // Force the voting meeting to fail at its no-work-folder guard so the request
        // gets PAST validation and we can prove the limits didn't stop it.
        mockDelegate.workFolderURL = nil

        let reply = await submitChangeRequest()

        XCTAssertFalse(reply.succeeded, "the meeting cannot run without a work folder")
        XCTAssertFalse(reply.text.contains("limit reached"),
                       "a 0 cap is unlimited — neither limit may fire; got: \(reply.text)")
        XCTAssertTrue(reply.text.lowercased().contains("voting meeting"),
                      "the failure must be the meeting, not a limit; got: \(reply.text)")
        // Contrast with the validation refusals above: a failed VOTE DOES record the CR.
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].changeRequests.count, 6,
                       "the failed-vote path records the request (as rejected) — 5 seeded + this one")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].changeRequests.last?.status, .rejected)
    }

    // MARK: Vote arms (real auto-created voting meeting)

    /// The approved arm end to end: validate → auto-create the voting meeting → every
    /// turn votes APPROVE → `tallyVotes` → `executeAmendment`.
    ///
    /// The assertions cover BOTH the `.approved` and `.tied` arms of the switch, which
    /// are behaviourally identical (V1 auto-approves a tie) — pinning the *outcome*
    /// rather than the tally's internal branch keeps this robust against speaker
    /// rotation, which decides how many ballots land.
    func testHandler_approvedVote_recordsAmendmentAndQueuesTargetForRevision() async {
        install(team: makeTeam(limits: TeamLimits(maxMeetingTurns: 2)), task: makeTask())
        let client = ScriptedVoteLLMClient(vote: "This is worth doing.\nVOTE: APPROVE")

        let reply = await submitChangeRequest(client: client)

        XCTAssertTrue(reply.succeeded, "an approved change request reports success; got: \(reply.text)")
        XCTAssertTrue(reply.text.uppercased().contains("APPROVED"),
                      "the reply must tell the model the vote carried; got: \(reply.text)")
        XCTAssertGreaterThan(client.callCount, 0, "premise: the voting meeting actually ran")

        guard let latestRun = mockDelegate.taskToMutate?.runs.last else {
            return XCTFail("the task lost its run")
        }
        XCTAssertEqual(latestRun.changeRequests.count, 1)
        XCTAssertEqual(latestRun.changeRequests[0].status, .approved,
                       "an approved (or tied→auto-approved) vote persists as .approved")
        XCTAssertNotNil(latestRun.changeRequests[0].meetingID,
                        "the recorded request must point at the meeting that decided it")

        guard let targetStep = latestRun.steps.first(where: { $0.id == targetRoleID }) else {
            return XCTFail("the target step vanished")
        }
        XCTAssertEqual(targetStep.amendments.count, 1, "the amendment must be recorded on the target step")
        XCTAssertEqual(targetStep.amendments[0].requestedByRoleID, Role.softwareEngineer.baseID)
        XCTAssertNotNil(targetStep.revisionComment,
                        "the raw amendment block must be stored so resetStepForRevision doesn't re-derive it")
        XCTAssertTrue(targetStep.messages.last?.content.contains("AMENDMENT REQUEST") ?? false,
                      "the amendment context must be injected into the target's messages")
        XCTAssertEqual(latestRun.roleStatuses[targetRoleID], .revisionRequested,
                       "the engine picks the revision up from this status")
    }

    /// A voting meeting that RAN and decided nothing must not carry the change.
    ///
    /// This is not a hypothetical: `tallyVotes` recognises one token, and a participant that
    /// answers in prose ("Let me think about it...") casts no vote. 0-0 used to fold into
    /// `.tied`, whose documented V1 policy is auto-approve — so a request nobody voted for
    /// reset the target role and cascaded a revision through every started downstream role.
    /// A sibling of this was already fixed at the caller for the case where the meeting never
    /// ran (`ChangeRequestVotingFailureTests`); this is the case where it ran and abstained.
    ///
    /// RED: restore `return .tied` for 0-0 in `tallyVotes` → the amendment count, the
    /// role status and the reply text all flip.
    func testHandler_noVotesCast_doesNotCarry_andAmendsNothing() async {
        install(team: makeTeam(limits: TeamLimits(maxMeetingTurns: 2)), task: makeTask())
        let client = ScriptedVoteLLMClient(vote: "Let me think about it — I need more context.")

        let reply = await submitChangeRequest(client: client)

        XCTAssertGreaterThan(client.callCount, 0, "premise: the voting meeting actually ran")
        guard let latestRun = mockDelegate.taskToMutate?.runs.last else {
            return XCTFail("the task lost its run")
        }
        let cast = (latestRun.meetings.last?.messages ?? [])
            .filter { $0.content.uppercased().contains("VOTE:") }
        XCTAssertTrue(cast.isEmpty, "premise: no participant emitted a ballot; got \(cast.count)")

        XCTAssertTrue(reply.text.uppercased().contains("NO VOTES"),
                      "the model must be told why it did not carry; got: \(reply.text)")
        XCTAssertEqual(latestRun.changeRequests.count, 1)
        XCTAssertEqual(latestRun.changeRequests[0].status, .rejected,
                       "an unvoted request must not persist as approved")

        guard let targetStep = latestRun.steps.first(where: { $0.id == targetRoleID }) else {
            return XCTFail("the target step vanished")
        }
        XCTAssertTrue(targetStep.amendments.isEmpty,
                      "nothing may be amended on the strength of zero votes")
        XCTAssertNil(targetStep.revisionComment)
        XCTAssertNotEqual(latestRun.roleStatuses[targetRoleID], .revisionRequested,
                          "the target must not be queued for revision")
    }

    /// The `.tied` arm proper: one APPROVE, one REJECT. Both sides were argued, so V1's
    /// auto-approve is a defensible coin flip — and it stays reachable after `.noVotes`
    /// split off, which is the half this pins.
    func testHandler_tiedVote_autoApproves_andAmends() async {
        install(team: makeTeam(limits: TeamLimits(maxMeetingTurns: 2)), task: makeTask())
        let client = ScriptedVoteLLMClient(votes: [
            "Worth doing.\nVOTE: APPROVE",
            "I disagree.\nVOTE: REJECT",
        ])

        let reply = await submitChangeRequest(client: client)

        guard let latestRun = mockDelegate.taskToMutate?.runs.last else {
            return XCTFail("the task lost its run")
        }
        let messages = latestRun.meetings.last?.messages ?? []
        let approves = messages.filter { $0.content.uppercased().contains("VOTE: APPROVE") }.count
        let rejects = messages.filter { $0.content.uppercased().contains("VOTE: REJECT") }.count
        XCTAssertEqual(approves, rejects, "premise: the ballots must actually tie")
        XCTAssertGreaterThan(approves, 0, "premise: a tie needs votes on both sides, or it is .noVotes")

        XCTAssertTrue(reply.succeeded, "got: \(reply.text)")
        XCTAssertTrue(reply.text.uppercased().contains("TIED VOTE"),
                      "the model must learn the change carried on a tie, not a majority; got: \(reply.text)")
        XCTAssertEqual(latestRun.changeRequests[0].status, .approved)

        guard let targetStep = latestRun.steps.first(where: { $0.id == targetRoleID }) else {
            return XCTFail("the target step vanished")
        }
        XCTAssertEqual(targetStep.amendments.count, 1, "a tie amends, exactly like an approval")
        XCTAssertEqual(latestRun.roleStatuses[targetRoleID], .revisionRequested)
    }

    /// Regression: a target step keyed by `systemRoleID` rather than `role.id`.
    ///
    /// This is the exact shape `validateChangeRequest`'s second disjunct exists for, and
    /// it used to pass validation, spend a full voting meeting, persist the request as
    /// `.approved` — and then amend nothing, because `executeAmendment` re-derived the
    /// lookup with only `role.id`. The reply still said the change had carried. Both
    /// halves now share `ChangeRequestService.targetStep(in:for:)`.
    func testHandler_targetStepKeyedBySystemRoleID_actuallyAmends() async {
        let team = makeTeam(limits: TeamLimits(maxMeetingTurns: 2))
        guard let targetRole = team.roles.first(where: { $0.id == targetRoleID }) else {
            return XCTFail("fixture: the target role vanished")
        }
        guard let systemID = targetRole.systemRoleID else {
            return XCTFail("fixture: the target role must carry a systemRoleID")
        }
        XCTAssertNotEqual(systemID, targetRole.id,
                          "premise: the two spellings must DIFFER or this test is vacuous")

        var task = makeTask()
        guard let idx = task.runs[0].steps.firstIndex(where: { $0.id == targetRoleID }) else {
            return XCTFail("fixture: the target step vanished")
        }
        task.runs[0].steps[idx].id = systemID          // step keyed by the system id
        install(team: team, task: task)

        let reply = await submitChangeRequest(
            client: ScriptedVoteLLMClient(vote: "Worth doing.\nVOTE: APPROVE"))

        XCTAssertTrue(reply.succeeded, "got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("Amendment initiated"),
                      "the amendment must actually run, not silently miss the step: \(reply.text)")

        guard let latestRun = mockDelegate.taskToMutate?.runs.last,
              let targetStep = latestRun.steps.first(where: { $0.id == systemID }) else {
            return XCTFail("the target step vanished")
        }
        XCTAssertEqual(targetStep.amendments.count, 1,
                       "the amendment must land on the system-id-keyed step")
        XCTAssertNotNil(targetStep.revisionComment)
        XCTAssertEqual(latestRun.roleStatuses[targetRoleID], .revisionRequested,
                       "roleStatuses stays keyed by role.id — that is what the engine seeds and reads")
    }

    /// Routing: an amendment that did NOT run must not be reported inside a success
    /// reply. Reachable because validation reads `runs[runIndex]` while the amendment
    /// re-reads `runs.last` — a second run appended during the (multi-turn, minutes-long)
    /// vote makes the two disagree.
    func testHandler_amendmentCouldNotRun_isReportedAsFailureNotSuccess() async {
        var task = makeTask()
        // Validation sees run 0 (has the target step); the amendment sees runs.last.
        task.runs.append(Run(id: 1, steps: [
            StepExecution(id: requesterStepID, role: .softwareEngineer, title: "SWE", status: .running)
        ]))
        install(team: makeTeam(limits: TeamLimits(maxMeetingTurns: 2)), task: task)

        let reply = await submitChangeRequest(
            client: ScriptedVoteLLMClient(vote: "Worth doing.\nVOTE: APPROVE"))

        XCTAssertFalse(reply.succeeded,
                       """
                       The vote carried but the amendment found no step. Reporting that \
                       inside `.ok(...)` paints the tool card green and tells the model its \
                       change landed when nothing was touched. got: \(reply.text)
                       """)
        XCTAssertTrue(reply.text.contains("Amendment failed"),
                      "the reply must say WHICH half failed: \(reply.text)")
    }

    /// The rejected arm: the existing work must stand — no amendment, no status change,
    /// and the reply still SUCCEEDS (the tool did its job; the vote simply said no).
    func testHandler_rejectedVote_leavesTheWorkStanding() async {
        install(team: makeTeam(limits: TeamLimits(maxMeetingTurns: 2)), task: makeTask())
        let client = ScriptedVoteLLMClient(vote: "I disagree with this.\nVOTE: REJECT")

        let reply = await submitChangeRequest(client: client)

        XCTAssertTrue(reply.succeeded,
                      "a rejected vote is a successful tool call — the answer is 'no'; got: \(reply.text)")
        XCTAssertTrue(reply.text.uppercased().contains("REJECTED"), "got: \(reply.text)")

        guard let latestRun = mockDelegate.taskToMutate?.runs.last else {
            return XCTFail("the task lost its run")
        }
        XCTAssertEqual(latestRun.changeRequests.count, 1)
        XCTAssertEqual(latestRun.changeRequests[0].status, .rejected)

        let targetStep = latestRun.steps.first(where: { $0.id == targetRoleID })
        XCTAssertEqual(targetStep?.amendments.count, 0,
                       "a rejected vote must not amend the target's completed work")
        XCTAssertNil(targetStep?.revisionComment)
        XCTAssertEqual(latestRun.roleStatuses[targetRoleID], .done,
                       "the target role keeps its terminal status")
        XCTAssertTrue(mockDelegate.heldDownstreamCalls.isEmpty,
                      "no downstream hold may fire for a rejected request")
    }

    // MARK: - Fixture

    private func install(team: Team, task: NTMSTask) {
        var task = task
        task.preferredTeamID = team.id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "T", activeTeamID: team.id),
                settings: .defaults,
                teams: [team]
            ),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: task.id,
            activeTask: task
        )
        service._testRegisterStepTask(stepID: requesterStepID, taskID: taskID)
    }

    private func submitChangeRequest(
        targetRoleID: String? = nil,
        client: (any LLMClient)? = nil
    ) async -> CollaborationReply {
        var effectiveClient: any LLMClient = RecordingSilentLLMClient()
        if let client { effectiveClient = client }
        return await service.handleChangeRequest(
            stepID: requesterStepID,
            targetRoleID: targetRoleID ?? self.targetRoleID,
            changes: "Tighten the error handling.",
            reasoning: "The current path swallows failures.",
            requestingRole: .softwareEngineer,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: effectiveClient,
            config: LLMConfig()
        )
    }

    /// Requester (`team_swe`, `.running`) at index 0 so `stepIndex: 0` addresses it,
    /// target (`team_pm`, `.done`) at index 1. The requester deliberately requires NO
    /// artifact, so the target has no downstream consumers and the propagation half
    /// stays out of the vote tests (it is covered directly in the sibling suite).
    private func makeTask(
        targetStepStatus: StepStatus = .done,
        includeTargetStep: Bool = true
    ) -> NTMSTask {
        let sweStep = StepExecution(
            id: requesterStepID, role: .softwareEngineer, title: "SWE", status: .running)
        var steps = [sweStep]
        if includeTargetStep {
            steps.append(StepExecution(
                id: targetRoleID, role: .productManager, title: "PM",
                expectedArtifacts: ["Product Requirements"],
                status: targetStepStatus,
                completedAt: targetStepStatus == .done ? MonotonicClock.shared.now() : nil,
                artifacts: [Artifact(name: "Product Requirements", mimeType: "text/markdown",
                                     relativePath: "steps/pm/prd.md")]
            ))
        }
        var roleStatuses: [String: RoleExecutionStatus] = [requesterStepID: .working]
        if includeTargetStep { roleStatuses[targetRoleID] = .done }
        let run = Run(id: 0, steps: steps, roleStatuses: roleStatuses)
        return NTMSTask(id: taskID, title: "T", supervisorTask: "Build it", runs: [run])
    }

    private func makeTeam(
        includeSupervisor: Bool = false,
        limits: TeamLimits = .default
    ) -> Team {
        var roles: [TeamRoleDefinition] = []
        if includeSupervisor {
            roles.append(TeamRoleDefinition(
                id: "team_supervisor", name: "Supervisor", prompt: "", toolIDs: [],
                usePlanningPhase: false, dependencies: RoleDependencies(),
                systemRoleID: "supervisor"))
        }
        roles.append(TeamRoleDefinition(
            id: targetRoleID, name: "Product Manager", prompt: "p", toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Product Requirements"]),
            systemRoleID: "productManager"))
        roles.append(TeamRoleDefinition(
            id: requesterStepID, name: "Software Engineer", prompt: "p",
            toolIDs: [ToolNames.requestChanges], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            systemRoleID: "softwareEngineer"))
        return Team(
            name: "CR Tail Team", roles: roles, artifacts: [],
            settings: TeamSettings(limits: limits), graphLayout: TeamGraphLayout())
    }
}

// MARK: - 2. propagateAmendmentDownstream / recordChangeRequest tail

/// Corners the existing propagation suites don't reach: transitive (two-hop) fan-out,
/// a downstream role with no step in the run, and the degenerate task shapes for
/// `executeAmendment` / `recordChangeRequest`.
@MainActor
final class ChangeRequestPropagationTailTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    /// `getDownstreamRoles` is a transitive BFS, not a one-hop lookup: amending the
    /// engineer must queue the reviewer (direct consumer) AND the TPM (consumer of the
    /// reviewer's output). A regression to direct-only consumers leaves the TPM
    /// shipping release notes derived from work that was withdrawn.
    func testPropagate_transitiveDownstream_queuesTheSecondHopToo() async {
        let (task, team) = makeChainTask()
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id, sourceRoleID: "engineer",
            changes: "Rework the parser", team: team)

        let updated = mockDelegate.taskToMutate!
        XCTAssertEqual(updated.runs[0].roleStatuses["reviewer"], .revisionRequested,
                       "the direct consumer must be queued")
        XCTAssertEqual(updated.runs[0].roleStatuses["tpm"], .revisionRequested,
                       "the SECOND hop must be queued too — propagation is transitive")
        XCTAssertTrue(result.runningRoleIDs.isEmpty, "both downstream roles were terminal, not running")
        XCTAssertTrue(result.summary.contains("reviewer"))
        XCTAssertTrue(result.summary.contains("tpm"))
    }

    /// A downstream role that exists in the TEAM but never produced a step in this run
    /// has nothing to revise — the `firstIndex(where:)` guard must `continue` past it
    /// without inventing a role status.
    func testPropagate_downstreamRoleWithNoStepInRun_isSkippedWithoutInventingAStatus() async {
        let (chainTask, team) = makeChainTask()
        var task = chainTask
        task.runs[0].steps.removeAll { $0.id == "tpm" }
        task.runs[0].roleStatuses.removeValue(forKey: "tpm")
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id, sourceRoleID: "engineer",
            changes: "Rework the parser", team: team)

        let updated = mockDelegate.taskToMutate!
        XCTAssertNil(updated.runs[0].roleStatuses["tpm"],
                     "a role with no step must not be given a roleStatus out of thin air")
        XCTAssertEqual(updated.runs[0].roleStatuses["reviewer"], .revisionRequested,
                       "the role that DOES have a step is still processed")
        XCTAssertFalse(result.runningRoleIDs.contains("tpm"))
    }

    /// `executeAmendment` reads `currentTask.runs.last`. A task with no runs at all must
    /// report failure rather than trap on the optional chain.
    func testExecuteAmendment_taskWithNoRuns_failsWithoutMutating() async {
        let task = NTMSTask(id: 77, title: "T", supervisorTask: "Goal", runs: [])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: "engineer", taskID: 77)

        let result = await service._testExecuteAmendment(
            taskID: 77, targetRoleID: "engineer", changes: "c", reasoning: "r",
            requestingRoleID: "reviewer", requesterStepID: "reviewer",
            meetingID: nil, team: nil)

        XCTAssertTrue(result.contains("failed"), "got: \(result)")
        XCTAssertTrue(mockDelegate.taskToMutate?.runs.isEmpty ?? false, "nothing may be created")
        XCTAssertTrue(mockDelegate.heldDownstreamCalls.isEmpty,
                      "a failed amendment must not fire the downstream hold")
    }

    /// `executeAmendment` for a task the delegate doesn't know: `loadedTask` returns nil
    /// so the whole amendment must abort — this is the guard that stops an amendment
    /// landing on whatever else answers to that id.
    func testExecuteAmendment_unknownTask_failsWithoutMutating() async {
        let (task, team) = makeChainTask()
        mockDelegate.taskToMutate = task

        let result = await service._testExecuteAmendment(
            taskID: task.id + 1_000, targetRoleID: "engineer", changes: "c", reasoning: "r",
            requestingRoleID: "reviewer", requesterStepID: "reviewer",
            meetingID: nil, team: team)

        XCTAssertTrue(result.contains("failed"), "got: \(result)")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].steps.first?.amendments.count, 0,
                       "the real task must be untouched")
    }

    /// `recordChangeRequest` guards on `task.runs.indices.last`. With no runs the mutation
    /// is a clean no-op — the change request has nowhere to live and must not crash.
    func testRecordChangeRequest_taskWithNoRuns_isACleanNoOp() async {
        let task = NTMSTask(id: 78, title: "T", supervisorTask: "Goal", runs: [])
        mockDelegate.taskToMutate = task

        await service.recordChangeRequest(
            taskID: 78,
            changeRequest: ChangeRequest(requestingRoleID: "a", targetRoleID: "b",
                                         changes: "c", reasoning: "r", status: .pending))

        XCTAssertTrue(mockDelegate.taskToMutate?.runs.isEmpty ?? false)
    }

    /// The upsert writes into `runs.last`, never an earlier run — a change request raised
    /// during run 2 must not be filed against run 1's history.
    func testRecordChangeRequest_multipleRuns_writesIntoTheLatestRunOnly() async {
        var task = NTMSTask(id: 79, title: "T", supervisorTask: "Goal", runs: [])
        task.runs = [Run(id: 0, steps: []), Run(id: 1, steps: [])]
        mockDelegate.taskToMutate = task

        await service.recordChangeRequest(
            taskID: 79,
            changeRequest: ChangeRequest(requestingRoleID: "a", targetRoleID: "b",
                                         changes: "c", reasoning: "r", status: .pending))

        XCTAssertTrue(mockDelegate.taskToMutate?.runs[0].changeRequests.isEmpty ?? false,
                      "the historical run must stay untouched")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[1].changeRequests.count, 1)
    }

    // MARK: - Fixture

    /// engineer → reviewer → tpm, all `.done`, so the two-hop fan-out is observable.
    private func makeChainTask() -> (NTMSTask, Team) {
        func step(_ id: String, _ role: Role, _ produces: String) -> StepExecution {
            StepExecution(
                id: id, role: role, title: id,
                expectedArtifacts: [produces], status: .done,
                completedAt: MonotonicClock.shared.now(),
                artifacts: [Artifact(name: produces, mimeType: "text/markdown",
                                     relativePath: "steps/\(id).md")])
        }
        let run = Run(
            id: 0,
            steps: [
                step("engineer", .softwareEngineer, "Engineering Notes"),
                step("reviewer", .codeReviewer, "Code Review Summary"),
                step("tpm", .tpm, "Release Notes"),
            ],
            roleStatuses: ["engineer": .done, "reviewer": .done, "tpm": .done])
        let task = NTMSTask(id: 80, title: "T", supervisorTask: "Goal", runs: [run])

        func role(_ id: String, _ name: String, requires: [String], produces: [String]) -> TeamRoleDefinition {
            TeamRoleDefinition(
                id: id, name: name, prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies(requiredArtifacts: requires, producesArtifacts: produces))
        }
        let team = Team(
            name: "Chain Team",
            roles: [
                role("engineer", "Engineer", requires: [], produces: ["Engineering Notes"]),
                role("reviewer", "Reviewer", requires: ["Engineering Notes"], produces: ["Code Review Summary"]),
                role("tpm", "TPM", requires: ["Code Review Summary"], produces: ["Release Notes"]),
            ],
            artifacts: [], settings: .default, graphLayout: TeamGraphLayout())
        return (task, team)
    }
}

// MARK: - 3. StepLifecycle loop-top arms

/// The two arms evaluated at the TOP of `startStepExecution`'s tool loop, before
/// `safetyIterations += 1` and before any LLM call:
///
///   1. `finishRequested`  → persist transcript + usage → `finishStepGraceful` → return
///   2. `parkForEventsRequested` → persist transcript + usage → `parkStepForEvents` → return
///
/// `AdvisoryAutoFinishTests` documented both as unpinned "by deliberate decision",
/// assuming a full tool-loop harness was required. It isn't: `startStepExecution` is
/// synchronous and its spawned Task's first statement awaits, so a flag written on the
/// very next line is guaranteed to be visible to the first loop-top check.
@MainActor
final class StepLifecycleLoopTopArmTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var stubClient: RecordingSilentLLMClient!
    private var tempDir: URL!

    private let stepID = "loop_top_step"
    private let taskID = 611

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let stub = RecordingSilentLLMClient()
        stubClient = stub
        service = LLMExecutionService(repository: NTMSRepository(), clientFactory: { stub })
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        stubClient = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: park (`wait_for_events`)

    func testLoopTop_parkForEvents_parksTheStepAndNeverCallsTheLLM() async {
        startAndArm { $0._testArmParkForEvents(stepID: self.stepID, taskID: self.taskID) }

        await waitUntilStatus(.needsSupervisorInput)

        let step = currentStep()
        XCTAssertEqual(step?.needsSupervisorInput, true)
        XCTAssertEqual(step?.supervisorQuestion, AutovisorConstants.idleParkQuestion,
                       "the standard idle park uses the constant the sidebar predicate matches")
        XCTAssertEqual(stubClient.callCount, 0,
                       "the park arm ends the pass BEFORE the iteration counter and the LLM call")
    }

    /// The park is what makes a human message continue the SAME conversation, which only
    /// works if the wire transcript reached disk first.
    func testLoopTop_parkForEvents_persistsTheWireTranscriptBeforeParking() async {
        startAndArm { $0._testArmParkForEvents(stepID: self.stepID, taskID: self.taskID) }

        await waitUntilStatus(.needsSupervisorInput)

        XCTAssertFalse(currentStep()?.wireTranscript.isEmpty ?? true,
                       "a park with no persisted transcript strands the conversation — "
                           + "re-entry would fall back to a lossy rebuild")
    }

    /// The flag is CONSUMED at the top of the arm, so a resumed step doesn't re-park
    /// itself immediately on its next entry.
    func testLoopTop_parkForEvents_consumesTheFlag() async {
        startAndArm { $0._testArmParkForEvents(stepID: self.stepID, taskID: self.taskID) }

        await waitUntilStatus(.needsSupervisorInput)

        XCTAssertFalse(service._testParkForEventsRequested(stepID: stepID, taskID: taskID),
                       "the park flag must not survive the arm that acted on it")
    }

    /// The thinking-loop terminal parks with its own diagnostic instead of the idle text,
    /// precisely so `taskHasIdleParkStep`'s exact-equality match does NOT read a dead pass
    /// as a healthy idle. The override must also be consumed.
    func testLoopTop_parkQuestionOverride_isUsedAndConsumed() async {
        let diagnostic = "The manager repeated the same block 6 times and could not recover."
        startAndArm {
            $0._testArmParkForEvents(
                stepID: self.stepID, taskID: self.taskID, questionOverride: diagnostic)
        }

        await waitUntilStatus(.needsSupervisorInput)

        XCTAssertEqual(currentStep()?.supervisorQuestion, diagnostic,
                       "the override must replace the idle text, not be appended to it")
        XCTAssertFalse(NTMSOrchestrator.taskHasIdleParkStep(mockDelegate.taskToMutate),
                       "a loop-terminated park must NOT be mistaken for a healthy idle park")
        XCTAssertNil(service._testParkQuestionOverride(stepID: stepID, taskID: taskID),
                     "the override is one-shot")
    }

    // MARK: graceful finish

    func testLoopTop_finishRequested_finishesGracefullyAndTearsDownTheState() async {
        // `requestFinish` is the production arming API (what "Finish Role" calls).
        startAndArm { $0.requestFinish(stepID: self.stepID, taskID: self.taskID) }

        await waitUntilStatus(.needsApproval)

        XCTAssertFalse(currentStep()?.wireTranscript.isEmpty ?? true,
                       "the graceful finish persists the transcript before completing")
        XCTAssertEqual(stubClient.callCount, 0, "the finish arm precedes the LLM call")
        XCTAssertFalse(service._testHasExecutionState(stepID: stepID, taskID: taskID),
                       "a terminal arm clears the per-step execution state")
    }

    /// Ordering pin: `finishRequested` is checked FIRST. With both flags armed the step
    /// must COMPLETE, not park — the two terminals disagree about whether the
    /// conversation is closed for good, so which one wins is a real contract.
    func testLoopTop_bothFlagsArmed_finishWinsOverPark() async {
        startAndArm {
            $0.requestFinish(stepID: self.stepID, taskID: self.taskID)
            $0._testArmParkForEvents(stepID: self.stepID, taskID: self.taskID)
        }

        await waitUntilStatus(.needsApproval)

        XCTAssertNotEqual(currentStep()?.status, .needsSupervisorInput,
                          "the finish arm is evaluated first and returns — the park must not run")
        XCTAssertNil(currentStep()?.supervisorQuestion,
                     "a completed step must not also be carrying a park question")
    }

    // MARK: - Fixture

    /// Starts the real execution and arms the loop-top flags in the SAME synchronous
    /// run, before the spawned Task can reach its first suspension point.
    ///
    /// `arm` receives the service so a caller can use the production arming API
    /// (`requestFinish`) where one exists; the idle-park flag has no synchronous
    /// production setter (`handleWaitForEvents` is `async`, and awaiting it here would
    /// let the loop take an LLM turn first), so those tests write the state directly.
    private func startAndArm(_ arm: (LLMExecutionService) -> Void) {
        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "SWE", status: .running)
        let task = NTMSTask(id: taskID, title: "T", supervisorTask: "Goal",
                            runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: task, runIndex: 0, stepIndex: 0)

        XCTAssertTrue(service._testHasExecutionState(stepID: stepID, taskID: taskID),
                      "premise: startStepExecution installs the execution state synchronously")
        arm(service)
    }

    private func currentStep() -> StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    private func waitUntilStatus(
        _ expected: StepStatus,
        timeout: TimeInterval = 8.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while currentStep()?.status != expected {
            if Date() > deadline {
                XCTFail(
                    "step never reached \(expected.rawValue) — got "
                        + "\(currentStep()?.status.rawValue ?? "nil") "
                        + "(llm calls: \(stubClient.callCount))",
                    file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - 4. ensureAutovisorTask lifecycle

/// `ensureAutovisorTask` is the lazy-creation seam behind both `openWorkFolder` and
/// `setAutovisorEnabled(true)`. `AutovisorOrchestratorTests` covers the write hook, the
/// wake gating and the sleep timer; this covers the creation path itself, its
/// idempotence, the stale-pin corner, and the disable→enable recurrence restore that
/// the production comment calls out as a fixed bug.
@MainActor
final class AutovisorLifecycleTailTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var taskCount: Int { sut.snapshot?.tasksIndex.tasks.count ?? 0 }

    /// Turns the feature on WITHOUT going through `setAutovisorEnabled` (which would
    /// itself call `ensureAutovisorTask`), so each test drives the seam exactly once.
    private func openAndEnable() async {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
    }

    // MARK: Guards

    func testEnsure_featureDisabled_createsNothing() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertFalse(sut.snapshot?.workFolder.settings.autovisorEnabled ?? true,
                       "premise: the feature is off by default")
        let before = taskCount

        await sut.ensureAutovisorTask()

        XCTAssertNil(sut.autovisorTaskID, "a disabled Autovisor must not materialize a manager")
        XCTAssertEqual(taskCount, before)
    }

    func testEnsure_withoutARealWorkFolder_createsNothing() async {
        XCTAssertFalse(sut.hasRealWorkFolder, "premise: default storage")

        await sut.ensureAutovisorTask()

        XCTAssertNil(sut.autovisorTaskID,
                     "default storage has nothing to manage — the manager must not be created")
    }

    // MARK: Creation

    func testEnsure_enabled_createsPinsAndSeedsTheReviewRecurrence() async {
        await openAndEnable()

        await sut.ensureAutovisorTask()

        guard let mgrID = sut.autovisorTaskID else {
            return XCTFail("enabling must lazily create the manager task")
        }
        defer { sut.stopEngineForTask(mgrID) }
        await sut.ensureTaskLoaded(mgrID)

        XCTAssertEqual(sut.loadedTask(mgrID)?.recurrence?.isEnabled, true,
                       "the review recurrence must be seeded enabled — the scheduler drives the passes")
        XCTAssertNotNil(sut.loadedTask(mgrID)?.recurrence?.nextFireAt,
                        "an enabled recurrence with no next slot would never fire")
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorGoal, AutovisorConstants.defaultGoal,
                       "an empty goal is seeded with the default so the first prompt has a directive")
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorMemory, AutovisorConstants.defaultMemory)
        XCTAssertEqual(sut.loadedTask(mgrID)?.supervisorTask, AutovisorConstants.defaultGoal,
                       "the manager's brief IS its goal")
    }

    /// The manager is hidden from every top-level enumeration — creating it must not
    /// steal the user's focus either.
    func testEnsure_createdManager_isHiddenAndNotActive() async {
        await openAndEnable()

        await sut.ensureAutovisorTask()

        guard let mgrID = sut.autovisorTaskID else { return XCTFail("no manager created") }
        defer { sut.stopEngineForTask(mgrID) }
        XCTAssertNotEqual(sut.activeTaskID, mgrID,
                          "the manager is created with makeActive: false — it must never steal focus")
        XCTAssertFalse(sut.allLoadedTasks.contains { $0.id == mgrID },
                       "the manager is the automated Supervisor, never supervised work")
    }

    func testEnsure_calledTwice_isIdempotent() async {
        await openAndEnable()
        await sut.ensureAutovisorTask()
        guard let first = sut.autovisorTaskID else { return XCTFail("no manager created") }
        sut.stopEngineForTask(first)
        let afterFirst = taskCount

        await sut.ensureAutovisorTask()

        XCTAssertEqual(sut.autovisorTaskID, first, "the pinned id must be reused, not replaced")
        XCTAssertEqual(taskCount, afterFirst, "a second ensure must not create a second manager")
        sut.stopEngineForTask(first)
    }

    /// A pinned id that is no longer in the index (task deleted out from under the pin)
    /// must fall through to creation rather than pinning a manager that does not exist —
    /// the `tasksIndex.tasks.contains` half of the existing-task guard.
    func testEnsure_stalePinnedID_createsAFreshManager() async {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder {
            $0.settings.autovisorEnabled = true
            $0.state.autovisorTaskID = 999_999   // never existed
        }

        await sut.ensureAutovisorTask()

        guard let mgrID = sut.autovisorTaskID else {
            return XCTFail("a stale pin must be replaced by a real manager")
        }
        defer { sut.stopEngineForTask(mgrID) }
        XCTAssertNotEqual(mgrID, 999_999, "the dangling id must not survive")
        XCTAssertTrue(sut.snapshot?.tasksIndex.tasks.contains { $0.id == mgrID } ?? false,
                      "the new pin must point at a task that actually exists")
    }

    /// The documented regression: `setAutovisorEnabled(false)` disables the manager's
    /// recurrence, and the EXISTING-task branch of `ensureAutovisorTask` is the only
    /// thing that turns it back on. Without the restore a disable→enable cycle runs one
    /// open-time pass and then never recurs again.
    func testEnsure_afterDisableEnableCycle_restoresTheReviewRecurrence() async {
        await openAndEnable()
        await sut.ensureAutovisorTask()
        guard let mgrID = sut.autovisorTaskID else { return XCTFail("no manager created") }
        sut.stopEngineForTask(mgrID)

        await sut.setAutovisorEnabled(false)
        await sut.ensureTaskLoaded(mgrID)
        XCTAssertEqual(sut.loadedTask(mgrID)?.recurrence?.isEnabled, false,
                       "premise: disabling stops the scheduler firing the manager")

        await sut.mutateWorkFolder { $0.settings.autovisorEnabled = true }
        await sut.ensureAutovisorTask()
        await sut.ensureTaskLoaded(mgrID)

        XCTAssertEqual(sut.autovisorTaskID, mgrID, "the same manager is reused")
        XCTAssertEqual(sut.loadedTask(mgrID)?.recurrence?.isEnabled, true,
                       "re-enabling must restore the review recurrence, not leave a one-shot manager")
        XCTAssertNotNil(sut.loadedTask(mgrID)?.recurrence?.nextFireAt,
                        "and it must be rescheduled to a future slot")
        sut.stopEngineForTask(mgrID)
    }

    /// An existing manager whose recurrence was lost entirely (older folder / manual
    /// edit) gets a default one seeded rather than staying un-scheduled forever.
    func testEnsure_existingManagerWithNoRecurrence_seedsADefaultOne() async {
        await openAndEnable()
        await sut.ensureAutovisorTask()
        guard let mgrID = sut.autovisorTaskID else { return XCTFail("no manager created") }
        sut.stopEngineForTask(mgrID)
        await sut.ensureTaskLoaded(mgrID)
        await sut.mutateTask(taskID: mgrID) { $0.recurrence = nil }
        XCTAssertNil(sut.loadedTask(mgrID)?.recurrence, "premise: the recurrence is gone")

        await sut.ensureAutovisorTask()
        await sut.ensureTaskLoaded(mgrID)

        XCTAssertEqual(sut.loadedTask(mgrID)?.recurrence?.isEnabled, true,
                       "a missing recurrence must be re-seeded, not left absent")
        sut.stopEngineForTask(mgrID)
    }

    // MARK: autovisorRole

    func testAutovisorRole_beforeAnyWorkFolder_isNil() async {
        XCTAssertNil(sut.autovisorRole,
                     "with no snapshot there is no hidden team and therefore no Manager role")
    }

    /// The hidden team is seeded on EVERY open, feature on or off — so the Settings
    /// Model card can always resolve the Manager role.
    func testAutovisorRole_isTheSingleNonSupervisorRoleOfTheHiddenTeam() async {
        await sut.openWorkFolder(tempDir)

        guard let role = sut.autovisorRole else {
            return XCTFail("the hidden Autovisor team is seeded on open even when disabled")
        }
        XCTAssertEqual(role.systemRoleID, AutovisorConstants.managerRoleSystemID)
        XCTAssertFalse(role.isSupervisor, "the resolver deliberately skips the Supervisor")
    }

    // MARK: auto-off banner variant

    /// The sleep timer expiring while tasks still need the manager gets the LOUDER
    /// banner — turning off is the last thing that can wake this folder, so "the timer
    /// ended" is the difference between a user who turns it back on and one who finds
    /// the folder abandoned. Sampled BEFORE the disable, because every wake guard reads
    /// the enabled flag.
    func testEvaluateAutoDisable_withPendingWork_saysTasksStillNeededIt() async {
        let mgrID = await pinEnabledManagerWithoutStartingAPass()
        await sut.ensureTaskLoaded(mgrID)
        await sut.setTaskRecurrence(
            taskID: mgrID,
            recurrence: TaskRecurrence(rule: .interval(seconds: 600), isEnabled: true))
        guard await makeReviewTask() != nil else { return }
        let deadline = Date()
        sut.autovisorAutoDisableAt = deadline

        await sut.evaluateAutovisorAutoDisable(now: deadline)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false,
                       "expiry disables the feature")
        XCTAssertTrue(sut.lastInfoMessage?.contains("still needed") ?? false,
                      "an expiry with unresolved work must say so; got: \(sut.lastInfoMessage ?? "nil")")
    }

    /// Control for the above: with nothing needing attention the calmer copy is used.
    /// Both variants come from the same slot, so a regression collapsing them is silent.
    func testEvaluateAutoDisable_withNoPendingWork_usesTheQuietCopy() async {
        let mgrID = await pinEnabledManagerWithoutStartingAPass()
        await sut.ensureTaskLoaded(mgrID)
        let deadline = Date()
        sut.autovisorAutoDisableAt = deadline

        await sut.evaluateAutovisorAutoDisable(now: deadline)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false)
        XCTAssertTrue(sut.lastInfoMessage?.contains("Autovisor turned off") ?? false,
                      "got: \(sut.lastInfoMessage ?? "nil")")
        XCTAssertFalse(sut.lastInfoMessage?.contains("still needed") ?? true,
                       "nothing was pending — the loud variant must not fire")
    }

    // MARK: - Fixture

    /// Pins an ENABLED manager by writing the settings directly, so no review pass (and
    /// therefore no engine / no LM Studio) is started.
    private func pinEnabledManagerWithoutStartingAPass() async -> Int {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee",
                                         makeActive: false)!
        await sut.mutateWorkFolder {
            $0.state.autovisorTaskID = mgrID
            $0.settings.autovisorEnabled = true
        }
        return mgrID
    }

    /// A non-chat (Startup) task parked at Review — the `onTaskCompleted` trigger's
    /// shape, which is what makes `autovisorHasUnresolvedAttention()` true.
    private func makeReviewTask() async -> Int? {
        guard let startupID = sut.snapshot?.workFolder.teams
            .first(where: { $0.templateID == "startup" })?.id else {
            XCTFail("the Startup team must be bootstrapped")
            return nil
        }
        guard let taskID = await sut.createTask(title: "Build X", supervisorTask: "do X",
                                                preferredTeamID: startupID, makeActive: false) else {
            XCTFail("createTask failed")
            return nil
        }
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["r": .needsAcceptance])]
        }
        return taskID
    }
}
