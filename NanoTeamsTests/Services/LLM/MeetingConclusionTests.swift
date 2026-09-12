import XCTest

@testable import NanoTeams

/// The meeting ends when — and only when — its coordinator calls `conclude_meeting`.
///
/// Drives `handleTeamMeeting` end to end with a scripted client: the coordinator opens,
/// the invited role speaks, the coordinator concludes. Pins what the runtime does on the
/// call (records the decision, stops the meeting without re-streaming, marks the record),
/// what it does when a non-coordinator tries (refuses, meeting goes on), when the decision
/// is empty (refuses, no signal), and what happens when the coordinator never calls it
/// (the last turn is the coordinator's; at the limit the record says so). Until 2026-09-06
/// the tool was an echo and every meeting ended by turn limit or a text heuristic.
@MainActor
final class MeetingConclusionTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let stepID = "team_software_engineer"
    private let taskID = 61
    private let initiator: Role = .softwareEngineer

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-conclusion-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - The coordinator ends the meeting

    func testCoordinatorCallsConcludeMeeting_recordsTheDecisionAndStopsWithoutReStreaming() async {
        // Turn 1: coordinator (TL) opens. Turn 2: the initiator (SWE, seated first) speaks.
        // Turn 3: PM speaks. Turn 4: the round is over, TL is back and concludes.
        let client = ScriptedMeetingClient(turns: [
            .text("Let's decide the storage layer."),
            .text("We need something local and simple."),
            .text("SQLite is enough for v1."),
            .toolCall(name: ToolNames.concludeMeeting, argsJSON: #"""
            {"decision":"SQLite for v1","rationale":"No server, no sync","next_steps":"Add the schema\nWrite the migration"}
            """#),
        ])
        seed(coordinatorID: "team_tl", maxTurns: 10)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "Storage", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, initiatorSeat: .speaks, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        XCTAssertTrue(reply.succeeded, reply.text)
        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        XCTAssertEqual(meeting?.status, .completed)
        XCTAssertEqual(meeting?.conclusionKind, .coordinatorCall)
        XCTAssertEqual(meeting?.decisions.last?.summary, "SQLite for v1")
        XCTAssertEqual(meeting?.decisions.last?.rationale, "No server, no sync")
        XCTAssertEqual(meeting?.decisions.last?.nextSteps, ["Add the schema", "Write the migration"])
        XCTAssertEqual(meeting?.decisions.last?.proposedBy, .techLead, "the decision is the coordinator's")
        XCTAssertEqual(meeting?.turnCount, 4, "the meeting stopped on the call, well under the limit of 10")
        XCTAssertEqual(client.streamCount, 4, "no follow-up stream after conclude_meeting")
        XCTAssertEqual(meeting?.messages.last?.messageType, .conclusion)
        XCTAssertEqual(meeting?.messages.last?.content, "SQLite for v1",
                       "a silent concluding turn speaks the decision, never a blank line")
        XCTAssertTrue(reply.text.contains("Decision: SQLite for v1"))
        XCTAssertTrue(reply.text.contains("via conclude_meeting"), reply.text)
        XCTAssertTrue(reply.text.contains("Concluded by: Tech Lead"), reply.text)
    }

    // MARK: - Nobody else can end it

    func testNonCoordinatorCallsConcludeMeeting_isRefusedAndTheMeetingGoesOn() async {
        // Turn 1: TL opens. Turn 2: the initiator (SWE) tries to conclude → not authorized
        // in this meeting; its follow-up stream speaks text. Then the meeting runs to the
        // limit of 3.
        let client = ScriptedMeetingClient(turns: [
            .text("Opening."),
            .toolCall(name: ToolNames.concludeMeeting, argsJSON: #"{"decision":"PM decides"}"#),
            .text("fine, I withdraw"),
            .text("closing remark"),
        ])
        seed(coordinatorID: "team_tl", maxTurns: 3)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "T", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, initiatorSeat: .speaks, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        XCTAssertTrue(reply.succeeded, reply.text)
        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        let summaries = meeting?.messages.compactMap(\.toolSummaries).flatMap { $0 } ?? []
        XCTAssertTrue(summaries.contains { $0.toolName == ToolNames.concludeMeeting && $0.isError },
                      "a non-coordinator's call must be recorded as rejected; got \(summaries)")
        XCTAssertNotEqual(meeting?.decisions.last?.summary, "PM decides",
                          "a non-coordinator cannot set the decision")
        XCTAssertEqual(meeting?.conclusionKind, .turnLimitFallback)
    }

    func testCoordinatorSendsAnEmptyDecision_isRefusedAndTheMeetingGoesOn() async {
        let client = ScriptedMeetingClient(turns: [
            .toolCall(name: ToolNames.concludeMeeting, argsJSON: #"{"decision":"  "}"#),
            .text("sorry, here is my input"),
            .text("PM input"),
        ])
        seed(coordinatorID: "team_tl", maxTurns: 2)

        _ = await service.handleTeamMeeting(
            stepID: stepID, topic: "T", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, initiatorSeat: .speaks, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        let summaries = meeting?.messages.compactMap(\.toolSummaries).flatMap { $0 } ?? []
        XCTAssertTrue(summaries.contains { $0.toolName == ToolNames.concludeMeeting && $0.isError })
        XCTAssertEqual(meeting?.conclusionKind, .turnLimitFallback, "an empty decision concludes nothing")
    }

    // MARK: - The turn-limit fallback

    func testNoConcludeCall_lastTurnIsTheCoordinators_andTheRecordSaysItEndedByLimit() async {
        let client = ScriptedMeetingClient(turns: [.text("TL 1"), .text("SWE 1"), .text("TL 2 — my final word")])
        seed(coordinatorID: "team_tl", maxTurns: 3)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "T", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, initiatorSeat: .speaks, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        XCTAssertTrue(reply.succeeded, reply.text)
        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        XCTAssertEqual(meeting?.messages.map(\.role), [.techLead, initiator, .techLead],
                       "the initiator speaks after the opening; the last turn under the limit is the coordinator's")
        XCTAssertEqual(meeting?.conclusionKind, .turnLimitFallback)
        XCTAssertEqual(meeting?.decisions.last?.summary, "TL 2 — my final word",
                       "the fallback records the coordinator's last contribution")
        XCTAssertTrue(reply.text.contains("Concluded at the turn limit"), reply.text)
        XCTAssertTrue(reply.text.contains("no conclude_meeting call"), reply.text)
    }

    /// A limit of zero allows no turn at all. The meeting still terminates through the
    /// fallback — `turnLimitFallback`, a decision that says so, no stream ever opened —
    /// instead of the silent `complete()` that until 2026-09-06 left the card with no
    /// conclusion kind and the initiator with a "completed" meeting nobody spoke in.
    func testZeroTurnLimit_endsThroughTheFallback_withoutAStream() async {
        let client = ScriptedMeetingClient(turns: [.text("never streamed")])
        seed(coordinatorID: "team_tl", maxTurns: 0)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "T", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, initiatorSeat: .speaks, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        XCTAssertTrue(reply.succeeded, reply.text)
        XCTAssertEqual(client.streamCount, 0, "no turn is allowed, so no stream is opened")
        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        XCTAssertEqual(meeting?.messages.count, 0)
        XCTAssertEqual(meeting?.conclusionKind, .turnLimitFallback)
        XCTAssertEqual(meeting?.decisions.last?.summary, "Meeting ended after 0 turns without a decision.")
        XCTAssertTrue(reply.text.contains("Concluded at the turn limit"), reply.text)
    }

    // MARK: - The coordinator is always a participant

    func testCoordinatorNotInvited_joinsTheMeeting_andHoldsConcludeMeetingOnItsTurns() async {
        // Three turns: TL opens, the initiator (SWE, seated first) speaks, TL takes the
        // last one (the limit hands it over) — the invited PM never gets a turn here.
        let client = ScriptedMeetingClient(turns: [.text("TL opens"), .text("PM speaks"), .text("TL closes")])
        seed(coordinatorID: "team_tl", maxTurns: 3)

        _ = await service.handleTeamMeeting(
            stepID: stepID, topic: "T", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, initiatorSeat: .speaks, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        XCTAssertTrue(meeting?.participants.contains(.techLead) ?? false,
                      "the coordinator is a participant by construction")
        XCTAssertEqual(meeting?.messages.first?.role, .techLead)
        XCTAssertTrue(client.toolNamesPerStream[0].contains(ToolNames.concludeMeeting),
                      "the coordinator's turn carries conclude_meeting")
        XCTAssertFalse(client.toolNamesPerStream[1].contains(ToolNames.concludeMeeting),
                       "the initiator's turn does not")
    }

    // MARK: - The initiator's seat

    /// `request_team_meeting` passes `.speaks`: the initiator is recorded as a participant
    /// at index 0 — before the invited roles and the coordinator — and takes the first turn
    /// after the coordinator's opening, because the meeting is its topic. Its turn carries
    /// no `conclude_meeting`. Until 2026-09-07 the initiator was filtered OUT ("you — the
    /// initiator") and never spoke in a meeting it convened.
    ///
    /// RED: drop `participants.insert(initiatingRole, at: 0)` in `handleTeamMeeting` → the
    /// PM takes turn 1 and the initiator is missing from `participants`.
    func testInitiatorSeat_speaks_seatsTheInitiatorFirst_andGivesItTheTurnAfterTheOpening() async {
        let client = ScriptedMeetingClient(turns: [
            .text("TL opens"), .text("SWE presents"), .text("PM replies"), .text("TL closes")])
        seed(coordinatorID: "team_tl", maxTurns: 4)

        _ = await service.handleTeamMeeting(
            stepID: stepID, topic: "T", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, initiatorSeat: .speaks, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        XCTAssertEqual(meeting?.participants, [initiator, .productManager, .techLead],
                       "initiator first, invitees next, the coordinator appended")
        XCTAssertEqual(meeting?.messages.map(\.role), [.techLead, initiator, .productManager, .techLead],
                       "the coordinator opens, the initiator speaks next, the invitee, the coordinator closes")
        XCTAssertFalse(client.toolNamesPerStream[1].contains(ToolNames.concludeMeeting),
                       "the initiator's turn does not carry conclude_meeting")
    }

    /// `request_changes` passes `.presentsOnly`: the requester's case IS the topic, it is
    /// not seated and never speaks — it must not vote on its own request. It is still the
    /// meeting's `initiatedBy`, and it is still announced to the UI.
    ///
    /// RED: seat the initiator regardless of `initiatorSeat` → it appears in `participants`
    /// and takes turn 1.
    func testInitiatorSeat_presentsOnly_keepsTheInitiatorOutOfTheRoomButOnTheRecord() async {
        let client = ScriptedMeetingClient(turns: [.text("TL opens"), .text("PM replies"), .text("TL closes")])
        seed(coordinatorID: "team_tl", maxTurns: 3)

        _ = await service.handleTeamMeeting(
            stepID: stepID, topic: "T", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, initiatorSeat: .presentsOnly(targetRoleID: "code_reviewer"),
            task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        XCTAssertEqual(meeting?.participants, [.productManager, .techLead])
        XCTAssertEqual(meeting?.messages.map(\.role), [.techLead, .productManager, .techLead])
        XCTAssertEqual(meeting?.initiatedBy, initiator, "the record still names who convened it")
        let announced = mockDelegate.setMeetingParticipantsCalls.last?.0 ?? []
        XCTAssertTrue(announced.contains(stepID), "the presenter's node still glows; got \(announced)")
    }


    // MARK: - Meetings switched off

    func testMeetingsOff_refusesTheCallWithoutStartingAMeeting() async {
        let client = ScriptedMeetingClient(turns: [.text("never called")])
        seed(coordinatorID: "team_tl", maxTurns: 3, meetingsEnabled: false)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "T", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, initiatorSeat: .speaks, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertEqual(reply.text, "Team meetings are off for this team. Continue without one.")
        XCTAssertEqual(client.streamCount, 0)
        XCTAssertTrue(mockDelegate.taskToMutate?.runs.first?.meetings.isEmpty ?? false)
    }

    /// A single-role team: the switch is on, but there is nobody to invite. The refusal
    /// names that, not the switch, and no meeting is recorded.
    func testSingleRoleTeam_refusesTheCallNamingTheMissingTeammate() async {
        let client = ScriptedMeetingClient(turns: [.text("never called")])
        seed(coordinatorID: stepID, maxTurns: 3, soloTeam: true)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "T", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, initiatorSeat: .speaks, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertEqual(reply.text, "This team has no teammate to meet with. Continue without a meeting.")
        XCTAssertEqual(client.streamCount, 0)
        XCTAssertTrue(mockDelegate.taskToMutate?.runs.first?.meetings.isEmpty ?? false)
    }

    // MARK: - Fixtures

    private func seed(coordinatorID: String, maxTurns: Int, meetingsEnabled: Bool = true, soloTeam: Bool = false) {
        let pm = TeamRoleDefinition(
            id: "team_pm", name: "Product Manager", prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "productManager")
        let tl = TeamRoleDefinition(
            id: "team_tl", name: "Tech Lead", prompt: "p",
            toolIDs: [ToolNames.readFile], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "techLead")
        let swe = TeamRoleDefinition(
            id: stepID, name: "Software Engineer", prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "softwareEngineer")
        let team = Team(
            name: "MeetingTeam", roles: soloTeam ? [swe] : [pm, tl, swe], artifacts: [],
            settings: TeamSettings(
                meetingCoordinatorRoleID: coordinatorID,
                meetingsEnabled: meetingsEnabled,
                limits: TeamLimits(maxMeetingsPerRun: 3, maxMeetingTurns: maxTurns)),
            graphLayout: TeamGraphLayout())
        let step = StepExecution(id: stepID, role: initiator, title: "SWE", status: .running)
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "b", runs: [Run(id: 0, steps: [step])])
        task.preferredTeamID = team.id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "T", activeTeamID: team.id),
                settings: .defaults, teams: [team]),
            tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: task.id, activeTask: task)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    private func stubConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
    }
}

// MARK: - Scripted client

/// One scripted reply per `streamChat` call, in order; the last entry repeats. Records the
/// tool names offered on every stream so a test can see who held `conclude_meeting`.
private final class ScriptedMeetingClient: LLMClient, @unchecked Sendable {
    enum Turn {
        case text(String)
        case toolCall(name: String, argsJSON: String)
    }

    private let lock = NSLock()
    private let turns: [Turn]
    private var _streamCount = 0
    private var _toolNamesPerStream: [[String]] = []

    var streamCount: Int { lock.withLock { _streamCount } }
    var toolNamesPerStream: [[String]] { lock.withLock { _toolNamesPerStream } }

    init(turns: [Turn]) { self.turns = turns }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let turn: Turn = lock.withLock {
            _toolNamesPerStream.append(tools.map(\.name))
            let index = min(_streamCount, turns.count - 1)
            _streamCount += 1
            return turns[index]
        }
        return AsyncThrowingStream { continuation in
            switch turn {
            case .text(let text):
                continuation.yield(StreamEvent(contentDelta: text))
            case .toolCall(let name, let argsJSON):
                continuation.yield(StreamEvent(toolCallDeltas: [
                    StreamEvent.ToolCallDelta(index: 0, id: "call_1", name: name, argumentsDelta: argsJSON)
                ]))
            }
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
