import Foundation

// MARK: - LLMProvider

enum LLMProvider: String, Codable, Hashable, CaseIterable, Identifiable {
    case lmStudio

    var id: String { rawValue }

    var displayName: String {
        "LM Studio"
    }

    var defaultBaseURL: String {
        "http://localhost:1234"
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
        0   // Server decides
    }
}

// MARK: - LLMConfig

struct LLMConfig: Hashable {
    var provider: LLMProvider
    var baseURLString: String
    var modelName: String
    var maxTokens: Int
    var temperature: Double?

    init(
        provider: LLMProvider = .lmStudio,
        baseURLString: String? = nil,
        modelName: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.provider = provider
        self.baseURLString = baseURLString ?? provider.defaultBaseURL
        self.modelName = modelName ?? provider.defaultModel
        self.maxTokens = maxTokens ?? provider.defaultMaxTokens
        self.temperature = temperature
    }
}

// MARK: - MessageRole

enum MessageRole: String, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

// MARK: - ImageContent

struct ImageContent: Codable, Hashable {
    var base64Data: String
    var mimeType: String
}

// MARK: - ChatMessage

struct ChatMessage: Codable, Hashable {
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

struct ChatToolCall: Codable, Hashable {
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

struct ToolSchema: Hashable {
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

struct StreamEvent: Hashable {
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

struct TokenUsage: Codable, Hashable {
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

struct LLMSession: Sendable, Hashable {
    var responseID: String
}

// MARK: - LLMClientError

enum LLMClientError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case badHTTPStatus(Int, String?)
    case missingResponse
    case rateLimited(retryAfter: Double?)
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let s):
            "Invalid LLM base URL: \(s)"
        case .badHTTPStatus(let code, let body):
            if let body {
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
