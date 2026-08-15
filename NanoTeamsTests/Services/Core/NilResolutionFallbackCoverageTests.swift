import XCTest

@testable import NanoTeams

// Coverage for the `??` fallback arms that fire when a resolution returns nil:
// no work folder open (`snapshot == nil`), or a run pinned to a team that no
// longer exists (`resolveTeam(task:) == nil` via `TeamResolution`'s fail-fast).
//
// These are not defensive dead code. Each one decides something the app then
// acts on — which cap binds, what the model is told to do next, whether stale
// downstream work is held — and the whole cluster is only reachable while the
// app is already in a degraded state, which is exactly when a wrong answer is
// hardest to notice.
//
// Ordered by consequence, not by line count:
//   1. `ToolErrorNotePolicy.direction` — the text the MODEL reads after a failed tool
//      call. Three whole branches (`plan_required`, `precondition_failed`,
//      `bash_denied`) were never exercised; each exists specifically because the
//      default branch's wording sends the model into a loop.
//   2. `handleTeammateConsultation` / `handleTeamMeeting` with an unresolvable
//      team — `team?.settings ?? .default` decides which limits bind.
//   3. `propagateAmendmentDownstream` — whether stale downstream work is held.
//   4. `performAutovisorAction` with no work folder — which tuning caps bind and
//      which failure reason the manager LLM is given.
//
// No network and no filesystem writes: every LLM call goes through a scripted
// client, and the only `workFolderURL` used is a path that is never created.

// MARK: - Scripted client

/// Yields one scripted content chunk, or throws. Records call count so a test
/// can assert that a rejection happened BEFORE the wire, not after it.
private final class NilFallbackScriptedClient: LLMClient, @unchecked Sendable {
    var content: String
    var shouldThrow: Error?
    private(set) var callCount = 0

    init(content: String = "", shouldThrow: Error? = nil) {
        self.content = content
        self.shouldThrow = shouldThrow
    }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        callCount += 1
        if let shouldThrow {
            return AsyncThrowingStream { $0.finish(throwing: shouldThrow) }
        }
        let c = content
        return AsyncThrowingStream { continuation in
            if !c.isEmpty { continuation.yield(StreamEvent(contentDelta: c)) }
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

private struct NilFallbackStreamError: Error, LocalizedError {
    var errorDescription: String? { "scripted stream failure" }
}

// MARK: - 1. Tool-error direction: the three never-exercised branches

/// `ToolErrorNotePolicy` turns a failed tool result into the `.user` follow-up the model
/// reads. Its `default` arm blames arguments unless the code family says otherwise; three
/// codes exist precisely because that wording is wrong for them. Until this suite none of
/// the three had a test, so deleting any of the three `case`s would have compiled, shipped,
/// and produced plausible-but-looping guidance.
///
/// The nil-resolutions under test narrowed when the policy stopped restating the envelope:
/// the intro fallbacks (`?? "Tool 'X' becomes available…"`, `?? "Tool 'X' is unavailable."`,
/// `?? "The command was blocked…"`) went with the intros. What remains — and is pinned
/// here — is the tool-name resolution `(dict["tool"] as? String) ?? result.toolName`, which
/// is what keeps an anti-retry instruction attached to a named call.
@MainActor
final class NilFallbackToolErrorGuidanceTests: XCTestCase {

    // MARK: plan_required

    /// `plan_required` is the ONE rejection with a retry contract: the role owns the
    /// tool, every work-folder precondition is met, and the identical call succeeds
    /// once `update_scratchpad` records the plan. Guidance must therefore steer TOWARD
    /// repeating the call — the opposite of every other rejection.
    ///
    /// Driven through the real emitter (`makeUnavailableToolResult`) rather than a
    /// hand-rolled envelope, so a change to the envelope shape breaks this test
    /// instead of silently orphaning the branch.
    ///
    /// RED: route `.withheldUntilPlanRecorded` to `errorCode = "precondition_failed"` (or
    /// delete the `plan_required` case so it falls through to `default`) → the model is
    /// handed "Do not retry 'read_file'", looks for a substitute tool that does not exist,
    /// and never records the plan that unblocks it → the nil assertion fails.
    func testPlanRequired_steersTowardRecordingThePlanAndRepeatingTheCall() async {
        let call = StepToolCall(name: "read_file", argumentsJSON: #"{"path":"a.swift"}"#)
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call,
            canonicalName: "read_file",
            scope: "for this role",
            reason: .withheldUntilPlanRecorded
        )
        let message = envelope.outputJSON

        XCTAssertTrue(
            message.contains("update_scratchpad"),
            "the unblocking call must be named — it is the only exit from this state; got: \(message)"
        )
        XCTAssertTrue(
            message.contains("call 'read_file' again"),
            "the retry contract must be stated explicitly, got: \(message)"
        )
        XCTAssertFalse(
            message.lowercased().contains("do not retry"),
            "plan_required is temporal, not structural — anti-retry steering strands the model; got: \(message)"
        )
        XCTAssertFalse(
            message.contains("different tool"),
            "no substitute tool exists for a phase-withheld call, got: \(message)"
        )
        // Everything above is in the envelope, which the model reads one turn earlier — so
        // the policy adds nothing. A paraphrase here reads as a SECOND instruction.
        XCTAssertNil(ToolErrorNotePolicy.direction(for: envelope))
    }

    /// The tool-name resolution, on the arm that still uses it. A degraded envelope carries
    /// no `tool` field, so the name has to come from the RESULT — otherwise the model is
    /// told "do not retry ''" and cannot tell which call was refused, which is worse than
    /// no direction at all.
    ///
    /// RED: drop the `?? result.toolName` fallback (e.g. `dict?["tool"] as? String ?? ""`)
    /// → the direction renders empty quotes → `contains("'read_lines'")` fails.
    func testToolNotAuthorized_bareEnvelope_namesTheToolFromTheResult() async throws {
        let envelope = ToolExecutionResult(
            toolName: "read_lines",
            argumentsJSON: "{}",
            outputJSON: #"{"error":"tool_not_authorized"}"#,
            isError: true
        )

        let guidance = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope))

        XCTAssertTrue(
            guidance.contains("do not retry 'read_lines'"),
            "the anti-loop instruction must name the tool from the result, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("''"),
            "a missing tool field must never render as empty quotes, got: \(guidance)"
        )
    }

    // MARK: precondition_failed

    /// A missing `.git` is a property of the work folder, not of the arguments. The
    /// `default` arm would answer "If the message indicates bad arguments, fix them
    /// and retry" for this code (it ends in neither `_DENIED` nor `_TIMED_OUT`), which
    /// is the loop this branch exists to prevent — no argument spelling creates a repo.
    ///
    /// RED: delete the `precondition_failed` case → the guidance loses "Do not retry
    /// 'git_add'" and gains the argument-blaming default direction →
    /// `guidance.contains("Do not retry 'git_add'")` fails.
    func testPreconditionFailed_namesTheWorkFolderBlockerAndForbidsRetry() async throws {
        let call = StepToolCall(name: "git_add", argumentsJSON: #"{"paths":["a.swift"]}"#)
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: call,
            canonicalName: "git_add",
            scope: "for this role",
            reason: .gitRepoMissing
        )

        XCTAssertTrue(
            envelope.outputJSON.contains(".git"),
            "the ENVELOPE names the actual blocker, got: \(envelope.outputJSON)"
        )

        let guidance = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope))

        XCTAssertTrue(
            guidance.contains("Do not retry 'git_add'"),
            "a work-folder precondition cannot be fixed from inside the role, got: \(guidance)"
        )
        XCTAssertTrue(
            guidance.contains("the precondition is set by the work folder, not by your arguments"),
            "the direction must say WHY retrying is pointless, got: \(guidance)"
        )
        // The default arm's ACTUAL wording for this envelope, not "Fix the arguments and retry."
        // That string is emitted only under `case "INVALID_ARGS"`, and the code there is read as
        // `errorObj?["code"]` — nested only — while `makeUnavailableToolResult` writes `error` as
        // a TOP-LEVEL String. So the old assertion could not fail on any input and proved nothing;
        // this one fails the moment the precondition branch stops matching and the envelope falls
        // through, which is the regression the test is named for.
        XCTAssertFalse(
            guidance.contains("otherwise choose a different approach"),
            "falling through to the default arm loses the named blocker, got: \(guidance)"
        )
    }

    /// Degraded `precondition_failed` envelope: no `tool`, no `message`. The direction is
    /// unchanged by that — it never read the message — but it must still name the tool from
    /// the result, or the anti-retry instruction attaches to nothing.
    ///
    /// RED: drop the `?? result.toolName` fallback → the direction says "Do not retry ''".
    func testPreconditionFailed_bareEnvelope_stillNamesTheToolFromTheResult() async throws {
        let envelope = ToolExecutionResult(
            toolName: "run_xcodebuild",
            argumentsJSON: "{}",
            outputJSON: #"{"error":"precondition_failed"}"#,
            isError: true
        )

        let guidance = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope))

        XCTAssertTrue(
            guidance.contains("Do not retry 'run_xcodebuild'"),
            "the anti-retry instruction must survive a message-less envelope, got: \(guidance)"
        )
        XCTAssertFalse(guidance.contains("''"), "got: \(guidance)")
    }

    // MARK: bash_denied

    /// `BASH_DENIED` means the command never ran — a deny rule, a judge rejection, or
    /// an approval that could not be obtained. Re-issuing it hits the same policy, so
    /// the guidance names alternatives (read-only / already-approved / ask the
    /// Supervisor) that the `default` arm does not offer.
    ///
    /// Driven through the real `makeErrorEnvelope(code: .bashDenied, …)` — that emitter
    /// writes the code UPPERCASE under `error.code`, so this also pins the
    /// `errorCode?.lowercased()` normalisation for a nested-shape envelope.
    ///
    /// RED: delete the `bash_denied` case → `BASH_DENIED` falls to `default`, whose
    /// `_DENIED` family arm produces "Tool 'bash' failed: [BASH_DENIED] …" — the machine
    /// code leaks into the prose and the alternatives disappear →
    /// `XCTAssertFalse(guidance.contains("[BASH_DENIED]"))` fails.
    func testBashDenied_surfacesThePolicyReasonAndOffersAlternatives() async throws {
        let envelope = ToolExecutionResult(
            toolName: "bash",
            argumentsJSON: #"{"command":"rm -rf /"}"#,
            outputJSON: makeErrorEnvelope(code: .bashDenied, message: "Blocked by deny rule: rm"),
            isError: true
        )

        XCTAssertTrue(
            envelope.outputJSON.contains("Blocked by deny rule: rm"),
            "the policy's own reason is the ENVELOPE's, got: \(envelope.outputJSON)"
        )

        let guidance = try XCTUnwrap(ToolErrorNotePolicy.direction(for: envelope))

        XCTAssertTrue(
            guidance.contains("Do NOT retry this command"),
            "a denied command never executed — retrying re-hits the same policy, got: \(guidance)"
        )
        XCTAssertTrue(
            guidance.contains("ask the Supervisor"),
            "the escalation route is what makes this branch better than the default arm, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("[BASH_DENIED]"),
            "the bracketed code prefix belongs to the default arm — its presence proves this branch was bypassed, got: \(guidance)"
        )
        XCTAssertFalse(
            guidance.contains("Blocked by deny rule: rm"),
            "the direction must not restate the envelope's reason, got: \(guidance)"
        )
    }

    /// The direction for `bash_denied` is a CONSTANT: it says the block is policy and lists
    /// the ways out, and it does not read the envelope's message at all.
    ///
    /// That property is what retired three separate nil-fallbacks (`?? "The command was
    /// blocked…"`, the empty-string collapse, the leading-space shape). Pinning the
    /// invariant is stronger than pinning each fallback: it holds for envelope shapes
    /// nobody has thought of yet, including ones with no `error` object at all.
    ///
    /// RED: reintroduce the reason as an intro → the three directions stop being equal.
    func testBashDenied_directionIsConstant_becauseItNeverReadsTheMessage() async throws {
        let shapes: [(String, String)] = [
            ("full", makeErrorEnvelope(code: .bashDenied, message: "Blocked by deny rule: rm")),
            ("no message", #"{"ok":false,"error":{"code":"BASH_DENIED"}}"#),
            ("empty message", #"{"ok":false,"error":{"code":"BASH_DENIED","message":""}}"#),
        ]

        var directions: [String] = []
        for (label, json) in shapes {
            let envelope = ToolExecutionResult(
                toolName: "bash", argumentsJSON: #"{"command":"ls"}"#,
                outputJSON: json, isError: true)
            let guidance = try XCTUnwrap(
                ToolErrorNotePolicy.direction(for: envelope), "\(label) produced no direction")
            XCTAssertFalse(
                guidance.hasPrefix(" "),
                "\(label): a missing reason must never render as a leading space, got: '\(guidance)'")
            directions.append(guidance)
        }

        XCTAssertEqual(Set(directions).count, 1,
                       "the direction must not vary with the envelope's message: \(directions)")
    }
}

// MARK: - Shared fixtures for the deleted-team-mid-run scenario

private enum NilFallbackFixtures {
    static let stepID = "team_swe"
    static let taskID = 4242
    static let ghostTeamID = "deleted_team_id"
    static let requester: Role = .softwareEngineer

    /// A run PINNED (`Run.teamID`) to a team the folder no longer contains. This is
    /// `TeamResolution`'s `.pinnedMissing` rung — the deleted-mid-run case that made
    /// the pin exist — so `LLMExecutionService.resolveTeam` answers nil loudly.
    static func taskPinnedToDeletedTeam(
        consultations: [TeammateConsultation] = []
    ) -> NTMSTask {
        let step = StepExecution(
            id: stepID, role: requester, title: "SWE step", status: .running,
            consultations: consultations)
        let run = Run(id: 0, steps: [step], teamID: ghostTeamID)
        return NTMSTask(
            id: taskID, title: "T", supervisorTask: "brief", runs: [run],
            preferredTeamID: ghostTeamID)
    }

    /// A folder with NO teams at all, so neither the pin nor the `activeTeam`
    /// fallback can resolve.
    static func emptyFolderSnapshot(task: NTMSTask) -> WorkFolderContext {
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "T", activeTeamID: nil),
            settings: .defaults,
            teams: [])
        return WorkFolderContext(
            projection: projection, tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: task.id, activeTask: task)
    }

    static func stubConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
    }

    static func consultation(question: String, consulted: Role) -> TeammateConsultation {
        var c = TeammateConsultationService.createConsultation(
            requestingRole: requester, consultedRole: consulted, question: question, context: nil)
        c.complete(with: "answered", responseTimeMs: 1)
        return c
    }
}

// MARK: - 2. Collaboration handlers with an unresolvable team

/// `handleTeammateConsultation` and `handleTeamMeeting` both open with
/// `let teamSettings = team?.settings ?? .default`. Reaching the `??` requires
/// `resolveTeam(task:)` to answer nil, which — per `TeamResolution` — happens for a
/// run pinned to a deleted team. Everything downstream (which limits bind, which
/// roles are consultable, which ids light up the graph) is then decided by
/// `TeamSettings.default` rather than by any team the user configured.
@MainActor
final class NilFallbackCollaborationNoTeamTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    /// A path that is NEVER created. `handleTeamMeeting` requires a non-nil
    /// `workFolderURL` before it will run, but on the paths under test nothing
    /// reads or writes it: logging is off (so no tool-call JSONL), no tool
    /// executes, and `NTMSPaths` is pure path arithmetic.
    private var phantomFolder: URL!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        phantomFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nilfallback-never-created-\(UUID().uuidString)", isDirectory: true)
        mockDelegate.workFolderURL = phantomFolder
        mockDelegate.loggingEnabled = false
    }

    override func tearDown() async throws {
        mockDelegate = nil
        service = nil
        phantomFolder = nil
        try await super.tearDown()
    }

    private func install(_ task: NTMSTask) {
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = NilFallbackFixtures.emptyFolderSnapshot(task: task)
        service._testRegisterStepTask(stepID: NilFallbackFixtures.stepID, taskID: NilFallbackFixtures.taskID)
    }

    /// The pin exists so a deleted team fails LOUDLY instead of swapping rosters
    /// mid-run. `resolveTeam`'s `.failed` arm is the only thing that turns that
    /// decision into something a human can see: the collaboration handler itself
    /// returns a perfectly ordinary reply afterwards, so nothing else in this flow
    /// would ever mention that the roster vanished.
    ///
    /// RED: make `resolveTeam`'s `.failed` arm `return nil` without calling
    /// `delegate?.setLastErrorMessageForUI(reason)` → the run keeps collaborating on
    /// a team that no longer exists with zero user-visible signal →
    /// `mockDelegate.lastErrorMessages` stays empty.
    func testDeletedMidRunTeam_surfacesTheRefusalReason_onTheConsultationPath() async {
        let task = NilFallbackFixtures.taskPinnedToDeletedTeam()
        install(task)
        let client = NilFallbackScriptedClient(content: "advice")

        _ = await service.handleTeammateConsultation(
            stepID: NilFallbackFixtures.stepID, consultedRoleID: "techLead",
            question: "q", context: nil,
            requestingRole: NilFallbackFixtures.requester, task: task,
            runIndex: 0, stepIndex: 0,
            client: client, config: NilFallbackFixtures.stubConfig())

        XCTAssertTrue(
            mockDelegate.lastErrorMessages.contains { $0.contains("Refusing to swap rosters mid-run") },
            "the pinned-team-deleted refusal must reach the banner, got: \(mockDelegate.lastErrorMessages)"
        )
        XCTAssertTrue(
            mockDelegate.lastErrorMessages.contains { $0.contains(NilFallbackFixtures.ghostTeamID) },
            "the reason must name the missing team id, got: \(mockDelegate.lastErrorMessages)"
        )
    }

    /// With the team gone, `TeamSettings.default` supplies the limits — and
    /// `TeamLimits.default.maxConsultationsPerStep` (5) is what actually binds. This is
    /// the fail-VISIBLE direction: a bounded cap that stops the loop, rather than the
    /// unbounded consultation spend an "unknown team ⇒ no limits" reading would allow.
    ///
    /// Asserted against the constant rather than a literal so the pin tracks the default
    /// instead of freezing today's number.
    ///
    /// One-sided ON ITS OWN: `hasReachedLimit` is `count >= limit`, so seeding exactly the
    /// cap also passes for any SMALLER fallback. The companion below seeds `cap - 1` and
    /// requires the call through, which is what pins the fallback at the default rather
    /// than merely at-or-below it.
    ///
    /// RED: replace `team?.settings ?? .default` with a permissive stand-in (e.g.
    /// `?? TeamSettings(limits: TeamLimits(maxConsultationsPerStep: .max))`) → the cap
    /// no longer binds, the consultation reaches the wire →
    /// `XCTAssertEqual(client.callCount, 0)` fails.
    func testDeletedMidRunTeam_consultationLimit_collapsesToTheDefaultCap() async {
        let atCap = (0..<TeamLimits.default.maxConsultationsPerStep).map {
            NilFallbackFixtures.consultation(question: "q\($0)", consulted: .productManager)
        }
        let task = NilFallbackFixtures.taskPinnedToDeletedTeam(consultations: atCap)
        install(task)
        let client = NilFallbackScriptedClient(content: "advice")

        let reply = await service.handleTeammateConsultation(
            stepID: NilFallbackFixtures.stepID, consultedRoleID: "techLead",
            question: "one more", context: nil,
            requestingRole: NilFallbackFixtures.requester, task: task,
            runIndex: 0, stepIndex: 0,
            client: client, config: NilFallbackFixtures.stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(
            reply.text.contains("Consultation limit reached"),
            "the default cap must be the one enforced, got: \(reply.text)"
        )
        XCTAssertEqual(
            client.callCount, 0,
            "a capped consultation must be rejected before the wire, not after"
        )
    }

    /// The other side of the cap, and the half that makes the pair mean "= default".
    /// One below it, the consultation must go through — a fallback that silently
    /// tightened to 1 would still satisfy the at-cap test above while starving every
    /// deleted-team step of the consultations the default allows.
    ///
    /// RED: narrow the fallback (`?? TeamSettings(limits: TeamLimits(maxConsultationsPerStep: 1))`)
    /// → the call is refused at `cap - 1` and `client.callCount == 1` fails.
    func testDeletedMidRunTeam_consultationOneBelowTheCap_stillReachesTheWire() async {
        let belowCap = (0..<(TeamLimits.default.maxConsultationsPerStep - 1)).map {
            NilFallbackFixtures.consultation(question: "q\($0)", consulted: .productManager)
        }
        let task = NilFallbackFixtures.taskPinnedToDeletedTeam(consultations: belowCap)
        install(task)
        let client = NilFallbackScriptedClient(content: "advice")

        let reply = await service.handleTeammateConsultation(
            stepID: NilFallbackFixtures.stepID, consultedRoleID: "techLead",
            question: "one more", context: nil,
            requestingRole: NilFallbackFixtures.requester, task: task,
            runIndex: 0, stepIndex: 0,
            client: client, config: NilFallbackFixtures.stubConfig())

        XCTAssertTrue(reply.succeeded, "one below the cap must not be refused: \(reply.text)")
        XCTAssertEqual(
            client.callCount, 1,
            "the fallback cap is the DEFAULT, not something tighter"
        )
    }

    /// CHOICE: with `team == nil`, `consultationValidationError`'s membership gate is
    /// `if let team` — so it is SKIPPED, and `TeamSettings.default.invitableRoles` is
    /// empty (which the code reads as "no allow-list, everyone permitted"). A built-in
    /// role that was never on any team is therefore consulted and the LLM IS called.
    /// The alternatives are (a) today's fail-open — the reply is still useful text, and
    /// the run is already failing for an unrelated reason (the pin refusal above), so
    /// rejecting here adds a second error without saving anything; (b) reject, spending
    /// no tokens on a "teammate" that provably does not exist. Both are defensible;
    /// the code picked (a) and nothing states it, hence this pin.
    ///
    /// **Re-litigated 2026-08-09 and left as (a), with the argument for (b) recorded so the
    /// next reader starts from here rather than from scratch.** (b) has a real precedent in this
    /// codebase: `TeamResolution.teamSettings(for:in:)` returns nil on `.failed`/`.noTeam`
    /// specifically "so a deleted team never borrows another team's acceptance mode", and this
    /// path does borrow — `team?.settings ?? .default`. What holds (a) in place is reachability
    /// plus blast radius. `team == nil` here implies the run is already doomed: a step only runs
    /// because the engine resolved a team at run start, so nil means the team was deleted
    /// underneath it and `TaskEngineStoreAdapter` will fail the run at the next reconcile. And
    /// the fallback is load-bearing beyond this gate — `testDeletedMidRunTeam_consultationOne
    /// BelowTheCap_stillReachesTheWire` pins the DEFAULT consultation cap on the same path, and
    /// refusing earlier would make that fallback unreachable. Switching to (b) is therefore a
    /// product decision about a doomed run, not a bug fix, and it must retire both pins together.
    ///
    /// FIXTURE: run pinned to `deleted_team_id`, folder holds zero teams, consulted role
    /// `techLead` (a valid `Role.builtInRole` id, member of nothing).
    func testCharacterization_deletedMidRunTeam_consultsANonMemberAndReachesTheWire() async {
        let task = NilFallbackFixtures.taskPinnedToDeletedTeam()
        install(task)
        let client = NilFallbackScriptedClient(content: "here is my advice")

        let reply = await service.handleTeammateConsultation(
            stepID: NilFallbackFixtures.stepID, consultedRoleID: "techLead",
            question: "q", context: nil,
            requestingRole: NilFallbackFixtures.requester, task: task,
            runIndex: 0, stepIndex: 0,
            client: client, config: NilFallbackFixtures.stubConfig())

        XCTAssertTrue(reply.succeeded, "got: \(reply.text)")
        XCTAssertEqual(reply.text, "here is my advice")
        XCTAssertEqual(
            client.callCount, 1,
            "current behaviour is fail-open: the consultation runs even with no team to be a member of"
        )
        XCTAssertFalse(
            reply.text.contains("not a member of this team"),
            "the membership gate is team-conditional and cannot fire here"
        )
    }

    /// The meeting announces its participants to the UI before the first turn, and the
    /// `defer` clears them afterwards — so the announcement is what pairs with the
    /// clear. With no team there is no roster to map ids through, and `?? p.baseID`
    /// is the only answer available; what must NOT be lost is the INITIATOR, inserted
    /// separately on the line below. A meeting whose own initiator is missing from the
    /// participant set leaves that role un-glowed for the whole meeting.
    ///
    /// The scripted client throws, so the meeting fails on its first turn — the
    /// announcement has already happened by then, and nothing writes to disk.
    ///
    /// RED: delete the `allParticipantIDs.insert(team?.findRole(…) ?? initiatingRole.baseID)`
    /// line → the initiator never appears →
    /// `XCTAssertTrue(announced.contains(Role.softwareEngineer.baseID))` fails.
    func testDeletedMidRunTeam_meetingAnnouncesParticipantsAndTheInitiatorByBaseID() async {
        let task = NilFallbackFixtures.taskPinnedToDeletedTeam()
        install(task)
        let client = NilFallbackScriptedClient(shouldThrow: NilFallbackStreamError())

        let reply = await service.handleTeamMeeting(
            stepID: NilFallbackFixtures.stepID, topic: "topic",
            participantIDs: ["techLead"], context: nil,
            initiatingRole: NilFallbackFixtures.requester, task: task,
            runIndex: 0, stepIndex: 0,
            client: client, config: NilFallbackFixtures.stubConfig())

        XCTAssertFalse(reply.succeeded, "the scripted stream failed; got: \(reply.text)")

        let announced = mockDelegate.setMeetingParticipantsCalls.last?.0 ?? []
        XCTAssertTrue(
            announced.contains(Role.techLead.baseID),
            "with no roster to map through, the participant's own baseID is the id; got: \(announced)"
        )
        XCTAssertTrue(
            announced.contains(Role.softwareEngineer.baseID),
            "the initiator is a participant in its own meeting and must be announced; got: \(announced)"
        )
    }

    /// `handleChangeRequest` opens with the same `team?.settings ?? .default`, then hands
    /// the nil team to `ChangeRequestService.validateChangeRequest`, whose first guard is
    /// `team?.findRole(byIdentifier:)`. With no roster the target cannot resolve, so the
    /// request is refused BEFORE `handleTeamMeeting` runs — which is the consequence worth
    /// pinning: a change request that reached the voting stage with no team would spend a
    /// full multi-turn meeting and then tally votes over a roster that does not exist.
    ///
    /// The "Available roles:" suffix is absent for the same reason (`team?.roles ?? []` is
    /// empty), so the rejection names no alternatives — correct here, since there are none.
    ///
    /// RED: move the `resolveTeam` result past validation (e.g. default the roster to the
    /// folder's active team) → the vote runs, `client.callCount` becomes non-zero, and a
    /// meeting record is written to a task pinned to a deleted team.
    func testDeletedMidRunTeam_changeRequest_isRefusedBeforeAnyVotingMeeting() async {
        let task = NilFallbackFixtures.taskPinnedToDeletedTeam()
        install(task)
        let client = NilFallbackScriptedClient(content: "unused")

        let reply = await service.handleChangeRequest(
            stepID: NilFallbackFixtures.stepID, targetRoleID: "techLead",
            changes: "rewrite", reasoning: "stale",
            requestingRole: NilFallbackFixtures.requester, task: task,
            runIndex: 0, stepIndex: 0,
            client: client, config: NilFallbackFixtures.stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(
            reply.text.contains("Target role 'techLead' not found in the team."),
            "got: \(reply.text)"
        )
        XCTAssertFalse(
            reply.text.contains("Available roles:"),
            "an empty roster has no alternatives to offer; the suffix must be omitted, got: \(reply.text)"
        )
        XCTAssertEqual(client.callCount, 0, "no voting meeting may run without a roster")
        XCTAssertTrue(
            mockDelegate.taskToMutate?.runs[0].meetings.isEmpty ?? false,
            "a refused change request must leave no meeting record behind"
        )
        XCTAssertTrue(
            mockDelegate.taskToMutate?.runs[0].changeRequests.isEmpty ?? false,
            "the request never became a record — only a voted-on one is persisted"
        )
    }

    /// The `?? .default` limits also govern the meeting cap. `TeamLimits.default
    /// .maxMeetingsPerRun` (3) is what binds when the team is gone — the same
    /// fail-visible direction as the consultation cap, and the reason the rejection
    /// message can quote a number at all.
    ///
    /// RED: replace `team?.settings ?? .default` with an unlimited stand-in → the
    /// meeting proceeds past the cap → `reply.succeeded` becomes true and the
    /// "Meeting limit reached" assertion fails.
    func testDeletedMidRunTeam_meetingLimit_collapsesToTheDefaultCap() async {
        var task = NilFallbackFixtures.taskPinnedToDeletedTeam()
        task.runs[0].meetings = (0..<TeamLimits.default.maxMeetingsPerRun).map { _ in
            TeamMeetingService.createMeeting(
                topic: "prior", initiatedBy: NilFallbackFixtures.requester,
                participants: [.techLead], context: nil)
        }
        install(task)
        let client = NilFallbackScriptedClient(content: "unused")

        let reply = await service.handleTeamMeeting(
            stepID: NilFallbackFixtures.stepID, topic: "one more",
            participantIDs: ["techLead"], context: nil,
            initiatingRole: NilFallbackFixtures.requester, task: task,
            runIndex: 0, stepIndex: 0,
            client: client, config: NilFallbackFixtures.stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(
            reply.text.contains("Meeting limit reached"),
            "the default per-run meeting cap must be the one enforced, got: \(reply.text)"
        )
        XCTAssertEqual(client.callCount, 0, "a capped meeting must never reach the wire")
    }

    /// The other side of the meeting cap. `hasReachedMeetingLimit` is `count >= limit`,
    /// so the at-cap test above also passes for any tighter fallback; only this one
    /// distinguishes "collapses to the default" from "collapses to something smaller".
    ///
    /// RED: narrow the fallback (`?? TeamSettings(limits: TeamLimits(maxMeetingsPerRun: 1))`)
    /// → the meeting is refused one below the default cap and `reply.succeeded` fails.
    func testDeletedMidRunTeam_meetingOneBelowTheCap_stillRuns() async {
        var task = NilFallbackFixtures.taskPinnedToDeletedTeam()
        task.runs[0].meetings = (0..<(TeamLimits.default.maxMeetingsPerRun - 1)).map { _ in
            TeamMeetingService.createMeeting(
                topic: "prior", initiatedBy: NilFallbackFixtures.requester,
                participants: [.techLead], context: nil)
        }
        install(task)
        let client = NilFallbackScriptedClient(content: "a turn")

        let reply = await service.handleTeamMeeting(
            stepID: NilFallbackFixtures.stepID, topic: "one more",
            participantIDs: ["techLead"], context: nil,
            initiatingRole: NilFallbackFixtures.requester, task: task,
            runIndex: 0, stepIndex: 0,
            client: client, config: NilFallbackFixtures.stubConfig())

        XCTAssertFalse(
            reply.text.contains("Meeting limit reached"),
            "one below the default cap must not be refused as capped: \(reply.text)"
        )
    }
}

// MARK: - 3. Amendment propagation with a missing roster / missing status

/// `propagateAmendmentDownstream` decides whether downstream roles are held for
/// revision after an upstream amendment. Two `??` arms gate that decision: the
/// roster it walks (`team?.roles ?? []`) and the status it reads per downstream
/// role (`roleStatuses[roleID] ?? .idle`). Both answer "do nothing", which is safe
/// but silent — the amendment lands on the target while stale downstream work keeps
/// its now-invalid input.
@MainActor
final class NilFallbackAmendmentPropagationTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    private let taskID = 91

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    /// PM produces "Spec"; SWE requires it. `getDownstreamRoles(of: pm)` == [swe].
    private func makeTeam() -> Team {
        Team(
            name: "PropTeam",
            roles: [
                TeamRoleDefinition(
                    id: "team_pm", name: "Product Manager", prompt: "",
                    toolIDs: [], usePlanningPhase: false,
                    dependencies: RoleDependencies(producesArtifacts: ["Spec"]),
                    systemRoleID: "productManager"),
                TeamRoleDefinition(
                    id: "team_swe", name: "Software Engineer", prompt: "",
                    toolIDs: [], usePlanningPhase: false,
                    dependencies: RoleDependencies(requiredArtifacts: ["Spec"]),
                    systemRoleID: "softwareEngineer"),
            ],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout())
    }

    private func installTask(roleStatuses: [String: RoleExecutionStatus]) {
        let sweStep = StepExecution(
            id: "team_swe", role: .softwareEngineer, title: "SWE", status: .done)
        let run = Run(id: 0, steps: [sweStep], roleStatuses: roleStatuses)
        mockDelegate.taskToMutate = NTMSTask(
            id: taskID, title: "T", supervisorTask: "b", runs: [run])
        mockDelegate.eventLog.removeAll()
    }

    /// When the team cannot be resolved there is no dependency graph, so nothing can
    /// be identified as downstream — and the method must return before its
    /// `mutateTask`, not enter it and write an empty pass. The `mutateTask` absence is
    /// the load-bearing assertion: it proves the early `guard` fired rather than the
    /// loop running over an empty roster and persisting a no-op.
    ///
    /// RED: substitute any non-empty roster for `team?.roles ?? []` (e.g. resolve the
    /// folder's active team) → `getDownstreamRoles` finds a match, `mutateTask` runs,
    /// and a role on a team this task is not pinned to gets a `revisionComment` →
    /// the `eventLog` assertion fails.
    func testPropagation_withNoResolvableTeam_writesNothingAtAll() async {
        installTask(roleStatuses: ["team_swe": .done])

        let result = await service.propagateAmendmentDownstream(
            taskID: taskID, sourceRoleID: "team_pm", changes: "redo it", team: nil)

        XCTAssertEqual(result.summary, "No downstream roles affected.")
        XCTAssertTrue(result.runningRoleIDs.isEmpty)
        XCTAssertFalse(
            mockDelegate.eventLog.contains { $0.hasPrefix("mutate-begin") },
            "an unresolvable roster must return before the mutation, got: \(mockDelegate.eventLog)"
        )
        XCTAssertNil(
            mockDelegate.taskToMutate?.runs[0].steps[0].revisionComment,
            "no downstream role may be queued for revision when there is no roster to identify one"
        )
    }

    /// Positive control for the pair below: with the status entry present and `.done`,
    /// the downstream role IS notified and queued. Without this the characterization
    /// test could pass for the wrong reason (e.g. the roster lookup silently failing).
    ///
    /// RED: drop the `isDone` arm's `roleStatuses[roleID] = .revisionRequested` write →
    /// the downstream role finishes on stale upstream output →
    /// `XCTAssertEqual(…roleStatuses["team_swe"], .revisionRequested)` fails.
    func testPropagation_downstreamRoleWithADoneStatus_isNotifiedAndQueued() async {
        installTask(roleStatuses: ["team_swe": .done])

        let result = await service.propagateAmendmentDownstream(
            taskID: taskID, sourceRoleID: "team_pm", changes: "redo it", team: makeTeam())

        XCTAssertTrue(
            result.summary.contains("Downstream amendments triggered: team_swe"),
            "got: \(result.summary)"
        )
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].roleStatuses["team_swe"], .revisionRequested)
        XCTAssertNotNil(
            mockDelegate.taskToMutate?.runs[0].steps[0].revisionComment,
            "the raw revision payload is what `resetStepForRevision` prefers; it must be set"
        )
    }

    /// CHOICE: a downstream role whose STEP is `.done` but which has no entry in
    /// `run.roleStatuses` reads as `.idle`, so the `isDone || isRunning` guard skips it
    /// and its stale work is left in place. The alternatives are (a) today's `.idle` —
    /// never reset a role whose completion the run does not record, which keeps
    /// propagation from fighting an engine that has not seeded the role yet; (b) derive
    /// from the STEP (`.done` step ⇒ done role), which would notify it, at the cost of
    /// queueing a revision for a role the run is not tracking. The step status alone
    /// says the work finished and is now stale, so (b) is not obviously wrong — the
    /// code picked (a) and nothing states it.
    ///
    /// Reachability: `RunService.initialRoleStatuses` seeds every role of the roster it
    /// saw, but `findOrCreateStep` can add a step later — a role added to the team after
    /// the run started has a step and no seeded status.
    ///
    /// FIXTURE: identical to the control above except `roleStatuses` is empty.
    func testCharacterization_downstreamRoleWithNoStatusEntry_isLeftOnStaleInput() async {
        installTask(roleStatuses: [:])

        let result = await service.propagateAmendmentDownstream(
            taskID: taskID, sourceRoleID: "team_pm", changes: "redo it", team: makeTeam())

        XCTAssertEqual(
            result.summary, "No downstream roles needed updates.",
            "a missing status entry reads as .idle — the role is skipped, not amended"
        )
        XCTAssertTrue(result.runningRoleIDs.isEmpty)
        XCTAssertNil(
            mockDelegate.taskToMutate?.runs[0].steps[0].revisionComment,
            "the skipped role gets no amendment notice"
        )
        XCTAssertNil(
            mockDelegate.taskToMutate?.runs[0].roleStatuses["team_swe"],
            "and no status is invented for it"
        )
    }
}

// MARK: - 4. Autovisor actions with no work folder open

/// `performAutovisorAction`'s `create_managed_task` arm reads two folder settings
/// through `snapshot?.…` — the tuning caps and the team-generation policy. With no
/// folder open both `??` arms fire, and each decides what the MANAGER LLM is told:
/// which cap it hit, or whether generation is available at all.
///
/// Nothing here touches disk: `createTask` and `mutateWorkFolder` both open with
/// `guard let url = workFolderURL`, which is nil for an orchestrator that never
/// opened a folder.
final class NilFallbackAutovisorNoFolderTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// The per-review creation cap must still bind when there is no folder to read a
    /// user-tuned value from — otherwise a manager pass with an unreadable snapshot
    /// has NO burst ceiling, which is the runaway this guard exists to stop. Asserted
    /// against `AutovisorTuning.default` rather than a literal so the pin tracks the
    /// default instead of freezing today's number.
    ///
    /// The concurrency cap is checked first, so the test asserts it cannot be the one
    /// firing — otherwise a regression that moved the per-review guard could pass here.
    ///
    /// RED: move the per-review check inside an `if let snapshot` (or drop `?? .default`
    /// so the cap is skipped when the snapshot is nil) → the call falls through to
    /// `createTask`, which fails for a different reason →
    /// `result.message.contains("Per-review task-creation limit")` fails.
    func testCreateManagedTask_withNoFolder_stillEnforcesThePerReviewCap() async {
        XCTAssertGreaterThan(
            AutovisorTuning.default.maxConcurrentManagedTasks, 0,
            "precondition: the concurrency cap must not be the guard that fires"
        )
        XCTAssertNil(sut.snapshot, "precondition: no work folder is open")
        sut.autovisorCreationsThisReview = AutovisorTuning.default.maxManagedTasksPerReview

        let result = await sut.performAutovisorAction(
            .createManagedTask(title: "T", brief: "B", teamID: nil))

        XCTAssertFalse(result.ok)
        XCTAssertTrue(
            result.message.contains("Per-review task-creation limit"),
            "the default per-review cap must bind with no folder open, got: \(result.message)"
        )
        XCTAssertTrue(
            result.message.contains("\(AutovisorTuning.default.maxManagedTasksPerReview)"),
            "the message must quote the cap the manager actually hit, got: \(result.message)"
        )
    }

    /// `autovisorAllowTeamGeneration` fails OPEN when there is no snapshot to read it
    /// from. That matters because the failure the manager receives is its only signal:
    /// reporting "Team generation is disabled for the Autovisor in this folder" would
    /// be a claim about a policy that was never authored, and would teach the manager
    /// to stop requesting generated teams permanently. The honest failure is the one
    /// that actually happened — task creation, because there is no folder.
    ///
    /// RED: flip `snapshot?.…autovisorAllowTeamGeneration ?? true` to `?? false` → the
    /// classifier answers `.generationDisabled` and the manager is told generation is
    /// switched off → the "disabled" assertion fails.
    func testCreateManagedTask_generatedSentinel_withNoFolder_isNotReportedAsDisabled() async {
        XCTAssertNil(sut.snapshot, "precondition: no work folder is open")

        let result = await sut.performAutovisorAction(
            .createManagedTask(
                title: "T", brief: "B", teamID: DelegationConstants.generatedTeamSentinel))

        XCTAssertFalse(result.ok)
        XCTAssertFalse(
            result.message.contains("Team generation is disabled"),
            "an unread policy must not be reported as switched off, got: \(result.message)"
        )
        XCTAssertEqual(
            result.message, "Failed to create task.",
            "the reported reason must be the one that actually blocked, got: \(result.message)"
        )
    }

    /// An omitted `team_id` means "use the folder's active team". The chat-team refusal
    /// on that path is gated on `snapshot?.workFolder.activeTeam` being present AND
    /// chat-mode; with no snapshot there is no active team to classify, so it must fall
    /// through to `.useActiveTeam` and fail on creation instead of inventing a verdict
    /// about a team it never saw.
    ///
    /// RED: change the omitted-id branch to treat an unreadable active team as
    /// `.unknown(raw)` or `.activeTeamIsChat` → the manager is told to pick a pipeline
    /// team from a catalog that does not exist → the exact-message assertion fails.
    func testCreateManagedTask_omittedTeamID_withNoFolder_makesNoClaimAboutTheActiveTeam() async {
        XCTAssertNil(sut.snapshot, "precondition: no work folder is open")

        let result = await sut.performAutovisorAction(
            .createManagedTask(title: "T", brief: "B", teamID: nil))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.message, "Failed to create task.",
            "no active team is readable, so no chat/unknown verdict may be reported, got: \(result.message)"
        )
    }

    /// A task-targeted action against a task that is not loaded must fail loudly rather
    /// than no-op downstream: every verb below this guard would otherwise mutate nothing
    /// and report success (the §7 `mutateTask == true` trap). With no folder open,
    /// `loadedTask` answers nil for every id, which is the cheapest way to reach it.
    ///
    /// RED: drop the `guard loadedTask(target) != nil` → `applyControlTask .pause` runs
    /// `reportingError` over a `pauseRun` that finds nothing, surfaces no error, and
    /// reports `ok: true` for a task that does not exist → `XCTAssertFalse(result.ok)` fails.
    func testTaskTargetedAction_againstAnUnloadedTask_failsLoudly() async {
        let result = await sut.performAutovisorAction(.controlTask(taskID: 777, verb: .pause))

        XCTAssertFalse(result.ok)
        XCTAssertTrue(
            result.message.contains("Task #777 not found"),
            "the manager needs the id it got wrong, got: \(result.message)"
        )
        XCTAssertTrue(
            result.message.contains("list_tasks"),
            "the recovery route must be named, got: \(result.message)"
        )
    }
}
