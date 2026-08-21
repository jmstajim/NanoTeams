import XCTest

@testable import NanoTeams

/// End-to-end pins for `LLMExecutionService.handleTeamMeeting` — the whole turn
/// loop, not just its guards.
///
/// Coverage context (measured 2026-08-07): `LLMExecutionService+TeamMeeting.swift`
/// sat at **7.4%** — 339 of 366 executable lines unreached, the single largest
/// uncovered file outside `Views/`. Every existing meeting test deliberately
/// short-circuits at an early guard (`CollaborationDispatchMeetingAttributionTests`
/// passes an EMPTY participant list on purpose; `ChangeRequestVotingFailureTests`
/// leaves `workFolderURL == nil`), so the 296-line body — speaker rotation, turn
/// limit, per-speaker config resolution, meeting persistence — had never run under
/// test at all.
///
/// These drive a real meeting to completion against a scripted client: no network,
/// no LM Studio, a temp work folder, and a 2-turn limit so the loop terminates
/// deterministically through the turn-limit branch.
@MainActor
final class TeamMeetingFlowTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let stepID = "team_software_engineer"
    private let taskID = 41
    private let initiator: Role = .softwareEngineer

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-flow-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - The full turn loop

    /// The headline path: a meeting with one valid participant runs turns until the
    /// turn limit, completes, and is persisted with the speakers' messages.
    ///
    /// Asserts the OUTCOME (a completed meeting carrying turns), not the number of
    /// turns — `determineNextSpeaker` rotation is a policy detail these tests should
    /// not freeze.
    func testMeeting_runsTurnsToTheLimit_andRecordsACompletedMeeting() async {
        let team = makeTeam(maxTurns: 2)
        let task = makeTask(team: team)
        seed(task: task, team: team)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "Ship the parser", participantIDs: ["team_pm"],
            context: "some context", initiatingRole: initiator, task: task,
            runIndex: 0, stepIndex: 0,
            client: ScriptedMeetingClient(reply: "I agree, ship it."), config: stubConfig())

        XCTAssertTrue(reply.succeeded, "a meeting with a valid participant must succeed; got: \(reply.text)")

        let meetings = mockDelegate.taskToMutate?.runs.first?.meetings ?? []
        XCTAssertEqual(meetings.count, 1, "exactly one meeting must be persisted, got \(meetings.count)")
        guard let meeting = meetings.first else { return }
        XCTAssertEqual(meeting.status, .completed,
                       "hitting the turn limit must complete the meeting, not leave it active")
        XCTAssertFalse(meeting.messages.isEmpty,
                       "the turn loop must have recorded at least one spoken turn")
        XCTAssertTrue(meeting.messages.contains { $0.content.contains("ship it") },
                      "the scripted speaker content must reach the meeting transcript")
        XCTAssertEqual(meeting.topic, "Ship the parser")
        XCTAssertEqual(meeting.initiatedBy.baseID, initiator.baseID)
    }

    /// The UI signal is a pair: participants are published when the meeting starts
    /// and cleared when it ends. The clear runs from a `defer`-spawned `@MainActor`
    /// Task, so it needs a turn of the runloop to land.
    func testMeeting_publishesThenClearsActiveParticipants() async {
        let team = makeTeam(maxTurns: 1)
        let task = makeTask(team: team)
        seed(task: task, team: team)

        _ = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, task: task, runIndex: 0, stepIndex: 0,
            client: ScriptedMeetingClient(reply: "ok"), config: stubConfig())

        XCTAssertFalse(mockDelegate.setMeetingParticipantsCalls.isEmpty,
                       "the meeting must publish its participants for the graph glow")
        let published = mockDelegate.setMeetingParticipantsCalls.last?.0 ?? []
        XCTAssertTrue(published.contains("team_pm"), "the invited role must be published, got \(published)")
        XCTAssertTrue(published.contains("team_software_engineer"),
                      "the initiator is a participant too, got \(published)")

        await Task.yield()
        XCTAssertFalse(mockDelegate.clearMeetingParticipantsCalls.isEmpty,
                       "the deferred clear must run so the graph glow does not stick")
    }

    // MARK: - Guards

    func testMeeting_withoutWorkFolder_failsBeforeCreatingAnything() async {
        let team = makeTeam(maxTurns: 2)
        let task = makeTask(team: team)
        seed(task: task, team: team)
        mockDelegate.workFolderURL = nil

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, task: task, runIndex: 0, stepIndex: 0,
            client: ScriptedMeetingClient(reply: "x"), config: stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("no work folder"), "got: \(reply.text)")
        XCTAssertTrue((mockDelegate.taskToMutate?.runs.first?.meetings ?? []).isEmpty,
                      "a meeting must not be persisted when the folder guard rejects")
    }

    /// An unknown participant must not fail silently: the reply names WHY it was
    /// rejected and what the model could have asked for instead. That list is the
    /// only recovery signal a small model gets.
    func testMeeting_unknownParticipant_namesTheRejectionAndTheAlternatives() async {
        let team = makeTeam(maxTurns: 2)
        let task = makeTask(team: team)
        seed(task: task, team: team)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["nobody_at_all"], context: nil,
            initiatingRole: initiator, task: task, runIndex: 0, stepIndex: 0,
            client: ScriptedMeetingClient(reply: "x"), config: stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("No valid participants"), "got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("nobody_at_all"),
                      "the rejected identifier must be echoed so the model can correct it; got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("Available teammates"),
                      "the recovery list must be present; got: \(reply.text)")
    }

    /// Inviting yourself is the degenerate case that leaves an EMPTY participant
    /// list after filtering — the same branch as "unknown role", reached differently.
    func testMeeting_invitingOnlyYourself_isRejected() async {
        let team = makeTeam(maxTurns: 2)
        let task = makeTask(team: team)
        seed(task: task, team: team)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_software_engineer"], context: nil,
            initiatingRole: initiator, task: task, runIndex: 0, stepIndex: 0,
            client: ScriptedMeetingClient(reply: "x"), config: stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("the initiator"),
                      "self-invitation must be named as such; got: \(reply.text)")
    }

    /// The limit is read from a FRESH task load, not from the `task` snapshot the
    /// step captured at start — that is the documented reason `loadedTask` is
    /// consulted here at all. Seeding the meetings only on the delegate's loaded
    /// copy proves the fresh read is the one that counts.
    func testMeeting_limitReached_readsTheFreshTaskNotTheSnapshot() async {
        let team = makeTeam(maxTurns: 2, maxMeetings: 1)
        let staleTask = makeTask(team: team)          // snapshot: zero meetings
        var freshTask = staleTask
        freshTask.runs[0].meetings = [
            TeamMeetingService.createMeeting(topic: "earlier", initiatedBy: initiator,
                                             participants: [.productManager], context: nil)
        ]
        seed(task: freshTask, team: team)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, task: staleTask, runIndex: 0, stepIndex: 0,
            client: ScriptedMeetingClient(reply: "x"), config: stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("Meeting limit reached"), "got: \(reply.text)")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs.first?.meetings.count, 1,
                       "the refused meeting must not be appended")
    }

    // MARK: - recordMeeting

    /// `recordMeeting` upserts by id. It is called after EVERY turn so the activity
    /// feed updates live, so an append-only implementation would leave one meeting
    /// duplicated per turn.
    func testRecordMeeting_upsertsByID_ratherThanAppending() async {
        let team = makeTeam(maxTurns: 2)
        let task = makeTask(team: team)
        seed(task: task, team: team)

        var meeting = TeamMeetingService.createMeeting(
            topic: "same meeting", initiatedBy: initiator,
            participants: [.productManager], context: nil)

        await service.recordMeeting(stepID: stepID, taskID: taskID, meeting: meeting)
        meeting.complete()
        await service.recordMeeting(stepID: stepID, taskID: taskID, meeting: meeting)

        let meetings = mockDelegate.taskToMutate?.runs.first?.meetings ?? []
        XCTAssertEqual(meetings.count, 1,
                       "recording the same meeting twice must replace, not append — got \(meetings.count)")
        XCTAssertEqual(meetings.first?.status, .completed,
                       "the second record must have overwritten the first with the newer state")
    }

    /// A finalizer landing after the step was torn down must not resurrect state on
    /// whatever now answers to that key — the house write-barrier rule.
    func testRecordMeeting_afterTeardown_doesNotMutate() async {
        let team = makeTeam(maxTurns: 2)
        let task = makeTask(team: team)
        seed(task: task, team: team)
        service.clearRunningTask(stepID: stepID, taskID: taskID)

        let meeting = TeamMeetingService.createMeeting(
            topic: "late", initiatedBy: initiator, participants: [.productManager], context: nil)
        await service.recordMeeting(stepID: stepID, taskID: taskID, meeting: meeting)

        XCTAssertTrue((mockDelegate.taskToMutate?.runs.first?.meetings ?? []).isEmpty,
                      "a meeting recorded after teardown must be dropped by the barrier")
    }

    // MARK: - Fixtures

    private func seed(task: NTMSTask, team: Team) {
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    private func makeTeam(maxTurns: Int, maxMeetings: Int = 3) -> Team {
        let pm = TeamRoleDefinition(
            id: "team_pm", name: "Product Manager", prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "productManager")
        let swe = TeamRoleDefinition(
            id: "team_software_engineer", name: "Software Engineer", prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "softwareEngineer")
        let limits = TeamLimits(maxMeetingsPerRun: maxMeetings, maxMeetingTurns: maxTurns)
        return Team(
            name: "MeetingTeam", roles: [pm, swe], artifacts: [],
            settings: TeamSettings(limits: limits),
            graphLayout: TeamGraphLayout())
    }

    private func makeTask(team: Team) -> NTMSTask {
        let step = StepExecution(id: stepID, role: initiator, title: "SWE step", status: .running)
        let run = Run(id: 0, steps: [step])
        var task = NTMSTask(id: taskID, title: "T", supervisorTask: "brief", runs: [run])
        task.preferredTeamID = team.id
        return task
    }

    private func makeSnapshot(team: Team, task: NTMSTask) -> WorkFolderContext {
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "T", activeTeamID: team.id),
            settings: .defaults,
            teams: [team])
        return WorkFolderContext(
            projection: projection, tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: task.id, activeTask: task)
    }

    private func stubConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
    }
}

// MARK: - Scripted client

/// Yields one content delta per call and finishes. No tool calls, so every turn
/// resolves in a single stream and the loop terminates on the turn limit.
private final class ScriptedMeetingClient: LLMClient, @unchecked Sendable {
    private let reply: String

    init(reply: String) { self.reply = reply }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let text = reply
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: text))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
