import XCTest
@testable import NanoTeams

/// Pins the fix for "a failed voting meeting silently auto-approves a change request".
///
/// `handleChangeRequest` runs an auto-voting meeting and reads its votes back from
/// persisted state. If that meeting fails to run (no work folder, no participants,
/// meeting-limit reached, cancellation), no meeting is persisted, so `tallyVotes([])`
/// returns `.tied` (0-0) and the `.tied` arm USED TO auto-approve and execute the
/// amendment with zero real votes — mutating a downstream deliverable and reporting
/// "APPROVED" to the Supervisor with no failure surfaced.
///
/// Forcing function: leave `workFolderURL == nil` so the inner `handleTeamMeeting`
/// short-circuits at its no-work-folder guard BEFORE persisting any meeting, while
/// change-request validation (which needs no work folder) still passes.
@MainActor
final class ChangeRequestVotingFailureTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    private let requestingStepID = "team_software_engineer"
    private let targetStepID = "team_pm"

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        // Deliberately NO workFolderURL — forces the voting meeting to fail at its
        // no-work-folder guard so we exercise the failed-meeting -> empty-tally path.
    }

    override func tearDown() {
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    func testChangeRequest_votingMeetingFails_doesNotAutoApprove() async {
        let team = makeTeam()
        let task = makeTask(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)
        service._testRegisterStepTask(stepID: requestingStepID, taskID: task.id)

        let reply = await service.handleChangeRequest(
            stepID: requestingStepID,
            targetRoleID: targetStepID,
            changes: "Tighten the error handling.",
            reasoning: "The current path swallows failures.",
            requestingRole: .softwareEngineer,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: SilentLLMClient(),
            config: LLMConfig()
        )

        // THE pin: a change request whose vote never ran must NOT report success.
        // Pre-fix this returned `.ok("...TIED VOTE — auto-approved...")` (succeeded == true).
        XCTAssertFalse(reply.succeeded,
            "A change request whose voting meeting failed to run must not auto-approve. got: \(reply.text)")
        XCTAssertTrue(reply.text.lowercased().contains("vote") || reply.text.lowercased().contains("voting"),
            "Failure reason should explain the vote did not run. got: \(reply.text)")

        // The recorded change request must not be marked approved.
        let recorded = mockDelegate.taskToMutate?.runs[0].changeRequests.last
        XCTAssertNotNil(recorded, "The change request must be recorded even when the vote fails.")
        XCTAssertNotEqual(recorded?.status, .approved,
            "A non-running vote must not leave the change request APPROVED.")

        // No silent amendment may have been executed against the target's completed work.
        let targetStep = mockDelegate.taskToMutate?.runs[0].steps.first { $0.id == targetStepID }
        XCTAssertEqual(targetStep?.amendments.count, 0,
            "A failed vote must not silently amend the target role's deliverable.")
    }

    // MARK: - Helpers

    private func makeTeam() -> Team {
        let pm = TeamRoleDefinition(
            id: targetStepID, name: "Product Manager", prompt: "p",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Product Requirements"]),
            systemRoleID: "productManager"
        )
        let swe = TeamRoleDefinition(
            id: requestingStepID, name: "Software Engineer", prompt: "p",
            toolIDs: [ToolNames.requestChanges], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Product Requirements"]),
            systemRoleID: "softwareEngineer"
        )
        return Team(
            name: "TestTeam", roles: [pm, swe], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    private func makeTask(team: Team) -> NTMSTask {
        // Target (PM) step is .done so change-request validation passes; the
        // requesting (SWE) step is .running so isExecutionLive holds.
        let pmStep = StepExecution(id: targetStepID, role: .productManager, title: "PM step", status: .done)
        let sweStep = StepExecution(id: requestingStepID, role: .softwareEngineer, title: "SWE step", status: .running)
        let run = Run(id: 0, steps: [sweStep, pmStep])
        var task = NTMSTask(id: 7, title: "T", supervisorTask: "...", runs: [run])
        task.preferredTeamID = team.id
        return task
    }

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

// MARK: - Silent LLM client (the voting meeting fails before any LLM call)

private final class SilentLLMClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
