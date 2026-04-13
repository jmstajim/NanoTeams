import XCTest
@testable import NanoTeams

/// Tests for the 3-way fallback strategy chain inside `TeamGenerationService.generate`:
/// resolved tool calls → Harmony-format parser → JSON object scan in content.
@MainActor
final class TeamGenerationServiceStreamTests: XCTestCase {

    // MARK: - Mock client

    /// Streams a single, fully-formed event (`StreamEvent`) and finishes. Lets each
    /// test isolate exactly which strategy in `generate()` should win.
    private final class StubLLMClient: LLMClient, @unchecked Sendable {
        var events: [StreamEvent] = []
        var error: Error?

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            session: LLMSession?,
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let captured = events
            let captureError = error
            return AsyncThrowingStream { continuation in
                if let captureError {
                    continuation.finish(throwing: captureError)
                    return
                }
                for event in captured { continuation.yield(event) }
                continuation.finish()
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    // MARK: - Helpers

    private func validConfigJSON() -> String {
        """
        {"name":"Stream Team","description":"x","roles":[{"name":"Eng","prompt":"p","produces_artifacts":["Code"],"requires_artifacts":["Supervisor Task"],"tools":[]}],"artifacts":[{"name":"Code","description":"c"}],"supervisor_requires":["Code"]}
        """
    }

    private func validNestedJSON() -> String {
        """
        {"team_config":\(validConfigJSON())}
        """
    }

    // MARK: - Strategy 1: resolved tool calls

    func testGenerate_resolvedToolCall_winsOverContent() async throws {
        let stub = StubLLMClient()
        let toolDelta = StreamEvent.ToolCallDelta(
            index: 0, id: "call_1", name: ToolNames.createTeam,
            argumentsDelta: validConfigJSON()
        )
        // Even with conflicting raw JSON in content, the resolved tool call should win.
        stub.events = [
            StreamEvent(toolCallDeltas: [toolDelta]),
            StreamEvent(contentDelta: "{\"name\":\"DECOY\",\"description\":\"\",\"roles\":[],\"artifacts\":[],\"supervisor_requires\":[]}"),
        ]

        let result = try await TeamGenerationService.generate(
            taskDescription: "build a team",
            config: LLMConfig(),
            client: stub
        )

        XCTAssertEqual(result.team.name, "Stream Team",
                       "Strategy 1 (resolved tool calls) should win — got '\(result.team.name)'")
    }

    // MARK: - Strategy 2: Harmony-format content

    func testGenerate_harmonyFormatContent_decodesTeam() async throws {
        let stub = StubLLMClient()
        let harmony = "<|channel|>commentary to=functions.\(ToolNames.createTeam)<|message|>\(validConfigJSON())<|call|>"
        stub.events = [StreamEvent(contentDelta: harmony)]

        let result = try await TeamGenerationService.generate(
            taskDescription: "build a team",
            config: LLMConfig(),
            client: stub
        )

        XCTAssertEqual(result.team.name, "Stream Team")
    }

    // MARK: - Strategy 3: raw JSON content scan

    func testGenerate_rawJSONInContent_decodesTeam() async throws {
        let stub = StubLLMClient()
        stub.events = [
            StreamEvent(contentDelta: "Here's the team:\n```json\n"),
            StreamEvent(contentDelta: validNestedJSON()),
            StreamEvent(contentDelta: "\n```\nDone!"),
        ]

        let result = try await TeamGenerationService.generate(
            taskDescription: "build a team",
            config: LLMConfig(),
            client: stub
        )

        XCTAssertEqual(result.team.name, "Stream Team")
    }

    // MARK: - No response

    func testGenerate_noToolCallsNoJSON_throwsNoResponse() async {
        let stub = StubLLMClient()
        stub.events = [StreamEvent(contentDelta: "I'm not going to give you JSON, sorry.")]

        do {
            _ = try await TeamGenerationService.generate(
                taskDescription: "build a team",
                config: LLMConfig(),
                client: stub
            )
            XCTFail("Expected GenerationError.noResponse")
        } catch let error as TeamGenerationService.GenerationError {
            if case .noResponse = error { return }
            XCTFail("Expected .noResponse, got \(error)")
        } catch {
            XCTFail("Expected GenerationError.noResponse, got \(error)")
        }
    }

    func testGenerate_clientThrows_propagatesError() async {
        struct FakeError: Error {}
        let stub = StubLLMClient()
        stub.error = FakeError()

        do {
            _ = try await TeamGenerationService.generate(
                taskDescription: "x",
                config: LLMConfig(),
                client: stub
            )
            XCTFail("Expected error to propagate")
        } catch is FakeError {
            // success
        } catch {
            XCTFail("Expected FakeError, got \(error)")
        }
    }

    // MARK: - Strategy 3 nested-shape (LLM emits {team_config: {...}} as plain text)

    func testGenerate_rawJSONInContent_nestedShape_decodesTeam() async throws {
        let stub = StubLLMClient()
        let nested = #"{"team_config":\#(validConfigJSON())}"#
        stub.events = [StreamEvent(contentDelta: nested)]

        let result = try await TeamGenerationService.generate(
            taskDescription: "x", config: LLMConfig(), client: stub
        )
        XCTAssertEqual(result.team.name, "Stream Team")
    }

    // MARK: - Decode failure inside a tool call should throw, not fall through

    func testGenerate_resolvedToolCall_invalidConfig_throwsInvalidResponse() async {
        let stub = StubLLMClient()
        let invalidConfig = #"{"name":"","description":"","roles":[],"artifacts":[],"supervisor_requires":[]}"#
        let toolDelta = StreamEvent.ToolCallDelta(
            index: 0, id: "call_1", name: ToolNames.createTeam,
            argumentsDelta: invalidConfig
        )
        stub.events = [StreamEvent(toolCallDeltas: [toolDelta])]

        do {
            _ = try await TeamGenerationService.generate(
                taskDescription: "x", config: LLMConfig(), client: stub
            )
            XCTFail("Empty roles in resolved tool call should throw, not silently fall through to content scan")
        } catch let err as TeamGenerationService.GenerationError {
            if case .invalidResponse = err { return }
            XCTFail("Expected .invalidResponse, got \(err)")
        } catch {
            XCTFail("Expected GenerationError.invalidResponse, got \(error)")
        }
    }

    // MARK: - Warnings surface through generate()

    func testGenerate_dropsUnknownTools_surfacesWarnings() async throws {
        let stub = StubLLMClient()
        let configWithBadTool = #"{"name":"Stream Team","description":"x","roles":[{"name":"Eng","prompt":"p","produces_artifacts":["Code"],"requires_artifacts":["Supervisor Task"],"tools":["read_file","fake_tool"]}],"artifacts":[{"name":"Code","description":"c"}],"supervisor_requires":["Code"]}"#
        let toolDelta = StreamEvent.ToolCallDelta(
            index: 0, id: "c1", name: ToolNames.createTeam,
            argumentsDelta: configWithBadTool
        )
        stub.events = [StreamEvent(toolCallDeltas: [toolDelta])]

        let result = try await TeamGenerationService.generate(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertEqual(result.team.roles[1].toolIDs, ["read_file"])
        XCTAssertFalse(result.warnings.isEmpty, "Dropped tools must surface in warnings")
        XCTAssertTrue(result.warnings.joined().contains("fake_tool"))
    }

    // MARK: - Streaming partial deltas

    func testGenerate_chunkedToolCallDeltas_assembledCorrectly() async throws {
        // The accumulator must reassemble argument deltas split across multiple events.
        let stub = StubLLMClient()
        let full = validConfigJSON()
        let mid = full.index(full.startIndex, offsetBy: 30)
        let part1 = String(full[..<mid])
        let part2 = String(full[mid...])

        stub.events = [
            StreamEvent(toolCallDeltas: [StreamEvent.ToolCallDelta(
                index: 0, id: "c1", name: ToolNames.createTeam, argumentsDelta: part1
            )]),
            StreamEvent(toolCallDeltas: [StreamEvent.ToolCallDelta(
                index: 0, id: nil, name: nil, argumentsDelta: part2
            )]),
        ]

        let result = try await TeamGenerationService.generate(
            taskDescription: "x", config: LLMConfig(), client: stub
        )
        XCTAssertEqual(result.team.name, "Stream Team")
    }

    func testGenerate_emptyStream_throwsNoResponse() async {
        // Server returned a response but with no events at all (unusual but possible).
        let stub = StubLLMClient()
        stub.events = []

        do {
            _ = try await TeamGenerationService.generate(
                taskDescription: "x", config: LLMConfig(), client: stub
            )
            XCTFail("Expected GenerationError.noResponse on empty stream")
        } catch is TeamGenerationService.GenerationError {
            // success
        } catch {
            XCTFail("Expected GenerationError, got \(error)")
        }
    }

    // MARK: - Task description piping

    func testGenerate_taskDescriptionAppearsInUserMessage() async throws {
        // The user message must contain the task description verbatim — otherwise the
        // LLM has no idea what to design a team for.
        final class CapturingClient: LLMClient, @unchecked Sendable {
            var capturedMessages: [ChatMessage] = []
            func streamChat(
                config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
                session: LLMSession?, logger: NetworkLogger?,
                stepID: String?, roleName: String?
            ) -> AsyncThrowingStream<StreamEvent, Error> {
                capturedMessages = messages
                return AsyncThrowingStream { $0.finish() }
            }
            func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
        }
        let cap = CapturingClient()
        _ = try? await TeamGenerationService.generate(
            taskDescription: "Build a Markdown editor with autosave",
            config: LLMConfig(), client: cap
        )

        let userContent = cap.capturedMessages.first(where: { $0.role == .user })?.content ?? ""
        XCTAssertTrue(userContent.contains("Build a Markdown editor with autosave"),
                      "User message must include the task description")
    }
}
