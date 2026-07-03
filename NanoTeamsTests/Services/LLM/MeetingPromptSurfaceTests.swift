import XCTest

@testable import NanoTeams

/// Pins the meeting prompt surface after the 2026-07 rework:
/// 1. Meeting turns resolve the team's user-editable `meetingPromptTemplate`
///    (pre-fix, initial turns rode the consultation chat's CONSULTATION
///    template, so the Settings-exposed meeting template never reached the
///    wire on the happy path).
/// 2. Tool follow-ups CONTINUE the turn's own conversation — same system
///    prompt, same grounding (pre-fix they rebuilt a different stack
///    mid-turn, letting a small model contradict its pre-tool statement).
@MainActor
final class MeetingPromptSurfaceTests: XCTestCase {

    // MARK: - Fixtures

    /// Capturing client: records every streamChat invocation, returns an
    /// empty stream (no tool calls → the executor loop exits).
    final class CapturingLLMClient: LLMClient, @unchecked Sendable {
        var captures: [[ChatMessage]] = []

        func streamChat(
            config _: LLMConfig, messages: [ChatMessage], tools _: [ToolSchema],
            session _: LLMSession?, logger _: NetworkLogger?, stepID _: String?,
            roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            captures.append(messages)
            return AsyncThrowingStream { $0.finish() }
        }

        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    private func makeContext(
        team: Team?,
        artifacts: [Artifact] = [],
        artifactReader: @escaping (Artifact) -> String? = { _ in nil }
    ) -> TeamMeetingService.MeetingContext {
        TeamMeetingService.MeetingContext(
            topic: "API design",
            initiatedBy: .productManager,
            participants: [.productManager, .softwareEngineer],
            additionalContext: nil,
            task: NTMSTask(id: 1, title: "T", supervisorTask: "S", runs: [Run(id: 0)]),
            availableArtifacts: artifacts,
            artifactReader: artifactReader,
            team: team,
            coordinatorRole: .productManager,
            limits: TeamLimits()
        )
    }

    // MARK: - Meeting template reaches the wire

    func testBuildMeetingMessages_systemPromptIsResolvedMeetingTemplate() {
        let faang = TeamTemplateFactory.faang()
        let meeting = TeamMeetingService.createMeeting(
            topic: "API design", initiatedBy: .productManager,
            participants: [.productManager, .softwareEngineer], context: nil)

        let messages = MeetingStreamingService.buildMeetingMessages(
            speaker: .softwareEngineer, meeting: meeting, context: makeContext(team: faang)
        )

        XCTAssertEqual(messages.first?.role, .system)
        let system = messages.first?.content ?? ""
        XCTAssertTrue(system.contains("## Role"), "meeting template is `##`-sectioned")
        XCTAssertTrue(system.contains("API design"), "{meetingTopic} chip must resolve")
        XCTAssertTrue(system.contains("team meeting") || system.contains("meeting"),
                      "system prompt must be the MEETING template, not the consultation one")
        XCTAssertFalse(system.contains("answering teammates' questions"),
                       "consultation-template phrasing must not leak into meeting turns")
    }

    func testBuildMeetingMessages_oneConsolidatedUserTurn_withDirective() {
        let faang = TeamTemplateFactory.faang()
        var meeting = TeamMeetingService.createMeeting(
            topic: "API design", initiatedBy: .productManager,
            participants: [.productManager, .softwareEngineer], context: nil)
        meeting.addMessage(TeamMessage(
            id: UUID(), createdAt: MonotonicClock.shared.now(),
            role: .productManager, content: "I propose REST.", messageType: .proposal))

        let messages = MeetingStreamingService.buildMeetingMessages(
            speaker: .softwareEngineer, meeting: meeting, context: makeContext(team: faang)
        )

        // system + ONE consolidated user turn (no artifacts here).
        XCTAssertEqual(messages.count, 2)
        let turn = messages.last?.content ?? ""
        XCTAssertTrue(turn.contains("Discussion so far"), "turn must re-consolidate the discussion")
        XCTAssertTrue(turn.contains("I propose REST."))
        XCTAssertTrue(turn.contains("Provide your input"), "turn must end with the directive")
    }

    func testBuildMeetingMessages_artifactGroundingInjected() {
        let faang = TeamTemplateFactory.faang()
        let meeting = TeamMeetingService.createMeeting(
            topic: "API design", initiatedBy: .productManager,
            participants: [.productManager], context: nil)
        let artifact = Artifact(name: "Product Requirements", relativePath: "a.md")

        let messages = MeetingStreamingService.buildMeetingMessages(
            speaker: .productManager, meeting: meeting,
            context: makeContext(team: faang, artifacts: [artifact],
                                 artifactReader: { _ in "REQ CONTENT" })
        )

        XCTAssertEqual(messages.count, 3, "system + artifact grounding + turn")
        XCTAssertTrue(messages[1].content?.contains("Product Requirements") ?? false)
        XCTAssertTrue(messages[1].content?.contains("REQ CONTENT") ?? false)
    }

    // MARK: - Tool follow-up continues the SAME conversation

    func testExecuteTurnToolLoop_followUpKeepsSystemPromptAndGrounding() async throws {
        let (_, runtime) = ToolRegistry.defaultRegistry(workFolderRoot: tempDir, toolCallsLogURL: nil)
        let client = CapturingLLMClient()
        let conversation = [
            ChatMessage(role: .system, content: "MEETING SYSTEM PROMPT MARKER"),
            ChatMessage(role: .user, content: "GROUNDING MARKER"),
        ]
        let initial = TeamMeetingService.MeetingStreamResult(
            content: "Let me check the files.",
            thinking: "",
            resolvedToolCalls: [StepToolCall(name: "list_files", argumentsJSON: #"{"path":"."}"#)]
        )
        let tools = [ToolSchema(
            name: "list_files", description: "t",
            parameters: JSONSchema(type: "object", properties: [:], required: []))]

        let result = try await MeetingToolExecutor.executeTurnToolLoop(
            initialResult: initial,
            conversationSoFar: conversation,
            meetingContext: makeContext(team: nil),
            client: client,
            config: LLMConfig(),
            tools: tools,
            runtime: runtime,
            toolContext: ToolExecutionContext(
                workFolderRoot: tempDir, taskID: 1, runID: 0, roleID: "pm")
        )

        XCTAssertEqual(client.captures.count, 1, "one follow-up call after the tool batch")
        let followUp = client.captures[0]
        XCTAssertEqual(followUp.first?.content, "MEETING SYSTEM PROMPT MARKER",
                       "follow-up must keep the EXACT system prompt of the initial call")
        XCTAssertEqual(followUp[1].content, "GROUNDING MARKER",
                       "follow-up must keep the grounding the speaker saw")
        XCTAssertEqual(followUp[2].role, .assistant, "then the assistant tool-call turn")
        XCTAssertEqual(followUp[3].role, .tool, "then the tool result")
        XCTAssertEqual(result.toolSummaries.count, 1)
    }
}
