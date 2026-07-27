import XCTest

@testable import NanoTeams

/// Drives the REAL `startStepExecution` retry loop
/// (`LLMExecutionService+StepLifecycle`) with a stub `LLMClient` scripted to throw
/// HTTP errors, and pins the retry-classification wiring end-to-end:
///
/// 1. A permanent error (HTTP 404 `model_not_found`) fails the step after exactly
///    ONE attempt — no infinite retry, no "LLM server error (attempt N)" spam —
///    and the failure reason is recorded so the activity feed can surface it.
/// 2. A transient error (HTTP 503) still takes the retry path (the "attempt N"
///    note is appended and the step does NOT fail) — proving the guard
///    discriminates rather than failing everything.
@MainActor
final class LLMServerErrorRetryClassificationTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var stubClient: ScriptedThrowingStubLLMClient!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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

    private func makeService(script: [Error?]) {
        let stub = ScriptedThrowingStubLLMClient(script: script)
        stubClient = stub
        service = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { stub }
        )
        // Keep retry-loop tests fast and decoupled from the 10s product backoff.
        service.retryDelaySeconds = 1
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        // Faithfully reproduce production: beginStreaming plants an empty .assistant
        // placeholder before each attempt. Without this the retry-collapse test gives
        // a false pass (the real placeholder defeats the prefix match).
        mockDelegate.plantsEmptyAssistantMessage = true
        service.attach(delegate: mockDelegate)
    }

    private func makeRunningTask(taskID: Int, stepID: String) -> NTMSTask {
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .running,
            llmConversation: [
                LLMMessage(role: .system, content: "System prompt"),
            ]
        )
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: taskID, title: "Test", supervisorTask: "Goal", runs: [run])
    }

    private func step(in taskID: Int, stepID: String) -> StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID })
    }

    // MARK: - Permanent error → fail fast, no retry

    func testHTTP404_failsStepAfterOneAttempt_noRetryNote() async throws {
        makeService(script: [LLMClientError.badHTTPStatus(
            404, "{\"error\":{\"code\":\"model_not_found\"}}")])
        let stepID = "swe_404"
        let task = makeRunningTask(taskID: 1, stepID: stepID)
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 1, task: task, runIndex: 0, stepIndex: 0)

        try await waitUntil { self.step(in: 1, stepID: stepID)?.status == .failed }

        XCTAssertEqual(stubClient.callCount, 1,
                       "A 404 must NOT be retried — exactly one streamChat call")

        let failed = step(in: 1, stepID: stepID)
        // Failure reason recorded (this is what the activity-feed bubble surfaces).
        let errorNote = failed?.messages.last(where: {
            $0.content.hasPrefix("\(StepExecution.llmErrorNotePrefix): ")
        })
        XCTAssertNotNil(errorNote, "The failure reason must be recorded for the error bubble")
        XCTAssertTrue(errorNote?.content.contains("404") ?? false,
                      "Recorded reason must carry the HTTP 404 detail")

        // No "attempt N" retry spam in the conversation.
        let retrySpam = failed?.llmConversation.contains(where: {
            $0.content.hasPrefix(LLMConstants.llmServerErrorRetryNotePrefix)
        }) ?? false
        XCTAssertFalse(retrySpam, "A permanent error must not append a retry note")
    }

    // MARK: - Transient error → retry path (does not fail fast)

    func testHTTP503_takesRetryPath_appendsNoteAndDoesNotFail() async throws {
        // 503 every call; maxLLMRetries = 0 (unlimited). The loop appends the
        // "attempt 1" note BEFORE its backoff sleep — we assert on that note
        // (fast) and cancel during the sleep so the test stays quick.
        makeService(script: [LLMClientError.badHTTPStatus(503, "model loading")])
        let stepID = "swe_503"
        let task = makeRunningTask(taskID: 2, stepID: stepID)
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 2, task: task, runIndex: 0, stepIndex: 0)

        try await waitUntil {
            self.step(in: 2, stepID: stepID)?.llmConversation.contains(where: {
                $0.content.hasPrefix(LLMConstants.llmServerErrorRetryNotePrefix)
            }) ?? false
        }

        let s = step(in: 2, stepID: stepID)
        XCTAssertNotEqual(s?.status, .failed,
                          "A transient 503 must keep retrying, not fail the step")
        let failureNote = s?.messages.contains(where: {
            $0.content.hasPrefix("\(StepExecution.llmErrorNotePrefix): ")
        }) ?? false
        XCTAssertFalse(failureNote, "No failure reason should be recorded while still retrying")

        await service.cancelStepExecution(stepID: stepID, taskID: 2)
    }

    // MARK: - Retry notes collapse into a single bubble

    func testRetryNotes_collapseIntoSingleBubble_acrossAttempts() async throws {
        // 503 is retryable; with unlimited retries the loop appends attempt 1, then
        // REPLACES it with attempt 2 (one 2s backoff between) instead of stacking.
        makeService(script: [LLMClientError.badHTTPStatus(503, "down")])
        let stepID = "swe_collapse"
        let task = makeRunningTask(taskID: 3, stepID: stepID)
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 3, task: task, runIndex: 0, stepIndex: 0)

        // Wait until the SECOND attempt has produced its (collapsed) note.
        try await waitUntil(timeout: 8) {
            let notes = self.retryNotes(taskID: 3, stepID: stepID)
            return notes.count == 1 && (notes.first?.contains("attempt 2") ?? false)
        }
        await service.cancelStepExecution(stepID: stepID, taskID: 3)

        let notes = retryNotes(taskID: 3, stepID: stepID)
        XCTAssertEqual(notes.count, 1,
                       "Retry notes must collapse into a single bubble across attempts, not stack")
    }

    // MARK: - Permanent error on a continuation step

    func testHTTP404_onContinuationStep_failsFast_recordsReason() async throws {
        // A supervisor/revision continuation step (saved session + revisionComment)
        // must also fail fast on a permanent error — the isRetryable guard sits at
        // the top of the catch, ahead of the continuation session-reset logic.
        makeService(script: [LLMClientError.badHTTPStatus(404, "model_not_found")])
        let stepID = "swe_cont"
        let contStep = StepExecution(
            id: stepID, role: .softwareEngineer, title: "SWE Step", status: .running,
            llmConversation: [LLMMessage(role: .system, content: "System prompt")],
            revisionComment: "Fix it.")
        let task = NTMSTask(id: 4, title: "Test", supervisorTask: "Goal",
                            runs: [Run(id: 0, steps: [contStep])])
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 4, task: task, runIndex: 0, stepIndex: 0)
        try await waitUntil { self.step(in: 4, stepID: stepID)?.status == .failed }

        XCTAssertEqual(stubClient.callCount, 1,
                       "Permanent error on a continuation step must fail fast — no retry")
        let errorNote = step(in: 4, stepID: stepID)?.messages.last {
            $0.content.hasPrefix("\(StepExecution.llmErrorNotePrefix): ")
        }
        XCTAssertTrue(errorNote?.content.contains("404") ?? false,
                      "Continuation-step failure must still record the reason")
    }

    // MARK: - Transient → permanent transition (features coexist)

    func testTransient503ThenPermanent404_collapsedNoteRemains_andFailureRecorded() async throws {
        // Realistic sequence: LM Studio is loading (503, retry) then the model is
        // genuinely missing (404, fail). The collapsed retry note survives in
        // llmConversation AND the failure reason lands in messages.
        makeService(script: [
            LLMClientError.badHTTPStatus(503, "loading"),
            LLMClientError.badHTTPStatus(404, "model_not_found"),
        ])
        let stepID = "swe_mix"
        let task = makeRunningTask(taskID: 5, stepID: stepID)
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 5, task: task, runIndex: 0, stepIndex: 0)
        try await waitUntil(timeout: 8) { self.step(in: 5, stepID: stepID)?.status == .failed }

        XCTAssertEqual(stubClient.callCount, 2,
                       "Transient 503 retried once, then permanent 404 failed fast")
        // Never floods across the transition — at most one retry note (the planning
        // phase can re-create/clear it between iterations, but it never stacks).
        XCTAssertLessThanOrEqual(retryNotes(taskID: 5, stepID: stepID).count, 1,
                                 "Retry notes must never stack, even across a transient→permanent transition")
        let errorNote = step(in: 5, stepID: stepID)?.messages.last {
            $0.content.hasPrefix("\(StepExecution.llmErrorNotePrefix): ")
        }
        XCTAssertTrue(errorNote?.content.contains("404") ?? false,
                      "The permanent failure reason must be recorded")
    }

    private func retryNotes(taskID: Int, stepID: String) -> [String] {
        (step(in: taskID, stepID: stepID)?.llmConversation ?? [])
            .map { $0.content }
            .filter { $0.hasPrefix(LLMConstants.llmServerErrorRetryNotePrefix) }
    }

    // MARK: - Helpers

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
            "waitUntil: condition not met within \(timeout)s."
        }
    }
}

// MARK: - Scripted throwing stub LLM client

/// Throws a scripted error per call (clamped to the last entry once the script is
/// exhausted). A `nil` script entry means "succeed": yield one content delta, then
/// suspend until cancelled (mimics a live server holding the connection).
final class ScriptedThrowingStubLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }
    private let script: [Error?]

    init(script: [Error?]) {
        precondition(!script.isEmpty, "script must have at least one entry")
        self.script = script
    }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let action: Error? = lock.withLock {
            let i = min(_callCount, script.count - 1)
            _callCount += 1
            return script[i]
        }
        return AsyncThrowingStream { continuation in
            if let error = action {
                continuation.finish(throwing: error)
                return
            }
            let producer = Task.detached {
                continuation.yield(StreamEvent(contentDelta: "ok"))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
