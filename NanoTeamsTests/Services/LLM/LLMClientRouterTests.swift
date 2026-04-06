import XCTest

@testable import NanoTeams

final class LLMClientRouterTests: XCTestCase {

    // MARK: - Properties

    var router: LLMClientRouter!

    override func setUp() {
        super.setUp()
        router = LLMClientRouter()
    }

    override func tearDown() {
        router = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func collectStreamError(_ stream: AsyncThrowingStream<StreamEvent, Error>) async -> Error? {
        do {
            for try await _ in stream { }
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Provider Routing Tests (via error signatures)

    func testRoutes_lmStudio_toNativeClient() async {
        // LM Studio routes to NativeLMStudioClient.
        // An empty baseURL triggers invalidBaseURL.
        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: "",
            modelName: "test-model"
        )

        let stream = router.streamChat(
            config: config,
            messages: [],
            tools: [],
            session: nil,
            logger: nil,
            stepID: nil
        )

        let error = await collectStreamError(stream)
        XCTAssertNotNil(error, "Expected an error from NativeLMStudioClient")

        guard let clientError = error as? LLMClientError else {
            XCTFail("Expected LLMClientError, got \(type(of: error!))")
            return
        }

        if case .invalidBaseURL(let url) = clientError {
            XCTAssertEqual(url, "", "Should report the empty URL")
        } else {
            XCTFail("Expected invalidBaseURL, got \(clientError)")
        }
    }

    // MARK: - fetchModels Routing Tests

    func testFetchModels_lmStudio_throwsWithBadURL() async {
        // NativeLMStudioClient.fetchModels checks baseURL validity.
        let config = LLMConfig(
            provider: .lmStudio,
            baseURLString: ""
        )

        do {
            _ = try await router.fetchModels(config: config, visionOnly: false)
            XCTFail("Expected invalidBaseURL error")
        } catch let error as LLMClientError {
            if case .invalidBaseURL(let url) = error {
                XCTAssertEqual(url, "", "Should report the empty URL")
            } else {
                XCTFail("Expected invalidBaseURL, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMClientError, got \(type(of: error))")
        }
    }

    // MARK: - Conformance Tests

    func testConformsToLLMClient() {
        // LLMClientRouter must conform to LLMClient protocol.
        let client: any LLMClient = router
        XCTAssertNotNil(client)
    }

    func testAllProvidersRouted() async {
        // Verify every LLMProvider case is handled by the router (no fatalError).
        // Each provider should produce a known error rather than crashing.
        for provider in LLMProvider.allCases {
            let config = LLMConfig(
                provider: provider,
                baseURLString: "",
                modelName: "test",
                maxTokens: 0
            )

            let stream = router.streamChat(
                config: config,
                messages: [],
                tools: [],
                session: nil,
                logger: nil,
                stepID: nil
            )

            let error = await collectStreamError(stream)
            XCTAssertNotNil(error, "Provider \(provider.displayName) should produce an error with invalid config")
            XCTAssertTrue(
                error is LLMClientError,
                "Provider \(provider.displayName) should produce LLMClientError, got \(type(of: error!))"
            )
        }
    }
}
