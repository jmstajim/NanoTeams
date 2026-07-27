import XCTest

@testable import NanoTeams

/// Pins the per-role override `preflightDecision` policy. The two
/// load-bearing branches:
///
/// 1. **401/403 on the override URL ⇒ KEEP the override** + post a system
///    message. Falling back to the global config would silently hide
///    "user enabled Require Authentication on this server but didn't add a
///    token". The user needs to see the auth-required message and either
///    enter the token or change the URL.
///
/// 2. **Transport error / non-auth HTTP error ⇒ FALL BACK to the global
///    config**. The override server is momentarily unreachable; running on
///    the global is better than wedging the step.
final class PreflightDecisionTests: XCTestCase {

    private final class StubSession: NetworkSession, @unchecked Sendable {
        var statusCode: Int = 200
        var errorToThrow: Error?
        var capturedRequest: URLRequest?

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedRequest = request
            if let errorToThrow { throw errorToThrow }
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: statusCode,
                httpVersion: nil, headerFields: nil)!)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    private let overrideConfig = LLMConfig(
        provider: .lmStudio, baseURLString: "http://override:9999",
        modelName: "override-m"
    )
    private let globalConfig = LLMConfig(
        provider: .lmStudio, baseURLString: "http://localhost:1234",
        modelName: "global-m"
    )

    private actor MessageCollector {
        private(set) var messages: [String] = []
        func add(_ s: String) { messages.append(s) }
    }

    // MARK: - 200 OK ⇒ keep override, no message

    func testPreflight_200_keepsOverride_noMessage() async {
        let session = StubSession(); session.statusCode = 200
        let collector = MessageCollector()

        let result = await LLMExecutionService.preflightDecision(
            effectiveConfig: overrideConfig,
            globalConfig: globalConfig,
            session: session,
            resolver: StubLLMTokenResolver([:]),
            appendSystemMessage: { await collector.add($0) }
        )

        XCTAssertEqual(result.baseURLString, overrideConfig.baseURLString)
        let messages = await collector.messages
        XCTAssertTrue(messages.isEmpty, "Successful preflight must NOT post a system message.")
    }

    // MARK: - 401 ⇒ keep override + post auth-required message (KEY POLICY)

    func testPreflight_401_keepsOverride_andPostsAuthRequiredMessage() async {
        let session = StubSession(); session.statusCode = 401
        let collector = MessageCollector()

        let result = await LLMExecutionService.preflightDecision(
            effectiveConfig: overrideConfig,
            globalConfig: globalConfig,
            session: session,
            resolver: StubLLMTokenResolver([:]),
            appendSystemMessage: { await collector.add($0) }
        )

        XCTAssertEqual(
            result.baseURLString, overrideConfig.baseURLString,
            "401 on the override URL must NOT silently fall back to global — that would mask the auth misconfig."
        )
        let messages = await collector.messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(
            messages.first?.contains("Authentication required") == true,
            "Auth-required message must be posted; got: \(messages.first ?? "")"
        )
    }

    func testPreflight_403_keepsOverride_andPostsAuthRequiredMessage() async {
        let session = StubSession(); session.statusCode = 403
        let collector = MessageCollector()

        let result = await LLMExecutionService.preflightDecision(
            effectiveConfig: overrideConfig,
            globalConfig: globalConfig,
            session: session,
            resolver: StubLLMTokenResolver([:]),
            appendSystemMessage: { await collector.add($0) }
        )

        XCTAssertEqual(result.baseURLString, overrideConfig.baseURLString)
        let messages = await collector.messages
        XCTAssertTrue(messages.first?.contains("Authentication required") == true)
    }

    // MARK: - Other non-2xx ⇒ fall back to global

    func testPreflight_500_fallsBackToGlobal() async {
        let session = StubSession(); session.statusCode = 500
        let collector = MessageCollector()

        let result = await LLMExecutionService.preflightDecision(
            effectiveConfig: overrideConfig,
            globalConfig: globalConfig,
            session: session,
            resolver: StubLLMTokenResolver([:]),
            appendSystemMessage: { await collector.add($0) }
        )

        XCTAssertEqual(
            result.baseURLString, globalConfig.baseURLString,
            "Non-auth server errors should fall back so the run isn't wedged."
        )
        let messages = await collector.messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.first?.contains("unavailable") == true)
        XCTAssertFalse(
            messages.first?.contains("Authentication required") == true,
            "500 must not be classified as an auth failure."
        )
    }

    // MARK: - Transport error ⇒ fall back to global

    func testPreflight_transportError_fallsBackToGlobal() async {
        let session = StubSession()
        session.errorToThrow = URLError(.cannotConnectToHost)
        let collector = MessageCollector()

        let result = await LLMExecutionService.preflightDecision(
            effectiveConfig: overrideConfig,
            globalConfig: globalConfig,
            session: session,
            resolver: StubLLMTokenResolver([:]),
            appendSystemMessage: { await collector.add($0) }
        )

        XCTAssertEqual(result.baseURLString, globalConfig.baseURLString)
        let messages = await collector.messages
        XCTAssertEqual(messages.count, 1)
    }

    // MARK: - Endpoint correctness

    func testPreflight_usesCanonicalAPIPath_notOpenAIShim() async {
        let session = StubSession(); session.statusCode = 200
        let collector = MessageCollector()

        _ = await LLMExecutionService.preflightDecision(
            effectiveConfig: overrideConfig,
            globalConfig: globalConfig,
            session: session,
            resolver: StubLLMTokenResolver([:]),
            appendSystemMessage: { await collector.add($0) }
        )

        XCTAssertEqual(
            session.capturedRequest?.url?.path, "/api/v1/models",
            "Preflight must hit LM Studio's native `/api/v1/models`, not the OpenAI shim `/v1/models` — older LM Studio builds don't expose the shim."
        )
    }

    func testPreflight_ollamaOverride_probesApiTags() async {
        let session = StubSession(); session.statusCode = 200
        let collector = MessageCollector()
        let ollamaOverride = LLMConfig(
            provider: .ollama, baseURLString: "http://override:11434",
            modelName: "gpt-oss:20b")

        _ = await LLMExecutionService.preflightDecision(
            effectiveConfig: ollamaOverride,
            globalConfig: globalConfig,
            session: session,
            resolver: StubLLMTokenResolver([:]),
            appendSystemMessage: { await collector.add($0) }
        )

        XCTAssertEqual(
            session.capturedRequest?.url?.path, "/api/tags",
            "An Ollama override must be probed on ITS provider's path — /api/v1/models 404s there and would silently fall back to the global config every step."
        )
    }

    // MARK: - Resolver token plumbed onto preflight request

    func testPreflight_appliesResolverToken() async {
        let session = StubSession(); session.statusCode = 200
        let collector = MessageCollector()

        _ = await LLMExecutionService.preflightDecision(
            effectiveConfig: overrideConfig,
            globalConfig: globalConfig,
            session: session,
            resolver: StubLLMTokenResolver([overrideConfig.baseURLString: "preflight-tok"]),
            appendSystemMessage: { await collector.add($0) }
        )

        XCTAssertEqual(
            session.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer preflight-tok"
        )
    }
}
