import XCTest

@testable import NanoTeams

final class VisionAnalysisServiceTests: XCTestCase {

    // MARK: - Mock LLM Client

    private final class MockVisionLLMClient: LLMClient, @unchecked Sendable {
        var streamedContent: [String] = ["Hello", " from", " vision"]
        var shouldThrow: Error?
        var capturedMessages: [ChatMessage] = []
        var capturedConfig: LLMConfig?

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            session: LLMSession?,
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            capturedMessages = messages
            capturedConfig = config

            if let error = shouldThrow {
                return AsyncThrowingStream { throw error }
            }

            let content = streamedContent
            return AsyncThrowingStream { continuation in
                for chunk in content {
                    continuation.yield(StreamEvent(contentDelta: chunk))
                }
                continuation.finish()
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    // MARK: - Tests

    func testAnalyze_collectsStreamedContent() async throws {
        let client = MockVisionLLMClient()
        client.streamedContent = ["A cat", " sitting", " on a mat"]

        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost:1234",
            modelName: "vision-model"
        )
        let result = try await VisionAnalysisService.analyze(
            prompt: "What is in this image?",
            imageBase64: "iVBORw0KGgo=",
            mimeType: "image/png",
            config: config,
            client: client
        )

        XCTAssertEqual(result, "A cat sitting on a mat")
    }

    func testAnalyze_passesCorrectMessages() async throws {
        let client = MockVisionLLMClient()
        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost:1234",
            modelName: "vision-model"
        )

        _ = try await VisionAnalysisService.analyze(
            prompt: "Describe this UI",
            imageBase64: "base64data",
            mimeType: "image/jpeg",
            config: config,
            client: client
        )

        XCTAssertEqual(client.capturedMessages.count, 2)
        XCTAssertEqual(client.capturedMessages[0].role, .system)
        XCTAssertTrue(client.capturedMessages[0].content?.contains("image analysis assistant") == true)
        XCTAssertEqual(client.capturedMessages[1].role, .user)
        XCTAssertEqual(client.capturedMessages[1].content, "Describe this UI" as String?)
        XCTAssertEqual(client.capturedMessages[1].imageContent?.count, 1)
        XCTAssertEqual(client.capturedMessages[1].imageContent?[0].base64Data, "base64data")
        XCTAssertEqual(client.capturedMessages[1].imageContent?[0].mimeType, "image/jpeg")
    }

    func testAnalyze_passesConfig() async throws {
        let client = MockVisionLLMClient()
        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://custom:5678",
            modelName: "my-vision"
        )

        _ = try await VisionAnalysisService.analyze(
            prompt: "Test",
            imageBase64: "data",
            mimeType: "image/png",
            config: config,
            client: client
        )

        XCTAssertEqual(client.capturedConfig?.modelName, "my-vision")
        XCTAssertEqual(client.capturedConfig?.baseURLString, "http://custom:5678")
    }

    func testAnalyze_throwsOnLLMError() async {
        let client = MockVisionLLMClient()
        client.shouldThrow = NSError(domain: "test", code: 500, userInfo: [
            NSLocalizedDescriptionKey: "Server error",
        ])

        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost:1234",
            modelName: "vision-model"
        )

        do {
            _ = try await VisionAnalysisService.analyze(
                prompt: "Test",
                imageBase64: "data",
                mimeType: "image/png",
                config: config,
                client: client
            )
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Server error"))
        }
    }

    func testAnalyze_emptyResponse_returnsEmptyString() async throws {
        let client = MockVisionLLMClient()
        client.streamedContent = []

        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost:1234",
            modelName: "vision-model"
        )
        let result = try await VisionAnalysisService.analyze(
            prompt: "Test",
            imageBase64: "data",
            mimeType: "image/png",
            config: config,
            client: client
        )

        XCTAssertEqual(result, "")
    }

    func testAnalyze_trimsWhitespace() async throws {
        let client = MockVisionLLMClient()
        client.streamedContent = ["  A response  \n  "]

        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost:1234",
            modelName: "vision-model"
        )
        let result = try await VisionAnalysisService.analyze(
            prompt: "Test",
            imageBase64: "data",
            mimeType: "image/png",
            config: config,
            client: client
        )

        XCTAssertEqual(result, "A response")
    }

    func testAnalyze_cleansModelTokens() async throws {
        let client = MockVisionLLMClient()
        client.streamedContent = ["A response<|channel|> text"]

        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost:1234",
            modelName: "vision-model"
        )
        let result = try await VisionAnalysisService.analyze(
            prompt: "Test",
            imageBase64: "data",
            mimeType: "image/png",
            config: config,
            client: client
        )

        XCTAssertFalse(result.contains("<|channel|>"))
        XCTAssertTrue(result.contains("A response"))
    }
}
