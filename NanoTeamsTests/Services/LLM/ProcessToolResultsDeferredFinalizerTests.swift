import XCTest

@testable import NanoTeams

/// `processToolResults` routes three signals to dedicated ASYNC finalizers
/// (`.visionAnalysis`, `.exploratorySearch`, `.computerUse`) instead of the
/// regular path, and deliberately SKIPS them in its pre-record tracker loop —
/// their `outputJSON` at that moment is an interim `{"status":"analyzing"}` /
/// `{"status":"exploring"}` placeholder, so recording it would poison the loop
/// detector's next `recentCalls` snapshot with a result that was never real.
///
/// The two halves of that contract live in different files (the skip predicate
/// here, the compensating `tracker.record` inside each finalizer), so only a test
/// that drives the WHOLE round trip can prove they still meet. The finalizer
/// suites call the finalizers directly and the routing suites stop at the
/// predicate; nothing exercised the dispatch itself.
///
/// Both signals are driven down a REJECTION path (`visionLLMConfig == nil`,
/// `workFolderURL == nil`) so no LLM request and no filesystem walk is needed —
/// the routing, the envelope rewrite and the tracker compensation are all
/// observable either way.
@MainActor
final class ProcessToolResultsDeferredFinalizerTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tracker: ToolCallTracker!
    private var memoryStore: MemoryTagStore!
    private var tempDir: URL!

    private let stepID = "worker"
    private let taskID = 64

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tracker = ToolCallTracker()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deferred-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        memoryStore = MemoryTagStore(workFolderRoot: tempDir)
        mockDelegate.workFolderURL = tempDir
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        memoryStore = nil
        tracker = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - Vision

    /// `analyze_image` with no vision model configured must come back as a typed
    /// FAILURE the model can act on — and the card must stop showing "analyzing",
    /// which is otherwise indistinguishable from a hung request.
    func testVisionSignal_routesToFinalizer_andRewritesTheAnalyzingPlaceholder() async {
        let callID = UUID()
        seedStep(callID: callID, toolName: ToolNames.analyzeImage)
        mockDelegate.visionLLMConfig = nil          // → VisionError.notConfigured

        var conversation: [ChatMessage] = []
        let outcome = await run(
            callID: callID, toolName: ToolNames.analyzeImage,
            outputJSON: #"{"ok":true,"data":{"status":"analyzing"}}"#,
            signal: .visionAnalysis(imagePath: "shot.png", prompt: "what is this"),
            conversation: &conversation)

        XCTAssertFalse(outcome.shouldStopForSupervisor)
        let card = card(callID)
        XCTAssertEqual(card?.isError, true, "an unconfigured vision model is a failure, not a pending state")
        XCTAssertFalse(card?.resultJSON?.contains("analyzing") ?? true,
                       "the interim placeholder must be replaced; got \(card?.resultJSON ?? "nil")")

        XCTAssertEqual(conversation.count, 1, "one tool result per tool call")
        XCTAssertEqual(conversation.first?.role, .tool)
        XCTAssertTrue((conversation.first?.content ?? "").contains(#""ok":false"#),
                      "got: \(conversation.first?.content ?? "nil")")
    }

    /// The skip/compensate pair: `processToolResults` must NOT record the
    /// placeholder, and the finalizer MUST record the real envelope — so the
    /// tracker ends with exactly one entry and it is the final one.
    func testVisionSignal_trackerRecordsTheFinalEnvelope_neverThePlaceholder() async {
        let callID = UUID()
        seedStep(callID: callID, toolName: ToolNames.analyzeImage)
        mockDelegate.visionLLMConfig = nil

        var conversation: [ChatMessage] = []
        _ = await run(
            callID: callID, toolName: ToolNames.analyzeImage,
            outputJSON: #"{"ok":true,"data":{"status":"analyzing"}}"#,
            signal: .visionAnalysis(imagePath: "shot.png", prompt: "p"),
            conversation: &conversation)

        let recorded = tracker.recentCalls(limit: 10)
        XCTAssertEqual(recorded.count, 1,
                       "exactly one tracker entry — skipped in the pre-record loop, recorded by the finalizer")
        XCTAssertFalse(recorded.first?.resultJSON.contains("analyzing") ?? true,
                       "the loop detector must never see the interim placeholder; got \(recorded.first?.resultJSON ?? "nil")")
        XCTAssertEqual(recorded.first?.wasSuccessful, false,
                       "the tracker's success flag drives loop detection — a failure recorded as success re-arms it")
    }

    // MARK: - Exploratory search

    /// The same contract for `search`'s exploratory mode.
    func testExploratorySignal_routesToFinalizer_andRewritesTheExploringPlaceholder() async {
        let callID = UUID()
        seedStep(callID: callID, toolName: ToolNames.search)
        mockDelegate.workFolderURL = nil            // → the `no_work_folder` envelope

        var conversation: [ChatMessage] = []
        _ = await run(
            callID: callID, toolName: ToolNames.search,
            outputJSON: #"{"ok":true,"data":{"status":"exploring"}}"#,
            signal: .exploratorySearch(try! payload(query: "needle")),
            conversation: &conversation)

        let resultJSON = card(callID)?.resultJSON ?? ""
        XCTAssertFalse(resultJSON.contains("exploring"),
                       "the interim placeholder must be replaced; got \(resultJSON)")
        XCTAssertEqual(conversation.count, 1)
        XCTAssertEqual(conversation.first?.role, .tool)
        XCTAssertFalse((conversation.first?.content ?? "").isEmpty,
                       "a blank tool result leaves the model with nothing to react to")
    }

    func testExploratorySignal_trackerRecordsTheFinalEnvelope_neverThePlaceholder() async {
        let callID = UUID()
        seedStep(callID: callID, toolName: ToolNames.search)
        mockDelegate.workFolderURL = nil

        var conversation: [ChatMessage] = []
        _ = await run(
            callID: callID, toolName: ToolNames.search,
            outputJSON: #"{"ok":true,"data":{"status":"exploring"}}"#,
            signal: .exploratorySearch(try! payload(query: "needle")),
            conversation: &conversation)

        let recorded = tracker.recentCalls(limit: 10)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertFalse(recorded.first?.resultJSON.contains("exploring") ?? true,
                       "got \(recorded.first?.resultJSON ?? "nil")")
    }

    // MARK: - Computer use

    /// The third deferred signal, and the one the class header has always named without a
    /// test behind it. The service is built with the DEFAULT computer-use environment, which
    /// resolves inward to `.inert` — so this drives the refusal arm and never touches the
    /// developer's screen, cursor or keyboard.
    ///
    /// RED: delete the `case .computerUse` arm from `processToolResults` → the call falls
    /// through to `processRegularToolResult`, the card keeps saying "pending", and the model
    /// is told a click it never got succeeded.
    func testComputerUseSignal_routesToFinalizer_andRewritesThePendingPlaceholder() async {
        let callID = UUID()
        seedStep(callID: callID, toolName: ToolNames.uiType)

        var conversation: [ChatMessage] = []
        let outcome = await run(
            callID: callID, toolName: ToolNames.uiType,
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            signal: .computerUse(.typeText(text: "must not be typed", target: nil)),
            conversation: &conversation)

        XCTAssertFalse(outcome.shouldStopForSupervisor)
        let card = card(callID)
        XCTAssertEqual(card?.isError, true,
                       "no Accessibility grant is a failure, not a pending state")
        XCTAssertFalse(card?.resultJSON?.contains("pending") ?? true,
                       "the interim placeholder must be replaced; got \(card?.resultJSON ?? "nil")")

        XCTAssertEqual(conversation.count, 1, "one tool result per tool call")
        XCTAssertEqual(conversation.first?.role, .tool)
        XCTAssertTrue((conversation.first?.content ?? "").contains(#""ok":false"#),
                      "got: \(conversation.first?.content ?? "nil")")
    }

    /// Same skip/compensate pair as the other two. It matters more here: a `ui_click` whose
    /// PLACEHOLDER reached the tracker would look like a distinct successful call every time,
    /// so a model clicking the same dead pixel forever would never trip the repetition detector.
    func testComputerUseSignal_trackerRecordsTheFinalEnvelope_neverThePlaceholder() async {
        let callID = UUID()
        seedStep(callID: callID, toolName: ToolNames.uiClick)

        var conversation: [ChatMessage] = []
        _ = await run(
            callID: callID, toolName: ToolNames.uiClick,
            outputJSON: #"{"ok":true,"data":{"status":"pending"}}"#,
            signal: .computerUse(.click(x: 10, y: 10, button: "left", double: false, target: nil)),
            conversation: &conversation)

        let recorded = tracker.recentCalls(limit: 10)
        XCTAssertEqual(recorded.count, 1,
                       "exactly one tracker entry — skipped pre-record, recorded by the finalizer")
        XCTAssertFalse(recorded.first?.resultJSON.contains("pending") ?? true,
                       "got \(recorded.first?.resultJSON ?? "nil")")
        XCTAssertEqual(recorded.first?.wasSuccessful, false,
                       "a refused click recorded as success re-arms the loop detector")
    }

    // MARK: - Mixed batch

    /// A deferred signal beside a plain result: the plain one takes the regular
    /// path (tracker + `[CALL]/[RESULT]` persistence), the deferred one is skipped
    /// there and finalized separately. Each tool call must end with exactly one
    /// tool result, in order — the pairing the chat protocol requires.
    func testMixedBatch_plainAndDeferred_eachGetExactlyOneToolResult() async {
        let plainID = UUID()
        let visionID = UUID()
        let plainCall = StepToolCall(
            id: plainID, providerID: "tc_plain", name: ToolNames.readFile,
            argumentsJSON: #"{"path":"a.txt"}"#, resultJSON: nil, isError: false)
        let visionCall = StepToolCall(
            id: visionID, providerID: "tc_vision", name: ToolNames.analyzeImage,
            argumentsJSON: #"{"path":"s.png"}"#, resultJSON: nil, isError: false)
        seedStep(calls: [plainCall, visionCall])
        mockDelegate.visionLLMConfig = nil

        var conversation: [ChatMessage] = []
        let task = mockDelegate.taskToMutate!
        _ = await service.processToolResults(
            resolvedToolCalls: [plainCall, visionCall],
            results: [
                ToolExecutionResult(
                    providerID: "tc_plain", toolName: ToolNames.readFile,
                    argumentsJSON: #"{"path":"a.txt"}"#,
                    outputJSON: #"{"ok":true,"data":{"content":"hello"}}"#, isError: false),
                ToolExecutionResult(
                    providerID: "tc_vision", toolName: ToolNames.analyzeImage,
                    argumentsJSON: #"{"path":"s.png"}"#,
                    outputJSON: #"{"ok":true,"data":{"status":"analyzing"}}"#, isError: false,
                    signal: .visionAnalysis(imagePath: "s.png", prompt: "p")),
            ],
            stepID: stepID, roleForMessage: .softwareEngineer, task: task,
            runIndex: 0, stepIndex: 0, assistantContent: "",
            client: InertVisionClient(), config: LLMConfig(), tracker: tracker,
            memoryStore: memoryStore,
            conversationMessages: &conversation, networkLogger: nil)

        let toolTurns = conversation.filter { $0.role == .tool }
        XCTAssertEqual(toolTurns.count, 2,
                       "one tool result per call — got \(conversation.map { "\($0.role):\(($0.content ?? "").prefix(30))" })")
        XCTAssertEqual(toolTurns.map(\.toolCallID), ["tc_plain", "tc_vision"],
                       "results must stay paired with their calls, in order")

        let recorded = tracker.recentCalls(limit: 10)
        XCTAssertEqual(recorded.count, 2,
                       "the plain call is recorded pre-finalize, the vision call by its finalizer")
        XCTAssertEqual(Set(recorded.map(\.toolName)), [ToolNames.readFile, ToolNames.analyzeImage])
    }

    // MARK: - Helpers

    private func payload(query: String) throws -> ExploratorySearchPayload {
        try ExploratorySearchPayload(
            query: query, mode: .substring, paths: nil, fileGlob: nil,
            contextBefore: 0, contextAfter: 0, maxResults: 10)
    }

    private func run(
        callID: UUID,
        toolName: String,
        outputJSON: String,
        signal: ToolSignal,
        conversation: inout [ChatMessage]
    ) async -> LLMExecutionService.ToolResultsOutcome {
        let task = mockDelegate.taskToMutate!
        let call = task.runs[0].steps[0].toolCalls.first { $0.id == callID }!
        return await service.processToolResults(
            resolvedToolCalls: [call],
            results: [ToolExecutionResult(
                providerID: call.providerID, toolName: toolName,
                argumentsJSON: call.argumentsJSON, outputJSON: outputJSON,
                isError: false, signal: signal)],
            stepID: stepID, roleForMessage: .softwareEngineer, task: task,
            runIndex: 0, stepIndex: 0, assistantContent: "",
            client: InertVisionClient(), config: LLMConfig(), tracker: tracker,
            memoryStore: memoryStore,
            conversationMessages: &conversation, networkLogger: nil)
    }

    private func card(_ id: UUID) -> StepToolCall? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }?
            .toolCalls.first { $0.id == id }
    }

    private func seedStep(callID: UUID, toolName: String) {
        seedStep(calls: [StepToolCall(
            id: callID, providerID: "tc_1", name: toolName, argumentsJSON: "{}",
            resultJSON: nil, isError: false)])
    }

    private func seedStep(calls: [StepToolCall]) {
        let step = StepExecution(
            id: stepID, role: .softwareEngineer, title: "Worker",
            status: .running, toolCalls: calls)
        let task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "b", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }
}

// MARK: - Inert client

/// Every path under test rejects before an LLM request. A client that DID stream
/// here would mean the finalizer skipped its own guard — which is why this stub
/// finishes empty rather than scripting a reply.
private final class InertVisionClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
