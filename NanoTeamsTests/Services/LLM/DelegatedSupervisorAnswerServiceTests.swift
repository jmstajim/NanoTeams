import XCTest
@testable import NanoTeams

/// User-path tests for `DelegatedSupervisorAnswerService` — the seeded stateful chain
/// that routes a delegated child team's `ask_supervisor` calls back to the parent role.
///
/// Covers:
/// - First question seeds chain with `parentStep.llmConversation` (session=nil), captures session id
/// - Subsequent question reuses `parentStep.delegationSession` via `previous_response_id` (only new turn sent)
/// - Plain-text answer routes through `delegate.answerSupervisorQuestion` (which engages engine resume)
/// - Tool-call escalation when `parentTask.parentTaskID != nil` recurses on the grandparent
/// - Top-of-chain escalation: persists `ancillaryQuestion`, surfaces info banner, returns `false`
@MainActor
final class DelegatedSupervisorAnswerServiceTests: XCTestCase {

    // MARK: - Test Fixtures

    /// Multi-task delegate stub used by these tests. Real `MockLLMExecutionDelegate`
    /// in `LLMExecutionServiceTests.swift` only mirrors one task; delegation flow
    /// requires parent + child + (sometimes) grandparent.
    final class MultiTaskDelegateStub: LLMExecutionDelegate, @unchecked Sendable {
        var tasks: [Int: NTMSTask] = [:]
        var workFolderProjection: WorkFolderProjection?
        // Captures
        var answerSupervisorCalls: [(taskID: Int, stepID: String, answer: String)] = []
        var lastInfoMessages: [String] = []

        // Scripted return values — answerSupervisorQuestion success
        var answerSupervisorReturn: Bool = true

        // MARK: TaskMutationDelegate
        @discardableResult
        func mutateTask(taskID: Int, _ mutate: (inout NTMSTask) -> Void) async -> Bool {
            guard var task = tasks[taskID] else { return false }
            mutate(&task)
            tasks[taskID] = task
            return true
        }

        // MARK: LLMStateDelegate
        var workFolderURL: URL? { nil }
        var globalLLMConfig: LLMConfig {
            LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "test")
        }
        var globalLLMContext: String { "" }
        var maxLLMRetries: Int { 0 }
        var visionLLMConfig: LLMConfig? { nil }
        var snapshot: WorkFolderContext? {
            guard let projection = workFolderProjection else { return nil }
            return WorkFolderContext(
                projection: projection,
                tasksIndex: TasksIndex(),
                toolDefinitions: [],
                activeTaskID: nil,
                activeTask: nil,
                loadedTasks: tasks
            )
        }
        var loggingEnabled: Bool { false }
        func loadedTask(_ taskID: Int) -> NTMSTask? { tasks[taskID] }
        func consumeQueuedSupervisorMessage(taskID _: Int, roleID _: String, stepID _: String) async -> String? { nil }

        var exploratorySearchEnabled: Bool { false }
        var searchExploratoryByDefault: Bool { false }
        var readFileMaxLines: Int { 500 }
        var searchMaxResults: Int { 50 }
        var searchContextBefore: Int { 2 }
        var searchContextAfter: Int { 2 }
        var hasRealWorkFolder: Bool { false }
        func awaitSearchIndex() async -> SearchIndex? { nil }
        func expandSearchQuery(query _: String, tokens _: [String]) async -> VocabVectorIndexService.ExpansionResult {
            .expanded(terms: [])
        }
        func setLastInfoMessageForUI(_ message: String) { lastInfoMessages.append(message) }
        var lastErrorMessages: [String] = []
        func setLastErrorMessageForUI(_ message: String) { lastErrorMessages.append(message) }
        func notifyQueuedMessageBackstop(taskID _: Int) {}

        // Delegation hooks
        func awaitTaskTerminalState(taskID _: Int) async -> TaskCompletionAwaiter.WaitOutcome { .terminal(.failed) }
        func createDelegatedTask(parentTaskID _: Int, parentRoleID _: String, title _: String, supervisorTask _: String, preferredTeamID _: NTMSID?, depth _: Int) async -> Int? { nil }
        func startRunForTask(taskID _: Int) async {}
        func closeTask(taskID _: Int) async -> Bool { true }
        func lastErrorMessageForTask(_ taskID: Int) -> String? { nil }
        func streamLastActivityAt(stepID _: String, taskID _: Int) -> Date? { nil }
        func streamLiveText(stepID _: String, taskID _: Int) -> String? { nil }
        func stopEngineForTask(_ taskID: Int) {}
        func pauseRun(taskID _: Int) async {}
        func resumeRun(taskID _: Int) async {}
        func activeDelegationChildID(taskID _: Int, roleID _: String) -> Int? { nil }

        @discardableResult
        func answerSupervisorQuestion(taskID: Int, stepID: String, answer: String) async -> Bool {
            answerSupervisorCalls.append((taskID, stepID, answer))
            return answerSupervisorReturn
        }

        func performAutovisorAction(_ action: AutovisorAction) async -> AutovisorActionResult { .success("ok") }
        func persistAutovisorMemory(_ text: String) async -> Bool { true }
        func autovisorLoadTask(_ taskID: Int) async -> NTMSTask? { loadedTask(taskID) }

        // MARK: LLMStreamingDelegate (no-op stubs)
        func beginStreaming(stepID _: String, taskID _: Int, messageID _: UUID, role _: Role) async {}
        func appendStreamingPreview(stepID _: String, taskID _: Int, messageID _: UUID, role _: Role, content _: String) {}
        func replaceStreamingPreview(stepID _: String, taskID _: Int, messageID _: UUID, role _: Role, content _: String) {}
        func appendStreamingThinking(stepID _: String, taskID _: Int, content _: String) {}
        func commitStreaming(stepID _: String, taskID _: Int, content _: String, thinking _: String?) async {}
        func discardStreaming(stepID _: String, messageID _: UUID, taskID _: Int) async {}
        func noteStreamLoop(taskID _: Int, stepID _: String, signal _: LoopSignal) -> Bool { true }
        func clearStreamingPreview(stepID _: String, taskID _: Int) {}
        func updateStreamingProcessingProgress(stepID _: String, taskID _: Int, progress _: Double) {}
        func clearStreamingProcessingProgress(stepID _: String, taskID _: Int) {}
        func markStreamActivity(stepID _: String, taskID _: Int) {}
        func markStreamingToolCall(stepID _: String, taskID _: Int) {}

        // MARK: LLMMeetingDelegate (no-op stubs)
        func setActiveMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int) {}
        func clearActiveMeetingParticipants(for taskID: Int) {}
    }

    /// Scripted LLM client. Captures every streamChat invocation; returns scripted
    /// content + (optional) tool call + session id from the next entry of `script`.
    final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
        struct ScriptedTurn {
            var content: String = ""
            var toolCalls: [(name: String, argumentsJSON: String)] = []
            var responseID: String? = nil
        }
        var script: [ScriptedTurn] = []
        var captures: [(messages: [ChatMessage], tools: [ToolSchema], session: LLMSession?)] = []

        func streamChat(
            config _: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            session: LLMSession?,
            logger _: NetworkLogger?,
            stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            captures.append((messages, tools, session))
            let turn = script.isEmpty ? ScriptedTurn() : script.removeFirst()
            return AsyncThrowingStream { continuation in
                if !turn.content.isEmpty {
                    continuation.yield(StreamEvent(contentDelta: turn.content))
                }
                for (i, call) in turn.toolCalls.enumerated() {
                    let delta = StreamEvent.ToolCallDelta(
                        index: i,
                        id: "call-\(i)",
                        name: call.name,
                        argumentsDelta: call.argumentsJSON
                    )
                    continuation.yield(StreamEvent(toolCallDeltas: [delta]))
                }
                if let rid = turn.responseID {
                    continuation.yield(StreamEvent(session: LLMSession(responseID: rid)))
                }
                continuation.finish()
            }
        }

        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }

    // MARK: - Helpers

    private func makeParentTeam() -> Team {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true, systemRoleID: "supervisor"
        )
        let pm = TeamRoleDefinition(
            id: "pm", name: "PM", prompt: "Product Manager",
            toolIDs: [ToolNames.delegateToTeam],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        var settings = TeamSettings()
        settings.hierarchy.reportsTo = ["pm": "sup"]
        return Team(
            id: "parent-team", name: "Parent Team",
            roles: [supervisor, pm],
            artifacts: [], settings: settings, graphLayout: TeamGraphLayout()
        )
    }

    private func makeProjection(teams: [Team] = []) -> WorkFolderProjection {
        WorkFolderProjection(
            state: WorkFolderState(name: "WF", activeTeamID: teams.first?.id),
            settings: ProjectSettings(),
            teams: teams
        )
    }

    /// Parent task with PM step containing seed conversation.
    private func makeParentTask(
        id: Int = 1,
        seedConversation: [LLMMessage] = [],
        parentTaskID: Int? = nil,
        parentRoleID: String? = nil
    ) -> NTMSTask {
        var step = StepExecution(id: "pm", role: .productManager, title: "PM Step")
        step.status = .running
        step.llmConversation = seedConversation
        var run = Run(id: 0, steps: [step])
        run.roleStatuses = ["pm": .working]
        let task = NTMSTask(
            id: id, title: "Parent Task", supervisorTask: "Build a calculator",
            runs: [run],
            preferredTeamID: "parent-team",
            parentTaskID: parentTaskID,
            parentRoleID: parentRoleID,
            delegationDepth: parentTaskID == nil ? 0 : 1
        )
        return task
    }

    /// Child task with a step in `.needsSupervisorInput` carrying a question.
    private func makeChildTask(question: String, askingStepID: String = "engineer", parentTaskID: Int = 1, parentRoleID: String = "pm") -> NTMSTask {
        var step = StepExecution(id: askingStepID, role: .softwareEngineer, title: "Engineer Step")
        step.status = .needsSupervisorInput
        step.needsSupervisorInput = true
        step.supervisorQuestion = question
        var run = Run(id: 0, steps: [step])
        run.roleStatuses = [askingStepID: .working]
        return NTMSTask(
            id: 2, title: "Child Task", supervisorTask: "Implement feature",
            runs: [run],
            parentTaskID: parentTaskID,
            parentRoleID: parentRoleID,
            delegationDepth: 1
        )
    }

    // MARK: - First Question: Seeded Chain

    func testFirstQuestion_seedsChainWithFullParentConversation() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        let seed: [LLMMessage] = [
            LLMMessage(role: .system, content: "You are PM."),
            LLMMessage(role: .user, content: "Build a calculator"),
            LLMMessage(role: .assistant, content: "Plan: ..."),
        ]
        delegate.tasks[1] = makeParentTask(seedConversation: seed)
        delegate.tasks[2] = makeChildTask(question: "Should the calculator support negative numbers?")

        let client = ScriptedLLMClient()
        client.script = [
            .init(content: "Yes, negative numbers are required.", toolCalls: [], responseID: "resp-1"),
        ]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2,
            parentTaskID: 1,
            parentRoleID: "pm",
            parentTeam: parentTeam,
            targetTeamName: "Engineering",
            client: client,
            globalConfig: delegate.globalLLMConfig,
            delegate: delegate
        )

        XCTAssertTrue(success, "Plain-text answer path should succeed")
        XCTAssertEqual(client.captures.count, 1, "One streamChat call expected for first question")
        let capture = client.captures[0]
        XCTAssertNil(capture.session, "First question must seed with session=nil (fresh chain)")
        // Seed = system + user + assistant + new user(question prefix). 4 messages total.
        XCTAssertEqual(capture.messages.count, seed.count + 1)
        XCTAssertEqual(capture.messages.first?.role, .system)
        XCTAssertTrue(capture.messages.last?.content?.contains("Should the calculator support negative numbers?") ?? false,
                      "Last message must contain the child's question")

        // Capture session id persists to parent step.delegationSession
        let parentTaskAfter = delegate.tasks[1]!
        let parentStep = parentTaskAfter.runs[0].steps[0]
        XCTAssertEqual(parentStep.delegationSession, "resp-1")

        // Q&A persisted to parent step's conversation
        XCTAssertEqual(parentStep.llmConversation.count, seed.count + 2)
        XCTAssertEqual(parentStep.llmConversation[seed.count].sourceContext, .delegatedQuestion)
        XCTAssertEqual(parentStep.llmConversation[seed.count].role, .user)
        XCTAssertEqual(parentStep.llmConversation[seed.count + 1].role, .assistant)

        // Child step received the answer via answerSupervisorQuestion (which resumes engine)
        XCTAssertEqual(delegate.answerSupervisorCalls.count, 1)
        XCTAssertEqual(delegate.answerSupervisorCalls[0].taskID, 2)
        XCTAssertEqual(delegate.answerSupervisorCalls[0].stepID, "engineer")
        XCTAssertEqual(delegate.answerSupervisorCalls[0].answer, "Yes, negative numbers are required.")
    }

    // MARK: - Subsequent Question: Stateful Continuation

    func testSubsequentQuestion_reusesDelegationSession_sendsOnlyNewTurn() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        var parentTask = makeParentTask(seedConversation: [LLMMessage(role: .system, content: "PM")])
        // Pre-seed delegationSession to simulate prior question in the same delegation
        parentTask.runs[0].steps[0].setDelegationSession("resp-prev")
        delegate.tasks[1] = parentTask
        delegate.tasks[2] = makeChildTask(question: "What about division by zero?")

        let client = ScriptedLLMClient()
        client.script = [
            .init(content: "Throw a DivisionByZeroError.", toolCalls: [], responseID: "resp-2"),
        ]

        _ = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2,
            parentTaskID: 1,
            parentRoleID: "pm",
            parentTeam: parentTeam,
            targetTeamName: "Engineering",
            client: client,
            globalConfig: delegate.globalLLMConfig,
            delegate: delegate
        )

        XCTAssertEqual(client.captures.count, 1)
        let capture = client.captures[0]
        XCTAssertEqual(capture.session?.responseID, "resp-prev",
                       "Subsequent question must reuse parent.delegationSession via previous_response_id")
        XCTAssertEqual(capture.messages.count, 1, "Only the new question turn — no full history rebuild")
        XCTAssertTrue(capture.messages.first?.content?.contains("What about division by zero?") ?? false)

        // Updated session captured on parent step
        XCTAssertEqual(delegate.tasks[1]!.runs[0].steps[0].delegationSession, "resp-2")
    }

    // MARK: - Mid-chain Escalation: Recursion to Grandparent

    func testEscalation_midChain_recursesOnGrandparent() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        // Three-level chain: grandparent task 0, parent task 1 (child of 0), child task 2 (child of 1).
        delegate.tasks[0] = makeParentTask(
            id: 0,
            seedConversation: [LLMMessage(role: .system, content: "Top PM")]
        )
        delegate.tasks[1] = makeParentTask(id: 1, parentTaskID: 0, parentRoleID: "pm")
        delegate.tasks[2] = makeChildTask(question: "Need clarification", parentTaskID: 1, parentRoleID: "pm")

        let client = ScriptedLLMClient()
        client.script = [
            // Parent escalates via ask_supervisor tool call
            .init(
                content: "",
                toolCalls: [(name: ToolNames.askSupervisor, argumentsJSON: "{\"question\": \"Need clarification (escalated)\"}")],
                responseID: "resp-parent"
            ),
            // Grandparent answers in plain text
            .init(content: "Use the standard approach.", toolCalls: [], responseID: "resp-gp"),
        ]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2,
            parentTaskID: 1,
            parentRoleID: "pm",
            parentTeam: parentTeam,
            targetTeamName: "Engineering",
            client: client,
            globalConfig: delegate.globalLLMConfig,
            delegate: delegate
        )

        XCTAssertTrue(success, "Recursion should bubble to grandparent and resolve there")
        XCTAssertEqual(client.captures.count, 2, "Two streamChat calls: parent escalation + grandparent answer")

        // Final answer routes to child via answerSupervisorQuestion
        XCTAssertEqual(delegate.answerSupervisorCalls.count, 1)
        XCTAssertEqual(delegate.answerSupervisorCalls[0].taskID, 2)
        XCTAssertEqual(delegate.answerSupervisorCalls[0].answer, "Use the standard approach.")

        // Parent step: question tagged `.delegationEscalation` because parent's response
        // was an ask_supervisor tool call (escalating up).
        let parentConv = delegate.tasks[1]!.runs[0].steps[0].llmConversation
        XCTAssertTrue(parentConv.contains { $0.sourceContext == .delegationEscalation },
                      "Parent step should record the question as an escalation since the parent escalated.")

        // Grandparent step: question tagged `.delegatedQuestion` because grandparent's
        // response was plain text (the chain bottoms here).
        let gpConv = delegate.tasks[0]!.runs[0].steps[0].llmConversation
        XCTAssertTrue(gpConv.contains { $0.sourceContext == .delegatedQuestion },
                      "Grandparent step should record the question as a delegated question since GP answered plainly.")

        // Each step's delegationSession was updated with its respective response id.
        XCTAssertEqual(delegate.tasks[1]!.runs[0].steps[0].delegationSession, "resp-parent")
        XCTAssertEqual(delegate.tasks[0]!.runs[0].steps[0].delegationSession, "resp-gp")
    }

    // MARK: - Top-of-chain Escalation: Aborts with Banner

    func testEscalation_topOfChain_abortsWithInfoBanner() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        // Top-level parent task — parentTaskID == nil
        delegate.tasks[1] = makeParentTask(seedConversation: [LLMMessage(role: .system, content: "PM")])
        delegate.tasks[2] = makeChildTask(question: "Cannot answer this from PM context")

        let client = ScriptedLLMClient()
        client.script = [
            .init(
                content: "",
                toolCalls: [(name: ToolNames.askSupervisor, argumentsJSON: "{\"question\": \"Need exec input\"}")],
                responseID: "resp-1"
            ),
        ]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2,
            parentTaskID: 1,
            parentRoleID: "pm",
            parentTeam: parentTeam,
            targetTeamName: "Engineering",
            client: client,
            globalConfig: delegate.globalLLMConfig,
            delegate: delegate
        )

        XCTAssertFalse(success, "Top-of-chain escalation aborts the delegation in V1")
        XCTAssertEqual(delegate.answerSupervisorCalls.count, 0, "No answer routed to child")
        XCTAssertFalse(delegate.lastInfoMessages.isEmpty, "User should see a banner explaining the abort")

        // Ancillary question persisted on parent step for diagnostics
        let parentStep = delegate.tasks[1]!.runs[0].steps[0]
        XCTAssertNotNil(parentStep.ancillaryQuestion)
        XCTAssertEqual(parentStep.ancillaryQuestion, "Need exec input")
    }

    // MARK: - Defensive Edge Cases

    func testNoChildQuestion_returnsFalse() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        delegate.tasks[1] = makeParentTask()
        // Child without a pending supervisor question — defensive guard
        var child = makeChildTask(question: "")
        child.runs[0].steps[0].needsSupervisorInput = false
        child.runs[0].steps[0].supervisorQuestion = nil
        delegate.tasks[2] = child

        let client = ScriptedLLMClient()
        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2,
            parentTaskID: 1,
            parentRoleID: "pm",
            parentTeam: parentTeam,
            targetTeamName: "Engineering",
            client: client,
            globalConfig: delegate.globalLLMConfig,
            delegate: delegate
        )
        XCTAssertFalse(success)
        XCTAssertEqual(client.captures.count, 0, "No streamChat invocation when child has no pending question")
    }

    func testParentNotFound_returnsFalse() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        // Only child registered — parent is missing (e.g., race after parent removal)
        delegate.tasks[2] = makeChildTask(question: "Q?")

        let client = ScriptedLLMClient()
        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2,
            parentTaskID: 1,
            parentRoleID: "pm",
            parentTeam: parentTeam,
            targetTeamName: "Engineering",
            client: client,
            globalConfig: delegate.globalLLMConfig,
            delegate: delegate
        )
        XCTAssertFalse(success)
        XCTAssertEqual(client.captures.count, 0)
    }
}
