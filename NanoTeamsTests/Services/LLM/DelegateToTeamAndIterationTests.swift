import XCTest

@testable import NanoTeams

// MARK: - File-scope fixtures / helpers
//
// Every file-scope declaration here is `private`: this module is written into
// by many suites at once and a bare `StubClient` / `parseEnvelope` would
// collide. Immutable globals of `Sendable` type are safe to read from any
// isolation domain, which is why they are NOT `static let` on the `@MainActor`
// test classes — several are used as default arguments, and a default-argument
// expression is evaluated in a nonisolated context.

private let dtParentTID = 11
private let dtChildTID = 91
private let dtStepID = "dt_delegator_step"
private let dtParentTeamID: NTMSID = "dt-parent-team"
private let dtTargetTeamID: NTMSID = "dt-target-team"
private let dtParentTeamName = "DT Parent Team"
private let dtTargetTeamName = "DT Target Team"

// Iteration-suite fixtures. File-scope for the same reason as the block above:
// they are read from a `nonisolated` `setUp` override and from default-argument
// position, where instance state is not reachable.
private let itStepID = "it_iteration_step"
private let itTaskID = 5

private func dtConfig() -> LLMConfig {
    LLMConfig(
        provider: .lmStudio,
        baseURLString: "http://localhost",
        modelName: "stub",
        temperature: nil
    )
}

private func dtParseEnvelope(_ json: String) throws -> [String: Any] {
    let any = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
    return try XCTUnwrap(any as? [String: Any], "envelope is not a JSON object: \(json)")
}

private func dtParseData(_ json: String) throws -> [String: Any] {
    let dict = try dtParseEnvelope(json)
    return try XCTUnwrap(dict["data"] as? [String: Any], "envelope carries no data object: \(json)")
}

/// Never streams anything. Every awaiter branch these suites drive is scripted
/// through `MockLLMExecutionDelegate.scriptedAwaitOutcomes`; the one branch that
/// would issue a real request (`.needsSupervisorInput` with a resolvable parent
/// step) is deliberately never reachable with the single-slot mock.
/// `callCount` exists so "the guard short-circuited BEFORE any network work"
/// is assertable rather than assumed.
private final class DTSilentClient: LLMClient, @unchecked Sendable {
    var callCount = 0
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        callCount += 1
        return AsyncThrowingStream { $0.finish() }
    }
    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// Emits one content delta carrying a valid `GeneratedTeamConfig` body, so
/// `TeamGenerationService.generate` resolves through its balanced-brace JSON
/// scan (no tool-call streaming machinery needed). The team it describes is
/// NOT chat-mode (`supervisor_requires` is non-empty), which matters: the
/// chat-mode rejection sits between generation and child-task creation.
private final class DTGeneratingClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let json = #"""
            {
                "name": "DT Generated Team",
                "description": "Synthetic team for the delegation tests",
                "roles": [
                    {
                        "name": "Worker",
                        "prompt": "Do the work.",
                        "produces_artifacts": ["Result"],
                        "requires_artifacts": [],
                        "tools": []
                    }
                ],
                "artifacts": [
                    {"name": "Result", "description": "Final output"}
                ],
                "supervisor_requires": ["Result"]
            }
            """#
            continuation.yield(StreamEvent(contentDelta: json))
            continuation.finish()
        }
    }
    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// Replays a fixed script of `StreamEvent`s, then finishes. Drives
/// `performStreamingCall` through its real path so the iteration tests exercise
/// production streaming rather than a hand-built `StreamingResult`.
private final class DTScriptedStreamClient: LLMClient, @unchecked Sendable {
    private let events: [StreamEvent]
    private(set) var sentMessages: [[ChatMessage]] = []

    init(events: [StreamEvent]) { self.events = events }

    func streamChat(
        config _: LLMConfig,
        messages: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sentMessages.append(messages)
        let scripted = events
        return AsyncThrowingStream { continuation in
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
    }
    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

// MARK: - handleDelegateToTeam: pre-flight, resolution and hand-off

/// Covers the parts of `handleDelegateToTeam` that the existing delegation
/// suites deliberately skip.
///
/// `DelegationReviewFixesTests` pins the depth cap at/above the limit;
/// `DelegateToTeamGenerationPlaceholderTests` pins the `create_team` placeholder
/// lifecycle and the generated-branch eligibility guard;
/// `DelegationControlsReentryTests` pins the three follow-up verbs;
/// `DelegationEnvelopesAndTaskStateTests` pins the success/paused envelope
/// shapes. None of them drive the entry handler's *resolution* stage — the
/// eligibility ladder, the two target-team branches, and the two
/// post-mutation verification guards that stand between a created child task
/// and a started engine. That is what this suite adds.
@MainActor
final class DelegateToTeamEntryResolutionTests: XCTestCase {

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

    // MARK: - Guards that must fire before anything is allocated

    /// The orchestrator was torn down (the service holds the delegate weakly).
    /// Every delegation entry point opens with this guard; without it the
    /// handler would run its whole resolution ladder against `nil`.
    func testDelegateDetached_returnsCommandFailed_withoutCreatingAnything() async {
        let task = seedParentTask()
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)
        service.delegate = nil

        let client = DTSilentClient()
        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("delegate unavailable"),
                      "A detached service must say so rather than proceed. envelope=\(envelope)")
        XCTAssertTrue(delegate.createdDelegatedTaskRequests.isEmpty)
        XCTAssertEqual(client.callCount, 0,
                       "The guard must short-circuit before any LLM work")
    }

    /// The liveness barrier: an orphaned call from a step whose execution state
    /// was already removed (pause / bulk cancel / task switch) must never spawn
    /// a child task against whatever now answers to the captured task id.
    func testStepNotRegistered_rejectedByLivenessBarrier() async {
        let task = seedParentTask()
        // Deliberately NOT calling `_testRegisterStepTask`.

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("no task context"),
                      "A torn-down step must be rejected by the liveness barrier. envelope=\(envelope)")
        XCTAssertTrue(delegate.createdDelegatedTaskRequests.isEmpty,
                      "An orphaned delegation must not allocate a child task")
        XCTAssertTrue(delegate.startedRunForTaskIDs.isEmpty)
    }

    // MARK: - Eligibility ladder

    /// No work-folder snapshot at all → `resolveTeam` yields nil. Every
    /// downstream check (role lookup, peer-status, whitelist) reads the parent
    /// team, so this has to fail loudly rather than fall through.
    func testParentTeamUnresolvable_returnsCommandFailed() async {
        let task = seedParentTask()
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)
        delegate.snapshot = nil

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("resolve parent team"),
                      "The diagnostic must name what could not be resolved. envelope=\(envelope)")
        XCTAssertTrue(delegate.createdDelegatedTaskRequests.isEmpty)
    }

    /// The delegating role was renamed or deleted from the team editor while
    /// the step was running. `parentRoleDef.id` is what gets stamped onto the
    /// child as `parentRoleID` (the escalation path keys `step.id == parentRoleID`),
    /// so an unresolvable role must abort rather than fall back to
    /// `initiatingRole.baseID`.
    func testInitiatingRoleAbsentFromParentTeam_returnsCommandFailed() async {
        let task = seedParentTask()
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            // Matches no role under any of `findRole`'s branches
            // (id / systemRoleID / name / normalized name).
            initiatingRole: .custom(id: "role_removed_from_team"),
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("resolve role"),
                      "Diagnostic must distinguish an unresolvable ROLE from an unresolvable TEAM. envelope=\(envelope)")
        XCTAssertTrue(delegate.createdDelegatedTaskRequests.isEmpty)
    }

    /// Peer-status invariant: only a role with no upstream `reportsTo` entry may
    /// delegate. The toolset↔hierarchy invariant is self-healed at load time,
    /// but a hand-edited / legacy `teams.json` can still present a subordinate
    /// role carrying `delegate_to_team`, and the runtime is the last line.
    func testRoleReportsToAnotherRole_isDeniedAsNonPeer() async {
        let task = seedParentTask(
            parentHierarchy: TeamHierarchy(reportsTo: [dtStepID: "some_manager_role"])
        )
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("DELEGATION_DENIED"),
                      "A subordinate role delegating must be denied, not merely warned. envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("peer"),
                      "The diagnostic must explain the peer-level rule so the model stops retrying. envelope=\(envelope)")
        XCTAssertTrue(delegate.createdDelegatedTaskRequests.isEmpty)
    }

    /// A role whose `reportsTo` entry points at ITSELF is still a peer —
    /// `roleIsTopLevelDelegator` treats the self-edge as "no upstream". A
    /// corrupted map must not silently disable a legitimately configured
    /// delegator.
    func testRoleReportsToItself_isStillTreatedAsPeer() async {
        let task = seedParentTask(
            parentHierarchy: TeamHierarchy(reportsTo: [dtStepID: dtStepID]),
            allowedDelegationTeamIDs: [dtTargetTeamID]
        )
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)
        // No `createDelegatedTaskStub` → the run stops at child creation, which
        // is already past every eligibility check this test cares about.

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertFalse(envelope.contains("DELEGATION_DENIED"),
                       "A self-edge is not an upstream entry; the role stays peer-level. envelope=\(envelope)")
        XCTAssertEqual(delegate.createdDelegatedTaskRequests.count, 1,
                       "The call must reach child-task creation")
    }

    // MARK: - Existing-team branch

    /// The whitelist is the authorization boundary for existing teams: a model
    /// that names any other team id must be refused even when that team exists
    /// and is perfectly runnable.
    func testTargetTeamNotWhitelisted_isDenied() async {
        let task = seedParentTask(allowedDelegationTeamIDs: [])  // empty whitelist
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("DELEGATION_DENIED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("whitelist"),
                      "The diagnostic must point at the whitelist, and the catalog embedded in the tool description, so the model re-picks rather than retries. envelope=\(envelope)")
        XCTAssertTrue(delegate.createdDelegatedTaskRequests.isEmpty)
    }

    /// Whitelisted but the team was deleted from the project since the schema
    /// (and therefore the inline catalog) was built. That is INVALID_ARGS, not
    /// DELEGATION_DENIED — the two are different remedies for the model: pick a
    /// different id vs. you were never allowed this one.
    func testWhitelistedTeamMissingFromProject_returnsInvalidArgs() async {
        let task = seedParentTask(
            allowedDelegationTeamIDs: [dtTargetTeamID],
            teamsInSnapshot: [makeParentTeam()]  // target team absent
        )
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("INVALID_ARGS"),
                      "A deleted-but-whitelisted team is an argument problem, not a policy denial. envelope=\(envelope)")
        XCTAssertFalse(envelope.contains("DELEGATION_DENIED"),
                       "The two rejection kinds must not collapse — their remedies differ. envelope=\(envelope)")
        XCTAssertTrue(delegate.createdDelegatedTaskRequests.isEmpty)
    }

    /// Small models routinely wrap the id in whitespace / a trailing newline
    /// copied out of the catalog. The whitelist check runs on the TRIMMED id,
    /// so a cosmetic difference must not read as an unauthorized team.
    func testTeamIDWithSurroundingWhitespace_isTrimmedBeforeAuthorization() async throws {
        let task = seedParentTask(allowedDelegationTeamIDs: [dtTargetTeamID])
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: "  \(dtTargetTeamID)\n",
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertFalse(envelope.contains("whitelist"),
                       "A padded id must not read as an unauthorized team. envelope=\(envelope)")
        XCTAssertFalse(envelope.contains("does not exist"),
                       "The trimmed id must also be what the project lookup uses. envelope=\(envelope)")
        let request = try XCTUnwrap(
            delegate.createdDelegatedTaskRequests.first,
            "The call must have reached child-task creation. envelope=\(envelope)")
        XCTAssertEqual(request.preferredTeamID, dtTargetTeamID,
                       "The child must be pinned to the TRIMMED id — a padded `preferredTeamID` would never resolve for the child engine")
    }

    /// Chat-mode teams never produce supervisor deliverables, so they never
    /// auto-complete and the parent would block for the full 30-minute timeout.
    /// They are filtered out of the inline catalog too, but the runtime check is
    /// what makes it structural.
    func testChatModeTargetTeam_isDenied() async {
        // Target team whose Supervisor requires nothing ⇒ `isChatMode`.
        let chatTarget = Team(
            id: dtTargetTeamID,
            name: dtTargetTeamName,
            roles: [makeSupervisorRole(requires: [])],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
        let task = seedParentTask(
            allowedDelegationTeamIDs: [dtTargetTeamID],
            teamsInSnapshot: [makeParentTeam(), chatTarget]
        )
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("DELEGATION_DENIED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("Chat-mode"),
                      "The diagnostic must name the reason — a chat team has no completion criterion. envelope=\(envelope)")
        XCTAssertTrue(delegate.createdDelegatedTaskRequests.isEmpty,
                      "The chat-mode check must precede child-task creation; a created-then-abandoned child is an orphan")
    }

    // MARK: - Depth cap boundary

    /// `DelegationReviewFixesTests` pins the rejection AT the cap. The other
    /// side of the boundary matters just as much: one level below must still be
    /// allowed, and the child must be stamped at exactly `parent + 1` so the
    /// next hop is the one that gets refused.
    func testOneBelowDepthCap_isAllowed_andStampsTheChildAtTheCap() async throws {
        var task = NTMSTask(
            id: dtParentTID,
            title: "deep",
            supervisorTask: "x",
            preferredTeamID: dtParentTeamID,
            parentTaskID: 0,
            parentRoleID: "ancestor_role",
            delegationDepth: DelegationConstants.maxDelegationDepth - 1
        )
        task.runs = [Run(id: 0, steps: [makeParentStep()])]
        installParent(task: task, teams: [makeParentTeam(), makeTargetTeam()])
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)

        XCTAssertEqual(task.delegationDepth, DelegationConstants.maxDelegationDepth - 1,
                       "Precondition: the lineage must normalize to one below the cap")

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertFalse(envelope.contains("DELEGATION_DENIED"),
                       "Depth cap - 1 must still delegate. envelope=\(envelope)")
        let request = try XCTUnwrap(delegate.createdDelegatedTaskRequests.first)
        XCTAssertEqual(request.depth, DelegationConstants.maxDelegationDepth,
                       "The child is stamped at parent + 1; the NEXT hop is what the cap refuses")
    }

    // MARK: - Post-creation verification guards

    /// `createDelegatedTask` returning nil means the repository refused. There
    /// is nothing to start and nothing to await; the handler must say so
    /// immediately rather than register an awaiter that can only time out.
    func testChildTaskCreationFails_abortsBeforeStartingOrAwaitingAnything() async {
        let task = seedParentTask(allowedDelegationTeamIDs: [dtTargetTeamID])
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)
        delegate.createDelegatedTaskStub = nil

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("Could not create delegated child task"), "envelope=\(envelope)")
        XCTAssertTrue(delegate.startedRunForTaskIDs.isEmpty,
                      "Nothing was created, so nothing may be started")
        XCTAssertTrue(delegate.awaitedTaskIDs.isEmpty,
                      "Registering an awaiter here would block the parent role for the full 30-minute timeout")
    }

    /// CLAUDE.md §7: `mutateTask` returning true means "persisted", NOT "the
    /// closure did something". The delegation marker is what the ENTIRE
    /// pause/cancel control plane keys on (`pauseRun`'s mid-delegation skip,
    /// `notifyDelegationInterrupt`, all three follow-up verbs), so the handler
    /// re-reads it and aborts loudly when it did not land.
    ///
    /// A parent task with no runs makes the mutation's own `guard` short-circuit
    /// while `mutateTask` still reports success — exactly the shape the guard
    /// exists for.
    func testDelegationMarkerDoesNotPersist_abortsAndTearsDownTheChild() async {
        var task = NTMSTask(
            id: dtParentTID,
            title: "Parent",
            supervisorTask: "x",
            preferredTeamID: dtParentTeamID
        )
        task.runs = []  // the marker mutation cannot land
        installParent(task: task, teams: [makeParentTeam(), makeTargetTeam()])
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)
        delegate.createDelegatedTaskStub = dtChildTID

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "do the thing",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("delegation marker"),
                      "The diagnostic must name the marker so the failure is attributable. envelope=\(envelope)")
        XCTAssertEqual(delegate.stopEngineCalls, [dtChildTID],
                       "The child must be torn down — without the marker no follow-up verb can ever reach it again")
        XCTAssertTrue(delegate.startedRunForTaskIDs.isEmpty,
                      "The abort happens BEFORE startRunForTask; starting an unreachable child is the worst outcome")
        XCTAssertTrue(delegate.awaitedTaskIDs.isEmpty,
                      "No awaiter may be registered for a child the parent can't control")
        XCTAssertFalse(delegate.lastErrorMessages.isEmpty,
                       "This failure is invisible to the human otherwise — the envelope only reaches the LLM")
    }

    /// Generated branch: `adoptGeneratedTeam` is the ONLY way the child engine
    /// can resolve a team that lives nowhere in `teams.json`. If it did not
    /// persist, `TaskEngineStoreAdapter.resolvedTeam` would fall through toward
    /// the parent-team fallback chain — the documented recursion bug. The
    /// handler verifies and aborts.
    ///
    /// The mock holds ONE loaded task, so `mutateTask(taskID: childTID)` misses
    /// and `loadedTask(childTID)` reads back nil — the production shape of "the
    /// child was created but never loaded".
    func testGeneratedTeamNotAdoptedByChild_abortsBeforeStartingIt() async {
        let task = seedParentTask(allowDelegationToGeneratedTeams: true)
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)
        delegate.createDelegatedTaskStub = dtChildTID

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: DelegationConstants.generatedTeamSentinel,
            taskBrief: "build a calculator",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTGeneratingClient(),
            config: dtConfig()
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("adoptGeneratedTeam"),
                      "The diagnostic must name the mutation that did not land. envelope=\(envelope)")
        XCTAssertTrue(delegate.startedRunForTaskIDs.isEmpty,
                      "A child whose roster never landed must not be started — it could only resolve the parent's team")
        XCTAssertTrue(delegate.awaitedTaskIDs.isEmpty)
        XCTAssertFalse(delegate.lastErrorMessages.isEmpty,
                       "Surfaced to the human banner, mirroring the marker guard")
    }

    // MARK: - Happy path (existing team)

    /// The whole entry pipeline in order: eligibility → target resolution →
    /// child creation with canonical parentage → marker persisted → engine
    /// started → awaiter entered on the CHILD → terminal envelope.
    ///
    /// `parentRoleID` is the load-bearing field. It MUST be the resolved
    /// `TeamRoleDefinition.id` (which equals `StepExecution.id`), never
    /// `initiatingRole.baseID` — the escalation path finds the owning step via
    /// `step.id == parentRoleID`, and for a built-in role `baseID` is the
    /// systemRoleID, which misses that key. The fixture keeps the two
    /// deliberately different so a regression cannot pass by coincidence.
    func testExistingTeamHappyPath_stampsCanonicalParentage_startsAndAwaitsTheChild() async throws {
        let task = seedParentTask(allowedDelegationTeamIDs: [dtTargetTeamID])
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)
        delegate.createDelegatedTaskStub = dtChildTID
        delegate.scriptedAwaitOutcomes = [.terminal(.done)]

        XCTAssertNotEqual(dtStepID, Role.codingAgent.baseID,
                          "Precondition: the role's id and its systemRoleID must differ, or the parentage assertion is vacuous")

        let envelope = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "ship the feature",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        let request = try XCTUnwrap(delegate.createdDelegatedTaskRequests.first)
        XCTAssertEqual(delegate.createdDelegatedTaskRequests.count, 1,
                       "Exactly one child per delegate_to_team call")
        XCTAssertEqual(request.parentTaskID, dtParentTID)
        XCTAssertEqual(request.parentRoleID, dtStepID,
                       "parentRoleID MUST be the canonical role-definition id (== StepExecution.id), not Role.baseID")
        XCTAssertEqual(request.preferredTeamID, dtTargetTeamID)
        XCTAssertEqual(request.depth, 1, "A root parent produces a depth-1 child")
        XCTAssertEqual(request.supervisorTask, "ship the feature",
                       "The brief must reach the child verbatim — it is the child's entire task statement")
        XCTAssertEqual(request.title, "Delegated · \(dtTargetTeamName)",
                       "An existing-team delegation must NOT carry the (generated) suffix")

        XCTAssertEqual(delegate.startedRunForTaskIDs, [dtChildTID],
                       "The child engine is started exactly once, after the marker is verified")
        XCTAssertEqual(delegate.awaitedTaskIDs, [dtChildTID],
                       "The awaiter must poll the CHILD; awaiting the parent would deadlock")

        // The marker survived long enough to be verified, then the terminal
        // outcome cleared it while preserving the append-only history the graph
        // renders as completed delegation layers.
        let step = delegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == dtStepID })
        XCTAssertNil(step?.activeDelegationChildID,
                     "A terminal outcome must clear the in-flight marker so the next delegation starts clean")
        XCTAssertEqual(step?.delegationChildIDs, [dtChildTID],
                       "The append-only history must survive the terminal cleanup")

        let dict = try dtParseEnvelope(envelope)
        XCTAssertEqual(dict["ok"] as? Bool, true, "envelope=\(envelope)")
        let data = try dtParseData(envelope)
        XCTAssertEqual(data["child_task_id"] as? Int, dtChildTID)
        XCTAssertEqual(data["team"] as? String, dtTargetTeamName)
        XCTAssertEqual(data["generated"] as? Bool, false,
                       "An existing-team delegation is not a generated one; the LLM branches on this flag")
    }

    /// No `create_team` placeholder may appear on the existing-team branch —
    /// the spinner pattern belongs exclusively to the generated one. (The
    /// generated-branch half of this invariant lives in
    /// `DelegateToTeamGenerationPlaceholderTests`; this is its complement on the
    /// full happy path, where generation is never even attempted.)
    func testExistingTeamHappyPath_emitsNoGenerationPlaceholder() async {
        let task = seedParentTask(allowedDelegationTeamIDs: [dtTargetTeamID])
        service._testRegisterStepTask(stepID: dtStepID, taskID: dtParentTID)
        delegate.createDelegatedTaskStub = dtChildTID
        delegate.scriptedAwaitOutcomes = [.terminal(.done)]

        _ = await service.handleDelegateToTeam(
            stepID: dtStepID,
            teamIDRaw: dtTargetTeamID,
            taskBrief: "ship the feature",
            initiatingRole: .codingAgent,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: DTSilentClient(),
            config: dtConfig()
        )

        let toolCalls = delegate.taskToMutate?.runs.last?.steps
            .first(where: { $0.id == dtStepID })?.toolCalls ?? []
        XCTAssertTrue(toolCalls.allSatisfy { $0.name != ToolNames.createTeam },
                      "A phantom 'generating…' card on an existing-team delegation would misreport what happened")
    }

    // MARK: - Fixtures

    /// Builds and installs a parent task + snapshot in the shape the handler
    /// expects, returning the task the caller should pass in. Every test breaks
    /// exactly one precondition so the failure is attributable.
    @discardableResult
    private func seedParentTask(
        parentHierarchy: TeamHierarchy = TeamHierarchy(),
        allowedDelegationTeamIDs: [NTMSID] = [dtTargetTeamID],
        allowDelegationToGeneratedTeams: Bool = false,
        teamsInSnapshot: [Team]? = nil
    ) -> NTMSTask {
        let parentTeam = makeParentTeam(
            hierarchy: parentHierarchy,
            allowedDelegationTeamIDs: allowedDelegationTeamIDs,
            allowDelegationToGeneratedTeams: allowDelegationToGeneratedTeams
        )
        var task = NTMSTask(
            id: dtParentTID,
            title: "Parent",
            supervisorTask: "x",
            preferredTeamID: dtParentTeamID
        )
        task.runs = [Run(id: 0, steps: [makeParentStep()])]
        installParent(task: task, teams: teamsInSnapshot ?? [parentTeam, makeTargetTeam()])
        return task
    }

    private func installParent(task: NTMSTask, teams: [Team]) {
        delegate.taskToMutate = task
        var state = WorkFolderState(name: "Test")
        state.activeTeamID = dtParentTeamID
        delegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: state,
                settings: .defaults,
                teams: teams
            ),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: dtParentTID,
            activeTask: task
        )
    }

    private func makeParentStep() -> StepExecution {
        StepExecution(id: dtStepID, role: .codingAgent, title: "Coding Agent", status: .running)
    }

    /// Parent team whose delegating role's `id` (`dtStepID`) is deliberately
    /// distinct from its `systemRoleID` (`Role.codingAgent.baseID`) — the
    /// production shape, and what makes the `parentRoleID` assertion meaningful.
    private func makeParentTeam(
        hierarchy: TeamHierarchy = TeamHierarchy(),
        allowedDelegationTeamIDs: [NTMSID] = [dtTargetTeamID],
        allowDelegationToGeneratedTeams: Bool = false
    ) -> Team {
        let delegator = TeamRoleDefinition(
            id: dtStepID,
            name: "Coding Agent",
            prompt: "p",
            toolIDs: [ToolNames.delegateToTeam],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowedDelegationTeamIDs: allowedDelegationTeamIDs,
            allowDelegationToGeneratedTeams: allowDelegationToGeneratedTeams,
            systemRoleID: Role.codingAgent.baseID
        )
        return Team(
            id: dtParentTeamID,
            name: dtParentTeamName,
            roles: [makeSupervisorRole(requires: ["Result"]), delegator],
            artifacts: [],
            settings: TeamSettings(hierarchy: hierarchy),
            graphLayout: TeamGraphLayout()
        )
    }

    /// A runnable (non chat-mode) delegation target: its Supervisor requires a
    /// deliverable, which is what gives the child a completion criterion.
    private func makeTargetTeam() -> Team {
        Team(
            id: dtTargetTeamID,
            name: dtTargetTeamName,
            roles: [makeSupervisorRole(requires: ["Result"])],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
    }

    private func makeSupervisorRole(requires: [String]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "supervisor_\(UUID().uuidString.prefix(6))",
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: requires),
            systemRoleID: "supervisor"
        )
    }
}

// MARK: - awaitDelegationCompletion: the arms the envelope suite skips

/// `DelegationEnvelopesAndTaskStateTests` covers the terminal arms (`.done`,
/// `.failed`, `.needsAcceptance`) and the two race re-checks on the
/// `.parentMessageQueued` path. What is left uncovered — and what this suite
/// adds — is the `.needsSupervisorInput` arm's failure mode, and the
/// `.parentMessageQueued` arm's marker-preservation contract, which is the
/// precondition for every follow-up verb being able to find the paused child.
@MainActor
final class DelegationAwaiterUncoveredArmsTests: XCTestCase {

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

    /// The defensive timeout — the one exit from the awaiter loop with real consequences,
    /// and the one no test could reach while the budget was a 1800-second constant.
    ///
    /// It stops the child engine, clears the parent's in-flight marker (so the follow-up verbs
    /// stop matching a child that is gone) and raises a human-visible banner, because the
    /// alternative — a collapsed tool-call card noticed half an hour later — is how a wedged
    /// child manifests otherwise.
    ///
    /// RED: restore the hard-coded `DelegationConstants.delegationTimeoutSeconds` deadline →
    /// this hangs instead of failing, which is itself the point.
    func testTimeout_stopsTheChild_clearsTheMarker_andRaisesABanner() async {
        service = LLMExecutionService(repository: NTMSRepository(), delegationTimeoutSeconds: 0)
        service.attach(delegate: delegate)

        let parent = makeParentWithLiveMarker()
        delegate.taskToMutate = parent
        delegate.scriptedAwaitOutcomes = []       // premise: the awaiter must never be consulted

        let team = makeMinimalTeam()
        let envelope = await service.awaitDelegationCompletion(
            childTID: dtChildTID,
            parentTID: dtParentTID,
            stepID: dtStepID,
            parentRoleDef: team.roles[0],
            parentTeam: team,
            targetTeam: team,
            isGeneratedFlow: false,
            generationWarnings: [],
            client: DTSilentClient(),
            config: dtConfig(),
            delegate: delegate
        )

        XCTAssertTrue(envelope.contains("DELEGATION_TIMED_OUT"), "envelope=\(envelope)")
        // The full phrase, NOT the bare "0-second timeout": the shipped constant is 1800, and
        // "1800-second timeout" CONTAINS "0-second timeout", so the short substring passes
        // against the very bug this line exists to catch (verified by mutation).
        XCTAssertTrue(envelope.contains("exceeded the 0-second timeout"),
                      "the envelope must report the budget that actually elapsed, not the shipped "
                          + "constant — the model reads this. envelope=\(envelope)")
        XCTAssertTrue(delegate.awaitedTaskIDs.isEmpty,
                      "the deadline is checked BEFORE awaiting, or a wedged child is waited on anyway")
        XCTAssertEqual(delegate.stopEngineCalls, [dtChildTID],
                       "a timed-out child must be torn down, not left running unreachable")

        let step = delegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == dtStepID })
        XCTAssertNil(step?.activeDelegationChildID,
                     "the in-flight marker must go, or every follow-up verb still matches a dead child")
        XCTAssertEqual(step?.delegationChildIDs, [dtChildTID],
                       "the append-only history survives the timeout, like every other cleanup")
        XCTAssertTrue(delegate.lastErrorMessages.contains { $0.contains("timed out") },
                      "a wedged child must reach the human banner; got: \(delegate.lastErrorMessages)")
    }

    /// The child asked its Supervisor a question and the side exchange could
    /// not produce an answer (here: the child task is no longer loaded, so
    /// `handleChildQuestion` bails at its first guard). The delegation must
    /// abort with a diagnostic — looping back into the awaiter would spin until
    /// the 30-minute timeout, since nothing about the child changed.
    func testNeedsSupervisorInput_answerFails_abortsAndClearsTheMarker() async {
        let parent = makeParentWithLiveMarker()
        delegate.taskToMutate = parent            // child is NOT loaded
        delegate.scriptedAwaitOutcomes = [.needsSupervisorInput]

        let team = makeMinimalTeam()
        let envelope = await service.awaitDelegationCompletion(
            childTID: dtChildTID,
            parentTID: dtParentTID,
            stepID: dtStepID,
            parentRoleDef: team.roles[0],
            parentTeam: team,
            targetTeam: team,
            isGeneratedFlow: false,
            generationWarnings: [],
            client: DTSilentClient(),
            config: dtConfig(),
            delegate: delegate
        )

        XCTAssertTrue(envelope.contains("COMMAND_FAILED"), "envelope=\(envelope)")
        XCTAssertTrue(envelope.contains("Failed to answer"),
                      "The diagnostic must distinguish an unanswerable question from a child failure. envelope=\(envelope)")
        XCTAssertEqual(delegate.awaitedTaskIDs, [dtChildTID],
                       "Exactly one awaiter pass — re-entering would spin to the timeout")

        let step = delegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == dtStepID })
        XCTAssertNil(step?.activeDelegationChildID,
                     "An aborted delegation must clear the in-flight marker")
        XCTAssertEqual(step?.delegationChildIDs, [dtChildTID],
                       "The append-only history survives every terminal cleanup")
        XCTAssertEqual(delegate.stopEngineCalls, [dtChildTID],
                       """
                       The child must be torn down BEFORE the marker is dropped, like the \
                       timeout and close-failure arms. Without it the child stays parked at \
                       .needsSupervisorInput with a live engine, is filtered out of the \
                       sidebar and Watchtower by `parentTaskID == nil`, and — because the \
                       marker this abort just cleared is what every follow-up verb and \
                       `notifyDelegationInterrupt` validate against — becomes permanently \
                       unreachable.
                       """)
    }

    /// Complement of the terminal arms: the paused envelope must leave the
    /// delegation markers ALONE. `cancel_delegation` / `resume_delegation` /
    /// `forward_to_team` all validate against `activeDelegationChildID`, so a
    /// cleared marker would make the envelope's own `next_actions` list
    /// unusable — every follow-up would answer INVALID_ARGS.
    func testParentMessageQueued_preservesTheMarkerSoFollowUpsCanFindTheChild() async throws {
        let parent = makeParentWithLiveMarker()
        delegate.taskToMutate = parent
        delegate.scriptedAwaitOutcomes = [.parentMessageQueued(text: "  stop and re-plan  ")]

        let team = makeMinimalTeam()
        let envelope = await service.awaitDelegationCompletion(
            childTID: dtChildTID,
            parentTID: dtParentTID,
            stepID: dtStepID,
            parentRoleDef: team.roles[0],
            parentTeam: team,
            targetTeam: team,
            isGeneratedFlow: false,
            generationWarnings: [],
            client: DTSilentClient(),
            config: dtConfig(),
            delegate: delegate
        )

        XCTAssertEqual(delegate.pauseRunCalls, [dtChildTID],
                       "The child is PAUSED, never stopped — the parent may still resume it")
        XCTAssertTrue(delegate.stopEngineCalls.isEmpty,
                      "Stopping would make resume_delegation restart the child from scratch")

        let data = try dtParseData(envelope)
        XCTAssertEqual(data["status"] as? String, "paused_by_supervisor")
        XCTAssertEqual(data["supervisor_message"] as? String, "stop and re-plan",
                       "The forwarded text is trimmed before it reaches the model")

        let step = delegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == dtStepID })
        XCTAssertEqual(step?.activeDelegationChildID, dtChildTID,
                       "A pause is NOT terminal — the marker must survive or every follow-up verb rejects with INVALID_ARGS")
    }

    /// Degenerate shape: the queued-message wake-up arrives for a child that is
    /// no longer loaded at all (evicted / removed). Neither race re-check can
    /// fire, so the handler still hands back the paused envelope and lets the
    /// follow-up verbs fail loudly with their own diagnostics. Characterization
    /// — it pins that an unloadable child does not crash or fabricate a
    /// terminal outcome.
    func testParentMessageQueued_childNotLoaded_stillReturnsPausedEnvelope() async throws {
        let parent = makeParentWithLiveMarker()
        delegate.taskToMutate = parent  // loadedTask(childTID) == nil
        delegate.scriptedAwaitOutcomes = [.parentMessageQueued(text: "check in")]

        let team = makeMinimalTeam()
        let envelope = await service.awaitDelegationCompletion(
            childTID: dtChildTID,
            parentTID: dtParentTID,
            stepID: dtStepID,
            parentRoleDef: team.roles[0],
            parentTeam: team,
            targetTeam: team,
            isGeneratedFlow: false,
            generationWarnings: [],
            client: DTSilentClient(),
            config: dtConfig(),
            delegate: delegate
        )

        let dict = try dtParseEnvelope(envelope)
        XCTAssertEqual(dict["ok"] as? Bool, true,
                       "An interrupt is a success outcome, not a failure. envelope=\(envelope)")
        let data = try dtParseData(envelope)
        XCTAssertEqual(data["status"] as? String, "paused_by_supervisor")
        XCTAssertEqual(data["child_task_id"] as? Int, dtChildTID,
                       "The envelope must name the child so the follow-up verbs can be called with the right id")
    }

    /// A non-terminal arm in the middle of the loop must not tear the delegation
    /// down. `.needsAcceptance` closes the child and RE-ENTERS the awaiter, so
    /// the marker has to survive that pass — otherwise a Supervisor interrupt
    /// arriving right after the close would land on a step that no longer
    /// records which child it owns, and all three follow-up verbs would reject.
    func testAcceptanceArm_reEntersTheLoop_withoutTearingDownTheDelegation() async throws {
        let parent = makeParentWithLiveMarker()
        delegate.taskToMutate = parent
        delegate.closeTaskStub = true
        delegate.scriptedAwaitOutcomes = [
            .terminal(.needsAcceptance),
            .parentMessageQueued(text: "hold on"),
        ]

        let team = makeMinimalTeam()
        let envelope = await service.awaitDelegationCompletion(
            childTID: dtChildTID,
            parentTID: dtParentTID,
            stepID: dtStepID,
            parentRoleDef: team.roles[0],
            parentTeam: team,
            targetTeam: team,
            isGeneratedFlow: false,
            generationWarnings: [],
            client: DTSilentClient(),
            config: dtConfig(),
            delegate: delegate
        )

        XCTAssertEqual(delegate.closedTaskIDs, [dtChildTID],
                       "Acceptance is auto-accepted exactly once")
        XCTAssertEqual(delegate.awaitedTaskIDs, [dtChildTID, dtChildTID],
                       "A successful close must RE-ENTER the awaiter rather than return; the engine's own .done transition is what ends the wait")
        XCTAssertEqual(delegate.pauseRunCalls, [dtChildTID],
                       "The second pass took the interrupt arm")

        let data = try dtParseData(envelope)
        XCTAssertEqual(data["status"] as? String, "paused_by_supervisor")

        let step = delegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == dtStepID })
        XCTAssertEqual(step?.activeDelegationChildID, dtChildTID,
                       "Neither the acceptance pass nor the pause is terminal — the marker must still name the child")
    }

    // MARK: - Fixtures

    /// Parent task carrying a live delegation marker on its step, so the
    /// clear/preserve assertions have something to observe.
    private func makeParentWithLiveMarker() -> NTMSTask {
        var task = NTMSTask(id: dtParentTID, title: "Parent", supervisorTask: "x")
        var step = StepExecution(id: dtStepID, role: .codingAgent, title: "Coding Agent", status: .running)
        step.setActiveDelegation(childID: dtChildTID)
        task.runs = [Run(id: 0, steps: [step])]
        return task
    }

    /// The awaiter only reads `parentRoleDef.id` (for escalation routing) and
    /// `targetTeam.name` / `supervisorRequiredArtifacts` (for the envelope), so
    /// a one-role team is sufficient and keeps the fixtures honest about what
    /// the function actually depends on.
    private func makeMinimalTeam() -> Team {
        let role = TeamRoleDefinition(
            id: dtStepID,
            name: "Coding Agent",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        return Team(
            id: dtParentTeamID,
            name: dtTargetTeamName,
            roles: [role],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
    }
}

// MARK: - runOneLLMToolIteration

/// End-to-end drives of the single-iteration orchestrator. No existing suite
/// calls `runOneLLMToolIteration` at all — every neighbouring test exercises
/// one of its callees in isolation, which leaves the ORCHESTRATION (ordering,
/// guard arms, the conversation mutations the iteration itself owns) unpinned.
///
/// These tests use the real streaming path (`performStreamingCall` against a
/// scripted client) rather than synthesizing a `StreamingResult`, so the
/// assertions cover the seam between the two.
@MainActor
final class LLMToolIterationOrchestrationTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var tracker: ToolCallTracker!
    private var memoryStore: MemoryTagStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-iter-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.workFolderURL = tempDir
        service.attach(delegate: delegate)

        // An EMPTY registry on purpose: these tests exercise the iteration's own
        // orchestration, not any handler. An unregistered tool yields an error
        // result, which is exactly the input the productivity accounting needs.
        runtime = ToolRuntime(registry: ToolRegistry(), logger: nil)
        tracker = ToolCallTracker()
        memoryStore = MemoryTagStore(workFolderRoot: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        memoryStore = nil
        tracker = nil
        runtime = nil
        service = nil
        delegate = nil
        try await super.tearDown()
    }

    /// The very first guard. It must return BEFORE the force-indexed
    /// `task.runs[runIndex].steps[stepIndex]` read two lines below — a detached
    /// orchestrator with a stale index would otherwise trap rather than
    /// degrade.
    func testNoDelegate_returnsToolFailure_withoutIndexingTheTask() async throws {
        let task = seedTask()
        service._testRegisterStepTask(stepID: itStepID, taskID: itTaskID)
        service.delegate = nil

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        var usage = TokenUsage()

        let stop = try await service.runOneLLMToolIteration(
            stepID: itStepID,
            roleForMessage: .softwareEngineer,
            client: DTSilentClient(),
            config: dtConfig(),
            tools: [],
            runtime: runtime,
            task: task,
            // Deliberately out of bounds: reachable only if the guard is removed.
            runIndex: 99,
            stepIndex: 99,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage
        )

        guard case .toolFailure(let message) = stop else {
            return XCTFail("Expected .toolFailure when the delegate is gone, got \(stop)")
        }
        XCTAssertEqual(message, "Delegate not available")
        XCTAssertEqual(conversation.count, 1,
                       "A guarded-out iteration must not mutate the conversation")
    }

    /// A plain prose reply with no tool call: the iteration appends the
    /// assistant turn, routes to `handleNoToolCalls`, and continues. The
    /// shape-independent non-productive ceiling is incremented exactly once —
    /// emitting nothing is the canonical non-productive turn.
    func testProseOnlyTurn_appendsAssistantTurn_nudgesAndContinues() async throws {
        let task = seedTask()
        service._testRegisterStepTask(stepID: itStepID, taskID: itTaskID)

        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "build it"),
        ]
        var usage = TokenUsage()
        let client = DTScriptedStreamClient(events: [
            StreamEvent(contentDelta: "Here is my plan in prose."),
            StreamEvent(tokenUsage: TokenUsage(inputTokens: 100, outputTokens: 7)),
        ])

        let stop = try await service.runOneLLMToolIteration(
            stepID: itStepID,
            roleForMessage: .softwareEngineer,
            client: client,
            config: dtConfig(),
            tools: [],
            runtime: runtime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage
        )

        guard case .continueLoop = stop else {
            return XCTFail("A single prose turn must nudge and continue, got \(stop)")
        }
        XCTAssertEqual(usage.outputTokens, 7,
                       "Token usage reported by the stream must accumulate into the caller's counter")
        XCTAssertEqual(usage.inputTokens, 100)

        XCTAssertTrue(
            conversation.contains { $0.role == .assistant && $0.content == "Here is my plan in prose." },
            "The assistant turn IS the request on the next iteration; omitting it shows the model tool results for calls it has no record of. conversation=\(conversation.map(\.role))"
        )
        XCTAssertEqual(conversation.last?.role, .user,
                       "handleNoToolCalls appends its nudge as the trailing user turn — append is the only prefix-preserving mutation")
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: itStepID, taskID: itTaskID), 1,
                       "A turn that emitted nothing must advance the shape-independent ceiling exactly once")
        XCTAssertEqual(
            delegate.commitStreamingCalls.map { $0.2 }, ["Here is my plan in prose."],
            "The real streaming path must have committed the turn — these tests are worthless against a synthesized StreamingResult")
    }

    /// A clean stream (no in-stream loop signal) resets the consecutive
    /// thinking-loop-break counter. Pinned here rather than through the helper
    /// because the reset lives in the ITERATION, not in the recovery policy: a
    /// refactor that drops the call would leave a stale count that terminates
    /// the step two breaks later for no reason.
    func testCleanStream_resetsTheThinkingLoopBreakCounter() async throws {
        let task = seedTask()
        service._testRegisterStepTask(stepID: itStepID, taskID: itTaskID)
        service._testSetThinkingLoopBreakCount(stepID: itStepID, taskID: itTaskID, count: 1)

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        var usage = TokenUsage()

        _ = try await service.runOneLLMToolIteration(
            stepID: itStepID,
            roleForMessage: .softwareEngineer,
            client: DTScriptedStreamClient(events: [StreamEvent(contentDelta: "ok")]),
            config: dtConfig(),
            tools: [],
            runtime: runtime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage
        )

        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: itStepID, taskID: itTaskID), 0,
                       "Any clean stream completion resets the consecutive-break count")
    }

    /// `ask_supervisor` is auto-answered under autonomous mode, so a turn whose
    /// ONLY tool call is `ask_supervisor` is not acting — the model can ping
    /// itself with it forever. It must advance the non-productive ceiling, and
    /// must do so exactly once even though the post-results accounting runs
    /// again on the same turn (`ToolTurnProductivity.alreadyCounted`).
    func testAskSupervisorOnlyTurn_countsAsNonProductive_exactlyOnce() async throws {
        let task = seedTask()
        service._testRegisterStepTask(stepID: itStepID, taskID: itTaskID)

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        var usage = TokenUsage()
        let tools = [
            ToolSchema(name: ToolNames.askSupervisor, description: "Ask", parameters: .object(properties: [:]))
        ]
        let client = DTScriptedStreamClient(events: [
            StreamEvent(toolCallDeltas: [
                StreamEvent.ToolCallDelta(
                    index: 0, id: "call-1",
                    name: ToolNames.askSupervisor, argumentsDelta: "{\"question\":\"?\"}")
            ])
        ])

        var observed: [[StepToolCall]] = []
        let stop = try await service.runOneLLMToolIteration(
            stepID: itStepID,
            roleForMessage: .softwareEngineer,
            client: client,
            config: dtConfig(),
            tools: tools,
            runtime: runtime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage,
            toolObserver: { calls, _ in observed.append(calls) }
        )

        guard case .continueLoop = stop else {
            return XCTFail("One ask_supervisor turn is under the ceiling and must continue, got \(stop)")
        }
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: itStepID, taskID: itTaskID), 1,
                       "Counted once at the pre-execution check; the post-results pass must classify it .alreadyCounted, never double-count")
        XCTAssertEqual(observed.first?.map(\.name), [ToolNames.askSupervisor],
                       "The observer must see the resolved call in emit order")
        XCTAssertTrue(
            conversation.contains { $0.role == .assistant && ($0.toolCalls?.isEmpty == false) },
            "The assistant turn must carry its tool calls; the stateless resend re-materializes them from here")
    }

    /// Emitting a parseable tool call resets the shape-specific caps (drift and
    /// Harmony parse-failure share one reset) — the model is acting, not just
    /// reasoning. The reset lives in the ITERATION, so a refactor that drops the
    /// call is only caught here; the helper-level tests delegate to the same
    /// production method and would stay green.
    ///
    /// Drift is the counter this drives because it can be primed through a real
    /// production path (`handleNoToolCalls`' drift arm) rather than a setter.
    func testParseableToolCall_resetsTheShapeSpecificCaps() async throws {
        let task = seedTask()
        service._testRegisterStepTask(stepID: itStepID, taskID: itTaskID)

        // Prime the drift counter through production: a long reasoning trace
        // with no content and no tool call is the canonical drift turn.
        var priming: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: itStepID,
            assistantContent: "",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: nil,
            conversationMessages: &priming,
            thinkingContent: String(
                repeating: "reasoning ",
                count: ConversationRepairService.thinkingDriftLengthThreshold / 10 + 200)
        )
        XCTAssertEqual(service._testDriftCounter(stepID: itStepID, taskID: itTaskID), 1,
                       "Precondition: the drift counter must be armed before the iteration runs")

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        var usage = TokenUsage()
        let tools = [
            ToolSchema(name: ToolNames.readFile, description: "Read", parameters: .object(properties: [:]))
        ]
        let client = DTScriptedStreamClient(events: [
            StreamEvent(toolCallDeltas: [
                StreamEvent.ToolCallDelta(
                    index: 0, id: "call-1",
                    name: ToolNames.readFile, argumentsDelta: "{\"path\":\"a.txt\"}")
            ])
        ])

        _ = try await service.runOneLLMToolIteration(
            stepID: itStepID,
            roleForMessage: .softwareEngineer,
            client: client,
            config: dtConfig(),
            tools: tools,
            runtime: runtime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage
        )

        XCTAssertEqual(service._testDriftCounter(stepID: itStepID, taskID: itTaskID), 0,
                       "A parseable tool call clears the drift cap — the model acted, so the next drift turn starts a fresh streak")
        XCTAssertEqual(service._testHarmonyParseFailureCounter(stepID: itStepID, taskID: itTaskID), 0,
                       "The same reset covers the Harmony parse-failure cap")
    }

    /// Images are single-use. Once sent, they must be dropped from the
    /// in-memory conversation so the next iteration's (otherwise byte-identical)
    /// prefix carries no base64 payload — the model saw the screenshot exactly
    /// once, and re-sending it both bloats the prompt and re-anchors attention.
    func testConversationCarriedImages_stripsThemAfterSending() async throws {
        let task = seedTask()
        service._testRegisterStepTask(stepID: itStepID, taskID: itTaskID)

        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(
                role: .user,
                content: "what is on screen?",
                imageContent: [ImageContent(base64Data: "QUJD", mimeType: "image/png")]
            ),
        ]
        var usage = TokenUsage()
        let client = DTScriptedStreamClient(events: [StreamEvent(contentDelta: "a window")])

        _ = try await service.runOneLLMToolIteration(
            stepID: itStepID,
            roleForMessage: .softwareEngineer,
            client: client,
            config: dtConfig(),
            tools: [],
            runtime: runtime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage
        )

        XCTAssertTrue(
            conversation.allSatisfy { $0.imageContent?.isEmpty ?? true },
            "Every image must be nilled out of the in-memory conversation after the send")
        XCTAssertEqual(conversation[1].content, "what is on screen?",
                       "Only the image payload is stripped — the accompanying text must survive verbatim, or the prefix breaks for a second reason")

        // The request itself DID carry the image: the strip is post-send.
        let sent = try XCTUnwrap(client.sentMessages.first)
        XCTAssertTrue(
            sent.contains { !($0.imageContent?.isEmpty ?? true) },
            "The strip must happen AFTER the request is built; stripping first would send the model a question about an image it never received")
    }

    /// The complementary case: a conversation with no images must come back
    /// untouched. The strip loop is unconditional over indices, so a regression
    /// that drops the `sentImages` gate would still pass the test above.
    func testConversationWithoutImages_isLeftUntouched() async throws {
        let task = seedTask()
        service._testRegisterStepTask(stepID: itStepID, taskID: itTaskID)

        let original: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "go"),
        ]
        var conversation = original
        var usage = TokenUsage()

        _ = try await service.runOneLLMToolIteration(
            stepID: itStepID,
            roleForMessage: .softwareEngineer,
            client: DTScriptedStreamClient(events: [StreamEvent(contentDelta: "ok")]),
            config: dtConfig(),
            tools: [],
            runtime: runtime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage
        )

        XCTAssertEqual(Array(conversation.prefix(original.count)), original,
                       "Existing turns must never be rewritten — append at `count` is the only prefix-preserving mutation")
    }

    /// A queued Supervisor message must be drained into THIS iteration's
    /// request. It is delivered immediately (that is the whole point of the
    /// queue), and it must reach the wire, not just the display record.
    func testQueuedSupervisorMessage_isDrainedIntoThisIterationsRequest() async throws {
        let task = seedTask()
        service._testRegisterStepTask(stepID: itStepID, taskID: itTaskID)
        delegate.scriptedQueuedMessages = [
            (taskID: itTaskID, roleID: nil, content: "look at the parser instead")
        ]

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        var usage = TokenUsage()
        let client = DTScriptedStreamClient(events: [StreamEvent(contentDelta: "ok")])

        _ = try await service.runOneLLMToolIteration(
            stepID: itStepID,
            roleForMessage: .softwareEngineer,
            client: client,
            config: dtConfig(),
            tools: [],
            runtime: runtime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage
        )

        XCTAssertEqual(delegate.consumedQueuedMessages.count, 1,
                       "The queue must be drained exactly once per iteration")
        let sent = try XCTUnwrap(client.sentMessages.first)
        XCTAssertTrue(
            sent.contains { ($0.content ?? "").contains("look at the parser instead") },
            "A queued message that does not reach the wire is a message the model never received")
    }

    /// The queue must NOT be touched for a step whose execution state is gone —
    /// popping is destructive, so an orphaned iteration would silently eat the
    /// human's message.
    func testQueuedSupervisorMessage_notDrainedForATornDownStep() async throws {
        let task = seedTask()
        // No `_testRegisterStepTask` → `isExecutionLive` is false.
        delegate.scriptedQueuedMessages = [
            (taskID: itTaskID, roleID: nil, content: "do not lose me")
        ]

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        var usage = TokenUsage()

        _ = try await service.runOneLLMToolIteration(
            stepID: itStepID,
            roleForMessage: .softwareEngineer,
            client: DTScriptedStreamClient(events: [StreamEvent(contentDelta: "ok")]),
            config: dtConfig(),
            tools: [],
            runtime: runtime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage
        )

        XCTAssertTrue(delegate.consumedQueuedMessages.isEmpty,
                      "A torn-down step must not destructively pop the Supervisor queue")
        XCTAssertEqual(delegate.scriptedQueuedMessages.count, 1,
                       "The message must still be there for the step that replaces this one")
    }

    /// The iteration re-reads the task through `refreshedTaskSnapshot`, so a
    /// mutation committed by a previous iteration is visible to THIS one.
    /// Pinned end-to-end (the helper contract itself is pinned by
    /// `IterationBoundaryRefreshTests`): here the fresh snapshot is what lets
    /// artifact completeness see an artifact the stale value does not have.
    func testCompletedArtifact_committedOutOfBand_isSeenViaTheFreshSnapshot() async throws {
        let task = seedTask(expectedArtifacts: ["Result"])
        service._testRegisterStepTask(stepID: itStepID, taskID: itTaskID)

        // Commit the artifact through the delegate only — the caller's `task`
        // value stays stale, exactly like a mid-loop `mutateTask`.
        _ = await delegate.mutateTask(taskID: itTaskID) { t in
            t.runs[0].steps[0].artifacts = [
                Artifact(name: "Result", mimeType: "text/markdown")
            ]
        }
        XCTAssertTrue(task.runs[0].steps[0].artifacts.isEmpty,
                      "Precondition: the caller's snapshot must still be stale")

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        var usage = TokenUsage()
        // A tool-emitting turn on purpose: the completeness check is step 7, and
        // a no-tool-call turn short-circuits into `handleNoToolCalls` at step 4
        // and never reaches it.
        let tools = [
            ToolSchema(name: ToolNames.readFile, description: "Read", parameters: .object(properties: [:]))
        ]
        let client = DTScriptedStreamClient(events: [
            StreamEvent(toolCallDeltas: [
                StreamEvent.ToolCallDelta(
                    index: 0, id: "call-1",
                    name: ToolNames.readFile, argumentsDelta: "{\"path\":\"a.txt\"}")
            ])
        ])

        let stop = try await service.runOneLLMToolIteration(
            stepID: itStepID,
            roleForMessage: .softwareEngineer,
            client: client,
            config: dtConfig(),
            tools: tools,
            runtime: runtime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage
        )

        guard case .completed = stop else {
            return XCTFail("All expected artifacts are present on the refreshed snapshot; the step must auto-complete. Got \(stop)")
        }
    }

    // MARK: - Fixtures

    @discardableResult
    private func seedTask(expectedArtifacts: [String] = []) -> NTMSTask {
        var step = StepExecution(
            id: itStepID, role: .softwareEngineer, title: "Engineer", status: .running)
        step.expectedArtifacts = expectedArtifacts
        var task = NTMSTask(id: itTaskID, title: "T", supervisorTask: "build")
        task.runs = [Run(id: 0, steps: [step])]
        delegate.taskToMutate = task
        return task
    }
}
