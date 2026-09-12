import XCTest

@testable import NanoTeams

/// The runner's own end state after a TIMEOUT, driven offline through the orchestrator
/// seam (`HeadlessRunner.init(config:makeOrchestrator:)`) around a client that never answers.
///
/// A timed-out run used to exit with its task still `.running` on disk — the engine was
/// live, the process simply left. `StatusRecoveryService` repairs that at the folder's next
/// open, but only AFTER the bootstrap's bundled-content reconcile has read the stranded step
/// as "actively executing" and deferred the team (`NTMSRepository.busyRoleIDs`) — so the
/// first measurement of a template change in that folder ran on the OLD templates
/// (MeditationApp task 60, 2026-09-11). The runner now pauses its task on a timeout: the
/// state the app itself writes for an interrupted run, and the one the reconcile ignores.
@MainActor
final class HeadlessRunnerTimeoutTests: XCTestCase {

    private var workFolder: URL!
    private var client: ScriptedToolCallClient!
    private var service: LLMExecutionService!
    private var runner: HeadlessRunner!

    override func setUp() async throws {
        try await super.setUp()
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-timeout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let hanging = ScriptedToolCallClient(script: [.hang])
        client = hanging
        service = LLMExecutionService(repository: NTMSRepository(), clientFactory: { hanging })
    }

    override func tearDown() async throws {
        runner = nil
        service = nil
        client = nil
        if let workFolder { try? FileManager.default.removeItem(at: workFolder) }
        workFolder = nil
        try await super.tearDown()
    }

    /// RED: drop the `pauseRun` on the timeout arm → the step stays `.running`, the role
    /// `.working`, `busyRoleIDs` names the role — the team is pinned by a ghost.
    func testATimedOutRun_leavesItsTaskPaused_soItDoesNotPinItsTeam() async throws {
        let json = """
        {"projectPath": "\(workFolder.path)", "taskTitle": "Timeout",
         "supervisorTask": "Hang until the clock runs out.", "teamTemplate": "codingAssistant",
         "timeoutSeconds": 1, "maxLLMRetries": 0}
        """
        let config = try JSONCoderFactory.makeWireDecoder().decode(HeadlessConfig.self, from: Data(json.utf8))
        let service = try XCTUnwrap(self.service)
        var captured: NTMSOrchestrator?
        runner = HeadlessRunner(config: config) { configuration in
            let orchestrator = TestOrchestrator.make(llmExecutionService: service, configuration: configuration)
            captured = orchestrator
            return orchestrator
        }

        let result = await runner.run()

        XCTAssertEqual(result.outcome, .timeout)
        XCTAssertEqual(client.callCount, 1, "anti-vacuum: the step reached the client and hung there")
        let taskID = try XCTUnwrap(result.taskID)
        let orchestrator = try XCTUnwrap(captured)
        XCTAssertEqual(orchestrator.taskEngineStates[taskID], .paused,
                       "the engine the runner is leaving behind is paused, not still running")
        let task = try NTMSRepository().loadTask(at: workFolder, taskID: taskID)
        let run = try XCTUnwrap(task.runs.last)
        XCTAssertEqual(run.steps.map(\.status), [.paused],
                       "the interrupted step is paused — the state the GUI's Pause leaves")
        XCTAssertTrue(NTMSRepository.busyRoleIDs(task).isEmpty,
                      "a paused task must not defer its team's bundled-content reconcile")
        XCTAssertEqual(result.roleResults.first(where: { $0.stepID == run.steps[0].id })?.stepStatus, .paused,
                       "the receipt reports the state the run was LEFT in, not the one it was interrupted in")
    }
}
