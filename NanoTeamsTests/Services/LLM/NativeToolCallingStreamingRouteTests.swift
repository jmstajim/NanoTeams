import XCTest

@testable import NanoTeams

/// `performStreamingCall` under a provider that speaks native tool calls (2026-09-13):
/// the server's rejection of a call is a TURN and not a thrown error, a duplicate native
/// delta stops absorption without breaking the stream (the terminal usage chunk — where
/// Ollama puts the calls themselves — still lands), every call leaves with ONE provider id,
/// and the mode the request ran under rides the result for the no-call branches.
@MainActor
final class NativeToolCallingStreamingRouteTests: XCTestCase {

    private final class Client: LLMClient, @unchecked Sendable {
        var events: [StreamEvent] = []
        var finishError: Error?

        func streamChat(
            config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
            logger _: NetworkLogger?, stepID _: String?, roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let scripted = events
            let thrown = finishError
            return AsyncThrowingStream { continuation in
                for event in scripted { continuation.yield(event) }
                continuation.finish(throwing: thrown)
            }
        }

        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
    }

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var client: Client!
    private let stepID = "engineer"
    private let taskID = 7

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        client = Client()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "Step", status: .running)
        delegate.taskToMutate = NTMSTask(
            id: taskID, title: "T", supervisorTask: "goal", runs: [Run(id: 0, steps: [step])])
    }

    override func tearDown() async throws {
        service = nil; delegate = nil; client = nil
        MonotonicClock.shared.reset()
        try await super.tearDown()
    }

    private func run(
        _ events: [StreamEvent], finishError: Error? = nil, mode: ToolCallingMode = .native
    ) async throws -> LLMExecutionService.StreamingResult {
        client.events = events
        client.finishError = finishError
        return try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: client,
            config: LLMConfig(
                provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m",
                toolCallingMode: mode),
            tools: [], conversationMessages: [], networkLogger: nil)
    }

    private func delta(_ index: Int, id: String, name: String, args: String) -> StreamEvent.ToolCallDelta {
        StreamEvent.ToolCallDelta(index: index, id: id, name: name, argumentsDelta: args)
    }

    // MARK: - The server rejected the model's call

    func testRejection_isATurn_committedWithWhatStreamedBefore_notAThrow() async throws {
        let result = try await run(
            [StreamEvent(thinkingDelta: "plan"), StreamEvent(contentDelta: "pre")],
            finishError: LLMClientError.nativeToolCallRejected("peg-native"))
        XCTAssertEqual(result.nativeCallRejection, "peg-native")
        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
        XCTAssertEqual(result.assistantContent, "pre", "the preamble is the turn's content")
        XCTAssertEqual(result.thinkingContent, "plan")
        XCTAssertEqual(result.toolCallingMode, .native)
        XCTAssertEqual(
            delegate.commitStreamingCalls.last?.2, "pre",
            "committed as the assistant turn, so the nudge that follows has something to answer")
        XCTAssertEqual(delegate.commitStreamingCalls.last?.3, "plan")
    }

    func testRejection_withNothingStreamed_stillResolvesToATurn() async throws {
        let result = try await run([], finishError: LLMClientError.nativeToolCallRejected("bad call"))
        XCTAssertEqual(result.nativeCallRejection, "bad call")
        XCTAssertEqual(result.assistantContent, "")
    }

    /// Every other mid-stream error keeps going to the retry loop.
    func testProviderError_stillThrows() async {
        do {
            _ = try await run([StreamEvent(contentDelta: "x")], finishError: LLMClientError.providerError("boom"))
            XCTFail("a provider error is the server's, not the model's — it must throw")
        } catch {
            XCTAssertEqual(error as? LLMClientError, .providerError("boom"))
        }
    }

    // MARK: - Duplicate native deltas

    /// Until 2026-09-13 a raw duplicate `break`-ed the stream, which on Ollama threw away the
    /// `done:true` chunk carrying the calls' usage and prefill counts.
    func testDuplicateNativeDeltas_stopAbsorbing_butTheTerminalChunkStillLands() async throws {
        let result = try await run([
            StreamEvent(toolCallDeltas: [
                delta(0, id: "c0", name: ToolNames.gitStatus, args: "{}"),
                delta(1, id: "c1", name: ToolNames.gitStatus, args: "{}"),
            ]),
            StreamEvent(toolCallDeltas: [delta(2, id: "c2", name: ToolNames.readFile, args: #"{"path":"a"}"#)]),
            StreamEvent(contentDelta: "tail"),
            StreamEvent(
                tokenUsage: TokenUsage(inputTokens: 475, outputTokens: 30),
                serverPrefill: ServerPrefillReport(prefillNs: 1_000, promptTokens: 475, cachedPromptTokens: 413),
                serverDoneReason: "stop"),
        ])
        XCTAssertEqual(
            result.resolvedToolCalls.map(\.name), [ToolNames.gitStatus],
            "collapsed to one, and the delta after the duplicate was not absorbed")
        XCTAssertEqual(result.assistantContent, "tail", "the stream ran to its end")
        XCTAssertEqual(result.tokenUsage?.inputTokens, 475)
        XCTAssertEqual(result.serverPrefill?.cachedPromptTokens, 413)
        XCTAssertEqual(result.serverDoneReason, "stop")
    }

    func testDistinctNativeDeltas_allResolve_inOrder() async throws {
        let result = try await run([
            StreamEvent(toolCallDeltas: [
                delta(0, id: "c0", name: ToolNames.readFile, args: #"{"path":"a"}"#),
                delta(1, id: "c1", name: ToolNames.readFile, args: #"{"path":"b"}"#),
            ]),
        ])
        XCTAssertEqual(result.resolvedToolCalls.map(\.argumentsJSON), [#"{"path":"a"}"#, #"{"path":"b"}"#])
    }

    // MARK: - One id per call

    /// The result is what `processStreamingResult` records and replays from, so the id it
    /// carries is the one the step record, the runtime result and the `.tool` message read.
    func testProviderID_isCarriedFromTheDelta_intoTheResult() async throws {
        let result = try await run([
            StreamEvent(toolCallDeltas: [delta(0, id: "call_abc", name: ToolNames.readFile, args: #"{"path":"a"}"#)]),
        ])
        XCTAssertEqual(result.resolvedToolCalls.first?.providerID, "call_abc")
    }

    func testProviderID_isMintedOnce_whenTheProviderSentNone() async throws {
        let result = try await run([
            StreamEvent(contentDelta: "<|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a\"}}<|end|>"),
        ], mode: .promptTaught)
        let minted = try XCTUnwrap(result.resolvedToolCalls.first?.providerID)
        XCTAssertNotNil(UUID(uuidString: minted), "a fresh UUID when the provider sent none: \(minted)")
        let again = try await run([
            StreamEvent(contentDelta: "<|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a\"}}<|end|>"),
        ], mode: .promptTaught)
        XCTAssertNotEqual(again.resolvedToolCalls.first?.providerID, minted, "one id per CALL, never reused")
    }

    func testAssigningProviderIDs_keepsAnExistingID_andMintsAMissingOne() {
        let calls = LLMExecutionService.assigningProviderIDs([
            StepToolCall(name: "x", argumentsJSON: "{}"),
            StepToolCall(providerID: "keep", name: "y", argumentsJSON: "{}"),
        ])
        XCTAssertNotNil(calls[0].providerID)
        XCTAssertEqual(calls[1].providerID, "keep")
        XCTAssertNotEqual(calls[0].providerID, calls[1].providerID)
        XCTAssertTrue(LLMExecutionService.assigningProviderIDs([]).isEmpty)
    }

    // MARK: - The mode rides the result

    func testToolCallingMode_ofTheRequest_ridesTheResult() async throws {
        let native = try await run([StreamEvent(contentDelta: "a")], mode: .native)
        XCTAssertEqual(native.toolCallingMode, .native)
        let taught = try await run([StreamEvent(contentDelta: "a")], mode: .promptTaught)
        XCTAssertEqual(taught.toolCallingMode, .promptTaught)
        XCTAssertNil(taught.nativeCallRejection)
    }


    /// The OpenAI-compat route streams the call's pieces before the server refuses it: the
    /// attempt rides the result for the card (never the wire), and an Ollama-style rejection
    /// with no delta at all carries none.
    func testRejection_carriesTheAbsorbedAttempt_forTheCard() async throws {
        let result = try await run(
            [StreamEvent(toolCallDeltas: [delta(0, id: "c1", name: "read_file", args: #"{"path":"a"}"#)])],
            finishError: LLMClientError.nativeToolCallRejected("peg-native"))
        XCTAssertEqual(result.nativeCallAttempt, #"read_file {"path":"a"}"#)
        XCTAssertTrue(result.resolvedToolCalls.isEmpty, "a refused call never resolves")
        let none = try await run([], finishError: LLMClientError.nativeToolCallRejected("peg-native"))
        XCTAssertNil(none.nativeCallAttempt)
    }
}
