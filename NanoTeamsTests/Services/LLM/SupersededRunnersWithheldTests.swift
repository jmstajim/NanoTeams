import XCTest

@testable import NanoTeams

/// The requester of an approved `request_changes` keeps working (`holdDownstreamForRevision`
/// does not cancel it) while the target rewrites the tree — so from the moment its status
/// flips to `.revisionRequested` it must not build. The flip happens from INSIDE its own
/// tool loop, after `resolveStepRuntime` resolved the schema at entry, and until the evening
/// of 2026-09-11 nothing re-read it: the runners stayed authorized for the whole step, and
/// the approval reply's "the build runners are withheld until then" was false for the one
/// step it was about (review of 1.9.18, S2-1).
///
/// The withhold is an AUTHORIZATION narrowed per iteration at the executor, like the
/// planning phase — never a narrowed wire: the tool catalog is rendered into the prompt, so
/// shrinking the `tools` array mid-step would re-prefill every remaining request.
@MainActor
final class SupersededRunnersWithheldTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let stepID = "verifier"
    private let taskID = 48

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        mockDelegate = MockLLMExecutionDelegate()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("superseded-\(UUID().uuidString)", isDirectory: true)
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

    /// Turn 1: `read_file`; the role is marked `.revisionRequested` while that request is
    /// in flight. Turn 2: `run_xcodebuild` — it must come back `work_superseded`, and the
    /// runner must never have run. And the wire must not have moved: request 2 advertises
    /// the same catalog as request 1.
    ///
    /// RED: drop `supersededToolNames` from `runOneLLMToolIteration` → turn 2's build
    /// executes (in this fixture: the runner's own "no project" error, not `work_superseded`).
    func testRunnersAreWithheldOnTheIterationAfterTheHold_andTheWireDoesNotMove() async throws {
        seed()
        let client = ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.readFile, argumentsJSON: #"{"path":"a.txt"}"#),
            .toolCall(name: ToolNames.runXcodebuild, argumentsJSON: "{}"),
            .hang,
        ])
        let delegate = mockDelegate!
        let stepID = self.stepID
        client.onRequest = { index in
            guard index == 0 else { return }
            Task { @MainActor in
                delegate.taskToMutate?.runs[0].roleStatuses[stepID] = .revisionRequested
            }
        }
        attach(client)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil {
            self.step()?.toolCalls.contains { $0.name == ToolNames.runXcodebuild && $0.resultJSON != nil } ?? false
        }
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)

        let build = step()!.toolCalls.first { $0.name == ToolNames.runXcodebuild }!
        XCTAssertTrue(build.resultJSON!.contains("work_superseded"), build.resultJSON!)
        XCTAssertTrue(build.resultJSON!.contains("re-run"), build.resultJSON!)
        XCTAssertEqual(build.isError, true)
        XCTAssertFalse(build.resultJSON!.contains("No Xcode project"),
                       "the runner must not have run at all: \(build.resultJSON!)")

        let advertised = client.toolNamesPerRequest
        XCTAssertGreaterThanOrEqual(advertised.count, 2, "premise: two requests went out")
        XCTAssertTrue(advertised[0].contains(ToolNames.runXcodebuild),
                      "premise: the schema resolved at entry carried the runner")
        XCTAssertEqual(advertised[1], advertised[0],
                       "the withhold is an authorization, not a narrowed wire — the catalog must "
                           + "stay byte-identical for the prompt-prefix cache")
    }

    /// A role that is NOT superseded keeps its runners authorized through the loop — the
    /// withhold is keyed on the status, not on the role holding runners.
    func testAnOrdinaryStep_keepsItsRunnersAuthorized() async throws {
        seed()
        let client = ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.runXcodebuild, argumentsJSON: "{}"),
            .hang,
        ])
        attach(client)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil {
            self.step()?.toolCalls.contains { $0.name == ToolNames.runXcodebuild && $0.resultJSON != nil } ?? false
        }
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)

        let build = step()!.toolCalls.first { $0.name == ToolNames.runXcodebuild }!
        XCTAssertFalse(build.resultJSON!.contains("work_superseded"), build.resultJSON!)
    }

    // MARK: - Fixtures

    private func step() -> StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    private func attach(_ client: ScriptedToolCallClient) {
        service = LLMExecutionService(repository: NTMSRepository(), clientFactory: { client })
        service.retryDelaySeconds = 1
        service.attach(delegate: mockDelegate)
    }

    /// A checker holding the runners, in a real (temp) work folder with a scheme selected —
    /// the resolver strips the runners without one (DEBTS D-B8), and the point here is a
    /// runner that IS in the schema and is refused by the executor.
    private func seed() {
        let role = TeamRoleDefinition(
            id: stepID, name: "Change Verifier", prompt: "p",
            toolIDs: [ToolNames.readFile, ToolNames.runXcodebuild, ToolNames.createArtifact],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Implementation Notes"],
                                           producesArtifacts: ["Verification Report"]),
            systemRoleID: "changeVerifier")
        let team = Team(
            name: "Pipeline", roles: [role], artifacts: [],
            settings: TeamSettings(supervisorMode: .manual), graphLayout: TeamGraphLayout())
        let step = StepExecution(
            id: stepID, role: .changeVerifier, title: "Verifier",
            expectedArtifacts: ["Verification Report"], status: .running,
            llmConversation: [LLMMessage(role: .system, content: "System prompt")])
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "Verify it",
            runs: [Run(id: 0, steps: [step], roleStatuses: [stepID: .working])])
        task.preferredTeamID = team.id
        mockDelegate.taskToMutate = task
        var settings = ProjectSettings.defaults
        settings.selectedScheme = "App"
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "T", activeTeamID: team.id),
                settings: settings, teams: [team]),
            tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: taskID, activeTask: task)
    }

    private func waitUntil(
        timeout: TimeInterval = 8.0,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw WaitTimeout(timeout: timeout) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct WaitTimeout: Error, LocalizedError {
        let timeout: TimeInterval
        var errorDescription: String? { "condition not met within \(timeout)s" }
    }
}
