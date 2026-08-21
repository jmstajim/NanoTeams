import XCTest

@testable import NanoTeams

/// Four one-shot LLM services that read only `contentDelta`, and one that read the
/// reasoning channel and then threw it away.
///
/// A reasoning model routes its entire reply through `reasoning_content` and leaves
/// `content` empty, and nothing merges the two on the way in — `SSEEventParser` maps
/// `reasoning.delta` to `.thinkingDelta`, and Ollama's `ThinkTagSplitter` actively pulls
/// inline `<think>` OUT of content. So each of these services did not see a degraded
/// answer; it saw no answer, and reported that as the model's fault:
///
/// - the work-folder summary became "Model returned no usable context. Try a more
///   descriptive prompt" — advice about a prompt that had just worked;
/// - the image analysis became `{"ok":true,…,"analysis":""}`;
/// - the generated team became "AI did not return a team configuration";
/// - the delegated Supervisor's decision became "(no answer provided)", delivered to a
///   whole child team as the Supervisor speaking;
/// - the meeting turn became a blank line every later speaker had to read.
final class OneShotReasoningChannelCoverageTests: XCTestCase {

    // MARK: - Doubles

    /// Emits `thinking` on the reasoning channel and `content` on the visible one.
    private final class ScriptedClient: LLMClient, @unchecked Sendable {
        var content = ""
        var thinking = ""

        func streamChat(
            config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
            logger: NetworkLogger?, stepID: String?, roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let (content, thinking) = (self.content, self.thinking)
            return AsyncThrowingStream { continuation in
                if !thinking.isEmpty { continuation.yield(StreamEvent(thinkingDelta: thinking)) }
                if !content.isEmpty { continuation.yield(StreamEvent(contentDelta: content)) }
                continuation.finish()
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    private var client: ScriptedClient!
    private var tempDir: URL!

    private let config = LLMConfig(
        provider: .lmStudio, baseURLString: "http://x", modelName: "m")

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        client = ScriptedClient()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-oneshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
        try? "let x = 1".write(
            to: tempDir.appendingPathComponent("Main.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Work folder context

    /// RED: drop the `thinkingDelta` accumulation in `WorkFolderContextService.stream` →
    /// this returns nil, and the orchestrator's `.emptyOutput` arm tells the user "Model
    /// returned no usable context. Try a more descriptive prompt or check that your LLM is
    /// responding" about a model that just answered.
    func testWorkFolderContext_reasoningOnlyReply_isUsed() async throws {
        client.thinking = "A Swift package with one source file."

        let context = try await WorkFolderContextService(client: client)
            .generate(workFolderRoot: tempDir, config: config)

        XCTAssertEqual(context, "A Swift package with one source file.")
    }

    /// RED: remove the `ModelTokenCleaner.clean` from `WorkFolderContextService.stream` →
    /// the envelope survives.
    ///
    /// This is the one site in the cluster with NO downstream cleaner: the value travels
    /// `WorkFolderManagementService` → `generateWorkFolderContext` →
    /// `updateWorkFolderContext` → the repository (which only trims) and lands in
    /// `settings.context`, which `PromptBuilder.buildWorkFolderContextMessage` renders into
    /// the system prompt of EVERY role on EVERY request — segment 0, where a stray token
    /// would sit for the life of the work folder.
    func testWorkFolderContext_stripsModelTokens() async throws {
        client.content = "<|channel|>final<|message|>A Swift package.<|end|>"

        let context = try await WorkFolderContextService(client: client)
            .generate(workFolderRoot: tempDir, config: config)

        XCTAssertEqual(context, "A Swift package.")
        XCTAssertFalse(context?.contains("<|") ?? true, context ?? "nil")
    }

    /// Both channels silent is a genuinely empty result, and `nil` — which routes to the
    /// generic info banner — is the right outcome there. Without this the fix above could
    /// degenerate into "always return something".
    func testWorkFolderContext_bothChannelsEmpty_stillReturnsNil() async throws {
        let context = try await WorkFolderContextService(client: client)
            .generate(workFolderRoot: tempDir, config: config)
        XCTAssertNil(context)
    }

    // MARK: - Vision

    /// RED: drop the `thinkingDelta` accumulation in `VisionAnalysisService.analyze` →
    /// this returns "".
    func testVision_reasoningOnlyReply_isUsed() async throws {
        client.thinking = "A login form with two text fields."

        let analysis = try await VisionAnalysisService.analyze(
            prompt: "what is this?", imageBase64: "AAAA", mimeType: "image/png",
            config: config, client: client)

        XCTAssertEqual(analysis, "A login form with two text fields.")
    }

    /// The service still returns "" when BOTH channels are silent — that is the input
    /// `+Vision` is contractually required to turn into an error rather than an empty
    /// success, and the assertion below is what keeps the two halves honest.
    func testVision_bothChannelsEmpty_returnsEmpty() async throws {
        let analysis = try await VisionAnalysisService.analyze(
            prompt: "what is this?", imageBase64: "AAAA", mimeType: "image/png",
            config: config, client: client)
        XCTAssertTrue(analysis.isEmpty)
    }

    // MARK: - Team generation

    /// RED: revert `parseSource()` to `fullContent` at the Harmony path → the envelope is
    /// invisible, no path sets `lastArgumentsJSON`, and the outcome is
    /// `GenerationError.noResponse`.
    ///
    /// The second assertion is the expensive half: `generate`'s ONE corrective retry is
    /// gated on `lastArgumentsJSON != nil`, so a reasoning-channel envelope did not merely
    /// fail — it failed in the one shape that also suppresses the retry built to rescue it.
    func testTeamGeneration_harmonyEnvelopeInTheReasoningChannel_isParsed() async {
        let teamConfig = """
        {"name":"Duo","roles":[{"name":"Engineer","prompt":"Build it",\
        "produces_artifacts":["Notes"],"requires_artifacts":["Supervisor Task"],\
        "tools":["read_file"]}],"supervisor_requires":["Notes"]}
        """
        let escaped = teamConfig
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // The envelope shape `TeamGenerationServiceTests` already pins as one a real model
        // emits, moved verbatim onto the reasoning channel.
        client.thinking = "<|channel|>final <|constrain|>create_team<|message|>"
            + "{\"name\":\"create_team\",\"arguments\":{\"team_config\":\"\(escaped)\"}}"

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "build a thing", config: config, client: client)

        guard case .success(let build) = outcome.result else {
            return XCTFail("expected a parsed team, got \(outcome.result)")
        }
        XCTAssertEqual(build.team.name, "Duo")
        XCTAssertEqual(outcome.diagnostics.parsingPath, .harmony)
        XCTAssertNotNil(
            outcome.diagnostics.lastArgumentsJSON,
            "the corrective retry is gated on this being non-nil")
    }

    /// RED: revert `parseSource()` to `fullContent` at the JSON-extract path → `nil`
    /// path and `noResponse`.
    func testTeamGeneration_bareJSONInTheReasoningChannel_isParsed() async {
        client.thinking = """
        Here is the team:
        {"name":"Solo","roles":[{"name":"Engineer","prompt":"Build it",\
        "produces_artifacts":["Notes"],"requires_artifacts":["Supervisor Task"],\
        "tools":["read_file"]}],"supervisor_requires":["Notes"]}
        """

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "build a thing", config: config, client: client)

        guard case .success(let build) = outcome.result else {
            return XCTFail("expected a parsed team, got \(outcome.result)")
        }
        XCTAssertEqual(build.team.name, "Solo")
        XCTAssertEqual(outcome.diagnostics.parsingPath, .jsonExtract)
    }

    /// RED: revert the three `diagnostics.rawContent = parseSource()` assignments to
    /// `fullContent` → this is "".
    ///
    /// `rawContent` has exactly one reader — the `create_team` trainer's
    /// `rawContentPreview`/`rawContentLength`, i.e. the audit loop that exists to diagnose
    /// failed generations. Recording "" for a model that produced a full config is the
    /// misdiagnosis this whole wave is about, reproduced inside the diagnostics.
    func testTeamGeneration_diagnosticsRecordWhatTheParserActuallyRead() async {
        client.thinking = "not a config at all"

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "build a thing", config: config, client: client)

        XCTAssertEqual(outcome.diagnostics.rawContent, "not a config at all")
    }

    /// Content still wins when both channels speak — a model that thinks out loud and then
    /// emits the real call must not have its deliberation parsed instead.
    func testTeamGeneration_contentWins_whenBothChannelsSpeak() async {
        client.thinking = """
        {"name":"WRONG","roles":[{"name":"Engineer","prompt":"x",\
        "produces_artifacts":["Notes"],"requires_artifacts":["Supervisor Task"],\
        "tools":["read_file"]}],"supervisor_requires":["Notes"]}
        """
        client.content = """
        {"name":"RIGHT","roles":[{"name":"Engineer","prompt":"x",\
        "produces_artifacts":["Notes"],"requires_artifacts":["Supervisor Task"],\
        "tools":["read_file"]}],"supervisor_requires":["Notes"]}
        """

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "build a thing", config: config, client: client)

        guard case .success(let build) = outcome.result else {
            return XCTFail("expected a parsed team, got \(outcome.result)")
        }
        XCTAssertEqual(build.team.name, "RIGHT")
    }

    // MARK: - The two judges

    /// Both judges already recovered the reasoning channel before this wave, and neither
    /// had a test for it: routing them through `ModelReplyChannels` made that visible,
    /// because dropping the seam's fallback reddened five suites and left the judges green.
    ///
    /// It matters here more than anywhere else. `parse("")` denies, and the judge is
    /// fail-closed by design — so losing the fallback does not open a hole, it silently
    /// denies EVERY command for anyone running a reasoning model as their judge.
    ///
    /// RED: drop the fallback in `ModelReplyChannels.answer` → `parse("")` → denied.
    func testBashJudge_verdictOnlyInTheReasoningChannel_isHonoured() async {
        client.thinking = #"{"decision":"OK","reason":"read only"}"#

        let decision = await BashJudgeService.judge(
            command: "ls", workingDirectory: nil,
            policy: BashPolicy(mode: .auto, restrictionLevel: .standard),
            config: config, client: client)

        XCTAssertTrue(decision.allowed, "got: \(decision.reason)")
    }

    /// RED: swap `content:` and `reasoning:` at the `BashJudgeService` call site → the
    /// discarded deliberation overrides the actual verdict and this ALLOWS.
    ///
    /// The seam's own tests pin the rule; this pins that the judge hands it the two
    /// channels the right way round — a one-word mutation nothing else would catch, and
    /// the one direction where being wrong turns a DENY into an ALLOW.
    func testBashJudge_contentVerdictWins_overAReasoningChannelSecondGuess() async {
        client.content = #"{"decision":"DENY","reason":"deletes files"}"#
        client.thinking = #"{"decision":"OK"}"#

        let decision = await BashJudgeService.judge(
            command: "rm -rf /", workingDirectory: nil,
            policy: BashPolicy(mode: .auto, restrictionLevel: .standard),
            config: config, client: client)

        XCTAssertFalse(decision.allowed, "the visible verdict is the verdict")
    }

    /// RED: drop the fallback in `ModelReplyChannels.answer` → denied.
    func testComputerUseJudge_verdictOnlyInTheReasoningChannel_isHonoured() async {
        client.thinking = #"{"decision":"OK","reason":"harmless scroll"}"#

        let decision = await ComputerUseJudgeService.judge(
            action: .click(x: 10, y: 20, button: "left", double: false, target: "Safari"),
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard),
            config: config, client: client)

        XCTAssertTrue(decision.allowed, "got: \(decision.reason)")
    }

    /// RED: swap `content:` and `reasoning:` at the `ComputerUseJudgeService` call site →
    /// the reasoning channel's "OK" overrides the visible DENY and this allows the click.
    func testComputerUseJudge_contentVerdictWins_overAReasoningChannelSecondGuess() async {
        client.content = #"{"decision":"DENY","reason":"types into a password field"}"#
        client.thinking = #"{"decision":"OK"}"#

        let decision = await ComputerUseJudgeService.judge(
            action: .click(x: 10, y: 20, button: "left", double: false, target: "Safari"),
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard),
            config: config, client: client)

        XCTAssertFalse(decision.allowed)
    }

    // MARK: - Meeting turn

    private func meeting() -> TeamMeeting {
        TeamMeetingService.createMeeting(
            topic: "API design", initiatedBy: .productManager,
            participants: [.productManager, .softwareEngineer], context: nil)
    }

    private func meetingContext() -> TeamMeetingService.MeetingContext {
        TeamMeetingService.MeetingContext(
            initiatedBy: .productManager,
            participants: [.productManager, .softwareEngineer],
            availableArtifacts: [],
            artifactReader: { _ in nil },
            team: nil,
            coordinatorRole: .productManager,
            limits: TeamLimits())
    }

    /// RED: revert `completeTurn`'s `spoken` to `ModelTokenCleaner.clean(content)` → the
    /// turn is recorded with empty content.
    ///
    /// `MeetingStreamingService` had always COLLECTED the reasoning channel; this was the
    /// one place that decides what the speaker said, and it ignored it. The cost compounds:
    /// `buildMeetingMessages` replays the transcript into every later turn, so one silent
    /// speaker leaves a blank line under "Discussion so far" for the rest of the meeting.
    func testMeetingTurn_reasoningOnlyTurn_becomesTheContribution() {
        var meeting = self.meeting()
        _ = TeamMeetingService.completeTurn(
            meeting: &meeting, speaker: .productManager,
            content: "", thinking: "I propose REST over GraphQL.",
            toolSummaries: nil, context: meetingContext())

        XCTAssertEqual(meeting.messages.last?.content, "I propose REST over GraphQL.")
    }

    /// A promoted reasoning channel must NOT also appear as the speaker's private
    /// thinking — the feed would render the same text twice, once as the contribution and
    /// once inside the disclosure.
    func testMeetingTurn_promotedReasoning_isNotAlsoTheDisclosure() {
        var meeting = self.meeting()
        _ = TeamMeetingService.completeTurn(
            meeting: &meeting, speaker: .productManager,
            content: "", thinking: "I propose REST over GraphQL.",
            toolSummaries: nil, context: meetingContext())

        XCTAssertNil(meeting.messages.last?.thinking)
    }

    /// When content speaks, thinking stays exactly where it was — a private disclosure,
    /// stored as captured. This is the pre-existing contract and the fix must not move it.
    func testMeetingTurn_contentSpeaking_keepsThinkingAsTheDisclosure() {
        var meeting = self.meeting()
        _ = TeamMeetingService.completeTurn(
            meeting: &meeting, speaker: .productManager,
            content: "REST.", thinking: "weighing options",
            toolSummaries: nil, context: meetingContext())

        XCTAssertEqual(meeting.messages.last?.content, "REST.")
        XCTAssertEqual(meeting.messages.last?.thinking, "weighing options")
    }

    /// The promoted contribution is classified like any other — otherwise a reasoning-only
    /// conclusion would never end the meeting.
    func testMeetingTurn_promotedReasoning_isClassified() {
        var meeting = self.meeting()
        meeting.addMessage(
            TeamMessage(role: .productManager, content: "Let's use REST.", messageType: .proposal))
        _ = TeamMeetingService.completeTurn(
            meeting: &meeting, speaker: .softwareEngineer,
            content: "", thinking: "In conclusion, REST it is.",
            toolSummaries: nil, context: meetingContext())

        XCTAssertEqual(meeting.messages.last?.messageType, .conclusion)
    }

    /// Both channels silent still records an empty turn — the meeting engine's own
    /// concern, unchanged. Pins that the fallback did not invent content.
    func testMeetingTurn_bothChannelsEmpty_recordsAnEmptyTurn() {
        var meeting = self.meeting()
        _ = TeamMeetingService.completeTurn(
            meeting: &meeting, speaker: .productManager,
            content: "", thinking: nil, toolSummaries: nil, context: meetingContext())

        XCTAssertEqual(meeting.messages.last?.content, "")
        XCTAssertNil(meeting.messages.last?.thinking)
    }
}
