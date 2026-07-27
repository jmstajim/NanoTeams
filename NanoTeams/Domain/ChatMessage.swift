import Foundation

// The wire-message value types. These model a single message as it is SENT to /
// RECEIVED from an LLM, independent of any provider: `NativeLMStudioClient` and
// `OllamaClient` each render `[ChatMessage]` into their own request shape.
//
// They live in Domain/ (not Services/LLM/) because `StepExecution.wireTranscript`
// persists them as the byte-faithful record of what a step actually sent — a
// Domain type must not reach up into Services for its own storage shape.

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
