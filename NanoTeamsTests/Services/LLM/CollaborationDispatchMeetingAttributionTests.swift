import XCTest
@testable import NanoTeams

/// Heavy-integration pins for the `.teamMeeting` branch of
/// `LLMExecutionService.appendCollaborationResult` — specifically the
/// attribution wiring `attributionRole = effectiveCoordinator(team:, initiator: roleForMessage)`.
///
/// `effectiveCoordinator(team:initiator:)` itself is unit-tested in
/// `LLMExecutionServiceTests`. These tests guard the **dispatcher call site**:
/// if a future refactor swaps `roleForMessage` for the wrong Role argument
/// (e.g. a meeting speaker instead of the meeting initiator), the helper
/// unit tests still pass and the LLM-conversation `sourceRole` silently
/// regresses. Round-3 review Gap 3 (pr-test-analyzer).
///
/// Strategy: drive `appendCollaborationResult` with a `.teamMeeting` signal
/// + EMPTY `participants` so `handleTeamMeeting` short-circuits at its
/// "no valid participants" guard. The dispatcher's attribution code still
/// runs after the early return, so the appended `LLMMessage.sourceRole`
/// reflects the attribution wiring under test.
@MainActor
final class CollaborationDispatchMeetingAttributionTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let initiatorRole: Role = .softwareEngineer
    private let designatedCoordRole: Role = .productManager

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("disp-meet-attr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Auto mode: attribution lands on the initiator

    func testDispatcher_autoMode_meetingResult_attributedToInitiator() async {
        let team = makeTeam(coordID: nil)
        let task = makeTaskWithStep(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        await driveTeamMeetingDispatch(task: task)

        let appended = mockDelegate.taskToMutate?
            .runs[0].steps[0].llmConversation
            .last(where: { $0.sourceContext == .meeting })
        XCTAssertNotNil(appended, "Meeting result must be appended to llmConversation")
        XCTAssertEqual(appended?.sourceRole, initiatorRole,
                       "Auto mode: meeting result must be attributed to the initiator (roleForMessage)")
    }

    // MARK: - Coordinator mode: attribution lands on the designated coordinator

    func testDispatcher_designatedCoordinatorMode_meetingResult_attributedToCoordinator() async {
        let team = makeTeam(coordID: "team_pm")
        let task = makeTaskWithStep(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        await driveTeamMeetingDispatch(task: task)

        let appended = mockDelegate.taskToMutate?
            .runs[0].steps[0].llmConversation
            .last(where: { $0.sourceContext == .meeting })
        XCTAssertNotNil(appended)
        XCTAssertEqual(appended?.sourceRole, designatedCoordRole,
                       "Coordinator mode: meeting result must be attributed to the designated coordinator")
    }

    // MARK: - Change-request: attribution lands on the requesting role

    /// Round-2 S2.3 / wiring pin: `+ToolResultDispatching.swift`'s
    /// `.changeRequest` branch uses `attributionRole = roleForMessage`, so the
    /// activity-feed entry for a change-request signal must surface under the
    /// requesting role's avatar (not the target role, not the coordinator).
    /// Drives the dispatcher with an invalid `targetRoleID` so
    /// `handleChangeRequest` short-circuits at validation and the attribution
    /// code still runs.
    func testDispatcher_changeRequest_attributedToRequestingRole() async {
        let team = makeTeam(coordID: nil)
        let task = makeTaskWithStep(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        let toolCallID = UUID()
        let result = ToolExecutionResult(
            providerID: "tc_cr",
            toolName: ToolNames.requestChanges,
            argumentsJSON: #"{"target_role":"ghost_role","changes":[],"reasoning":"…"}"#,
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            isError: false,
            signal: .changeRequest(targetRole: "ghost_role", changes: "", reasoning: "…")
        )
        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: result,
            toolCallID: toolCallID,
            roleForMessage: initiatorRole,
            stepID: stepID,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: StubLLMClient(),
            config: LLMConfig(),
            networkLogger: nil,
            conversationMessages: &conversation
        )

        let appended = mockDelegate.taskToMutate?
            .runs[0].steps[0].llmConversation
            .last(where: { $0.sourceContext == .changeRequest })
        XCTAssertNotNil(appended,
                        "Change-request dispatcher must append a result message with .changeRequest context")
        XCTAssertEqual(appended?.sourceRole, initiatorRole,
                       "Change-request attribution must land on the requesting role")
    }

    // MARK: - Orphan mode: attribution falls back to the initiator

    func testDispatcher_orphanCoordinator_meetingResult_attributedToInitiator() async {
        // Stored coord references a role that doesn't exist on the team —
        // `effectiveCoordinator` self-heals to the initiator.
        let team = makeTeam(coordID: "ghost-of-deleted-coord")
        let task = makeTaskWithStep(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        await driveTeamMeetingDispatch(task: task)

        let appended = mockDelegate.taskToMutate?
            .runs[0].steps[0].llmConversation
            .last(where: { $0.sourceContext == .meeting })
        XCTAssertNotNil(appended)
        XCTAssertEqual(appended?.sourceRole, initiatorRole,
                       "Orphan coord: meeting result must self-heal to initiator attribution")
    }

    // MARK: - Helpers

    private let stepID = "team_software_engineer"

    /// Calls `appendCollaborationResult` with a `.teamMeeting` signal and
    /// EMPTY participants list. `handleTeamMeeting` short-circuits at the
    /// "no valid participants" guard, so this test reaches the dispatcher's
    /// attribution code path without needing a real LLM round-trip.
    private func driveTeamMeetingDispatch(task: NTMSTask) async {
        let toolCallID = UUID()
        let result = ToolExecutionResult(
            providerID: "tc_meeting",
            toolName: ToolNames.requestTeamMeeting,
            argumentsJSON: #"{"topic":"x","participants":[]}"#,
            outputJSON: #"{"ok":true,"data":{"status":"started"}}"#,
            isError: false,
            signal: .teamMeeting(topic: "x", participants: [], context: nil)
        )
        var conversation: [ChatMessage] = []
        await service.appendCollaborationResult(
            result: result,
            toolCallID: toolCallID,
            roleForMessage: initiatorRole,
            stepID: stepID,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: StubLLMClient(),
            config: LLMConfig(),
            networkLogger: nil,
            conversationMessages: &conversation
        )
    }

    private func makeTeam(coordID: String?) -> Team {
        let pm = TeamRoleDefinition(
            id: "team_pm",
            name: "Product Manager",
            prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            systemRoleID: "productManager"
        )
        let swe = TeamRoleDefinition(
            id: "team_software_engineer",
            name: "Software Engineer",
            prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            systemRoleID: "softwareEngineer"
        )
        return Team(
            name: "TestTeam",
            roles: [pm, swe],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: coordID),
            graphLayout: TeamGraphLayout()
        )
    }

    private func makeTaskWithStep(team: Team) -> NTMSTask {
        let step = StepExecution(
            id: stepID,
            role: initiatorRole,
            title: "SWE step",
            status: .running
        )
        let run = Run(id: 0, steps: [step])
        var task = NTMSTask(
            id: 7,
            title: "T",
            supervisorTask: "...",
            runs: [run]
        )
        task.preferredTeamID = team.id
        return task
    }

    /// Builds a `WorkFolderContext` snapshot the service can use to resolve
    /// the team via `delegate.snapshot?.workFolder` — the path
    /// `resolveTeam(task:)` actually takes.
    private func makeSnapshot(team: Team, task: NTMSTask) -> WorkFolderContext {
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "T", activeTeamID: team.id),
            settings: .defaults,
            teams: [team]
        )
        return WorkFolderContext(
            projection: projection,
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: task.id,
            activeTask: task
        )
    }
}

// MARK: - Stub LLM client (never called for the empty-participants path)

private final class StubLLMClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        session _: LLMSession?,
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
