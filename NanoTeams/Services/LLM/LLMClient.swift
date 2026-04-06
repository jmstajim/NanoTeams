import Foundation

// MARK: - Network Session

/// DIP abstraction over URLSession for testable network I/O.
/// URLSession conforms automatically via its existing `data(for:)` and `bytes(for:)` overloads.
protocol NetworkSession: Sendable {
    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse)
    func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

extension URLSession: @retroactive NetworkSession {
    // Bridge to URLSession methods which have an additional `delegate` parameter with default value.
    // Swift protocols don't match methods with extra defaulted parameters automatically.
    public func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
    public func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await bytes(for: request)
    }
}

// MARK: - LLM Client

/// Protocol for all LLM clients (ChatCompletions, Responses API).
/// Callers use this protocol — the router dispatches to the correct implementation.
protocol LLMClient: Sendable {

    /// Stream a chat completion from the LLM provider.
    ///
    /// - Parameters:
    ///   - config: Provider configuration (URL, model, API key, etc.)
    ///   - messages: Conversation history
    ///   - tools: Available tool schemas
    ///   - session: Optional session for stateful providers.
    ///     Stateless providers ignore this parameter.
    ///   - logger: Optional network logger
    ///   - stepID: Optional step ID for log correlation
    ///   - roleName: Optional role name for log attribution
    /// - Returns: Async stream of events (content, thinking, tool calls, usage, session)
    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        session: LLMSession?,
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error>

    /// Fetch available models from the provider.
    /// Not all providers may support this.
    /// - Parameter visionOnly: When `true`, returns only vision-capable models.
    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String]
}

extension LLMClient {
    /// Convenience overload without roleName — existing callers don't need to change.
    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        session: LLMSession?,
        logger: NetworkLogger?,
        stepID: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        streamChat(
            config: config, messages: messages, tools: tools,
            session: session, logger: logger, stepID: stepID, roleName: nil)
    }
}
