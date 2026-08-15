import XCTest

@testable import NanoTeams

/// Drives the REAL `startStepExecution` revision-continuation branch
/// (`LLMExecutionService+StepLifecycle`) with a capturing stub `LLMClient` and pins
/// the send-time half of the revision invariant — the part storage-level tests
/// (`RequestRevisionTests`, `RevisionContinuationTests`) cannot see:
///
/// 1. The wire user message carries exactly ONE "Supervisor Feedback: " prefix.
/// 2. The prior conversation is REPLAYED and the feedback APPENDED — not re-synthesized.
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

    override func setUp() async throws {
        try await super.setUp()
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

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        stubClient = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    func testRevisionContinuation_wireAndDisplay_singlePrefixAndChangeRequestTag() async throws {
        let stepID = "swe_revision_send"
        let task = makeRevisionContinuationTask(
            taskID: 7, stepID: stepID,
            revisionComment: "Fix the restart bug."
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
        XCTAssertTrue(
            call.messages.contains { $0.role == .assistant && $0.content == "Prior turn" },
            "Revision continuation must REPLAY the prior conversation, not re-synthesize one")
        XCTAssertEqual(call.messages.last?.role, .user,
                       "The feedback is appended last so the replayed prefix stays byte-identical")

        // Display: the persisted LLMMessage mirrors the wire content and carries the tag.
        let step = mockDelegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID })
        let feedback = step?.llmConversation.last(where: { $0.role == .user })
        XCTAssertEqual(feedback?.content, "Supervisor Feedback: Fix the restart bug.")
        XCTAssertEqual(feedback?.sourceRole, .supervisor)
        XCTAssertEqual(feedback?.sourceContext, .changeRequest,
                       "Without the tag the bubble renders '(consultation)' — the label bug")
    }

    func testRevisionContinuation_legacyPrefixedComment_doesNotDoublePrefix() async throws {
        let stepID = "swe_legacy_send"
        // A task persisted by a pre-fix build: resetStepForRevision derived
        // revisionComment from the already-prefixed message content.
        let task = makeRevisionContinuationTask(
            taskID: 8, stepID: stepID,
            revisionComment: "Supervisor Feedback: Legacy stored comment."
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

    /// When BOTH an UNDELIVERED `supervisorAnswer` and a `revisionComment` are set, the
    /// supervisor continuation wins: the wire carries the answer as a TOOL result
    /// resolving the pending `ask_supervisor` call — sending a user-role feedback turn
    /// instead would leave that call unanswered in the replayed transcript.
    ///
    /// "Undelivered" is load-bearing and is why `supervisorAnswerPendingDelivery` is set
    /// explicitly here. The precondition used to be the weaker `supervisorAnswer != nil`,
    /// which never went false — so a step that had EVER been answered could not take the
    /// revision branch at all. The complement is pinned by
    /// `SupervisorAnswerDeliveryOnceTests.testRevisionAfterAnAnsweredQuestion_deliversTheFeedback`.
    func testBothContinuations_undeliveredSupervisorAnswerWins() async throws {
        let stepID = "swe_precedence"
        var task = makeRevisionContinuationTask(
            taskID: 9, stepID: stepID,
            revisionComment: "Revise section 2."
        )
        task.runs[0].steps[0].supervisorAnswer = "Use PostgreSQL."
        task.runs[0].steps[0].supervisorAnswerPendingDelivery = true
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
    }

    // MARK: - Corner: no replayable history

    /// A step with nothing to replay (no `wireTranscript`, no `llmConversation`) falls
    /// back to the freshly built conversation, where the feedback arrives via the
    /// single prefixed `StepMessage` relay — exactly once, and with no planning-phase
    /// hijack (a step under revision never enters planning even with a nil scratchpad).
    func testNoReplayableHistory_feedbackExactlyOnce_noPlanningHijack() async throws {
        let stepID = "swe_fresh_rebuild"
        let rawComment = "Revise the error handling."
        var task = makeRevisionContinuationTask(
            taskID: 10, stepID: stepID,
            revisionComment: rawComment
        )
        task.runs[0].steps[0].llmConversation = []  // nothing to replay
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
        let joined = call.messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertEqual(joined.components(separatedBy: rawComment).count, 2,
                       "Feedback text exactly once in the rebuild")
        XCTAssertEqual(joined.components(separatedBy: "Supervisor Feedback:").count, 2,
                       "Exactly one attribution prefix in the rebuild")
        XCTAssertFalse(joined.contains("PLANNING PHASE"),
                       "A revision step (nil scratchpad) must not be hijacked into planning")
    }

    // MARK: - Helpers

    /// Step shaped exactly like the engine leaves it after `resetStepForRevision` +
    /// `prepareStepForExecution`: `.running`, a replayable conversation, raw
    /// revisionComment, no supervisor answer (the `hasRevisionFeedback` precondition).
    private func makeRevisionContinuationTask(
        taskID: Int, stepID: String, revisionComment: String
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

/// Records every `streamChat` invocation's messages, emits one content delta,
/// then suspends until cancelled — mimics a live server holding the connection so the
/// test controls when the call ends via `cancelStepExecution`.
final class CapturingStubLLMClient: LLMClient, @unchecked Sendable {
    struct CapturedCall {
        let messages: [ChatMessage]
    }

    private let lock = NSLock()
    private var _capturedCalls: [CapturedCall] = []
    var capturedCalls: [CapturedCall] { lock.withLock { _capturedCalls } }

    func streamChat(
        config _: LLMConfig,
        messages: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock {
            _capturedCalls.append(CapturedCall(messages: messages))
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
