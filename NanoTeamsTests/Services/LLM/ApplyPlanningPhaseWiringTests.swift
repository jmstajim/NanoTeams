import XCTest

@testable import NanoTeams

/// Integration wiring for `PlanningPhasePolicy` inside `LLMExecutionService.applyPlanningPhase`.
/// `PlanningPhasePolicyTests` pins the pure decisions in isolation; this proves they are wired
/// into the @MainActor orchestration correctly — the ENTRY branch (first iteration → planning
/// prompt swapped in + tools narrowed to `update_scratchpad` + original prompt stashed) and the
/// two no-enter gates. The restore branch is already covered by `IterationBoundaryRefreshTests`.
@MainActor
final class ApplyPlanningPhaseWiringTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    private let fullTools: [ToolSchema] = [
        ToolSchema(name: ToolNames.updateScratchpad, description: "Scratchpad", parameters: .object(properties: [:])),
        ToolSchema(name: ToolNames.search, description: "Search", parameters: .object(properties: [:])),
        ToolSchema(name: ToolNames.writeFile, description: "Write", parameters: .object(properties: [:])),
        ToolSchema(name: ToolNames.createArtifact, description: "Artifact", parameters: .object(properties: [:])),
    ]
    private let originalPrompt = "You are Software Engineer."

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Notes", status: .running)
        stepID = step.id
        task = NTMSTask(id: 0, title: "Test", supervisorTask: "goal", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() {
        mockDelegate = nil; service = nil; task = nil; stepID = nil
        super.tearDown()
    }

    private func role(usePlanning: Bool) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "test_step", name: "Software Engineer", prompt: "", toolIDs: [],
            usePlanningPhase: usePlanning,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Engineering Notes"]))
    }

    private func firstIterationStep() -> StepExecution {
        // scratchpad nil + revisionComment nil + empty llmConversation ⇒ first iteration.
        StepExecution(id: "test_step", role: .softwareEngineer, title: "Notes", status: .running)
    }

    private func systemContent(_ conversation: [ChatMessage]) -> String {
        conversation.first(where: { $0.role == .system })?.content ?? ""
    }

    // MARK: - ENTRY

    func testEntry_swapsToPlanningPrompt_narrowsTools_stashesOriginal() async {
        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: originalPrompt),
            ChatMessage(role: .user, content: "Build a thing"),
        ]
        let (tools, resetSession) = await service.applyPlanningPhase(
            stepID: stepID, taskID: task.id, roleForMessage: .softwareEngineer,
            tools: fullTools, step: firstIterationStep(), tracker: ToolCallTracker(),
            conversationMessages: &conversation, roleDefinition: role(usePlanning: true))

        XCTAssertEqual(tools.map(\.name), [ToolNames.updateScratchpad],
                       "Planning narrows the toolset to update_scratchpad only")
        XCTAssertFalse(resetSession, "Entering planning does not reset the session")
        XCTAssertTrue(PlanningPhasePolicy.isPlanningSystemPrompt(systemContent(conversation)),
                      "System message swapped to the planning prompt")
        XCTAssertTrue(systemContent(conversation).contains("Software Engineer"),
                      "Planning prompt carries the role name")
        XCTAssertEqual(service._testGetOriginalSystemPrompt(stepID: stepID, taskID: task.id), originalPrompt,
                       "Original prompt stashed for the restore branch")
    }

    // MARK: - No-enter gates

    func testNoEntry_whenScratchpadToolAbsent() async {
        let toolsWithoutScratchpad = fullTools.filter { $0.name != ToolNames.updateScratchpad }
        var conversation: [ChatMessage] = [ChatMessage(role: .system, content: originalPrompt)]
        let (tools, resetSession) = await service.applyPlanningPhase(
            stepID: stepID, taskID: task.id, roleForMessage: .softwareEngineer,
            tools: toolsWithoutScratchpad, step: firstIterationStep(), tracker: ToolCallTracker(),
            conversationMessages: &conversation, roleDefinition: role(usePlanning: true))

        XCTAssertEqual(tools.map(\.name), toolsWithoutScratchpad.map(\.name), "Toolset unchanged")
        XCTAssertFalse(resetSession)
        XCTAssertEqual(systemContent(conversation), originalPrompt, "System prompt not swapped")
        XCTAssertNil(service._testGetOriginalSystemPrompt(stepID: stepID, taskID: task.id))
    }

    func testNoEntry_whenRoleOptedOut() async {
        var conversation: [ChatMessage] = [ChatMessage(role: .system, content: originalPrompt)]
        let (tools, _) = await service.applyPlanningPhase(
            stepID: stepID, taskID: task.id, roleForMessage: .softwareEngineer,
            tools: fullTools, step: firstIterationStep(), tracker: ToolCallTracker(),
            conversationMessages: &conversation, roleDefinition: role(usePlanning: false))

        XCTAssertEqual(tools.count, fullTools.count, "usePlanningPhase=false ⇒ full toolset")
        XCTAssertEqual(systemContent(conversation), originalPrompt, "No swap")
    }

    func testNoEntry_underRevision() async {
        // revisionComment set ⇒ never first iteration, even with a nil scratchpad.
        let revisionStep = StepExecution(
            id: "test_step", role: .softwareEngineer, title: "Notes", status: .running,
            revisionComment: "address feedback")
        var conversation: [ChatMessage] = [ChatMessage(role: .system, content: originalPrompt)]
        let (tools, _) = await service.applyPlanningPhase(
            stepID: stepID, taskID: task.id, roleForMessage: .softwareEngineer,
            tools: fullTools, step: revisionStep, tracker: ToolCallTracker(),
            conversationMessages: &conversation, roleDefinition: role(usePlanning: true))

        XCTAssertEqual(tools.count, fullTools.count, "A revision is not first-iteration work — no planning")
        XCTAssertEqual(systemContent(conversation), originalPrompt, "No swap")
    }
}
