import XCTest

@testable import NanoTeams

/// Two seams that share one shape — "a tool signal suspends the tool loop, something outside the
/// loop answers, and the answer has to land on exactly the right step":
///
///  1. `LLMExecutionService+Vision.appendVisionResult` — the `.visionAnalysis` finalizer. Every
///     case here drives the REAL entry point (`loadVisionImage` is `private`, so the sandbox /
///     size / MIME rules are reached only through it) and asserts on the three things that leave
///     it: the in-memory `conversationMessages`, the persisted `llmConversation` + tool card, and
///     the loop-detector tracker.
///  2. `LLMExecutionService+ComputerUseApproval` — the one-shot `ApprovalWaiter` registry. The
///     safety-critical property is that the continuation resumes EXACTLY once: a double tap, a
///     Pause landing on an already-resolved waiter, or a teardown racing a tap must be absorbed,
///     never a double `resume` (which traps the process, not the test).
///
/// SAFETY: no network, no LM Studio, no screen capture, no CGEvent. The vision client is a local
/// stub; the approval tests never touch the gate's OS-facing half.
///
/// `@MainActor` + `async` test methods per the documented sync-test abort gotcha (constructing the
/// `@MainActor` `LLMExecutionService` from a synchronous test method aborts on this Xcode); `setUp`
/// is immune. `conversationMessages` is always a LOCAL `var` — Swift 6 refuses to pass an
/// actor-isolated stored property `inout` to an `async` call.
@MainActor
final class VisionAndComputerUseApprovalFlowTests: XCTestCase {

    var service: LLMExecutionService!
    var delegate: MockLLMExecutionDelegate!
    // Class-level, never a local in a @MainActor test body.
    private var tracker: ToolCallTracker!
    private var client: StubVisionClient!
    private var tempDir: URL!

    // Static so the fixture builders below need no `self`. `setUp()` is
    // inherited nonisolated from XCTestCase, so calling an instance method of
    // this @MainActor class from it makes the compiler send `self` across an
    // isolation boundary ("sending 'self' risks causing data races").
    // `nonisolated` because the class is @MainActor and these are read from the
    // nonisolated static builder below. Legal for a `let` of a Sendable type.
    nonisolated private static let stepIDValue = "software_engineer"
    nonisolated private static let taskIDValue = 7
    nonisolated private static let toolCallIDValue = UUID()
    nonisolated private static let providerIDValue = "call_v1"

    // STORED (not computed) so every test body reads unchanged AND `setUp` can
    // read them: a stored `let` of a Sendable type is readable from the
    // inherited-nonisolated `setUp()`, whereas a computed var is a method call
    // and would reintroduce the very "sending 'self'" error this fixes.
    private let stepID = VisionAndComputerUseApprovalFlowTests.stepIDValue
    private let taskID = VisionAndComputerUseApprovalFlowTests.taskIDValue
    private let toolCallID = VisionAndComputerUseApprovalFlowTests.toolCallIDValue
    private let providerID = VisionAndComputerUseApprovalFlowTests.providerIDValue

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.snapshot = nil
        delegate.workFolderURL = tempDir
        service.attach(delegate: delegate)

        tracker = ToolCallTracker()
        client = StubVisionClient()

        // Live execution: everything the finalizer persists is gated on this entry existing.
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] =
            LLMExecutionService.StepExecutionState()
        delegate.taskToMutate = Self.makeTask()
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        service = nil
        delegate = nil
        tracker = nil
        client = nil
        MonotonicClock.shared.reset()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A task whose latest run carries the step AND the interim `{"status":"analyzing"}` tool card
    /// the finalizer is supposed to overwrite. `TaskMutationService.updateToolCallResult` looks the
    /// card up by `toolCallID`, so it must exist or the persist half is silently a no-op.
    /// `nonisolated static` for the same reason the constants above are static:
    /// it is called from the inherited-nonisolated `setUp()`.
    nonisolated private static func makeTask() -> NTMSTask {
        let call = StepToolCall(
            id: toolCallIDValue,
            providerID: providerIDValue,
            name: ToolNames.analyzeImage,
            argumentsJSON: #"{"path":"shot.png","prompt":"Describe it"}"#,
            resultJSON: makeSuccessEnvelope(data: ["status": "analyzing", "path": "shot.png"]),
            isError: false)
        let step = StepExecution(
            id: stepIDValue, role: .softwareEngineer, title: "Engineer",
            status: .running, toolCalls: [call])
        return NTMSTask(
            id: taskIDValue, title: "t", supervisorTask: "g", runs: [Run(id: 0, steps: [step])])
    }

    private func visionResult(path: String, prompt: String = "Describe it") -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: providerID,
            toolName: ToolNames.analyzeImage,
            argumentsJSON: #"{"path":"\#(path)","prompt":"\#(prompt)"}"#,
            outputJSON: makeSuccessEnvelope(data: ["status": "analyzing", "path": path]),
            isError: false,
            signal: .visionAnalysis(imagePath: path, prompt: prompt))
    }

    @discardableResult
    private func writeImage(_ name: String, bytes: Data = Data("PNGBYTES".utf8)) -> Data {
        let url = tempDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: url)
        return bytes
    }

    /// Drives the real finalizer and hands back the conversation it built.
    private func runVision(_ result: ToolExecutionResult) async -> [ChatMessage] {
        var conversation: [ChatMessage] = []
        await service.appendVisionResult(
            result: result,
            toolCallID: toolCallID,
            stepID: stepID,
            taskID: taskID,
            client: client,
            config: LLMConfig(),
            networkLogger: nil,
            conversationMessages: &conversation,
            tracker: tracker)
        return conversation
    }

    // MARK: - Assertion helpers

    private func envelope(_ json: String?) -> [String: Any] {
        guard let json, let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private func errorMessage(_ json: String?) -> String {
        (envelope(json)["error"] as? [String: Any])?["message"] as? String ?? ""
    }

    private func errorCode(_ json: String?) -> String {
        (envelope(json)["error"] as? [String: Any])?["code"] as? String ?? ""
    }

    private func successData(_ json: String?) -> [String: Any] {
        envelope(json)["data"] as? [String: Any] ?? [:]
    }

    private var persistedStep: StepExecution? {
        delegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    private var persistedToolCard: StepToolCall? {
        persistedStep?.toolCalls.first { $0.id == toolCallID }
    }

    /// The interim card, unchanged — the shape every "nothing was recorded" case must leave behind.
    private func assertToolCardStillSaysAnalyzing(
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(persistedToolCard?.isAnalyzing, true, message, file: file, line: line)
    }

    // MARK: - Vision: the signal guard

    /// `appendVisionResult` is dispatched from a switch that also carries non-vision signals; the
    /// `guard case .visionAnalysis` is what stops it acting on one. Nothing at all may move.
    func testNonVisionSignal_isIgnoredEntirely() async {
        delegate.visionLLMConfig = LLMConfig()
        let notVision = ToolExecutionResult(
            providerID: providerID, toolName: ToolNames.askSupervisor,
            argumentsJSON: "{}", outputJSON: "{}", isError: false,
            signal: .supervisorQuestion("what now?"))

        let conversation = await runVision(notVision)

        XCTAssertTrue(conversation.isEmpty, "a non-vision signal must not append a tool turn")
        XCTAssertTrue(persistedStep?.llmConversation.isEmpty ?? false, "nothing may be persisted")
        assertToolCardStillSaysAnalyzing("the tool card must be untouched")
        XCTAssertEqual(client.streamChatCallCount, 0, "no vision call for a non-vision signal")
        XCTAssertTrue(tracker.recentCalls(limit: 10).isEmpty)
    }

    /// A result carrying NO signal at all takes the same arm.
    func testNilSignal_isIgnoredEntirely() async {
        delegate.visionLLMConfig = LLMConfig()
        let unsignalled = ToolExecutionResult(
            providerID: providerID, toolName: ToolNames.analyzeImage,
            argumentsJSON: "{}", outputJSON: "{}", isError: false)

        let conversation = await runVision(unsignalled)

        XCTAssertTrue(conversation.isEmpty)
        XCTAssertEqual(client.streamChatCallCount, 0)
    }

    // MARK: - Vision: the sub-model guard arms
    //
    // With Computer Use enabled (the shipped default is `.manual`, i.e. `isEnabled == true`) the
    // in-chat branch is still skipped because the stub's `modelSupportsVision` returns nil — the
    // documented "undeterminable probes fail toward the vision-model fallback" rule. Each of these
    // therefore exercises the sub-model path under a production-shaped policy.

    func testVisionNotConfigured_failsWithAnActionableEnvelope_andNeverCallsAModel() async {
        delegate.visionLLMConfig = nil  // Settings → Vision left blank
        writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png"))

        XCTAssertEqual(conversation.count, 1)
        XCTAssertEqual(conversation.first?.role, .tool)
        XCTAssertEqual(conversation.first?.toolCallID, providerID,
                       "the tool turn must answer the call the model made")
        XCTAssertEqual(errorCode(conversation.first?.content), ToolErrorCode.commandFailed.rawValue)
        let message = errorMessage(conversation.first?.content)
        XCTAssertTrue(message.hasPrefix("Vision analysis failed:"),
                      "every vision failure is wrapped, got: \(message)")
        XCTAssertTrue(message.contains("No vision model is configured"),
                      "the model must be told WHICH precondition is missing, got: \(message)")
        XCTAssertTrue(message.contains("supervisor"),
                      "the message must name a model-reachable remedy, got: \(message)")
        XCTAssertFalse(message.contains("Settings"),
                       "the model cannot open a Settings pane, got: \(message)")
        XCTAssertEqual(client.streamChatCallCount, 0, "no config → nothing to call")
    }

    func testNoWorkFolder_reportsTheMissingProjectRatherThanAMissingFile() async {
        delegate.visionLLMConfig = LLMConfig()
        delegate.workFolderURL = nil

        let conversation = await runVision(visionResult(path: "shot.png"))

        let message = errorMessage(conversation.first?.content)
        XCTAssertTrue(message.contains("No work folder available"),
                      "default storage must be named as the blocker, got: \(message)")
        XCTAssertEqual(client.streamChatCallCount, 0)
    }

    func testMissingImageFile_namesThePathTheModelAskedFor() async {
        delegate.visionLLMConfig = LLMConfig()
        // deliberately not written

        let conversation = await runVision(visionResult(path: "nope.png"))

        let message = errorMessage(conversation.first?.content)
        XCTAssertTrue(message.contains("Image file not found"), "got: \(message)")
        XCTAssertTrue(message.contains("nope.png"),
                      "the model must see which path failed so it can correct it, got: \(message)")
        XCTAssertEqual(client.streamChatCallCount, 0)
    }

    /// The unconfigured-Vision check runs BEFORE the file is read, so a run that is broken both
    /// ways reports the missing model, not the file. Ordering matters: blaming a path when the
    /// real blocker is an absent vision model sends the model chasing the wrong fix.
    func testUnconfiguredVisionBeatsAMissingFile() async {
        delegate.visionLLMConfig = nil

        let conversation = await runVision(visionResult(path: "also-missing.png"))

        let message = errorMessage(conversation.first?.content)
        XCTAssertTrue(message.contains("No vision model is configured"), "got: \(message)")
        XCTAssertFalse(message.contains("also-missing.png"),
                       "the file is never reached, so it must not be blamed: \(message)")
    }

    /// The size cap is `<=`, so `maxImageBytes` exactly is ACCEPTED and one byte more is refused.
    /// An off-by-one here silently rejects a legitimately-sized screenshot.
    func testImageSizeCap_isInclusiveAtTheBoundary() async {
        delegate.visionLLMConfig = LLMConfig()
        client.reply = "Looks fine."
        writeImage("at-cap.png", bytes: Data(repeating: 0x41, count: VisionConstants.maxImageBytes))
        writeImage("over-cap.png",
                   bytes: Data(repeating: 0x41, count: VisionConstants.maxImageBytes + 1))

        let atCap = await runVision(visionResult(path: "at-cap.png"))
        XCTAssertEqual(envelope(atCap.first?.content)["ok"] as? Bool, true,
                       "exactly the cap must be allowed through")
        XCTAssertEqual(successData(atCap.first?.content)["analysis"] as? String, "Looks fine.")

        let overCap = await runVision(visionResult(path: "over-cap.png"))
        let message = errorMessage(overCap.first?.content)
        XCTAssertTrue(message.contains("Image too large"), "got: \(message)")
        XCTAssertEqual(client.streamChatCallCount, 1,
                       "the oversized image must be refused before any model call")
    }

    /// The sandbox is the same one the file tools use: `..` never escapes the work folder, and the
    /// refusal reaches the model as a vision failure rather than being swallowed.
    func testParentTraversal_isRefusedBySandbox() async {
        delegate.visionLLMConfig = LLMConfig()

        let conversation = await runVision(visionResult(path: "../outside.png"))

        let message = errorMessage(conversation.first?.content)
        XCTAssertTrue(message.hasPrefix("Vision analysis failed:"), "got: \(message)")
        XCTAssertTrue(message.contains("Parent traversal"), "got: \(message)")
        XCTAssertEqual(client.streamChatCallCount, 0)
    }

    /// `.nanoteams/internal` is hidden from every LLM-facing tool, and the refusal is deliberately
    /// indistinguishable from absence ("File not found.") — it must NOT echo the path back, which
    /// would confirm the internal layout exists.
    func testInternalDirectoryImage_isRefusedAsAPlainNotFound() async {
        delegate.visionLLMConfig = LLMConfig()
        writeImage(".nanoteams/internal/secret.png")

        let conversation = await runVision(visionResult(path: ".nanoteams/internal/secret.png"))

        let message = errorMessage(conversation.first?.content)
        XCTAssertTrue(message.contains("File not found"), "got: \(message)")
        XCTAssertFalse(message.contains("secret.png"),
                       "the restricted-path refusal must not echo the internal path: \(message)")
        XCTAssertEqual(client.streamChatCallCount, 0,
                       "an internal file must never be shipped to a model")
    }

    // MARK: - Vision: MIME resolution + the bytes actually sent

    func testMimeType_isResolvedFromTheExtension() async {
        delegate.visionLLMConfig = LLMConfig()
        client.reply = "ok"
        for (ext, mime) in [("png", "image/png"), ("jpg", "image/jpeg"),
                            ("jpeg", "image/jpeg"), ("gif", "image/gif"),
                            ("webp", "image/webp"), ("bmp", "image/bmp")] {
            let name = "pic.\(ext)"
            let bytes = writeImage(name, bytes: Data("BYTES-\(ext)".utf8))

            _ = await runVision(visionResult(path: name))

            XCTAssertEqual(client.lastImage?.mimeType, mime, "\(ext) must map to \(mime)")
            XCTAssertEqual(client.lastImage?.base64Data, bytes.base64EncodedString(),
                           "the file's own bytes must be what reaches the vision model")
        }
    }

    /// An extension outside `VisionConstants.mimeTypes` degrades to `image/jpeg` rather than
    /// failing. Characterization, not a recommendation: the REAL rejection of unsupported formats
    /// lives in `AnalyzeImageTool.handle`, which never emits the signal for a `.tiff` — so this
    /// arm is only reachable by a hand-built signal, and its `?? "image/jpeg"` is a deliberate
    /// last-resort default.
    func testUnknownExtension_fallsBackToJpegRatherThanFailing() async {
        delegate.visionLLMConfig = LLMConfig()
        client.reply = "ok"
        writeImage("pic.tiff")

        let conversation = await runVision(visionResult(path: "pic.tiff"))

        XCTAssertEqual(client.lastImage?.mimeType, "image/jpeg")
        XCTAssertEqual(envelope(conversation.first?.content)["ok"] as? Bool, true)
    }

    /// The vision sub-model gets a fresh two-message chat every call — no step history leaks into
    /// it, and the prompt the model wrote is the user turn.
    func testSubModelCall_isAFreshTwoTurnChatCarryingThePrompt() async {
        delegate.visionLLMConfig = LLMConfig()
        client.reply = "A red button."
        writeImage("shot.png")

        _ = await runVision(visionResult(path: "shot.png", prompt: "What is highlighted?"))

        XCTAssertEqual(client.lastMessages.count, 2, "system + one user turn, nothing else")
        XCTAssertEqual(client.lastMessages.first?.role, .system)
        XCTAssertEqual(client.lastMessages.last?.role, .user)
        XCTAssertEqual(client.lastMessages.last?.content, "What is highlighted?")
        XCTAssertNil(client.lastMessages.first?.imageContent,
                     "the image rides the user turn, not the system prompt")
    }

    // MARK: - Vision: the success commit

    func testSuccess_commitsToAllThreeSurfaces() async {
        delegate.visionLLMConfig = LLMConfig()
        client.reply = "A red button."
        writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png"))

        // 1. the in-memory conversation the tool loop will send next iteration
        XCTAssertEqual(conversation.count, 1)
        XCTAssertEqual(conversation.first?.role, .tool)
        XCTAssertEqual(conversation.first?.toolCallID, providerID)
        XCTAssertEqual(envelope(conversation.first?.content)["ok"] as? Bool, true)
        XCTAssertEqual(successData(conversation.first?.content)["analysis"] as? String, "A red button.")
        XCTAssertEqual(successData(conversation.first?.content)["path"] as? String, "shot.png",
                       "the envelope must say which image was analysed")

        // 2. the persisted transcript
        let persisted = persistedStep?.llmConversation ?? []
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.role, .tool)
        XCTAssertTrue(persisted.first?.content.contains("[CALL] \(ToolNames.analyzeImage)") ?? false,
                      "got: \(persisted.first?.content ?? "")")
        XCTAssertTrue(persisted.first?.content.contains("[RESULT]") ?? false)
        XCTAssertTrue(persisted.first?.content.contains("A red button.") ?? false)

        // 3. the activity-feed card: the interim placeholder is REPLACED, not appended to
        XCTAssertEqual(persistedStep?.toolCalls.count, 1, "no second card may appear")
        XCTAssertEqual(persistedToolCard?.isError, false)
        XCTAssertEqual(persistedToolCard?.isAnalyzing, false,
                       "the `analyzing` placeholder must be gone once the result lands")
        XCTAssertEqual(successData(persistedToolCard?.resultJSON)["analysis"] as? String, "A red button.")

        // …and the loop detector, which upstream `processToolResults` deliberately skips for
        // `.visionAnalysis` (it only holds the placeholder at that point).
        let tracked = tracker.recentCalls(limit: 10)
        XCTAssertEqual(tracked.count, 1)
        XCTAssertEqual(tracked.first?.toolName, ToolNames.analyzeImage)
        XCTAssertEqual(tracked.first?.wasSuccessful, true)
        XCTAssertTrue(tracked.first?.resultJSON.contains("A red button.") ?? false,
                      "the tracker must hold the REAL envelope, not the placeholder")
    }

    func testSuccess_stripsModelSentinelsAndTrimsTheAnalysis() async {
        delegate.visionLLMConfig = LLMConfig()
        client.reply = "  <|channel|>final<|message|>A red button.  "
        writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png"))

        // RED: revert the service to the bare `ModelTokenCleaner.clean` → "finalA red button."
        //
        // This test previously pinned that concatenation, reasoning that "a cleaner that also
        // swallowed inter-token text would be deleting model output". True of a greedy
        // cleaner; false of `cleanHarmonyTokens`, whose four patterns remove only an
        // ENUMERATED protocol keyword immediately following its own token. "final" there is
        // Harmony header syntax, and the analysis is read back as prose by the model that
        // asked for it, so the concatenation was debris being pinned as a contract.
        XCTAssertEqual(successData(conversation.first?.content)["analysis"] as? String,
                       "A red button.",
                       "the channel header, keyword included, is not part of the analysis")
    }

    /// RED: drop the `analysisText.isEmpty` arm in `appendVisionResult` → `ok:true` with an
    /// empty `analysis`.
    ///
    /// This test used to assert exactly that, on the grounds that the model gets "an honest
    /// 'nothing came back' rather than a fabricated failure". Neither half survives contact
    /// with the consumer: `ok:true` does not say "nothing came back", it says the tool
    /// succeeded — and the only code that reads the flag, `ToolTurnProductivity.classify`
    /// via `effectiveResults`, uses it to decide whether the model ACTED, so an empty
    /// analysis re-armed `maxNonProductiveTurns` and a silent vision model could be asked
    /// forever under `maxToolIterations == 0`. Nor is the failure fabricated: the analysis
    /// really did produce nothing. Same rule as every other tool since wave 19 — the
    /// envelope reports the outcome, not the attempt.
    func testEmptyAnalysis_isReportedAsAFailure() async {
        delegate.visionLLMConfig = LLMConfig()
        client.reply = "   "
        writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png"))

        XCTAssertEqual(envelope(conversation.first?.content)["ok"] as? Bool, false)
        XCTAssertEqual(errorCode(conversation.first?.content), ToolErrorCode.commandFailed.rawValue)
        XCTAssertEqual(
            tracker.recentCalls(limit: 10).first?.wasSuccessful, false,
            "an empty analysis must not re-arm the no-tool ceiling")
    }

    // MARK: - Vision: failure + cancellation

    func testTransportFailure_isReportedWithTheUnderlyingReason_andRecordedAsAnError() async {
        delegate.visionLLMConfig = LLMConfig()
        client.failure = StubVisionFailure()
        writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png"))

        XCTAssertEqual(errorCode(conversation.first?.content), ToolErrorCode.commandFailed.rawValue)
        let message = errorMessage(conversation.first?.content)
        XCTAssertTrue(message.contains("the vision server exploded"),
                      "the underlying reason must survive the wrapper, got: \(message)")
        XCTAssertEqual(persistedToolCard?.isError, true, "the feed card must render red")
        XCTAssertEqual(tracker.recentCalls(limit: 10).first?.wasSuccessful, false)
    }

    /// Pause cancels the step mid-analysis. `catch is CancellationError` returns WITHOUT recording
    /// anything — a paused step must not be left carrying a fabricated failure that the model then
    /// tries to recover from on resume.
    func testCancellation_leavesNoRecordAtAll() async {
        delegate.visionLLMConfig = LLMConfig()
        client.failure = CancellationError()
        writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png"))

        XCTAssertTrue(conversation.isEmpty, "a cancelled analysis appends no tool turn")
        XCTAssertTrue(persistedStep?.llmConversation.isEmpty ?? false)
        assertToolCardStillSaysAnalyzing(
            "a cancelled analysis must leave the interim card, not an error")
        XCTAssertTrue(tracker.recentCalls(limit: 10).isEmpty,
                      "nothing happened, so the loop detector must see nothing")
    }

    /// RED: drop the `thinkingDelta` accumulation in `VisionAnalysisService.analyze` → the
    /// error arm above fires and the real description is lost.
    ///
    /// The two tests are a pair on purpose: the fix that makes silence loud must not make a
    /// reasoning-only answer loud too, or it trades a wrong success for a wrong failure.
    func testReasoningOnlyAnalysis_commitsAsASuccess() async {
        delegate.visionLLMConfig = LLMConfig()
        client.reply = ""
        client.reasoning = "A login form with two text fields."
        writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png"))

        XCTAssertEqual(
            successData(conversation.first?.content)["analysis"] as? String,
            "A login form with two text fields.")
        XCTAssertEqual(persistedToolCard?.isError, false)
    }

    // MARK: - Vision: the post-teardown write barrier

    /// The step was torn down (Pause / supersede / folder switch) while the analysis was in
    /// flight. `isExecutionLive` is the write barrier: the late result must not land on whatever
    /// currently answers to this (taskID, stepID) — task ids are reused across folders.
    func testPostTeardown_persistsNothing() async {
        delegate.visionLLMConfig = LLMConfig()
        client.reply = "A red button."
        writeImage("shot.png")
        service.executionStates[TaskStepKey(taskID: taskID, stepID: stepID)] = nil

        let conversation = await runVision(visionResult(path: "shot.png"))

        XCTAssertEqual(conversation.count, 1,
                       "the caller's own in-memory array is a local it owns; only PERSISTENCE is barred")
        XCTAssertTrue(persistedStep?.llmConversation.isEmpty ?? false,
                      "no orphaned transcript entry may be written after teardown")
        assertToolCardStillSaysAnalyzing("no orphaned card update may be written after teardown")
    }

    // MARK: - Vision: the unified in-chat branch

    /// Computer Use on + the main model auto-detected as vision-capable + a readable file ⇒ the
    /// image goes straight into the MAIN chat and the Vision sub-model is never called.
    func testInChat_whenMainModelSeesImages_feedsTheImageAndSkipsTheSubModel() async {
        delegate.computerUsePolicy = ComputerUsePolicy(mode: .manual)
        delegate.visionLLMConfig = LLMConfig()  // configured, and still must not be used
        client.visionSupport = true
        let bytes = writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png", prompt: "What is this?"))

        XCTAssertEqual(client.streamChatCallCount, 0,
                       "one brain: the sub-model must not be consulted when the main model can see")

        XCTAssertEqual(conversation.count, 2, "the tool envelope, then the image-bearing user turn")
        XCTAssertEqual(conversation[0].role, .tool)
        XCTAssertEqual(conversation[0].toolCallID, providerID)
        XCTAssertEqual(envelope(conversation[0].content)["ok"] as? Bool, true)
        XCTAssertTrue(
            (successData(conversation[0].content)["status"] as? String ?? "")
                .contains("Image attached below"),
            "the envelope must tell the model where to look")

        XCTAssertEqual(conversation[1].role, .user)
        XCTAssertEqual(conversation[1].content, "[Image for tool_call \(providerID)] What is this?",
                       "the caption must tie the image back to the call and carry the prompt")
        XCTAssertEqual(conversation[1].imageContent?.count, 1)
        XCTAssertEqual(conversation[1].imageContent?.first?.base64Data, bytes.base64EncodedString())
        XCTAssertEqual(conversation[1].imageContent?.first?.mimeType, "image/png")
    }

    /// The persisted copy of that image turn is REDACTED — base64 lives only in the single
    /// in-memory send, never in `task.json`.
    func testInChat_persistsOnlyARedactedPlaceholder_neverTheBase64() async {
        delegate.computerUsePolicy = ComputerUsePolicy(mode: .manual)
        delegate.visionLLMConfig = LLMConfig()
        client.visionSupport = true
        let bytes = writeImage("shot.png")

        _ = await runVision(visionResult(path: "shot.png"))

        let persisted = persistedStep?.llmConversation ?? []
        XCTAssertEqual(persisted.count, 2, "the tool turn plus the redacted image turn")
        XCTAssertEqual(persisted[1].role, .user)
        XCTAssertTrue(persisted[1].content.hasPrefix("[screenshot "),
                      "got: \(persisted[1].content)")
        XCTAssertFalse(persisted[1].content.contains(bytes.base64EncodedString()),
                       "image bytes must never reach disk")
        XCTAssertEqual(persistedToolCard?.isError, false,
                       "the in-chat branch still commits the tool card")
    }

    /// Computer Use off ⇒ the in-chat branch is not even considered, no matter how capable the
    /// main model is. This is what keeps `analyze_image` unchanged for everyone who never enabled
    /// the feature.
    func testInChat_notTakenWhenComputerUseIsOff() async {
        delegate.computerUsePolicy = ComputerUsePolicy(mode: .off)
        delegate.visionLLMConfig = LLMConfig()
        client.visionSupport = true
        client.reply = "A red button."
        writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png"))

        XCTAssertEqual(client.streamChatCallCount, 1, "the sub-model path must still be used")
        XCTAssertEqual(conversation.count, 1, "no image turn is appended")
        XCTAssertNil(conversation.first?.imageContent)
        XCTAssertEqual(successData(conversation.first?.content)["analysis"] as? String, "A red button.")
    }

    /// An UNDETERMINABLE capability probe (the `LLMClient` default, and what every server without
    /// capability metadata returns) must fail toward the sub-model, never assume vision.
    func testInChat_notTakenWhenCapabilityIsUndeterminable() async {
        delegate.computerUsePolicy = ComputerUsePolicy(mode: .manual)
        delegate.visionLLMConfig = LLMConfig()
        client.visionSupport = nil
        client.reply = "A red button."
        writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png"))

        XCTAssertEqual(client.streamChatCallCount, 1)
        XCTAssertNil(conversation.first?.imageContent)
    }

    /// An explicit "no" is the same answer as "don't know" for routing purposes.
    func testInChat_notTakenWhenMainModelExplicitlyCannotSeeImages() async {
        delegate.computerUsePolicy = ComputerUsePolicy(mode: .manual)
        delegate.visionLLMConfig = LLMConfig()
        client.visionSupport = false
        client.reply = "A red button."
        writeImage("shot.png")

        let conversation = await runVision(visionResult(path: "shot.png"))

        XCTAssertEqual(client.streamChatCallCount, 1)
        XCTAssertNil(conversation.first?.imageContent)
    }

    /// The in-chat branch reads the file with `try?`. A read failure must FALL THROUGH to the
    /// sub-model path so the accurate typed reason still reaches the model — not be swallowed.
    func testInChat_unreadableFile_fallsThroughToTheAccurateSubModelError() async {
        delegate.computerUsePolicy = ComputerUsePolicy(mode: .manual)
        delegate.visionLLMConfig = LLMConfig()
        client.visionSupport = true
        // file deliberately absent

        let conversation = await runVision(visionResult(path: "gone.png"))

        XCTAssertEqual(conversation.count, 1, "no image turn — there was no image")
        let message = errorMessage(conversation.first?.content)
        XCTAssertTrue(message.contains("Image file not found"), "got: \(message)")
        XCTAssertTrue(message.contains("gone.png"), "got: \(message)")
        XCTAssertEqual(client.streamChatCallCount, 0,
                       "there is nothing to describe, so no model call either")
    }

    // MARK: - Computer-use approval: the one-shot waiter registry

    private func approvalRequest(
        actionKey: String = "action-1",
        taskID: Int? = nil,
        stepID: String? = nil
    ) -> ComputerUseApprovalRequest {
        ComputerUseApprovalRequest(
            taskID: taskID ?? self.taskID,
            stepID: stepID ?? self.stepID,
            actionKey: actionKey,
            actionSummary: "click (10, 10)",
            targetApp: "ZZZPhantomApp",
            offerAlways: true,
            screenshotBase64: nil,
            targetX: 10,
            targetY: 10,
            createdAt: MonotonicClock.shared.now())
    }

    /// Starts the real `awaitComputerUseApproval` and waits until its waiter is REGISTERED (which
    /// is also when the card is published). Returns the still-suspended task.
    private func hold(
        _ request: ComputerUseApprovalRequest
    ) async -> Task<ComputerUseApprovalDecision, Never> {
        let running = Task { [service, request] in
            await service!.awaitComputerUseApproval(request: request)
        }
        let key = TaskStepKey(taskID: request.taskID, stepID: request.stepID)
        for _ in 0..<500 {
            if service.computerUseApprovalWaiters[key]?[request.actionKey] != nil { return running }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the approval waiter was never registered")
        running.cancel()
        return running
    }

    func testApproval_publishesTheCard_thenClearsItAndTheRegistryOnResolution() async {
        let request = approvalRequest()
        let key = TaskStepKey(taskID: taskID, stepID: stepID)

        let running = await hold(request)
        XCTAssertEqual(delegate.computerUseApprovalBeganRequests.count, 1,
                       "the card must be published while the loop is suspended")
        XCTAssertEqual(delegate.computerUseApprovalBeganRequests.first?.actionKey, "action-1")

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "action-1", decision: .allow)
        let decision = await running.value

        XCTAssertEqual(decision, .allow)
        XCTAssertNil(service.computerUseApprovalWaiters[key],
                     "the last waiter for a step must take the whole key with it")
        XCTAssertTrue(delegate.computerUseApprovalBeganRequests.isEmpty,
                      "`computerUseApprovalDidEnd` must retire the published card")
    }

    /// Every decision reaches the gate verbatim — `alwaysAllowApp` must not be flattened to
    /// `allow` in transit, or the per-run grant would never be recorded.
    func testApproval_deliversEachDecisionVerbatim() async {
        for expected in [ComputerUseApprovalDecision.allow, .deny, .alwaysAllowApp] {
            let request = approvalRequest(actionKey: "k-\(expected)")
            let running = await hold(request)
            service.resolveComputerUseApproval(
                taskID: taskID, stepID: stepID, actionKey: request.actionKey, decision: expected)
            let decision = await running.value
            XCTAssertEqual(decision, expected)
        }
    }

    /// The safety-critical property: the continuation resumes EXACTLY once. A double tap (or a tap
    /// racing a teardown) hits the same still-registered waiter, and the second call must be
    /// absorbed. Without the `settled` guard this is a double `resume` — a process trap, not a
    /// test failure.
    func testApproval_secondResolveIsAbsorbed_andTheFirstDecisionWins() async {
        let request = approvalRequest()
        let running = await hold(request)

        // No `await` between these two: the suspended task cannot run in between, so both land on
        // the same waiter — exactly the double-tap shape.
        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "action-1", decision: .allow)
        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "action-1", decision: .deny)

        let decision = await running.value
        XCTAssertEqual(decision, .allow, "first resolution wins; the second is a no-op")
    }

    /// A tap arriving AFTER the await has already finished (the card was still on screen when the
    /// user pressed it) must be a no-op, not a crash.
    func testApproval_resolveAfterCompletion_isANoOp() async {
        let request = approvalRequest()
        let running = await hold(request)
        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "action-1", decision: .allow)
        _ = await running.value

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "action-1", decision: .deny)

        XCTAssertNil(service.computerUseApprovalWaiters[TaskStepKey(taskID: taskID, stepID: stepID)])
    }

    /// Nobody is waiting on any of these ids. Documented contract: "no-op if no waiter is
    /// registered — a double-tap or a tap after Pause can't crash."
    func testApproval_resolvingAnUnknownIdentity_isANoOp() async {
        service.resolveComputerUseApproval(
            taskID: 999, stepID: "ghost", actionKey: "nobody", decision: .allow)
        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "nobody", decision: .allow)
        XCTAssertTrue(service.computerUseApprovalWaiters.isEmpty)
    }

    /// A decision aimed at the wrong task, the wrong step, or the wrong action must not resolve a
    /// live waiter. Task ids are reused across work folders, so a mis-keyed tap would approve an
    /// action the human never saw. The proof is the DECISION: a leak would surface as `.deny`.
    func testApproval_misKeyedDecisionsCannotResolveALiveWaiter() async {
        let request = approvalRequest()
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let running = await hold(request)

        service.resolveComputerUseApproval(
            taskID: taskID + 1, stepID: stepID, actionKey: "action-1", decision: .deny)
        service.resolveComputerUseApproval(
            taskID: taskID, stepID: "other_role", actionKey: "action-1", decision: .deny)
        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "action-2", decision: .deny)
        // Give any stray resumption a chance to actually land before checking.
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertNotNil(service.computerUseApprovalWaiters[key]?["action-1"],
                        "the real waiter must still be held")
        XCTAssertEqual(delegate.computerUseApprovalBeganRequests.count, 1,
                       "the card must still be on screen")

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "action-1", decision: .allow)
        let decision = await running.value
        XCTAssertEqual(decision, .allow, "a mis-keyed deny must never have been delivered")
    }

    /// Pause cancels the step's task while an action is held ⇒ `.deny`. Fail-safe: an unapproved
    /// OS action is never run.
    func testApproval_cancellationResolvesAsDeny() async {
        let request = approvalRequest()
        let running = await hold(request)

        running.cancel()
        let decision = await running.value

        XCTAssertEqual(decision, .deny, "a cancelled approval denies, it never runs")
        XCTAssertNil(service.computerUseApprovalWaiters[TaskStepKey(taskID: taskID, stepID: stepID)],
                     "the cancelled waiter must still be unregistered")
    }

    /// Per-step teardown (`failPendingComputerUseApprovals`, reached from `clearBashState` on every
    /// step-completion / cancel path) resolves everything still held with `.deny` and drops the key.
    func testApproval_perStepTeardown_deniesEveryHeldActionAndDropsTheKey() async {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let first = await hold(approvalRequest(actionKey: "a"))
        let second = await hold(approvalRequest(actionKey: "b"))
        XCTAssertEqual(service.computerUseApprovalWaiters[key]?.count, 2)

        service.failPendingComputerUseApprovals(stepID: stepID, taskID: taskID)

        let firstDecision = await first.value
        let secondDecision = await second.value
        XCTAssertEqual(firstDecision, .deny)
        XCTAssertEqual(secondDecision, .deny)
        XCTAssertNil(service.computerUseApprovalWaiters[key])
    }

    /// Same teardown reached through the shared per-step entry point the step lifecycle actually
    /// calls, so a refactor that drops the computer-use half of `clearBashState` is caught.
    func testApproval_clearBashState_alsoDeniesHeldComputerUseActions() async {
        let running = await hold(approvalRequest())

        service.clearBashState(stepID: stepID, taskID: taskID)

        let decision = await running.value
        XCTAssertEqual(decision, .deny)
        XCTAssertNil(service.computerUseApprovalWaiters[TaskStepKey(taskID: taskID, stepID: stepID)])
    }

    /// Teardown of ANOTHER step must not disturb this one — `executionStates.removeAll()`-style
    /// blanket clears are what leak decisions across steps.
    func testApproval_teardownOfADifferentStep_leavesThisWaiterHeld() async {
        let running = await hold(approvalRequest())

        service.failPendingComputerUseApprovals(stepID: "some_other_role", taskID: taskID)
        service.failPendingComputerUseApprovals(stepID: stepID, taskID: taskID + 1)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertNotNil(
            service.computerUseApprovalWaiters[TaskStepKey(taskID: taskID, stepID: stepID)]?["action-1"])

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "action-1", decision: .allow)
        let decision = await running.value
        XCTAssertEqual(decision, .allow)
    }

    /// Resolving one of two concurrently-held actions on the same step must leave the other held —
    /// and the step's key must survive until the LAST one resolves.
    func testApproval_resolvingOneOfTwoLeavesTheOtherHeld() async {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let first = await hold(approvalRequest(actionKey: "a"))
        let second = await hold(approvalRequest(actionKey: "b"))

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "a", decision: .allow)
        let firstDecision = await first.value

        XCTAssertEqual(firstDecision, .allow)
        XCTAssertNotNil(service.computerUseApprovalWaiters[key]?["b"],
                        "the sibling action must still be held")
        XCTAssertNil(service.computerUseApprovalWaiters[key]?["a"], "the resolved one is retired")
        XCTAssertEqual(delegate.computerUseApprovalBeganRequests.count, 1,
                       "only the resolved card is retired")

        service.resolveComputerUseApproval(
            taskID: taskID, stepID: stepID, actionKey: "b", decision: .deny)
        let secondDecision = await second.value
        XCTAssertEqual(secondDecision, .deny)
        XCTAssertNil(service.computerUseApprovalWaiters[key],
                     "the key is dropped only once the dictionary empties")
    }

    /// Full teardown (work-folder switch): every held waiter denies, the registry empties, and the
    /// orchestrator's published cards are cleared DIRECTLY — the orphaned `didEnd` callbacks may
    /// land after a new folder has already rendered.
    func testApproval_cancelAllExecutions_deniesHeldActionsAndClearsPublishedCards() async {
        let running = await hold(approvalRequest())

        service.cancelAllExecutions()

        let decision = await running.value
        XCTAssertEqual(decision, .deny)
        XCTAssertTrue(service.computerUseApprovalWaiters.isEmpty)
        XCTAssertEqual(delegate.clearAllComputerUseApprovalRequestsCallCount, 1)
    }

    // MARK: - Computer-use: the per-run app grant

    /// The grant is stored LOWERCASED so the gate's case-insensitive lookup matches whatever
    /// casing the model spells next time.
    func testAllowAppForRun_storesLowercased_andAccumulates() async {
        service.allowComputerUseAppForRun(taskID: taskID, bundleOrName: "ZZZPhantomApp")
        XCTAssertEqual(service.computerUseSessionAllowedApps[taskID], ["zzzphantomapp"])

        service.allowComputerUseAppForRun(taskID: taskID, bundleOrName: "com.ZZZ.Other")
        XCTAssertEqual(service.computerUseSessionAllowedApps[taskID],
                       ["zzzphantomapp", "com.zzz.other"],
                       "a second grant must ADD, never replace the first")

        service.allowComputerUseAppForRun(taskID: taskID, bundleOrName: "zzzphantomapp")
        XCTAssertEqual(service.computerUseSessionAllowedApps[taskID]?.count, 2,
                       "re-granting the same app in another casing must not duplicate it")
    }

    /// Grants are keyed per task — task ids are reused across work folders, so one task's grant
    /// must never answer for another's.
    func testAllowAppForRun_isScopedPerTask() async {
        service.allowComputerUseAppForRun(taskID: 1, bundleOrName: "Safari")
        XCTAssertNil(service.computerUseSessionAllowedApps[2])
        XCTAssertEqual(service.computerUseSessionAllowedApps[1], ["safari"])
    }
}

// MARK: - Stubs

/// A `LocalizedError` whose description must survive the finalizer's wrapper.
private struct StubVisionFailure: LocalizedError {
    var errorDescription: String? { "the vision server exploded" }
}

/// Scriptable `LLMClient` for the vision paths: yields a fixed reply (or throws a scripted error),
/// records what it was sent, and answers the vision-capability probe. Never touches the network.
private final class StubVisionClient: LLMClient, @unchecked Sendable {
    /// Content the vision model "returns".
    var reply: String = "ok"
    /// Reasoning channel. A vision model asked to describe a screenshot is a prime
    /// candidate for putting the whole answer here and leaving `reply` empty.
    var reasoning: String = ""
    /// When set, the stream throws this instead of yielding `reply`.
    var failure: Error?
    /// Answer to `modelSupportsVision`. `nil` mirrors the protocol default (undeterminable).
    var visionSupport: Bool?

    private(set) var streamChatCallCount = 0
    private(set) var lastMessages: [ChatMessage] = []

    var lastImage: ImageContent? {
        lastMessages.compactMap(\.imageContent).flatMap { $0 }.last
    }

    func streamChat(
        config _: LLMConfig,
        messages: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        streamChatCallCount += 1
        lastMessages = messages
        let text = reply
        let thinking = reasoning
        let error = failure
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            if !thinking.isEmpty { continuation.yield(StreamEvent(thinkingDelta: thinking)) }
            continuation.yield(StreamEvent(contentDelta: text))
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }

    func modelSupportsVision(config _: LLMConfig) async -> Bool? { visionSupport }
}
