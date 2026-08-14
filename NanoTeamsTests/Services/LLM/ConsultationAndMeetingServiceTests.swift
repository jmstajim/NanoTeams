import XCTest

@testable import NanoTeams

// Coverage for the consultation + meeting + Autovisor-handler seam:
//
//   • `LLMExecutionService+TeammateConsultation` — every guard arm of
//     `handleTeammateConsultation` plus the empty-answer hardening chain
//     (empty content → thinking fallback → `CollaborationReply.failed` sentinel
//     recorded on the consultation via `fail(with:)`, so no surface is blank).
//   • `LLMExecutionService+Autovisor` — the WRITE handlers, which translate a
//     manager tool signal into one `AutovisorAction` and route it through the
//     single `performAutovisorAction` hook, plus every failure arm (no delegate,
//     unknown task, action refused).
//   • `MeetingStreamingService.streamParticipantResponse` — untested before this
//     file — and the artifact-grounding turn `buildMeetingMessages` splices in.
//   • `TeamMeetingService.completeTurn`'s conclusion decision.
//
// No network, no LM Studio: every LLM call goes through a scripted client, and
// the only filesystem touched is a per-test temp dir.

// MARK: - Scripted clients

/// Yields a configurable (thinking, content, toolCallDeltas) sequence and records
/// what it was asked to send. Mirrors `VisionAnalysisServiceTests.MockVisionLLMClient`.
private final class ScriptedConsultClient: LLMClient, @unchecked Sendable {
    var content: String
    var thinking: String
    var toolCallDeltas: [StreamEvent.ToolCallDelta]
    var shouldThrow: Error?

    private(set) var callCount = 0
    private(set) var capturedConfig: LLMConfig?
    private(set) var capturedMessages: [ChatMessage] = []
    private(set) var capturedTools: [ToolSchema] = []

    init(
        content: String = "",
        thinking: String = "",
        toolCallDeltas: [StreamEvent.ToolCallDelta] = [],
        shouldThrow: Error? = nil
    ) {
        self.content = content
        self.thinking = thinking
        self.toolCallDeltas = toolCallDeltas
        self.shouldThrow = shouldThrow
    }

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        callCount += 1
        capturedConfig = config
        capturedMessages = messages
        capturedTools = tools

        if let error = shouldThrow {
            return AsyncThrowingStream { throw error }
        }

        let t = thinking
        let c = content
        let deltas = toolCallDeltas
        return AsyncThrowingStream { continuation in
            if !t.isEmpty { continuation.yield(StreamEvent(thinkingDelta: t)) }
            if !c.isEmpty { continuation.yield(StreamEvent(contentDelta: c)) }
            if !deltas.isEmpty { continuation.yield(StreamEvent(toolCallDeltas: deltas)) }
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

private struct ScriptedConsultError: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

// MARK: - Shared fixtures

private enum ConsultMeetFixtures {
    static let stepID = "team_software_engineer"
    static let taskID = 77
    static let requester: Role = .softwareEngineer

    /// PM + SWE, optionally a Supervisor role, with tunable limits / invite policy.
    static func makeTeam(
        limits: TeamLimits = TeamLimits(),
        includeSupervisor: Bool = false,
        supervisorCanBeInvited: Bool = false,
        invitableRoles: Set<String> = [],
        pmOverride: LLMOverride? = nil
    ) -> Team {
        var roles: [TeamRoleDefinition] = []
        if includeSupervisor {
            roles.append(TeamRoleDefinition(
                id: "team_supervisor", name: "Supervisor", prompt: "",
                toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies(), systemRoleID: "supervisor"))
        }
        roles.append(TeamRoleDefinition(
            id: "team_pm", name: "Product Manager", prompt: "pm guidance",
            toolIDs: [ToolNames.askTeammate], usePlanningPhase: false,
            dependencies: RoleDependencies(), llmOverride: pmOverride,
            systemRoleID: "productManager"))
        roles.append(TeamRoleDefinition(
            id: "team_swe", name: "Software Engineer", prompt: "swe guidance",
            toolIDs: [ToolNames.askTeammate], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "softwareEngineer"))

        return Team(
            name: "ConsultTeam",
            roles: roles,
            artifacts: [],
            settings: TeamSettings(
                invitableRoles: invitableRoles,
                supervisorCanBeInvited: supervisorCanBeInvited,
                limits: limits),
            graphLayout: TeamGraphLayout())
    }

    static func makeTask(
        team: Team,
        consultations: [TeammateConsultation] = [],
        chats: [String: RoleConsultationChat] = [:]
    ) -> NTMSTask {
        let step = StepExecution(
            id: stepID, role: requester, title: "SWE step", status: .running,
            consultations: consultations)
        let run = Run(id: 0, steps: [step], consultationChats: chats)
        var task = NTMSTask(id: taskID, title: "T", supervisorTask: "brief", runs: [run])
        task.preferredTeamID = team.id
        return task
    }

    static func makeSnapshot(team: Team, task: NTMSTask?) -> WorkFolderContext {
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "T", activeTeamID: team.id),
            settings: .defaults,
            teams: [team])
        return WorkFolderContext(
            projection: projection, tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: task?.id, activeTask: task)
    }

    static func completedConsultation(
        question: String, response: String?, consulted: Role = .productManager
    ) -> TeammateConsultation {
        var c = TeammateConsultationService.createConsultation(
            requestingRole: requester, consultedRole: consulted,
            question: question, context: nil)
        if let response { c.complete(with: response, responseTimeMs: 1) }
        return c
    }

    static func stubConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "global-model")
    }
}

// MARK: - handleTeammateConsultation

@MainActor
final class TeammateConsultationHandlerTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    // Value-type literals only (mirrors `TeamMeetingFlowTests`) — a stored
    // property initialiser runs outside the class's actor isolation.
    private let stepID = "team_software_engineer"
    private let taskID = 77
    private let requester: Role = .softwareEngineer

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("consult-handler-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    // MARK: Availability guards

    /// No delegate at all (composition never completed / torn down): the handler
    /// must fail with a reason rather than trap on the optional.
    func testConsultation_noDelegate_failsWithReason_andNeverCallsTheLLM() async {
        let detached = LLMExecutionService(repository: NTMSRepository())  // deliberately un-attached
        let team = ConsultMeetFixtures.makeTeam()
        let task = ConsultMeetFixtures.makeTask(team: team)
        let client = ScriptedConsultClient(content: "unused")

        let reply = await detached.handleTeammateConsultation(
            stepID: stepID, consultedRoleID: "team_pm", question: "q", context: nil,
            requestingRole: requester, task: task, runIndex: 0, stepIndex: 0,
            client: client, config: ConsultMeetFixtures.stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("delegate not available"), "got: \(reply.text)")
        XCTAssertEqual(client.callCount, 0, "no delegate ⇒ nothing may reach the wire")
    }

    /// The write barrier: a consultation dispatched after the step was torn down
    /// (pause / task switch) must abort before touching the chat or the wire.
    func testConsultation_stepNotLive_failsBeforeTouchingTheWire() async {
        let team = ConsultMeetFixtures.makeTeam()
        let task = ConsultMeetFixtures.makeTask(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = ConsultMeetFixtures.makeSnapshot(team: team, task: task)
        // Deliberately NO _testRegisterStepTask → isExecutionLive == false.
        let client = ScriptedConsultClient(content: "unused")

        let reply = await service.handleTeammateConsultation(
            stepID: stepID, consultedRoleID: "team_pm", question: "q", context: nil,
            requestingRole: requester, task: task, runIndex: 0, stepIndex: 0,
            client: client, config: ConsultMeetFixtures.stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("no task context"), "got: \(reply.text)")
        XCTAssertEqual(client.callCount, 0)
        XCTAssertTrue(mockDelegate.taskToMutate?.runs[0].steps[0].consultations.isEmpty ?? false,
                      "a dead step must not record a consultation")
    }

    // MARK: Validation arms — every rejection names the alternatives

    func testConsultation_askingYourself_isRejected_andListsAlternatives() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "unused")

        let reply = await consult(
            "softwareEngineer", question: "q", task: task, client: client)

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("cannot ask yourself"), "got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("Available teammates"),
                      "the recovery list is the model's only correction signal; got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("productManager"),
                      "the list must name a real teammate id; got: \(reply.text)")
        XCTAssertEqual(client.callCount, 0)
    }

    /// A BUILT-IN role id that resolves (`Role.builtInRole`) but is not on this
    /// team — the branch that would otherwise consult a stranger.
    func testConsultation_builtInRoleNotOnThisTeam_isRejectedAsNonMember() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "unused")

        let reply = await consult("techLead", question: "q", task: task, client: client)

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("Tech Lead"), "got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("not a member of this team"), "got: \(reply.text)")
        XCTAssertEqual(client.callCount, 0)
    }

    /// An identifier that resolves to nothing at all takes the earlier
    /// "Unknown teammate role" arm, which echoes the bad identifier verbatim.
    func testConsultation_unresolvableIdentifier_echoesItBack() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "unused")

        let reply = await consult("ghost_role", question: "q", task: task, client: client)

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("Unknown teammate role: ghost_role"), "got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("Available teammates"), "got: \(reply.text)")
        XCTAssertEqual(client.callCount, 0)
    }

    func testConsultation_supervisorNotInvitable_isRejected() async {
        let team = ConsultMeetFixtures.makeTeam(includeSupervisor: true, supervisorCanBeInvited: false)
        let task = ConsultMeetFixtures.makeTask(team: team)
        install(team: team, task: task)
        let client = ScriptedConsultClient(content: "unused")

        let reply = await consult("supervisor", question: "q", task: task, client: client)

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("Supervisor cannot be consulted"), "got: \(reply.text)")
        XCTAssertEqual(client.callCount, 0)
    }

    /// Same team, same role — but the team's invite policy now allows it. The
    /// negative test above would pass for the wrong reason without this pair.
    func testConsultation_supervisorInvitable_reachesTheWire() async {
        let team = ConsultMeetFixtures.makeTeam(includeSupervisor: true, supervisorCanBeInvited: true)
        let task = ConsultMeetFixtures.makeTask(team: team)
        install(team: team, task: task)
        let client = ScriptedConsultClient(content: "Ship it.")

        let reply = await consult("supervisor", question: "q", task: task, client: client)

        XCTAssertTrue(reply.succeeded, "got: \(reply.text)")
        XCTAssertEqual(client.callCount, 1)
    }

    func testConsultation_roleOutsideInvitableRoles_isRejected() async {
        let team = ConsultMeetFixtures.makeTeam(invitableRoles: ["team_swe"])
        let task = ConsultMeetFixtures.makeTask(team: team)
        install(team: team, task: task)
        let client = ScriptedConsultClient(content: "unused")

        let reply = await consult("team_pm", question: "q", task: task, client: client)

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("not available for consultation"), "got: \(reply.text)")
        XCTAssertEqual(client.callCount, 0)
    }

    // MARK: Limits — read from the FRESH task, not the step-start snapshot

    /// The stale `task` parameter carries ZERO consultations; the freshly-loaded
    /// one carries the limit-filling record. Pins that the fresh re-read (whose
    /// whole purpose is exactly this) is what the limit check consults.
    func testConsultation_limitReached_readsTheFreshTaskNotTheSnapshot() async {
        let team = ConsultMeetFixtures.makeTeam(limits: TeamLimits(maxConsultationsPerStep: 1))
        let staleTask = ConsultMeetFixtures.makeTask(team: team)
        let freshTask = ConsultMeetFixtures.makeTask(
            team: team,
            consultations: [ConsultMeetFixtures.completedConsultation(question: "earlier", response: "a")])
        install(team: team, task: freshTask)
        let client = ScriptedConsultClient(content: "unused")

        let reply = await consult("team_pm", question: "new q", task: staleTask, client: client)

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("Consultation limit reached"), "got: \(reply.text)")
        XCTAssertEqual(client.callCount, 0)
    }

    /// Same-teammate cap fires while the overall cap still has room, so the
    /// message steers toward a DIFFERENT teammate rather than "stop asking".
    func testConsultation_sameTeammateLimit_steersToADifferentTeammate() async {
        let team = ConsultMeetFixtures.makeTeam(
            limits: TeamLimits(maxConsultationsPerStep: 9, maxSameTeammateAsks: 1))
        let task = ConsultMeetFixtures.makeTask(
            team: team,
            consultations: [ConsultMeetFixtures.completedConsultation(question: "earlier", response: "a")])
        install(team: team, task: task)
        let client = ScriptedConsultClient(content: "unused")

        let reply = await consult("team_pm", question: "different q", task: task, client: client)

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("Product Manager"), "got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("different teammate"), "got: \(reply.text)")
        XCTAssertEqual(client.callCount, 0)
    }

    /// A repeat of an already-ANSWERED question short-circuits to the stored
    /// answer — no second LLM round-trip, no second record.
    func testConsultation_duplicateAnsweredQuestion_replaysTheStoredAnswer() async {
        let team = ConsultMeetFixtures.makeTeam()
        let task = ConsultMeetFixtures.makeTask(
            team: team,
            consultations: [ConsultMeetFixtures.completedConsultation(
                question: "  Which DB?  ", response: "SQLite.")])
        install(team: team, task: task)
        let client = ScriptedConsultClient(content: "unused")

        // Different casing + whitespace: duplicate detection normalises both sides.
        let reply = await consult("team_pm", question: "which db?", task: task, client: client)

        XCTAssertTrue(reply.succeeded, "a replayed answer is a success, not a failure")
        XCTAssertEqual(reply.text, "(Previously answered) SQLite.")
        XCTAssertEqual(client.callCount, 0, "a replay must not cost a round-trip")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].steps[0].consultations.count, 1,
                       "a replay must not append a second record")
    }

    /// Guard-failure corner of the same branch: the earlier consultation matches
    /// but has NO stored response (it failed). The `if let previousAnswer` misses,
    /// so the handler must fall through and actually ask again.
    func testConsultation_duplicateQuestionWithNoStoredAnswer_asksAgain() async {
        let team = ConsultMeetFixtures.makeTeam()
        let task = ConsultMeetFixtures.makeTask(
            team: team,
            consultations: [ConsultMeetFixtures.completedConsultation(
                question: "Which DB?", response: nil)])
        install(team: team, task: task)
        let client = ScriptedConsultClient(content: "SQLite.")

        let reply = await consult("team_pm", question: "Which DB?", task: task, client: client)

        XCTAssertTrue(reply.succeeded, "got: \(reply.text)")
        XCTAssertEqual(reply.text, "SQLite.")
        XCTAssertEqual(client.callCount, 1, "an unanswered duplicate must re-ask, not replay nil")
    }

    // MARK: Empty-answer hardening (the documented chain)

    /// Content channel empty, reasoning channel non-empty: the answer is
    /// recovered from thinking rather than silently dropped, and the record is
    /// `.completed` with that text.
    func testConsultation_emptyContent_recoversTheReasoningChannel() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "", thinking: "  Use a debounce.  ")

        let reply = await consult("team_pm", question: "q", task: task, client: client)

        XCTAssertTrue(reply.succeeded, "got: \(reply.text)")
        XCTAssertEqual(reply.text, "Use a debounce.", "thinking must be trimmed + cleaned")
        let record = mockDelegate.taskToMutate?.runs[0].steps[0].consultations.last
        XCTAssertEqual(record?.status, .completed)
        XCTAssertEqual(record?.response, "Use a debounce.")
    }

    /// BOTH channels empty ⇒ the honest-failure sentinel. It must reach three
    /// places at once: the reply, the record's status, and the record's
    /// `response` (which is what the structured consultations panel renders —
    /// a reason-less `.failed` is the blank-red-card state `fail(with:)` exists
    /// to prevent).
    func testConsultation_bothChannelsEmpty_failsWithSentinelStoredOnTheRecord() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "   ", thinking: "\n\t ")

        let reply = await consult("team_pm", question: "q", task: task, client: client)

        XCTAssertFalse(reply.succeeded)
        XCTAssertEqual(reply.text, "(Product Manager returned an empty response.)",
                       "the sentinel must name WHO was silent")
        let record = mockDelegate.taskToMutate?.runs[0].steps[0].consultations.last
        XCTAssertEqual(record?.status, .failed)
        XCTAssertEqual(record?.response, reply.text,
                       "the reason must persist so no surface is silently blank")
        XCTAssertNil(record?.responseTimeMs,
                     "a failed consultation records no response time")
    }

    /// A reply consisting ONLY of model sentinels cleans down to empty and must
    /// take the same honest-failure path, not ship `<|channel|>` as an answer.
    func testConsultation_sentinelOnlyReply_isTreatedAsEmpty() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "<|channel|><|message|>")

        let reply = await consult("team_pm", question: "q", task: task, client: client)

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("empty response"), "got: \(reply.text)")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].steps[0].consultations.last?.status, .failed)
    }

    /// A real answer wrapped in model sentinels keeps the prose and drops the
    /// tokens — the model's internal vocabulary must never reach the requester.
    func testConsultation_answerIsStrippedOfModelTokens() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "<|channel|>Use a debounce.")

        let reply = await consult("team_pm", question: "q", task: task, client: client)

        XCTAssertTrue(reply.succeeded, "got: \(reply.text)")
        XCTAssertEqual(reply.text, "Use a debounce.")
        XCTAssertFalse(reply.text.contains("<|"), "no model sentinel may survive into the answer")
    }

    /// Transport failure: the reason names the teammate AND the underlying error,
    /// and is persisted on the record for the same no-blank-surface reason.
    func testConsultation_streamThrows_recordsAFailedConsultationCarryingTheReason() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(shouldThrow: ScriptedConsultError(text: "connection refused"))

        let reply = await consult("team_pm", question: "q", task: task, client: client)

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.contains("Product Manager"), "got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("connection refused"),
                      "the transport reason must survive into the message; got: \(reply.text)")
        let record = mockDelegate.taskToMutate?.runs[0].steps[0].consultations.last
        XCTAssertEqual(record?.status, .failed)
        XCTAssertEqual(record?.response, reply.text)
        XCTAssertNil(mockDelegate.taskToMutate?.runs[0].consultationChats["team_pm"],
                     "a failed exchange must not persist a chat holding an unanswered question")
    }

    /// RED: drop the `CancellationClassifier` arm from the catch → a `.failed` consultation
    /// carrying "cancelled" is written onto the step and survives the pause.
    ///
    /// A Pause is not a failed consultation. `consultation.fail` is DURABLE: the record is
    /// persisted to `step.consultations` and `RoleConsultationsPanel` renders it red for the
    /// life of the run, so the user stopping their own run left a permanent defect on the
    /// transcript — and the text was fed back into the wire conversation as the teammate's
    /// answer. Same rule `TeamGenerationService` already applied to generation.
    func testConsultation_cancelled_leavesNoFailedRecordBehind() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(shouldThrow: CancellationError())

        let reply = await consult("team_pm", question: "q", task: task, client: client)

        XCTAssertFalse(reply.succeeded, "a cancelled consultation still has no answer")
        let records = mockDelegate.taskToMutate?.runs[0].steps[0].consultations ?? []
        XCTAssertTrue(
            records.allSatisfy { $0.status != .failed },
            "a Pause must not be recorded as a teammate failure; got: \(records.map(\.status))")
    }

    /// The other side of the same coin, so the fix cannot degenerate into "never record a
    /// failure": a real transport error is still durably recorded.
    func testConsultation_urlCancelled_isAlsoTreatedAsAPause() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(
            shouldThrow: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))

        _ = await consult("team_pm", question: "q", task: task, client: client)

        let records = mockDelegate.taskToMutate?.runs[0].steps[0].consultations ?? []
        XCTAssertTrue(records.allSatisfy { $0.status != .failed })
    }

    // MARK: Success path — chat persistence, attribution, per-role config

    func testConsultation_success_recordsCompletedConsultationWithTiming() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "Use a debounce.")

        let reply = await consult("team_pm", question: "How do I throttle?", task: task, client: client)

        XCTAssertTrue(reply.succeeded, "got: \(reply.text)")
        let record = mockDelegate.taskToMutate?.runs[0].steps[0].consultations.last
        XCTAssertEqual(record?.status, .completed)
        XCTAssertEqual(record?.question, "How do I throttle?")
        XCTAssertEqual(record?.consultedRole, .productManager)
        XCTAssertEqual(record?.requestingRole, requester)
        XCTAssertNotNil(record?.responseTimeMs, "a completed consultation records its latency")
    }

    /// The persistent per-role chat is the whole point of the feature: the
    /// question turn (attributed with the TEAM's role name) and the answer turn
    /// must both land in `run.consultationChats[<consulted role>]`.
    func testConsultation_success_persistsTheChatWithQuestionAndAnswerTurns() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "Use a debounce.")

        _ = await consult("team_pm", question: "How do I throttle?", task: task, client: client)

        guard let chat = mockDelegate.taskToMutate?.runs[0].consultationChats["team_pm"] else {
            XCTFail("the consultation chat must be persisted under the CONSULTED role's id")
            return
        }
        XCTAssertTrue(
            chat.messages.contains { $0.role == .user && $0.content.contains("Software Engineer asks: How do I throttle?") },
            "the question turn must name the requester using the TEAM's role name")
        XCTAssertEqual(chat.messages.last?.role, .assistant)
        XCTAssertEqual(chat.messages.last?.content, "Use a debounce.")
    }

    /// Optional `context` rides the same question turn (never a separate one —
    /// a second user turn would fragment the chat's growing prefix).
    func testConsultation_withContext_appendsItToTheQuestionTurn() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "ok")

        _ = await consult("team_pm", question: "How?", context: "we ship Friday", task: task, client: client)

        let chat = mockDelegate.taskToMutate?.runs[0].consultationChats["team_pm"]
        let questionTurn = chat?.messages.first { $0.content.contains("Software Engineer asks:") }
        XCTAssertNotNil(questionTurn)
        XCTAssertTrue(questionTurn?.content.contains("Context: we ship Friday") ?? false,
                      "got: \(questionTurn?.content ?? "nil")")
    }

    /// Whitespace-only context is NOT appended — an empty `Context:` line is
    /// pure prompt noise on every consultation.
    func testConsultation_whitespaceOnlyContext_isOmitted() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "ok")

        _ = await consult("team_pm", question: "How?", context: "   \n ", task: task, client: client)

        let chat = mockDelegate.taskToMutate?.runs[0].consultationChats["team_pm"]
        let questionTurn = chat?.messages.first { $0.content.contains("Software Engineer asks:") }
        XCTAssertFalse(questionTurn?.content.contains("Context:") ?? true,
                       "got: \(questionTurn?.content ?? "nil")")
    }

    /// The call is issued with the CONSULTED role's LLM override, not the
    /// requester's or the global config — the consulted role is the one speaking.
    func testConsultation_usesTheConsultedRolesOwnLLMOverride() async {
        let team = ConsultMeetFixtures.makeTeam(pmOverride: LLMOverride(modelName: "pm-model"))
        let task = ConsultMeetFixtures.makeTask(team: team)
        install(team: team, task: task)
        let client = ScriptedConsultClient(content: "ok")

        _ = await consult("team_pm", question: "q", task: task, client: client)

        XCTAssertEqual(client.capturedConfig?.modelName, "pm-model",
                       "the consulted role's override must win over the global model")
        XCTAssertEqual(client.capturedConfig?.baseURLString, "http://127.0.0.1:1234",
                       "a model-only override must not disturb the URL")
    }

    /// A consultation is a chat, not a tool loop: no tools are offered, so the
    /// consulted role answers in prose instead of trying to act.
    func testConsultation_offersNoToolsToTheConsultedRole() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "ok")

        _ = await consult("team_pm", question: "q", task: task, client: client)

        XCTAssertTrue(client.capturedTools.isEmpty, "a consultation must ship an empty tool catalog")
        XCTAssertEqual(client.capturedMessages.first?.role, .system,
                       "the chat opens with the resolved consultation system prompt")
    }

    /// Second question to the same role, driven the way production does it —
    /// with the FRESHLY loaded task (`runOneLLMToolIteration` refreshes the
    /// snapshot each iteration). The existing chat must be reused and appended
    /// to, so the consulted role remembers the earlier exchange.
    func testConsultation_secondQuestion_appendsToTheExistingChat() async {
        let (_, task) = seed()
        let client = ScriptedConsultClient(content: "First answer.")

        _ = await consult("team_pm", question: "First?", task: task, client: client)

        guard let refreshed = mockDelegate.loadedTask(taskID) else {
            XCTFail("precondition: the first consultation must have persisted")
            return
        }
        client.content = "Second answer."
        _ = await consult("team_pm", question: "Second?", task: refreshed, client: client)

        guard let chat = mockDelegate.taskToMutate?.runs[0].consultationChats["team_pm"] else {
            XCTFail("chat must still be persisted")
            return
        }
        XCTAssertTrue(chat.messages.contains { $0.content.contains("First?") },
                      "the earlier question must survive in the accumulating chat")
        XCTAssertTrue(chat.messages.contains { $0.content == "First answer." })
        XCTAssertTrue(chat.messages.contains { $0.content.contains("Second?") })
        XCTAssertEqual(chat.messages.last?.content, "Second answer.")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].steps[0].consultations.count, 2)
    }

    // MARK: recordConsultation

    /// A consultation finalizer landing after teardown must be dropped by the
    /// write barrier — never resurrected onto whatever now owns that key.
    func testRecordConsultation_afterTeardown_doesNotMutate() async {
        _ = seed()
        service.clearRunningTask(stepID: stepID, taskID: taskID)

        await service.recordConsultation(
            stepID: stepID, taskID: taskID,
            consultation: ConsultMeetFixtures.completedConsultation(question: "late", response: "x"))

        XCTAssertTrue(mockDelegate.taskToMutate?.runs[0].steps[0].consultations.isEmpty ?? false,
                      "a late record must be dropped by the isExecutionLive barrier")
    }

    /// The record targets the step by id inside the LATEST run. A step that is
    /// not in it (a fresh run was appended mid-flight) is a no-op, not a crash
    /// and not a write onto a sibling step.
    func testRecordConsultation_stepMissingFromLatestRun_isANoOp() async {
        _ = seed()
        let stranger = StepExecution(id: "someone_else", role: .productManager, title: "Other")
        mockDelegate.taskToMutate?.runs = [Run(id: 1, steps: [stranger])]

        await service.recordConsultation(
            stepID: stepID, taskID: taskID,
            consultation: ConsultMeetFixtures.completedConsultation(question: "q", response: "a"))

        XCTAssertTrue(mockDelegate.taskToMutate?.runs.last?.steps.first?.consultations.isEmpty ?? false,
                      "an unrelated step in the latest run must not receive the record")
    }

    // MARK: - Helpers

    @discardableResult
    private func seed() -> (Team, NTMSTask) {
        let team = ConsultMeetFixtures.makeTeam()
        let task = ConsultMeetFixtures.makeTask(team: team)
        install(team: team, task: task)
        return (team, task)
    }

    private func install(team: Team, task: NTMSTask) {
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = ConsultMeetFixtures.makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    private func consult(
        _ consultedRoleID: String,
        question: String,
        context: String? = nil,
        task: NTMSTask,
        client: ScriptedConsultClient
    ) async -> CollaborationReply {
        await service.handleTeammateConsultation(
            stepID: stepID, consultedRoleID: consultedRoleID, question: question,
            context: context, requestingRole: requester, task: task,
            runIndex: 0, stepIndex: 0,
            client: client, config: ConsultMeetFixtures.stubConfig())
    }
}

// MARK: - Autovisor handlers

@MainActor
final class AutovisorHandlerEnvelopeTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    private let stepID = "autovisor_manager"
    private let managerTaskID = 900

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() {
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    // MARK: Writes — signal → AutovisorAction → single hook

    func testHandleCreateManagedTask_forwardsTheAction_andReturnsTheNewTaskID() async {
        mockDelegate.autovisorActionResult = .success("Created task #42", createdTaskID: 42)

        let json = await service.handleCreateManagedTask(
            title: "Audit the parser", brief: "read + report", teamID: "engineering")

        XCTAssertEqual(
            mockDelegate.autovisorActions,
            [.createManagedTask(title: "Audit the parser", brief: "read + report", teamID: "engineering")],
            "the handler is a pure translator — exactly one action, verbatim")
        let ok = try? Self.decodeOK(json)
        XCTAssertEqual(ok?.status, "ok")
        XCTAssertEqual(ok?.message, "Created task #42")
        XCTAssertEqual(ok?.task_id, 42, "the manager needs the id to reference the task next pass")
    }

    /// `teamID: nil` (omitted `team_id` → active team) must forward as nil, not
    /// as an empty string that would fail catalog resolution downstream.
    func testHandleCreateManagedTask_nilTeamID_forwardsNil() async {
        _ = await service.handleCreateManagedTask(title: "T", brief: "B", teamID: nil)
        XCTAssertEqual(mockDelegate.autovisorActions,
                       [.createManagedTask(title: "T", brief: "B", teamID: nil)])
    }

    /// A refused action is reported as an ERROR envelope carrying the refusal
    /// reason — reporting `ok:true` for a no-op is the dishonesty these
    /// handlers were hardened against.
    func testHandleCreateManagedTask_refused_returnsErrorEnvelopeWithTheReason() async {
        mockDelegate.autovisorActionResult = .failure("Concurrent managed-task cap reached.")

        let json = await service.handleCreateManagedTask(title: "T", brief: "B", teamID: nil)

        let err = try? Self.decodeError(json)
        XCTAssertEqual(err?.code, "COMMAND_FAILED")
        XCTAssertEqual(err?.message, "Concurrent managed-task cap reached.")
        XCTAssertTrue(json.contains("\"ok\":false"), "got: \(json)")
    }

    func testHandleControlTask_forwardsTypedVerbsVerbatim() async {
        _ = await service.handleControlTask(taskID: 5, verb: .pause)
        _ = await service.handleControlTask(taskID: 5, verb: .rename(title: "Renamed"))
        _ = await service.handleControlTask(taskID: 5, verb: .setTimeout(seconds: 900))
        _ = await service.handleControlTask(taskID: 5, verb: .setTimeout(seconds: nil))

        XCTAssertEqual(mockDelegate.autovisorActions, [
            .controlTask(taskID: 5, verb: .pause),
            .controlTask(taskID: 5, verb: .rename(title: "Renamed")),
            .controlTask(taskID: 5, verb: .setTimeout(seconds: 900)),
            .controlTask(taskID: 5, verb: .setTimeout(seconds: nil)),
        ], "the typed verb (and its argument) must survive the hop unchanged")
    }

    func testHandleManageRole_forwardsRoleVerbsIncludingTheirFeedback() async {
        _ = await service.handleManageRole(taskID: 6, roleID: "r1", verb: .accept)
        _ = await service.handleManageRole(taskID: 6, roleID: "r1", verb: .requestChanges(comment: "tighten it"))
        _ = await service.handleManageRole(taskID: 6, roleID: "r1", verb: .restart(comment: nil))
        _ = await service.handleManageRole(taskID: 6, roleID: "r1", verb: .finishAdvisory)

        XCTAssertEqual(mockDelegate.autovisorActions, [
            .manageRole(taskID: 6, roleID: "r1", verb: .accept),
            .manageRole(taskID: 6, roleID: "r1", verb: .requestChanges(comment: "tighten it")),
            .manageRole(taskID: 6, roleID: "r1", verb: .restart(comment: nil)),
            .manageRole(taskID: 6, roleID: "r1", verb: .finishAdvisory),
        ])
    }

    func testHandleAnswerTaskQuestion_forwardsTheAnswer() async {
        _ = await service.handleAnswerTaskQuestion(taskID: 7, answer: "Use SQLite.")
        XCTAssertEqual(mockDelegate.autovisorActions,
                       [.answerTaskQuestion(taskID: 7, answer: "Use SQLite.")])
    }

    /// Targeted and untargeted steering are different actions; `roleID: nil`
    /// means "Team queue", and must not collapse into a role-targeted send.
    func testHandleMessageTask_distinguishesTargetedFromTeamWide() async {
        _ = await service.handleMessageTask(taskID: 8, text: "focus on tests", roleID: "engineer")
        _ = await service.handleMessageTask(taskID: 8, text: "any role", roleID: nil)

        XCTAssertEqual(mockDelegate.autovisorActions, [
            .messageTask(taskID: 8, text: "focus on tests", roleID: "engineer"),
            .messageTask(taskID: 8, text: "any role", roleID: nil),
        ])
    }

    /// `intervalMinutes == 0` is the documented "clear the recurrence" spelling —
    /// it must reach the hook, not be filtered as a no-op.
    func testHandleScheduleTask_forwardsZeroAsTheClearSignal() async {
        _ = await service.handleScheduleTask(taskID: 9, intervalMinutes: 0)
        _ = await service.handleScheduleTask(taskID: 9, intervalMinutes: 30)

        XCTAssertEqual(mockDelegate.autovisorActions, [
            .scheduleTask(taskID: 9, intervalMinutes: 0),
            .scheduleTask(taskID: 9, intervalMinutes: 30),
        ])
    }

    func testHandleSetWorkFolderContext_forwardsTheContent() async {
        _ = await service.handleSetWorkFolderContext(content: "Swift 6, no deps.")
        XCTAssertEqual(mockDelegate.autovisorActions,
                       [.setWorkFolderContext(content: "Swift 6, no deps.")])
    }

    /// Every write handler shares one `applyAutovisorAction` guard: with no
    /// delegate it must report failure AND perform nothing.
    func testWriteHandlers_withoutDelegate_returnErrorEnvelopeAndPerformNothing() async {
        let detached = LLMExecutionService(repository: NTMSRepository())  // deliberately un-attached

        var envelopes: [String] = []
        envelopes.append(await detached.handleCreateManagedTask(title: "T", brief: "B", teamID: nil))
        envelopes.append(await detached.handleControlTask(taskID: 1, verb: .stop))
        envelopes.append(await detached.handleManageRole(taskID: 1, roleID: "r", verb: .accept))
        envelopes.append(await detached.handleAnswerTaskQuestion(taskID: 1, answer: "a"))
        envelopes.append(await detached.handleMessageTask(taskID: 1, text: "t", roleID: nil))
        envelopes.append(await detached.handleScheduleTask(taskID: 1, intervalMinutes: 5))
        envelopes.append(await detached.handleSetWorkFolderContext(content: "c"))

        for json in envelopes {
            XCTAssertTrue(json.contains("\"ok\":false"), "got: \(json)")
            XCTAssertTrue(json.contains("Autovisor unavailable"), "got: \(json)")
        }
        XCTAssertTrue(mockDelegate.autovisorActions.isEmpty,
                      "the un-attached service must not reach THIS test's delegate either")
    }

    // MARK: Reads — guards

    func testHandleListTasks_withoutDelegate_returnsErrorEnvelope() async {
        let detached = LLMExecutionService(repository: NTMSRepository())
        let json = await detached.handleListTasks()
        XCTAssertTrue(json.contains("\"ok\":false"), "got: \(json)")
        XCTAssertTrue(json.contains("Autovisor unavailable"), "got: \(json)")
    }

    func testHandleTaskStatus_withoutDelegate_returnsErrorEnvelope() async {
        let detached = LLMExecutionService(repository: NTMSRepository())
        let json = await detached.handleTaskStatus(taskID: 1)
        XCTAssertTrue(json.contains("\"ok\":false"), "got: \(json)")
        XCTAssertTrue(json.contains("Autovisor unavailable"), "got: \(json)")
    }

    /// A task id the manager hallucinated (or that was deleted between passes)
    /// must fail loudly and name the id, not return an empty-but-successful status.
    func testHandleTaskStatus_unknownTask_failsAndNamesTheID() async {
        mockDelegate.taskToMutate = NTMSTask(id: 1, title: "T", supervisorTask: "s", runs: [Run(id: 0)])

        let json = await service.handleTaskStatus(taskID: 4242)

        XCTAssertTrue(json.contains("\"ok\":false"), "got: \(json)")
        XCTAssertTrue(json.contains("Task #4242 not found"), "got: \(json)")
    }

    // MARK: list_tasks

    /// Triage list: the manager's OWN task and every delegation CHILD are
    /// excluded, and the rest are newest-first.
    func testHandleListTasks_excludesManagerAndChildren_newestFirst() async throws {
        let old = MonotonicClock.shared.now()
        let newer = old.addingTimeInterval(60)
        let index = TasksIndex(tasks: [
            TaskSummary(id: 1, title: "older", status: .running, updatedAt: old),
            TaskSummary(id: 2, title: "newer", status: .running, updatedAt: newer),
            TaskSummary(id: managerTaskID, title: "manager", status: .running, updatedAt: newer),
            TaskSummary(id: 3, title: "child", status: .running, updatedAt: newer, parentTaskID: 1),
        ])
        mockDelegate.snapshot = Self.snapshot(tasksIndex: index, autovisorTaskID: managerTaskID)

        let rows = try Self.decodeTaskRows(await service.handleListTasks())

        XCTAssertEqual(rows.map(\.id), [2, 1],
                       "manager + children excluded, remainder sorted by updatedAt descending")
        XCTAssertEqual(rows.first?.title, "newer")
    }

    /// `chat_mode` and `updated_seconds_ago` exist so the manager doesn't guess:
    /// a chat task never reaches Review, and a large idle gap flags a triage target.
    func testHandleListTasks_reportsChatModeAndStaleness() async throws {
        let stale = MonotonicClock.shared.now().addingTimeInterval(-300)
        let index = TasksIndex(tasks: [
            TaskSummary(id: 1, title: "chat", status: .running,
                        updatedAt: MonotonicClock.shared.now(), isChatMode: true),
            TaskSummary(id: 2, title: "stale", status: .running, updatedAt: stale, isChatMode: false),
        ])
        mockDelegate.snapshot = Self.snapshot(tasksIndex: index, autovisorTaskID: nil)

        let rows = try Self.decodeTaskRows(await service.handleListTasks())
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        XCTAssertEqual(byID[1]?.chat_mode, true)
        XCTAssertEqual(byID[2]?.chat_mode, false)
        XCTAssertLessThan(byID[1]?.updated_seconds_ago ?? .max, 5,
                          "a just-touched task reads as fresh")
        XCTAssertGreaterThan(byID[2]?.updated_seconds_ago ?? -1, 250,
                             "a 5-minute-old task must read as stale")
        XCTAssertEqual(byID[1]?.status, TaskStatus.running.rawValue)
    }

    /// Degenerate corner: no snapshot at all (folder not yet assembled). The
    /// read must still answer with a well-formed empty list.
    func testHandleListTasks_noSnapshot_returnsAnEmptyList() async throws {
        mockDelegate.snapshot = nil
        let rows = try Self.decodeTaskRows(await service.handleListTasks())
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: task_status fields not covered elsewhere

    func testHandleTaskStatus_surfacesThePendingSupervisorQuestion() async throws {
        let step = StepExecution(
            id: "r", role: .softwareEngineer, title: "R", status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: "Which database?")
        mockDelegate.taskToMutate = NTMSTask(
            id: 1, title: "T", supervisorTask: "s", runs: [Run(id: 0, steps: [step])])

        let status = try Self.decodeStatus(await service.handleTaskStatus(taskID: 1))

        XCTAssertEqual(status.pending_question, "Which database?",
                       "the manager answers via answer_task_question — it needs the text")
    }

    /// An EMPTY question is not a question: surfacing `""` would tell the manager
    /// to answer something it cannot see.
    func testHandleTaskStatus_emptySupervisorQuestion_isNotSurfaced() async throws {
        let step = StepExecution(
            id: "r", role: .softwareEngineer, title: "R", status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: "")
        mockDelegate.taskToMutate = NTMSTask(
            id: 1, title: "T", supervisorTask: "s", runs: [Run(id: 0, steps: [step])])

        let status = try Self.decodeStatus(await service.handleTaskStatus(taskID: 1))

        XCTAssertNil(status.pending_question)
    }

    func testHandleTaskStatus_reportsRunTimeoutAndTimedOutFlag() async throws {
        let run = Run(id: 0,
                      steps: [StepExecution(id: "r", role: .softwareEngineer, title: "R", status: .paused)],
                      timedOutAt: MonotonicClock.shared.now())
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "s", runs: [run])
        task.runTimeoutSeconds = 900

        mockDelegate.taskToMutate = task
        let status = try Self.decodeStatus(await service.handleTaskStatus(taskID: 1))

        XCTAssertEqual(status.run_timeout_seconds, 900)
        XCTAssertTrue(status.timed_out)
    }

    /// A task with no run at all (created but never started): every run-derived
    /// field is absent/empty rather than fabricated.
    func testHandleTaskStatus_taskWithNoRuns_reportsEmptyRunDerivedFields() async throws {
        mockDelegate.taskToMutate = NTMSTask(id: 1, title: "Fresh", supervisorTask: "s", runs: [])

        let status = try Self.decodeStatus(await service.handleTaskStatus(taskID: 1))

        XCTAssertEqual(status.task_id, 1)
        XCTAssertEqual(status.title, "Fresh")
        XCTAssertTrue(status.steps.isEmpty)
        XCTAssertTrue(status.artifacts.isEmpty)
        XCTAssertNil(status.elapsed_seconds, "no run ⇒ no elapsed time to report")
        XCTAssertNil(status.roles_needing_acceptance)
        XCTAssertFalse(status.timed_out)
    }

    /// `last_error` is TASK-scoped: it comes from the delegate's per-task lookup,
    /// never the global banner (which can belong to a different task).
    func testHandleTaskStatus_lastErrorIsScopedToTheInspectedTask() async throws {
        mockDelegate.taskToMutate = NTMSTask(
            id: 1, title: "T", supervisorTask: "s",
            runs: [Run(id: 0, steps: [StepExecution(id: "r", role: .softwareEngineer, title: "R", status: .failed)])])
        mockDelegate.lastErrorPerTaskStub = [1: "Role 'R' failed.", 2: "someone else's failure"]

        let status = try Self.decodeStatus(await service.handleTaskStatus(taskID: 1))

        XCTAssertEqual(status.last_error, "Role 'R' failed.")
    }

    // MARK: isAutovisorStep / autovisorPromptBlock

    func testIsAutovisorStep_managerTeam_isTrue() {
        installManagerTask()
        XCTAssertTrue(service.isAutovisorStep(stepID: stepID, taskID: managerTaskID))
    }

    func testIsAutovisorStep_ordinaryTeam_isFalse() {
        let team = ConsultMeetFixtures.makeTeam()
        var task = NTMSTask(
            id: managerTaskID, title: "T", supervisorTask: "s",
            runs: [Run(id: 0, steps: [StepExecution(id: stepID, role: .softwareEngineer, title: "S", status: .running)])])
        task.preferredTeamID = team.id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = ConsultMeetFixtures.makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: managerTaskID)

        XCTAssertFalse(service.isAutovisorStep(stepID: stepID, taskID: managerTaskID),
                       "detection keys on the manager team's templateID, nothing else")
    }

    func testIsAutovisorStep_afterTeardown_isFalse() {
        installManagerTask()
        service.clearRunningTask(stepID: stepID, taskID: managerTaskID)
        XCTAssertFalse(service.isAutovisorStep(stepID: stepID, taskID: managerTaskID),
                       "a dead step is not a manager step — the write-through must not fire")
    }

    func testIsAutovisorStep_unknownTask_isFalse() {
        installManagerTask()
        XCTAssertFalse(service.isAutovisorStep(stepID: stepID, taskID: 4242))
    }

    /// Whitespace-only memory is no memory: emitting a bodyless
    /// "## Current Memory" header would ship a header with nothing under it on
    /// every single manager request.
    func testAutovisorPromptBlock_whitespaceOnlyMemory_returnsEmpty() {
        mockDelegate.snapshot = Self.snapshot(tasksIndex: TasksIndex(), autovisorTaskID: nil, memory: "  \n\t ")
        XCTAssertEqual(service.autovisorPromptBlock(), "")
    }

    func testAutovisorPromptBlock_trimsTheStoredMemory() {
        mockDelegate.snapshot = Self.snapshot(
            tasksIndex: TasksIndex(), autovisorTaskID: nil, memory: "\n  Reviewed 3 tasks.  \n")
        let block = service.autovisorPromptBlock()
        XCTAssertEqual(block, "## Current Memory (your standing notes from prior reviews)\nReviewed 3 tasks.")
    }

    func testAutovisorPromptBlock_noSnapshot_returnsEmpty() {
        mockDelegate.snapshot = nil
        XCTAssertEqual(service.autovisorPromptBlock(), "")
    }

    // MARK: - Helpers

    private func installManagerTask() {
        let team = TeamTemplateFactory.autovisor()
        var task = NTMSTask(
            id: managerTaskID, title: "Autovisor", supervisorTask: "goal",
            runs: [Run(id: 0, steps: [StepExecution(id: stepID, role: .autovisor, title: "Manager", status: .running)])],
            isChatMode: true)
        task.preferredTeamID = team.id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "T", activeTeamID: team.id, autovisorTaskID: managerTaskID),
                settings: .defaults, teams: [team]),
            tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: managerTaskID, activeTask: task)
        service._testRegisterStepTask(stepID: stepID, taskID: managerTaskID)
    }

    private static func snapshot(
        tasksIndex: TasksIndex, autovisorTaskID: Int?, memory: String = ""
    ) -> WorkFolderContext {
        var settings = ProjectSettings.defaults
        settings.autovisorMemory = memory
        return WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "T", autovisorTaskID: autovisorTaskID),
                settings: settings, teams: []),
            tasksIndex: tasksIndex, toolDefinitions: [], activeTaskID: nil)
    }

    // Decoding DTOs — deliberately narrow so unrelated envelope fields can grow.

    private struct OKDTO: Decodable { let status: String; let message: String; let task_id: Int? }
    private struct ErrDTO: Decodable { let code: String; let message: String }
    private struct TaskRowDTO: Decodable {
        let id: Int
        let title: String
        let status: String
        let chat_mode: Bool
        let updated_seconds_ago: Int
    }
    private struct ArtifactRowDTO: Decodable { let name: String; let path: String? }
    private struct StepRowDTO: Decodable { let role_id: String; let status: String }
    private struct StatusDTO: Decodable {
        let task_id: Int
        let title: String
        let chat_mode: Bool
        let elapsed_seconds: Int?
        let run_timeout_seconds: Int?
        let timed_out: Bool
        let steps: [StepRowDTO]
        let artifacts: [ArtifactRowDTO]
        let pending_question: String?
        let last_error: String?
        let roles_needing_acceptance: [String]?
    }

    private static func decodeOK(_ json: String) throws -> OKDTO {
        struct Envelope: Decodable { let data: OKDTO }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data
    }

    private static func decodeError(_ json: String) throws -> ErrDTO {
        struct Envelope: Decodable { let error: ErrDTO }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).error
    }

    private static func decodeTaskRows(_ json: String) throws -> [TaskRowDTO] {
        struct Envelope: Decodable {
            struct Block: Decodable { let tasks: [TaskRowDTO] }
            let data: Block
        }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data.tasks
    }

    private static func decodeStatus(_ json: String) throws -> StatusDTO {
        struct Envelope: Decodable { let data: StatusDTO }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data
    }
}

// MARK: - MeetingStreamingService

@MainActor
final class MeetingStreamingTransportTests: XCTestCase {

    // MARK: streamParticipantResponse — the transport wrapper, untested before this

    func testStreamParticipantResponse_accumulatesContentThinkingAndToolCalls() async throws {
        let client = ScriptedConsultClient(
            content: "We should ship.",
            thinking: "Weighing the options.",
            toolCallDeltas: [
                StreamEvent.ToolCallDelta(index: 0, id: "tc_1", name: ToolNames.readFile,
                                          argumentsDelta: #"{"path":"a.swift"}"#)
            ])

        let result = try await MeetingStreamingService.streamParticipantResponse(
            messages: [ChatMessage(role: .user, content: "go")],
            client: client, config: Self.config(), tools: [])

        XCTAssertEqual(result.content, "We should ship.")
        XCTAssertEqual(result.thinking, "Weighing the options.")
        XCTAssertEqual(result.resolvedToolCalls.count, 1,
                       "tool-call deltas must be absorbed and finalized, not dropped")
        XCTAssertEqual(result.resolvedToolCalls.first?.name, ToolNames.readFile)
        XCTAssertEqual(result.resolvedToolCalls.first?.argumentsJSON, #"{"path":"a.swift"}"#)
    }

    /// Both channels are trimmed: a turn whose content is padded whitespace must
    /// not enter the transcript as a leading blank line.
    func testStreamParticipantResponse_trimsBothChannels() async throws {
        let client = ScriptedConsultClient(content: "\n  spoken  \n", thinking: "  reasoned  ")

        let result = try await MeetingStreamingService.streamParticipantResponse(
            messages: [], client: client, config: Self.config(), tools: [])

        XCTAssertEqual(result.content, "spoken")
        XCTAssertEqual(result.thinking, "reasoned")
    }

    /// A stream that yields nothing at all resolves to an empty result rather
    /// than throwing — the caller decides what an empty turn means.
    func testStreamParticipantResponse_emptyStream_returnsEmptyResult() async throws {
        let client = ScriptedConsultClient()

        let result = try await MeetingStreamingService.streamParticipantResponse(
            messages: [], client: client, config: Self.config(), tools: [])

        XCTAssertEqual(result.content, "")
        XCTAssertEqual(result.thinking, "")
        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
    }

    func testStreamParticipantResponse_transportFailure_propagates() async {
        let client = ScriptedConsultClient(shouldThrow: ScriptedConsultError(text: "boom"))

        do {
            _ = try await MeetingStreamingService.streamParticipantResponse(
                messages: [], client: client, config: Self.config(), tools: [])
            XCTFail("a throwing stream must surface to the caller, not resolve empty")
        } catch {
            XCTAssertTrue("\(error)".contains("boom"), "got: \(error)")
        }
    }

    /// The tool catalog is passed straight through in both directions — the
    /// empty case must ship an empty array, not a nil-ish placeholder.
    func testStreamParticipantResponse_passesTheToolCatalogThrough() async throws {
        let schema = ToolSchema(name: ToolNames.readFile, description: "d",
                                parameters: JSONSchema(type: "object"))
        let client = ScriptedConsultClient(content: "x")

        _ = try await MeetingStreamingService.streamParticipantResponse(
            messages: [], client: client, config: Self.config(), tools: [schema])
        XCTAssertEqual(client.capturedTools.map(\.name), [ToolNames.readFile])

        _ = try await MeetingStreamingService.streamParticipantResponse(
            messages: [], client: client, config: Self.config(), tools: [])
        XCTAssertTrue(client.capturedTools.isEmpty)
    }

    // MARK: buildMeetingMessages — artifact grounding

    /// Grounding rides its own user turn, immediately after the system prompt
    /// and BEFORE the meeting header (it is fixed, so it belongs in the cached head).
    func testBuildMeetingMessages_withReadableArtifact_insertsGroundingAfterTheSystemPrompt() {
        let artifact = Artifact(name: "Product Requirements")
        let wire = MeetingStreamingService.buildMeetingMessages(
            speaker: .softwareEngineer,
            meeting: Self.meeting(),
            context: Self.context(artifacts: [artifact], reader: { _ in "Ship the parser." }))

        XCTAssertEqual(wire.first?.role, .system)
        let grounding = wire[1]
        XCTAssertEqual(grounding.role, .user)
        XCTAssertTrue(grounding.content?.contains("Available team artifacts:") ?? false,
                      "got: \(grounding.content ?? "nil")")
        XCTAssertTrue(grounding.content?.contains("[Product Requirements]:") ?? false)
        XCTAssertTrue(grounding.content?.contains("Ship the parser.") ?? false)
        XCTAssertTrue(wire[2].content?.contains("## Team meeting") ?? false,
                      "the header must follow the grounding turn")
    }

    /// No artifacts ⇒ no grounding turn at all. An empty "Available team
    /// artifacts:" user turn would be a wasted (and confusing) segment.
    func testBuildMeetingMessages_noArtifacts_emitsNoGroundingTurn() {
        let wire = MeetingStreamingService.buildMeetingMessages(
            speaker: .softwareEngineer, meeting: Self.meeting(), context: Self.context())

        XCTAssertEqual(wire.first?.role, .system)
        XCTAssertTrue(wire[1].content?.contains("## Team meeting") ?? false,
                      "the header must follow the system prompt directly; got: \(wire[1].content ?? "nil")")
        XCTAssertFalse(wire.contains { $0.content?.contains("Available team artifacts:") ?? false })
    }

    /// An artifact whose file can't be read is still ANNOUNCED by name — the
    /// speaker must know it exists even when its body is unavailable.
    func testBuildMeetingMessages_unreadableArtifact_isStillAnnouncedByName() {
        let wire = MeetingStreamingService.buildMeetingMessages(
            speaker: .softwareEngineer, meeting: Self.meeting(),
            context: Self.context(artifacts: [Artifact(name: "Design Spec")], reader: { _ in nil }))

        let grounding = wire[1].content ?? ""
        XCTAssertTrue(grounding.contains("[Design Spec]:"), "got: \(grounding)")
        XCTAssertFalse(grounding.contains("```"), "no fence may be opened for absent content")
    }

    /// Oversized artifacts are capped at `ArtifactConstants.maxConsultationChars`
    /// and the cut is ANNOUNCED — a silent truncation reads as a complete document.
    func testBuildMeetingMessages_oversizedArtifact_isTruncatedAndSaysSo() {
        let cap = ArtifactConstants.maxConsultationChars
        let body = String(repeating: "x", count: cap + 200)
        let wire = MeetingStreamingService.buildMeetingMessages(
            speaker: .softwareEngineer, meeting: Self.meeting(),
            context: Self.context(artifacts: [Artifact(name: "Big")], reader: { _ in body }))

        let grounding = wire[1].content ?? ""
        XCTAssertTrue(grounding.contains("... (truncated)"), "the cut must be announced")
        XCTAssertFalse(grounding.contains(String(repeating: "x", count: cap + 1)),
                       "no more than the cap may ship")
    }

    /// Exactly at the cap is NOT truncated — the boundary must not report a cut
    /// that did not happen.
    func testBuildMeetingMessages_artifactExactlyAtTheCap_isNotMarkedTruncated() {
        let body = String(repeating: "y", count: ArtifactConstants.maxConsultationChars)
        let wire = MeetingStreamingService.buildMeetingMessages(
            speaker: .softwareEngineer, meeting: Self.meeting(),
            context: Self.context(artifacts: [Artifact(name: "Exact")], reader: { _ in body }))

        XCTAssertFalse(wire[1].content?.contains("... (truncated)") ?? true)
    }

    // MARK: determineNextSpeaker corners

    /// Degenerate roster: a meeting that somehow has messages but no remaining
    /// participants falls back to the coordinator rather than trapping on `.first`.
    func testDetermineNextSpeaker_noPendingParticipants_fallsBackToCoordinator() {
        var meeting = Self.meeting()
        meeting.addMessage(TeamMessage(role: .softwareEngineer, content: "done"))

        let next = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting, participants: [], coordinator: .productManager)

        XCTAssertEqual(next, .productManager)
    }

    /// A participant who has NOT spoken inside the recency window is chosen in
    /// declaration order — round-robin, not "whoever spoke least".
    func testDetermineNextSpeaker_picksTheFirstParticipantWhoHasNotSpokenRecently() {
        var meeting = Self.meeting()
        meeting.addMessage(TeamMessage(role: .productManager, content: "opening"))

        let next = MeetingStreamingService.determineNextSpeaker(
            meeting: meeting,
            participants: [.productManager, .softwareEngineer],
            coordinator: .productManager)

        XCTAssertEqual(next, .softwareEngineer)
    }

    // MARK: - Fixtures

    private static func config() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
    }

    private static func meeting() -> TeamMeeting {
        TeamMeetingService.createMeeting(
            topic: "API design", initiatedBy: .productManager,
            participants: [.productManager, .softwareEngineer], context: nil)
    }

    private static func context(
        artifacts: [Artifact] = [],
        reader: @escaping (Artifact) -> String? = { _ in nil }
    ) -> TeamMeetingService.MeetingContext {
        TeamMeetingService.MeetingContext(
            initiatedBy: .productManager,
            participants: [.productManager, .softwareEngineer],
            availableArtifacts: artifacts,
            artifactReader: reader,
            team: nil,
            coordinatorRole: .productManager,
            limits: TeamLimits())
    }
}

// MARK: - TeamMeetingService.completeTurn

@MainActor
final class TeamMeetingTurnCompletionTests: XCTestCase {

    /// A turn that leaves work outstanding (someone has not spoken) keeps the
    /// meeting going — `completeTurn` returns "continue".
    func testCompleteTurn_participantStillSilent_continues() {
        var meeting = Self.meeting()
        let shouldContinue = TeamMeetingService.completeTurn(
            meeting: &meeting, speaker: .productManager,
            content: "Let's discuss the API surface.", thinking: nil, toolSummaries: nil,
            context: Self.context(maxTurns: 10))

        XCTAssertTrue(shouldContinue, "one silent participant remains")
        XCTAssertEqual(meeting.messages.count, 1)
    }

    /// Everyone has spoken AND the last turns carry a CONCLUSION: the meeting
    /// stops. This is the `hasConclusion` half of the agreement/conclusion pair.
    func testCompleteTurn_allParticipatedAndConcluded_stops() {
        var meeting = Self.meeting()
        meeting.addMessage(TeamMessage(role: .productManager, content: "Let's use REST.",
                                       messageType: .proposal))
        let shouldContinue = TeamMeetingService.completeTurn(
            meeting: &meeting, speaker: .softwareEngineer,
            content: "In conclusion, REST it is.", thinking: nil, toolSummaries: nil,
            context: Self.context(maxTurns: 10))

        XCTAssertEqual(meeting.messages.last?.messageType, .conclusion,
                       "precondition: the classifier must read this as a conclusion")
        XCTAssertFalse(shouldContinue, "an all-hands conclusion ends the meeting")
    }

    /// The turn limit stops the meeting regardless of who has spoken — the
    /// branch a real run reaches most often.
    func testCompleteTurn_turnLimitReached_stops() {
        var meeting = Self.meeting()
        let shouldContinue = TeamMeetingService.completeTurn(
            meeting: &meeting, speaker: .productManager,
            content: "Opening remarks.", thinking: nil, toolSummaries: nil,
            context: Self.context(maxTurns: 1))

        XCTAssertFalse(shouldContinue, "turnCount(1) >= maxMeetingTurns(1)")
    }

    /// Model sentinels are stripped before the turn enters the transcript — the
    /// transcript is replayed verbatim into every later turn's wire.
    func testCompleteTurn_stripsModelTokensFromTheRecordedTurn() {
        var meeting = Self.meeting()
        _ = TeamMeetingService.completeTurn(
            meeting: &meeting, speaker: .productManager,
            content: "<|channel|>Let's use REST.", thinking: "raw", toolSummaries: nil,
            context: Self.context(maxTurns: 10))

        XCTAssertEqual(meeting.messages.last?.content, "Let's use REST.")
        XCTAssertEqual(meeting.messages.last?.thinking, "raw",
                       "thinking is stored as captured — only the spoken content is cleaned")
    }

    /// `MeetingContext.globalContext` defaults to empty so existing call sites
    /// stay valid AND a context-free meeting ships no stray guidance block.
    func testMeetingContext_globalContextDefaultsToEmpty() {
        XCTAssertEqual(Self.context(maxTurns: 10).globalContext, "")
    }

    // MARK: - Fixtures

    private static func meeting() -> TeamMeeting {
        TeamMeetingService.createMeeting(
            topic: "API design", initiatedBy: .productManager,
            participants: [.productManager, .softwareEngineer], context: nil)
    }

    private static func context(maxTurns: Int) -> TeamMeetingService.MeetingContext {
        TeamMeetingService.MeetingContext(
            initiatedBy: .productManager,
            participants: [.productManager, .softwareEngineer],
            availableArtifacts: [],
            artifactReader: { _ in nil },
            team: nil,
            coordinatorRole: .productManager,
            limits: TeamLimits(maxMeetingTurns: maxTurns))
    }
}
