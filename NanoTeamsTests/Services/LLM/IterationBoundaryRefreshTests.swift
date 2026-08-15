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

    override func setUp() async throws {
        try await super.setUp()
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

    override func tearDown() async throws {
        mockDelegate = nil
        service = nil
        task = nil
        stepID = nil
        try await super.tearDown()
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

    /// Composed scenario: a planning-phase iteration answers with PROSE instead
    /// of calling `update_scratchpad` → `handleNoToolCalls` persists the prose as
    /// the plan through the delegate → fresh snapshot via `refreshedTaskSnapshot`
    /// → `applyPlanningPhase` crosses the boundary (full authorization, wire
    /// rebuilt from the seed).
    ///
    /// If a future change removes the `refreshedTaskSnapshot` call in
    /// `runOneLLMToolIteration`, `applyPlanningPhase` sees the stale step
    /// (scratchpad still nil), stays in planning, and this test fails — which is
    /// the Run-8 regression it was written for.
    func testBoundaryCrossedAfterProseResponse_onFreshSnapshot() async {
        let role = TeamRoleDefinition(
            id: "swe", name: "Software Engineer", prompt: "", toolIDs: [],
            usePlanningPhase: true,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Engineering Notes"])
        )
        let systemPrompt = "You are Software Engineer."
        let fullTools: [ToolSchema] = [
            ToolSchema(name: ToolNames.updateScratchpad, description: "Scratchpad", parameters: .object(properties: [:])),
            ToolSchema(name: ToolNames.search, description: "Search", parameters: .object(properties: [:])),
            ToolSchema(name: ToolNames.writeFile, description: "Write", parameters: .object(properties: [:])),
            ToolSchema(name: ToolNames.createArtifact, description: "Artifact", parameters: .object(properties: [:])),
        ]

        // A wire mid-planning: the brief is a trailing user turn, the system
        // message is untouched.
        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: "Build"),
            ChatMessage(role: .user, content: PlanningPhasePolicy.planningBrief(
                exploreToolNames: [ToolNames.search], expectedArtifacts: ["Engineering Notes"])),
            ChatMessage(role: .assistant, content: "Below is a complete implementation…"),
        ]

        // handleNoToolCalls writes the scratchpad via the delegate.
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

        let authorization = await service.applyPlanningPhase(
            stepID: stepID,
            taskID: task.id,
            tools: fullTools,
            step: refreshedStep,
            team: nil,
            conversationMessages: &conversation,
            roleDefinition: role
        )

        XCTAssertEqual(authorization.allowed.count, 4,
                       "Everything must be authorized once the plan is recorded")
        XCTAssertTrue(authorization.withheldByPhase.isEmpty)
        XCTAssertEqual(conversation.first(where: { $0.role == .system })?.content, systemPrompt,
                       "The system message is never touched — that is the whole point")
        XCTAssertFalse(PlanningPhasePolicy.wireCarriesBrief(conversation),
                       "The boundary removes the brief, which is what makes it fire once")
        XCTAssertTrue(conversation.last?.content?.contains(PlanningPhasePolicy.seedMarker) ?? false,
                      "The implementation phase opens on the seeded plan")
    }
}
