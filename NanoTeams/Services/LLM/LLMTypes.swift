import Foundation

// MARK: - LLMProvider

nonisolated enum LLMProvider: String, Codable, Hashable, CaseIterable, Identifiable {
    case lmStudio

    var id: String { rawValue }

    var displayName: String {
        "LM Studio"
    }

    var defaultBaseURL: String {
        // `127.0.0.1` over `localhost` because the UI placeholder + the
        // Keychain key normalization both treat them as distinct hosts —
        // keeping a single canonical form avoids drift between what the
        // user sees, what Reset restores, and what the bearer token is
        // saved under.
        "http://127.0.0.1:1234"
    }

    var defaultModel: String {
        "openai/gpt-oss-20b"
    }

    var supportsModelFetching: Bool {
        true
    }

    var supportsStatefulSessions: Bool {
        true
    }

    var defaultMaxTokens: Int {
        // 0 = "server decides" (LM Studio forwards nil max_tokens → no cap).
        // Runaway thinking on local models is cappable via Settings → Generation
        // → Response Limit (UI renders 0 as "Unlimited" and supports 1–128k).
        0
    }
}

// MARK: - LLMConfig

nonisolated struct LLMConfig: Hashable {
    var provider: LLMProvider
    var baseURLString: String
    var modelName: String
    var maxTokens: Int
    var temperature: Double?
    /// Streaming HTTP request timeout in seconds. `0` = no timeout (wait indefinitely).
    /// Minimum effective value is 1s; values below 1 other than 0 are clamped up.
    var requestTimeoutSeconds: Int

    init(
        provider: LLMProvider = .lmStudio,
        baseURLString: String? = nil,
        modelName: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        requestTimeoutSeconds: Int? = nil
    ) {
        self.provider = provider
        self.baseURLString = baseURLString ?? provider.defaultBaseURL
        self.modelName = modelName ?? provider.defaultModel
        self.maxTokens = maxTokens ?? provider.defaultMaxTokens
        self.temperature = temperature
        self.requestTimeoutSeconds = requestTimeoutSeconds ?? LLMConstants.defaultLLMRequestTimeoutSeconds
    }
}

// MARK: - MessageRole

nonisolated enum MessageRole: String, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

// MARK: - ImageContent

nonisolated struct ImageContent: Codable, Hashable {
    var base64Data: String
    var mimeType: String
}

// MARK: - ChatMessage

nonisolated struct ChatMessage: Codable, Hashable {
    var role: MessageRole
    var content: String?
    var toolCallID: String?
    var toolCalls: [ChatToolCall]?
    var isToolError: Bool?
    var imageContent: [ImageContent]?

    init(
        role: MessageRole,
        content: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [ChatToolCall]? = nil,
        isToolError: Bool? = nil,
        imageContent: [ImageContent]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.isToolError = isToolError
        self.imageContent = imageContent
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
        case isToolError = "is_tool_error"
        case imageContent = "image_content"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolCalls = try container.decodeIfPresent([ChatToolCall].self, forKey: .toolCalls)
        isToolError = try container.decodeIfPresent(Bool.self, forKey: .isToolError)
        imageContent = try container.decodeIfPresent([ImageContent].self, forKey: .imageContent)
    }
}

// MARK: - ChatToolCall

nonisolated struct ChatToolCall: Codable, Hashable {
    var id: String
    var name: String
    var argumentsJSON: String

    init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case argumentsJSON = "arguments_json"
    }
}

// MARK: - ToolSchema

nonisolated struct ToolSchema: Hashable, Codable {
    var name: String
    var description: String
    var parameters: JSONSchema

    init(name: String, description: String, parameters: JSONSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - StreamEvent

nonisolated struct StreamEvent: Hashable {
    var contentDelta: String
    var thinkingDelta: String
    var toolCallDeltas: [ToolCallDelta]
    var tokenUsage: TokenUsage?
    var session: LLMSession?
    /// Prompt processing progress (0.0–1.0). Non-nil during prompt_processing phase.
    var processingProgress: Double?

    init(
        contentDelta: String = "",
        thinkingDelta: String = "",
        toolCallDeltas: [ToolCallDelta] = [],
        tokenUsage: TokenUsage? = nil,
        session: LLMSession? = nil,
        processingProgress: Double? = nil
    ) {
        self.contentDelta = contentDelta
        self.thinkingDelta = thinkingDelta
        self.toolCallDeltas = toolCallDeltas
        self.tokenUsage = tokenUsage
        self.session = session
        self.processingProgress = processingProgress
    }

    var isEmpty: Bool {
        contentDelta.isEmpty && thinkingDelta.isEmpty && toolCallDeltas.isEmpty
            && tokenUsage == nil && session == nil && processingProgress == nil
    }

    struct ToolCallDelta: Hashable {
        var index: Int?
        var id: String?
        var name: String?
        var argumentsDelta: String?
    }
}

// MARK: - TokenUsage

nonisolated struct TokenUsage: Codable, Hashable {
    var inputTokens: Int
    var outputTokens: Int

    init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Accumulate usage from another instance (for multi-iteration tool loops).
    mutating func accumulate(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
    }
}

// MARK: - LLMSession

nonisolated struct LLMSession: Sendable, Hashable {
    var responseID: String
}

// MARK: - LLMClientError

nonisolated enum LLMClientError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case badHTTPStatus(Int, String?)
    case missingResponse
    case rateLimited(retryAfter: Double?)
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let s):
            // Empty / whitespace URL means "not configured yet" rather than
            // "user typed something invalid" — surface a hint instead of the
            // raw empty string so onAppear-triggered preflights don't show
            // a useless `Invalid LLM base URL:` row.
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                "Server address is empty. Enter the LM Studio URL above."
            } else {
                "Invalid LLM base URL: \(s)"
            }
        case .badHTTPStatus(let code, let body):
            // 401 / 403: route through the auth classifier so every UI that
            // surfaces this error (settings cards, role editor, status banners)
            // shows the actionable "add your API token" message instead of
            // dumping the raw LM Studio JSON envelope.
            if LLMAuthErrorClassifier.isAuthFailure(status: code) {
                LLMAuthErrorClassifier.message(forStatus: code, body: body)
            } else if let body {
                "LLM request failed with HTTP \(code): \(body)"
            } else {
                "LLM request failed with HTTP status \(code)"
            }
        case .missingResponse:
            "Missing HTTP response from LLM server"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                "Rate limited. Retry after \(Int(seconds))s"
            } else {
                "Rate limited. Please retry later"
            }
        case .providerError(let message):
            "LLM provider error: \(message)"
        }
    }
}
