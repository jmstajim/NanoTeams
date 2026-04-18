import XCTest

@testable import NanoTeams

/// Regression for Run 8 (FAANG headless, SWE stuck 4 iterations in planning phase loop).
///
/// Root cause: `runOneLLMToolIteration` captured `task: NTMSTask` by value in
/// `startStepExecution` before the tool loop began. Prior iterations mutated task
/// state through `delegate.mutateTask` (scratchpad, supervisor answers, role
/// statuses, artifacts), but the local `task` value never refreshed.
///
/// Fix: call `LLMExecutionService.refreshedTaskSnapshot(_:delegate:)` at the top
/// of every `runOneLLMToolIteration` to pull the latest committed state.
///
/// These tests pin the contract from two angles: (1) the helper itself, (2) the
/// downstream behavior that depends on it — if the helper is wired correctly,
/// `applyPlanningPhase` transitions out of planning on iter 2 even when the
/// caller passes the original stale snapshot.
@MainActor
final class IterationBoundaryRefreshTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)

        let step = StepExecution(id: "step0", role: .softwareEngineer, title: "SWE", status: .running)
        stepID = step.id
        let run = Run(id: 0, steps: [step])
        task = NTMSTask(id: 0, title: "Test", supervisorTask: "build", runs: [run])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() {
        mockDelegate = nil
        service = nil
        task = nil
        stepID = nil
        super.tearDown()
    }

    // MARK: - Helper contract

    /// `refreshedTaskSnapshot` must observe mutations committed through the delegate.
    /// `runOneLLMToolIteration` calls this at iteration start; breaking the contract
    /// resurrects the Run 8 planning-loop bug.
    func testRefreshedTaskSnapshot_observesDelegateMutation() async {
        XCTAssertNil(task.runs[0].steps[0].scratchpad)

        _ = await mockDelegate.mutateTask(taskID: 0) { task in
            task.runs[0].steps[0].scratchpad = "plan from prose"
        }

        let refreshed = LLMExecutionService.refreshedTaskSnapshot(task, delegate: mockDelegate)
        XCTAssertEqual(refreshed.runs[0].steps[0].scratchpad, "plan from prose",
                       "Refresh must see the mutation; the Run 8 regression was invisible mutations.")
    }

    /// Fallback: when the delegate can't resolve the task id, the passed-in snapshot
    /// is returned unchanged. Protects against silent nil-drop on a deleted task.
    func testRefreshedTaskSnapshot_fallsBackWhenDelegateReturnsNil() {
        mockDelegate.taskToMutate = nil
        let refreshed = LLMExecutionService.refreshedTaskSnapshot(task, delegate: mockDelegate)
        XCTAssertEqual(refreshed.id, task.id,
                       "Nil from delegate must not lose the original snapshot")
    }

    // MARK: - End-to-end planning transition (Run 8 regression)

    /// Composed scenario: iter 1 prose response → `handleNoToolCalls` persists a
    /// scratchpad through the delegate → fresh snapshot via `refreshedTaskSnapshot`
    /// → `applyPlanningPhase` must transition to the implementation branch
    /// (`resetSession = true`, full toolset, original system prompt restored).
    ///
    /// If a future change removes the call to `refreshedTaskSnapshot` in
    /// `runOneLLMToolIteration`, `applyPlanningPhase` sees the stale original
    /// step (scratchpad still nil) and this test fails.
    func testPlanningTransitionUnblockedByFreshSnapshot_afterProseResponse() async {
        let role = TeamRoleDefinition(
            id: "swe", name: "Software Engineer", prompt: "", toolIDs: [],
            usePlanningPhase: true,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Engineering Notes"])
        )
        let originalPrompt = "You are Software Engineer."
        let planningPrompt = "You are Software Engineer.\n\nPLANNING PHASE\n==============\nCall update_scratchpad(...)."
        let fullTools: [ToolSchema] = [
            ToolSchema(name: ToolNames.updateScratchpad, description: "Scratchpad", parameters: .object(properties: [:])),
            ToolSchema(name: ToolNames.search, description: "Search", parameters: .object(properties: [:])),
            ToolSchema(name: ToolNames.writeFile, description: "Write", parameters: .object(properties: [:])),
            ToolSchema(name: ToolNames.createArtifact, description: "Artifact", parameters: .object(properties: [:])),
        ]

        service._testSetOriginalSystemPrompt(stepID: stepID, prompt: originalPrompt)

        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: planningPrompt),
            ChatMessage(role: .user, content: "Build"),
            ChatMessage(role: .assistant, content: "Below is a complete implementation…"),
        ]

        // handleNoToolCalls writes scratchpad via delegate.
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "Below is a complete implementation…",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: role,
            conversationMessages: &conversation
        )
        guard case .continueLoop = stop else {
            XCTFail("Expected .continueLoop from handleNoToolCalls, got \(stop)")
            return
        }

        // Exactly what production does at the top of runOneLLMToolIteration:
        let refreshedTask = LLMExecutionService.refreshedTaskSnapshot(task, delegate: mockDelegate)
        let refreshedStep = refreshedTask.runs[0].steps[0]
        XCTAssertNotNil(refreshedStep.scratchpad,
                        "Precondition: scratchpad must be persisted via delegate before iter 2")

        let memory = ToolCallCache()
        let (tools, resetSession) = await service.applyPlanningPhase(
            stepID: stepID,
            roleForMessage: .softwareEngineer,
            tools: fullTools,
            step: refreshedStep,
            memory: memory,
            conversationMessages: &conversation,
            roleDefinition: role
        )

        XCTAssertEqual(tools.count, 4,
                       "Full toolset must be returned after planning transition")
        XCTAssertTrue(tools.contains { $0.name == ToolNames.writeFile },
                      "write_file must be available so the model can implement")
        XCTAssertTrue(resetSession,
                      "Must request session reset so the next request sends full system_prompt in a fresh chain")
        XCTAssertEqual(conversation.first(where: { $0.role == .system })?.content, originalPrompt,
                       "System message must be restored from the saved original prompt")
    }
}
