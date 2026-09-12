import XCTest
@testable import NanoTeams

/// Pins the plumbing `allowedToolNames ∋ ask_supervisor_form → ToolExecutionContext
/// .questionnaireAvailable → AskSupervisorTool`, the way `ExpectedArtifactsPlumbingTests` pins
/// `expectedArtifacts`: the handler-level tests build the context by hand, so a refactor that
/// drops the argument from `executeToolCalls` compiles, passes them, and silently turns the
/// refusal off for every real batch — the defect this wave measured would be back with no test
/// red.
@MainActor
final class QuestionnaireAvailabilityPlumbingTests: XCTestCase {

    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var runtime: ToolRuntime!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try FileManager.default.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        runtime = nil
        service = nil
        mockDelegate = nil
        tempDir = nil
        try await super.tearDown()
    }

    /// Two questions as a numbered list — the shape the run of 2026-09-11 sent 30 times.
    private static let questionnaire = "Two things before I plan:\n1. Which view hides the badge?\n2. Should the choice persist?"
    private static let questionnaireJSON = "{\"question\":\"Two things before I plan:\\n1. Which view hides the badge?\\n2. Should the choice persist?\"}"

    func testExecuteToolCalls_formInTheBatch_refusesTheQuestionnaireShapedPlainAsk() async {
        let batch = await execute(allowed: [ToolNames.askSupervisor, ToolNames.askSupervisorForm])

        XCTAssertEqual(batch.count, 1)
        XCTAssertTrue(batch[0].isError, batch[0].outputJSON)
        XCTAssertTrue(batch[0].outputJSON.contains(ToolErrorCode.questionnaireRequired.rawValue), batch[0].outputJSON)
        XCTAssertTrue(batch[0].outputJSON.contains(ToolNames.askSupervisorForm), batch[0].outputJSON)
        XCTAssertNil(batch[0].signal, "a refused call must not park the step")
    }

    /// The plain ask alone: the same text parks, because the numbered list is that role's
    /// sanctioned fallback and a refusal naming a tool it lacks is the 2026-07-25 defect.
    func testExecuteToolCalls_plainAskAlone_parksOnTheSameText() async {
        let batch = await execute(allowed: [ToolNames.askSupervisor])

        XCTAssertEqual(batch.count, 1)
        XCTAssertFalse(batch[0].isError, batch[0].outputJSON)
        XCTAssertEqual(batch[0].signal, .supervisorQuestion(Self.questionnaire))
    }

    private func execute(allowed: Set<String>) async -> [ToolExecutionResult] {
        let stepID = "assistant_step"
        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "Assistant", status: .running)
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 7, title: "T", supervisorTask: "plan", runs: [run])
        return await service.executeToolCalls(
            resolvedToolCalls: [StepToolCall(name: ToolNames.askSupervisor, argumentsJSON: Self.questionnaireJSON)],
            gateRefusals: [],
            allowedToolNames: allowed,
            runtime: runtime,
            tracker: ToolCallTracker(),
            task: task,
            runIndex: 0,
            roleID: stepID
        )
    }
}
