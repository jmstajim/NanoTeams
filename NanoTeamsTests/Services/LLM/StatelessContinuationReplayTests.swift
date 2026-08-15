import XCTest

@testable import NanoTeams

/// Pins the continuation contract on BOTH providers: when a step is re-entered
/// after a Supervisor answer, the conversation sent to the model must still contain
/// the tool calls and tool results the step accumulated before it parked.
///
/// Regression this guards: `LLMExecutionService+StepLifecycle` used to fall to
/// `conversation = fullConversation` on re-entry. `PromptBuilder.buildChatMessages`
/// reads `step.messages` — never `step.llmConversation` and never `step.toolCalls` —
/// and in a Harmony tool loop almost every assistant turn is envelope-only, so no
/// `StepMessage` is ever written for it and tool results are not written there at all.
///
/// Observed live (2026-07-23, `qwen3.6:35b-a3b` over Ollama): the request at 17:53:43
/// carried system + task + four assistant/tool-result pairs; the request at 17:55:16,
/// immediately after the Supervisor answered, carried four messages total — system,
/// task, a synthesized `ask_supervisor` envelope, and the answer. Every read, every
/// write and the bash denial were gone, so the model re-read the same files, re-wrote
/// the same files, hit the same denial and re-asked the same question.
@MainActor
final class StatelessContinuationReplayTests: XCTestCase {

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

    // MARK: - The reported bug

    func testOllamaContinuation_afterSupervisorAnswer_resendsPriorToolHistory() async throws {
        let stepID = "swe_ollama_replay"
        mockDelegate.globalLLMConfig = LLMConfig(provider: .ollama)
        let task = makeParkedThenAnsweredTask(taskID: 21, stepID: stepID)
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 21, task: task, runIndex: 0, stepIndex: 0)
        try await waitUntil { !self.stubClient.capturedCalls.isEmpty }
        await service.cancelStepExecution(stepID: stepID, taskID: 21)

        let call = stubClient.capturedCalls[0]
        let wire = call.messages.compactMap(\.content).joined(separator: "\n")

        XCTAssertTrue(
            wire.contains("Package.swift"),
            "The read the role already performed must survive the Supervisor round-trip — "
                + "without it the role re-reads the same file")
        XCTAssertTrue(
            wire.contains("MeditationLibrary.swift"),
            "The write the role already performed must survive — without it the role "
                + "re-writes a file it already created")
        XCTAssertTrue(
            wire.contains("BASH_DENIED"),
            "The bash denial must survive — without it the role retries a command that "
                + "policy already refused")
        XCTAssertTrue(
            wire.contains("swift build"),
            "The Supervisor's answer must still reach the model")
    }

    /// The SAME step under LM Studio must behave identically. Server-side response
    /// chains were removed, so LM Studio no longer gets a "send only the answer"
    /// shortcut — it replays the full transcript and appends the answer turn, exactly
    /// like Ollama. Pinned so the two providers cannot drift apart again.
    func testLMStudioContinuation_afterSupervisorAnswer_alsoReplaysFullTranscript() async throws {
        let stepID = "swe_lmstudio_replay"
        mockDelegate.globalLLMConfig = LLMConfig(provider: .lmStudio)
        let task = makeParkedThenAnsweredTask(taskID: 22, stepID: stepID)
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: 22, task: task, runIndex: 0, stepIndex: 0)
        try await waitUntil { !self.stubClient.capturedCalls.isEmpty }
        await service.cancelStepExecution(stepID: stepID, taskID: 22)

        let call = stubClient.capturedCalls[0]
        let wire = call.messages.compactMap(\.content).joined(separator: "\n")

        XCTAssertTrue(wire.contains("Package.swift"),
                      "LM Studio must replay the read the role already performed")
        XCTAssertTrue(wire.contains("MeditationLibrary.swift"),
                      "LM Studio must replay the write the role already performed")
        XCTAssertTrue(wire.contains("BASH_DENIED"),
                      "LM Studio must replay the bash denial")
        XCTAssertTrue(wire.contains("swift build"),
                      "The Supervisor's answer must still reach the model")
        XCTAssertEqual(call.messages.last?.role, .tool,
                       "The answer rides as the tool result resolving the pending ask_supervisor")
    }

    // MARK: - Helpers

    /// A step shaped exactly as the runtime leaves it after `ask_supervisor` parked it
    /// and `StepMessagingService.answerSupervisorQuestion` delivered the answer:
    /// `.running` (markStepRunning already ran), the question and answer both set, and
    /// a `llmConversation` / `toolCalls` history carrying the work already done.
    private func makeParkedThenAnsweredTask(taskID: Int, stepID: String) -> NTMSTask {
        let readResult = #"{"ok":true,"data":{"path":"Package.swift","content":"// swift-tools-version: 5.9"}}"#
        let writeResult = #"{"ok":true,"data":{"created":true,"path":"Sources/MeditationApp/MeditationLibrary.swift"}}"#
        let bashResult = #"{"ok":false,"error":{"code":"BASH_DENIED","message":"needs human approval"}}"#

        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .running,
            messages: [],
            toolCalls: [
                StepToolCall(providerID: "call_1", name: "read_file",
                             argumentsJSON: #"{"path":"Package.swift"}"#,
                             resultJSON: readResult),
                StepToolCall(providerID: "call_2", name: "write_file",
                             argumentsJSON: #"{"path":"Sources/MeditationApp/MeditationLibrary.swift"}"#,
                             resultJSON: writeResult),
                StepToolCall(providerID: "call_3", name: "bash",
                             argumentsJSON: #"{"command":"swift build"}"#,
                             resultJSON: bashResult, isError: true),
            ],
            needsSupervisorInput: false,
            supervisorQuestion: "Please approve running `swift build` to verify the build.",
            supervisorAnswer: "Please run `swift build` and report the final status line.",
            llmConversation: [
                LLMMessage(role: .system, content: "System prompt"),
                LLMMessage(role: .user, content: "## Supervisor Task\n\nImplement M2."),
                LLMMessage(role: .tool, content: """
                    [CALL] read_file
                    Arguments: {"path":"Package.swift"}

                    [RESULT]
                    \(readResult)
                    """),
                LLMMessage(role: .tool, content: """
                    [CALL] write_file
                    Arguments: {"path":"Sources/MeditationApp/MeditationLibrary.swift"}

                    [RESULT]
                    \(writeResult)
                    """),
                LLMMessage(role: .tool, content: """
                    [CALL] bash
                    Arguments: {"command":"swift build"}

                    [RESULT]
                    \(bashResult)
                    """),
                LLMMessage(
                    role: .user,
                    content: MessageSourceContext.supervisorAnswerPrefix
                        + "Please run `swift build` and report the final status line.",
                    sourceRole: .supervisor,
                    sourceContext: .supervisorAnswer),
            ]
        )
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: taskID, title: "Test", supervisorTask: "Implement M2.", runs: [run])
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw ReplayWaitTimeoutError(timeout: timeout)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct ReplayWaitTimeoutError: Error, LocalizedError {
        let timeout: TimeInterval
        var errorDescription: String? {
            "waitUntil: condition not met within \(timeout)s — the stub stream never started."
        }
    }
}
