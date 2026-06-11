import XCTest

@testable import NanoTeams

/// Drives the REAL `startStepExecution` revision-continuation branch
/// (`LLMExecutionService+StepLifecycle`) with a capturing stub `LLMClient` and pins
/// the send-time half of the revision invariant — the part storage-level tests
/// (`RequestRevisionTests`, `RevisionContinuationTests`) cannot see:
///
/// 1. The wire user message carries exactly ONE "Supervisor Feedback: " prefix.
/// 2. The stateful session (`previous_response_id`) is used, not a stateless rebuild.
/// 3. The persisted display `LLMMessage` is tagged `sourceContext: .changeRequest` —
///    without the tag, `sourceContextDisplayLabel` falls back to "(consultation)"
///    (the exact label bug this guards against; the parameter defaults to `nil`,
///    so dropping it compiles silently).
/// 4. Legacy `revisionComment` values persisted by pre-fix builds (already prefixed)
///    are stripped before prefixing — the doubled prefix cannot resurrect.
@MainActor
final class RevisionContinuationSendPathTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var stubClient: CapturingStubLLMClient!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let stub = CapturingStubLLMClient()
        stubClient = stub
        service = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { stub }
        )
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        stubClient = nil
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testRevisionContinuation_wireAndDisplay_singlePrefixAndChangeRequestTag() async throws {
        let stepID = "swe_revision_send"
        let task = makeRevisionContinuationTask(
            taskID: 7, stepID: stepID,
            revisionComment: "Fix the restart bug.",
            sessionID: "resp_42"
        )
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 7,
            task: task, runIndex: 0, stepIndex: 0)
        try await waitUntil { !self.stubClient.capturedCalls.isEmpty }
        await service.cancelStepExecution(stepID: stepID, taskID: 7)

        // Wire: the continuation sends the feedback as a user turn with exactly one prefix.
        let call = stubClient.capturedCalls[0]
        let userMessage = call.messages.first(where: { $0.role == .user })
        XCTAssertEqual(userMessage?.content, "Supervisor Feedback: Fix the restart bug.")
        XCTAssertEqual(
            userMessage?.content?.components(separatedBy: "Supervisor Feedback:").count, 2,
            "Exactly one prefix on the wire — the doubled-prefix bug fired here")
        XCTAssertEqual(call.session?.responseID, "resp_42",
                       "Revision continuation must reuse the saved stateful session")

        // Display: the persisted LLMMessage mirrors the wire content and carries the tag.
        let step = mockDelegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID })
        let feedback = step?.llmConversation.last(where: { $0.role == .user })
        XCTAssertEqual(feedback?.content, "Supervisor Feedback: Fix the restart bug.")
        XCTAssertEqual(feedback?.sourceRole, .supervisor)
        XCTAssertEqual(feedback?.sourceContext, .changeRequest,
                       "Without the tag the bubble renders '(consultation)' — the label bug")
        XCTAssertNil(step?.llmSessionID,
                     "Saved session must be cleared once consumed (prevents stale-session retry)")
    }

    func testRevisionContinuation_legacyPrefixedComment_doesNotDoublePrefix() async throws {
        let stepID = "swe_legacy_send"
        // A task persisted by a pre-fix build: resetStepForRevision derived
        // revisionComment from the already-prefixed message content.
        let task = makeRevisionContinuationTask(
            taskID: 8, stepID: stepID,
            revisionComment: "Supervisor Feedback: Legacy stored comment.",
            sessionID: "resp_legacy"
        )
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 8,
            task: task, runIndex: 0, stepIndex: 0)
        try await waitUntil { !self.stubClient.capturedCalls.isEmpty }
        await service.cancelStepExecution(stepID: stepID, taskID: 8)

        let userMessage = stubClient.capturedCalls[0].messages.first(where: { $0.role == .user })
        XCTAssertEqual(userMessage?.content, "Supervisor Feedback: Legacy stored comment.",
                       "Send site must strip a legacy prefix before re-applying")

        let step = mockDelegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID })
        let feedback = step?.llmConversation.last(where: { $0.role == .user })
        XCTAssertEqual(feedback?.content, "Supervisor Feedback: Legacy stored comment.",
                       "Display copy must match the wire copy — single prefix")
    }

    // MARK: - Corner: continuation precedence

    /// When BOTH `supervisorAnswer` and `revisionComment` are set, the supervisor
    /// continuation wins (`hasRevisionContinuation` requires `effectiveSupervisorAnswer
    /// == nil`): the wire carries the answer as a TOOL result resolving the pending
    /// `ask_supervisor` call — sending a user-role feedback turn instead would leave
    /// that tool call unresolved and poison the stateful chain.
    func testBothContinuations_supervisorAnswerWins() async throws {
        let stepID = "swe_precedence"
        var task = makeRevisionContinuationTask(
            taskID: 9, stepID: stepID,
            revisionComment: "Revise section 2.",
            sessionID: "resp_both"
        )
        task.runs[0].steps[0].supervisorAnswer = "Use PostgreSQL."
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 9,
            task: task, runIndex: 0, stepIndex: 0)
        try await waitUntil { !self.stubClient.capturedCalls.isEmpty }
        await service.cancelStepExecution(stepID: stepID, taskID: 9)

        let call = stubClient.capturedCalls[0]
        let toolMessage = call.messages.first(where: { $0.role == .tool })
        XCTAssertNotNil(toolMessage, "Supervisor continuation sends the answer as a tool result")
        XCTAssertTrue(toolMessage?.content?.contains("Use PostgreSQL.") ?? false)
        XCTAssertNil(
            call.messages.first(where: {
                $0.role == .user && ($0.content?.hasPrefix("Supervisor Feedback:") ?? false)
            }),
            "Revision feedback must NOT be sent while a supervisor answer is pending")
        XCTAssertEqual(call.session?.responseID, "resp_both")
    }

    // MARK: - Corner: stateless fallback (no saved session)

    /// With no saved session, the revision-continuation block is skipped entirely:
    /// the wire is the full stateless rebuild, where the feedback arrives via the
    /// single prefixed `StepMessage` relay — exactly once, and with no planning-phase
    /// hijack (a step under revision never enters planning even with a nil scratchpad).
    func testStatelessFallback_feedbackExactlyOnce_noPlanningHijack() async throws {
        let stepID = "swe_stateless"
        let rawComment = "Revise the error handling."
        var task = makeRevisionContinuationTask(
            taskID: 10, stepID: stepID,
            revisionComment: rawComment,
            sessionID: "ignored"
        )
        task.runs[0].steps[0].llmSessionID = nil  // stateless resume
        task.runs[0].steps[0].messages.append(StepMessage(
            role: .supervisor,
            content: MessageSourceContext.supervisorFeedbackPrefix + rawComment
        ))
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 10,
            task: task, runIndex: 0, stepIndex: 0)
        try await waitUntil { !self.stubClient.capturedCalls.isEmpty }
        await service.cancelStepExecution(stepID: stepID, taskID: 10)

        let call = stubClient.capturedCalls[0]
        XCTAssertNil(call.session, "No saved session — must rebuild stateless")

        let joined = call.messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertEqual(joined.components(separatedBy: rawComment).count, 2,
                       "Feedback text exactly once in the stateless rebuild")
        XCTAssertEqual(joined.components(separatedBy: "Supervisor Feedback:").count, 2,
                       "Exactly one attribution prefix in the stateless rebuild")
        XCTAssertFalse(joined.contains("PLANNING PHASE"),
                       "A revision step (nil scratchpad) must not be hijacked into planning")
    }

    // MARK: - Helpers

    /// Step shaped exactly like the engine leaves it after `resetStepForRevision` +
    /// `prepareStepForExecution`: `.running`, saved session, raw revisionComment,
    /// no supervisor answer (the `hasRevisionContinuation` precondition set).
    private func makeRevisionContinuationTask(
        taskID: Int, stepID: String, revisionComment: String, sessionID: String
    ) -> NTMSTask {
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .running,
            messages: [StepMessage(role: .softwareEngineer, content: "Earlier work")],
            llmConversation: [
                LLMMessage(role: .system, content: "System prompt"),
                LLMMessage(role: .assistant, content: "Prior turn"),
            ],
            llmSessionID: sessionID,
            revisionComment: revisionComment
        )
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: taskID, title: "Test", supervisorTask: "Goal", runs: [run])
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw WaitTimeoutError(timeout: timeout)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct WaitTimeoutError: Error, LocalizedError {
        let timeout: TimeInterval
        var errorDescription: String? {
            "waitUntil: condition not met within \(timeout)s — the stub stream never started."
        }
    }
}

// MARK: - Capturing stub LLM client

/// Records every `streamChat` invocation (messages + session), emits one content delta,
/// then suspends until cancelled — mimics a live server holding the connection so the
/// test controls when the call ends via `cancelStepExecution`.
final class CapturingStubLLMClient: LLMClient, @unchecked Sendable {
    struct CapturedCall {
        let messages: [ChatMessage]
        let session: LLMSession?
    }

    private let lock = NSLock()
    private var _capturedCalls: [CapturedCall] = []
    var capturedCalls: [CapturedCall] { lock.withLock { _capturedCalls } }

    func streamChat(
        config _: LLMConfig,
        messages: [ChatMessage],
        tools _: [ToolSchema],
        session: LLMSession?,
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock {
            _capturedCalls.append(CapturedCall(messages: messages, session: session))
        }
        return AsyncThrowingStream { continuation in
            let producer = Task.detached {
                continuation.yield(StreamEvent(contentDelta: "Acknowledged."))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
