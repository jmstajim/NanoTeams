import XCTest
@testable import NanoTeams

/// Verifies the `systemPrompt` parameter on `TeamGenerationService.generate`:
/// `nil` → built-in default; non-nil → exact string replacement. Uses a capturing
/// stub LLM client to inspect the system message that reaches `streamChat`.
@MainActor
final class TeamGenerationServicePromptOverrideTests: XCTestCase {

    // MARK: - Capturing stub

    private final class CapturingLLMClient: LLMClient, @unchecked Sendable {
        var capturedMessages: [ChatMessage] = []

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            capturedMessages = messages
            // Finish without any output so the service returns `GenerationError.noResponse`.
            // We only care about what was sent, not the decoded team.
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
    }

    // MARK: - Tests

    func testGenerate_systemPromptNil_usesBuiltInDefault() async {
        let stub = CapturingLLMClient()
        _ = try? await TeamGenerationService.generate(
            taskDescription: "build something",
            config: LLMConfig(),
            client: stub,
            systemPrompt: nil
        )

        guard let first = stub.capturedMessages.first else {
            return XCTFail("Expected at least one message sent to streamChat")
        }
        XCTAssertEqual(first.role, .system)
        XCTAssertEqual(first.content, TeamGenerationService.defaultSystemPrompt)
    }

    func testGenerate_systemPromptCustom_replacesDefault() async {
        let stub = CapturingLLMClient()
        _ = try? await TeamGenerationService.generate(
            taskDescription: "build something",
            config: LLMConfig(),
            client: stub,
            systemPrompt: "YOU ARE A CUSTOM TEAM ARCHITECT."
        )

        guard let first = stub.capturedMessages.first else {
            return XCTFail("Expected at least one message sent to streamChat")
        }
        XCTAssertEqual(first.role, .system)
        XCTAssertEqual(first.content, "YOU ARE A CUSTOM TEAM ARCHITECT.")
        XCTAssertNotEqual(first.content, TeamGenerationService.defaultSystemPrompt,
                          "Custom prompt must fully replace the default, not append")
    }

    func testGenerate_systemPromptDefaultsToNil_whenArgumentOmitted() async {
        // Backward compatibility: existing call sites that don't pass `systemPrompt`
        // must keep sending the built-in default.
        let stub = CapturingLLMClient()
        _ = try? await TeamGenerationService.generate(
            taskDescription: "x",
            config: LLMConfig(),
            client: stub
        )

        XCTAssertEqual(stub.capturedMessages.first?.content, TeamGenerationService.defaultSystemPrompt)
    }

    // MARK: - No explicit CoT (reasoning-model default)

    /// The default model is a reasoning model (gpt-oss-20b) — instructing prose
    /// planning before the tool call degrades it AND feeds the jsonExtract
    /// fallback parser. The `## Output` contract is a direct single tool call.
    func testDefaultSystemPrompt_noExplicitCoTInstruction() {
        let p = TeamGenerationService.defaultSystemPrompt
        XCTAssertFalse(p.contains("First plan"), "no prose-planning instruction before the tool call")
        XCTAssertFalse(p.contains("3-5 short lines"), "the 2026-07 plan-first experiment stays reverted")
        XCTAssertTrue(p.contains("exactly once"), "output contract: one direct create_team call")
        XCTAssertTrue(p.contains("no prose"), "output contract: no prose around the call")
    }
}
