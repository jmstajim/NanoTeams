import XCTest
@testable import NanoTeams

/// User-path tests for `DelegatedSupervisorAnswerService` — the side exchange that
/// routes a delegated child team's `ask_supervisor` calls back to the parent role.
///
/// Covers:
/// - Every question seeds from `parentStep.llmConversation` + the new question turn
/// - A SECOND question in the same delegation re-seeds and sees the first Q&A, because
///   `persistExchange` appended it to the very conversation the seed is built from
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
        var bashPolicy: BashPolicy { BashPolicy() }
        var computerUsePolicy: ComputerUsePolicy { ComputerUsePolicy() }
        func bashApprovalDidBegin(_ request: BashApprovalRequest) {}
        func bashApprovalDidEnd(taskID: Int, stepID: String, commandKey: String, createdAt: Date) {}
        func clearAllBashApprovalRequests() {}
        func computerUseApprovalDidBegin(_ request: ComputerUseApprovalRequest) {}
        func computerUseApprovalDidEnd(taskID: Int, stepID: String, actionKey: String, createdAt: Date) {}
        func clearAllComputerUseApprovalRequests() {}
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
        var agentInstructions: AgentInstructionsSnapshot? { nil }
        var roleSkills: RoleSkillsSnapshot? { nil }
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
        func holdDownstreamForRevision(taskID _: Int, runningRoleIDs _: [String], requesterRoleID _: String) async {}
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
        func updateStreamingProcessingStatus(stepID _: String, taskID _: Int, status _: PromptProcessingStatus) {}
        func clearStreamingProcessingStatus(stepID _: String, taskID _: Int) {}
        func markStreamActivity(stepID _: String, taskID _: Int) {}
        func markStreamingToolCall(stepID _: String, taskID _: Int) {}

        // MARK: LLMMeetingDelegate (no-op stubs)
        func setActiveMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int) {}
        func clearActiveMeetingParticipants(for taskID: Int) {}
    }

    /// Scripted LLM client. Captures every streamChat invocation; returns scripted
    /// content + (optional) tool call from the next entry of `script`.
    final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
        struct ScriptedTurn {
            var content: String = ""
            /// Reasoning channel. A reasoning model puts the whole reply here — escalation
            /// envelope included — and leaves `content` empty.
            var reasoning: String = ""
            var toolCalls: [(name: String, argumentsJSON: String)] = []
        }
        var script: [ScriptedTurn] = []
        var captures: [(messages: [ChatMessage], tools: [ToolSchema])] = []
        /// Thrown instead of streaming. Lets a test distinguish a user Pause from a
        /// transport failure, which the service must NOT conflate.
        var shouldThrow: Error?

        func streamChat(
            config _: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            logger _: NetworkLogger?,
            stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            captures.append((messages, tools))
            if let shouldThrow {
                return AsyncThrowingStream { $0.finish(throwing: shouldThrow) }
            }
            let turn = script.isEmpty ? ScriptedTurn() : script.removeFirst()
            return AsyncThrowingStream { continuation in
                if !turn.reasoning.isEmpty {
                    continuation.yield(StreamEvent(thinkingDelta: turn.reasoning))
                }
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
                continuation.finish()
            }
        }

        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
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
            .init(content: "Yes, negative numbers are required.", toolCalls: []),
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
        // Seed = system + user + assistant + new user(question prefix). 4 messages total.
        XCTAssertEqual(capture.messages.count, seed.count + 1)
        XCTAssertEqual(capture.messages.first?.role, .system)
        XCTAssertTrue(capture.messages.last?.content?.contains("Should the calculator support negative numbers?") ?? false,
                      "Last message must contain the child's question")

        let parentTaskAfter = delegate.tasks[1]!
        let parentStep = parentTaskAfter.runs[0].steps[0]

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

    // MARK: - Subsequent Question: Re-seeds And Carries The Prior Q&A

    /// The second question in a delegation must SEE the first one. There is no
    /// server-side chain any more, so the guarantee comes from `persistExchange`
    /// appending each (question, answer) pair to the very `llmConversation` the
    /// seed is rebuilt from.
    // MARK: - The reasoning channel

    /// RED: drop the `ModelReplyChannels` promotion after the stream loop → the child is
    /// answered with the literal string "(no answer provided)".
    ///
    /// This is the worst blast radius in the one-shot cluster: the value is delivered to a
    /// whole CHILD TEAM as the Supervisor's decision, and its blocked role acts on it. The
    /// parent's model had answered — in the channel nobody read.
    func testReasoningOnlyAnswer_reachesTheChild() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        delegate.tasks[1] = makeParentTask(seedConversation: [
            LLMMessage(role: .system, content: "You are PM."),
        ])
        delegate.tasks[2] = makeChildTask(question: "Negative numbers?")

        let client = ScriptedLLMClient()
        client.script = [.init(content: "", reasoning: "Yes, negative numbers are required.")]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm", parentTeam: parentTeam,
            targetTeamName: "Engineering", client: client,
            globalConfig: delegate.globalLLMConfig, delegate: delegate)

        XCTAssertTrue(success)
        XCTAssertEqual(delegate.answerSupervisorCalls.count, 1)
        XCTAssertEqual(
            delegate.answerSupervisorCalls.first?.answer, "Yes, negative numbers are required.")
    }

    /// RED: same mutation → the Harmony salvage's `content.contains("<|")` gate never fires,
    /// so the escalation is invisible and the raw envelope is delivered to the child as the
    /// Supervisor's answer.
    ///
    /// The salvage exists precisely because gpt-oss-class local models emit tool calls as
    /// text envelopes — and those are exactly the models that put the text on the reasoning
    /// channel, so the fallback was blind in the case it was written for.
    func testEscalationEnvelopeInTheReasoningChannel_isSalvaged() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        delegate.tasks[1] = makeParentTask(seedConversation: [
            LLMMessage(role: .system, content: "PM"),
        ])
        delegate.tasks[2] = makeChildTask(question: "Cannot answer this from PM context")

        let client = ScriptedLLMClient()
        client.script = [
            .init(
                content: "",
                reasoning: "<|channel|>commentary to=functions.ask_supervisor<|message|>"
                    + "{\"question\": \"Need exec input\"}<|call|>")
        ]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm", parentTeam: parentTeam,
            targetTeamName: "Engineering", client: client,
            globalConfig: delegate.globalLLMConfig, delegate: delegate)

        XCTAssertFalse(success, "an escalation aborts the delegation, it is not an answer")
        XCTAssertEqual(
            delegate.answerSupervisorCalls.count, 0,
            "the raw envelope must never reach the child as the Supervisor's answer")
        XCTAssertEqual(
            delegate.tasks[1]?.runs[0].steps[0].ancillaryQuestion, "Need exec input")
    }

    /// Content still wins when both channels speak.
    func testContentWins_whenBothChannelsSpeak() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        delegate.tasks[1] = makeParentTask(seedConversation: [
            LLMMessage(role: .system, content: "You are PM."),
        ])
        delegate.tasks[2] = makeChildTask(question: "Negative numbers?")

        let client = ScriptedLLMClient()
        client.script = [.init(content: "Yes.", reasoning: "hmm, maybe no")]

        _ = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm", parentTeam: parentTeam,
            targetTeamName: "Engineering", client: client,
            globalConfig: delegate.globalLLMConfig, delegate: delegate)

        XCTAssertEqual(delegate.answerSupervisorCalls.first?.answer, "Yes.")
    }

    // MARK: - Cancellation is not an answering failure

    /// RED: drop the `CancellationClassifier` arm from the catch → a red banner blaming the
    /// role appears on a user-initiated Pause.
    ///
    /// `handleDelegateToTeam` reads a `false` return as an internal failure and tears the
    /// child team down, so classifying the user's own Pause as one destroys the delegation
    /// they paused to inspect. The parent step is being cancelled anyway; the child must
    /// survive for the resume.
    func testCancellation_raisesNoBannerBlamingTheRole() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.tasks[1] = makeParentTask(seedConversation: [
            LLMMessage(role: .system, content: "You are the PM."),
        ])
        delegate.tasks[2] = makeChildTask(question: "Negative numbers?")

        let client = ScriptedLLMClient()
        client.shouldThrow = CancellationError()

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm", parentTeam: parentTeam,
            targetTeamName: "Engineering", client: client,
            globalConfig: delegate.globalLLMConfig, delegate: delegate)

        XCTAssertFalse(success, "a cancelled exchange still produced no answer")
        XCTAssertTrue(
            delegate.lastErrorMessages.isEmpty,
            "a Pause must not post an error banner; got \(delegate.lastErrorMessages)")
    }

    /// The other half, so the fix cannot become "never report anything": a genuine
    /// transport failure still names the role and the reason.
    func testTransportFailure_stillReportsTheReason() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.tasks[1] = makeParentTask(seedConversation: [
            LLMMessage(role: .system, content: "You are the PM."),
        ])
        delegate.tasks[2] = makeChildTask(question: "Negative numbers?")

        let client = ScriptedLLMClient()
        client.shouldThrow = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: "could not connect"])

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm", parentTeam: parentTeam,
            targetTeamName: "Engineering", client: client,
            globalConfig: delegate.globalLLMConfig, delegate: delegate)

        XCTAssertFalse(success)
        XCTAssertTrue(
            delegate.lastErrorMessages.contains { $0.contains("pm") },
            "a real failure must still surface; got \(delegate.lastErrorMessages)")
    }

    func testSubsequentQuestion_reSeeds_andCarriesThePriorExchange() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        var parentTask = makeParentTask(seedConversation: [LLMMessage(role: .system, content: "PM")])
        // A prior question in the same delegation, already recorded by persistExchange.
        parentTask.runs[0].steps[0].llmConversation.append(
            LLMMessage(role: .user, content: "Earlier question",
                       sourceRole: nil, sourceContext: .delegatedQuestion))
        parentTask.runs[0].steps[0].llmConversation.append(
            LLMMessage(role: .assistant, content: "Earlier answer"))
        delegate.tasks[1] = parentTask
        delegate.tasks[2] = makeChildTask(question: "What about division by zero?")

        let client = ScriptedLLMClient()
        client.script = [
            .init(content: "Throw a DivisionByZeroError.", toolCalls: []),
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
        // system + earlier Q + earlier A + the new question turn
        XCTAssertEqual(capture.messages.count, 4,
                       "The seed is rebuilt from the parent's conversation every time")
        let wire = capture.messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertTrue(wire.contains("Earlier question"),
                      "The prior exchange must ride the seed — nothing holds it server-side")
        XCTAssertTrue(wire.contains("Earlier answer"))
        XCTAssertTrue(capture.messages.last?.content?.contains("What about division by zero?") ?? false)
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
                toolCalls: [(name: ToolNames.askSupervisor, argumentsJSON: "{\"question\": \"Need clarification (escalated)\"}")]
            ),
            // Grandparent answers in plain text
            .init(content: "Use the standard approach.", toolCalls: []),
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
                toolCalls: [(name: ToolNames.askSupervisor, argumentsJSON: "{\"question\": \"Need exec input\"}")]
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

    // MARK: - Prompt contract: escalation is a tool call, not prose

    /// The wire `tools` array offers ONLY `ask_supervisor`; escalation is detected
    /// exclusively via that tool call. The question turn must therefore instruct
    /// escalation AS a tool call — the prior wording "If outside your scope, say so
    /// and the system will escalate" made a compliant model refuse in prose, which
    /// was then delivered to the child as the Supervisor's final answer.
    func testQuestionTurn_instructsToolCallEscalation_andSingleToolAvailability() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        delegate.tasks[1] = makeParentTask(seedConversation: [LLMMessage(role: .system, content: "PM")])
        delegate.tasks[2] = makeChildTask(question: "Q?")

        let client = ScriptedLLMClient()
        client.script = [.init(content: "A.", toolCalls: [])]

        _ = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm",
            parentTeam: parentTeam, targetTeamName: "Engineering",
            client: client, globalConfig: delegate.globalLLMConfig, delegate: delegate
        )

        let turn = client.captures[0].messages.last?.content ?? ""
        XCTAssertTrue(turn.contains("ask_supervisor"),
                      "escalation must be instructed as an ask_supervisor tool call — got:\n\(turn)")
        XCTAssertFalse(turn.contains("say so"),
                       "prose escalation instruction contradicts the tool-call-only detection")
        XCTAssertTrue(turn.localizedCaseInsensitiveContains("only"),
                      "turn must state ask_supervisor is the only tool available in this exchange "
                          + "(the seeded system prompt advertises the role's full toolset)")
        XCTAssertFalse(turn.contains("«"), "guillemets are a one-off delimiter — use plain quotes")
    }

    // MARK: - Harmony-envelope escalation fallback

    /// gpt-oss-class local models emit tool calls as Harmony text envelopes
    /// (`<|channel|>commentary to=functions.X<|message|>{…}<|call|>`) instead of
    /// OpenAI deltas. Without the parser fallback the escalation was invisible AND
    /// the raw envelope leaked to the child as the Supervisor's answer.
    func testEscalation_viaHarmonyEnvelope_isDetected_notLeakedAsAnswer() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        delegate.tasks[1] = makeParentTask(seedConversation: [LLMMessage(role: .system, content: "PM")])
        delegate.tasks[2] = makeChildTask(question: "Cannot answer from PM context")

        let client = ScriptedLLMClient()
        client.script = [
            .init(
                content: "<|channel|>commentary to=functions.ask_supervisor<|message|>"
                    + "{\"question\": \"Need exec input\"}<|call|>",
                toolCalls: []
            ),
        ]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm",
            parentTeam: parentTeam, targetTeamName: "Engineering",
            client: client, globalConfig: delegate.globalLLMConfig, delegate: delegate
        )

        XCTAssertFalse(success, "Harmony-envelope escalation at top of chain must abort, not answer")
        XCTAssertEqual(delegate.answerSupervisorCalls.count, 0,
                       "raw Harmony envelope must never be delivered to the child as an answer")
        XCTAssertEqual(delegate.tasks[1]!.runs[0].steps[0].ancillaryQuestion, "Need exec input")
    }

    /// Stray `<|…|>` model tokens in a plain-text answer (no tool call anywhere)
    /// are stripped before delivery to the child.
    func testPlainAnswer_withStrayModelTokens_isCleaned() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])
        delegate.tasks[1] = makeParentTask(seedConversation: [LLMMessage(role: .system, content: "PM")])
        delegate.tasks[2] = makeChildTask(question: "Q?")

        let client = ScriptedLLMClient()
        client.script = [
            .init(content: "<|channel|>final<|message|>Use approach B.", toolCalls: []),
        ]

        _ = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm",
            parentTeam: parentTeam, targetTeamName: "Engineering",
            client: client, globalConfig: delegate.globalLLMConfig, delegate: delegate
        )

        XCTAssertEqual(delegate.answerSupervisorCalls.count, 1)
        XCTAssertEqual(delegate.answerSupervisorCalls[0].answer, "Use approach B.",
                       "model tokens must be stripped from the delivered answer")
    }


    // MARK: - Grandparent team unresolvable (resolveTeam's non-.resolved arms)

    /// A grandparent whose run is PINNED to a team that no longer exists must
    /// abort the escalation LOUDLY. `TeamResolution` refuses to swap rosters
    /// mid-run, and `resolveTeam` puts that reason on the error banner rather
    /// than letting the chain answer the child from some other team's context.
    ///
    /// RED: delete `delegate.setLastErrorMessageForUI(reason)` from the
    /// `.failed` arm of `DelegatedSupervisorAnswerService.resolveTeam` →
    /// `XCTAssertTrue(delegate.lastErrorMessages.contains { $0.contains("deleted-team") })`
    /// fails (the delegation still aborts, but silently — the user is left
    /// with an abort and no diagnostic).
    func testEscalation_grandparentTeamDeletedMidRun_abortsLoudly() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        delegate.workFolderProjection = makeProjection(teams: [parentTeam])

        // Grandparent's run is pinned to a team absent from the work folder —
        // the deleted-mid-run shape TeamResolution reports as `.failed`.
        var grandparent = makeParentTask(
            id: 0,
            seedConversation: [LLMMessage(role: .system, content: "Top PM")]
        )
        grandparent.runs[0].teamID = "deleted-team"
        delegate.tasks[0] = grandparent
        delegate.tasks[1] = makeParentTask(id: 1, parentTaskID: 0, parentRoleID: "pm")
        delegate.tasks[2] = makeChildTask(question: "Need clarification", parentTaskID: 1, parentRoleID: "pm")

        let client = ScriptedLLMClient()
        client.script = [
            .init(
                content: "",
                toolCalls: [(name: ToolNames.askSupervisor,
                             argumentsJSON: "{\"question\": \"Escalate me\"}")]
            ),
        ]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm",
            parentTeam: parentTeam, targetTeamName: "Engineering",
            client: client, globalConfig: delegate.globalLLMConfig, delegate: delegate
        )

        XCTAssertFalse(success, "an unresolvable grandparent must abort the delegation")
        XCTAssertEqual(client.captures.count, 1,
                       "recursion must NOT proceed — exactly one streamChat (the parent's escalation)")
        XCTAssertTrue(delegate.answerSupervisorCalls.isEmpty,
                      "the child must never receive an answer produced from another team's roster")
        XCTAssertTrue(
            delegate.lastErrorMessages.contains { $0.contains("deleted-team") },
            "the pinned-team-deleted reason must reach the error banner — got \(delegate.lastErrorMessages)"
        )
        // Falls through to the same top-of-chain abort as a missing grandparent.
        XCTAssertEqual(delegate.tasks[1]?.runs[0].steps[0].ancillaryQuestion, "Escalate me")
        XCTAssertFalse(delegate.lastInfoMessages.isEmpty)
    }

    /// A grandparent that resolves to NO team (the work folder has none) aborts
    /// the escalation SILENTLY: `.noTeam` means "nothing selected yet", not a
    /// failure, so it must not write the error banner. It must still refuse to
    /// recurse — answering from the delegating role's own team would seat that
    /// role as its own Supervisor.
    ///
    /// RED: change the call site in `askSupervisorRole` from
    /// `let grandparentTeamRef = resolveTeam(task: grandparentTask, delegate: delegate)`
    /// to `... = resolveTeam(task: grandparentTask, delegate: delegate) ?? roleTeam`
    /// → `XCTAssertEqual(client.captures.count, 1)` and `XCTAssertFalse(success)`
    /// both fail: the recursion proceeds on a borrowed roster and the child is
    /// handed an answer.
    func testEscalation_grandparentHasNoTeam_abortsSilently() async {
        let delegate = MultiTaskDelegateStub()
        let parentTeam = makeParentTeam()
        // No teams at all ⇒ preferredTeamID does not resolve and activeTeam is nil.
        delegate.workFolderProjection = makeProjection(teams: [])

        delegate.tasks[0] = makeParentTask(
            id: 0,
            seedConversation: [LLMMessage(role: .system, content: "Top PM")]
        )
        delegate.tasks[1] = makeParentTask(id: 1, parentTaskID: 0, parentRoleID: "pm")
        delegate.tasks[2] = makeChildTask(question: "Need clarification", parentTaskID: 1, parentRoleID: "pm")

        let client = ScriptedLLMClient()
        client.script = [
            .init(
                content: "",
                toolCalls: [(name: ToolNames.askSupervisor,
                             argumentsJSON: "{\"question\": \"Escalate me\"}")]
            ),
        ]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm",
            parentTeam: parentTeam, targetTeamName: "Engineering",
            client: client, globalConfig: delegate.globalLLMConfig, delegate: delegate
        )

        XCTAssertFalse(success, "no resolvable grandparent ⇒ abort, never a borrowed roster")
        XCTAssertEqual(client.captures.count, 1,
                       "recursion must NOT proceed on a team the grandparent does not own")
        XCTAssertTrue(delegate.answerSupervisorCalls.isEmpty)
        XCTAssertTrue(delegate.lastErrorMessages.isEmpty,
                      "'no team selected' is not an error — it must not clobber the error banner")
        XCTAssertEqual(delegate.tasks[1]?.runs[0].steps[0].ancillaryQuestion, "Escalate me")
        XCTAssertFalse(delegate.lastInfoMessages.isEmpty,
                       "the user still gets the informational abort banner")
    }
}
