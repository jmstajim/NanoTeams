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
    /// On a `.tool` turn: a `ToolErrorNotePolicy` direction rides this turn's tail. In-process
    /// routing, never sent to a provider (no builder reads it; `PromptPrefixFingerprint` skips it).
    /// It stands in for the `.user` direction turn the wire carried until 2026-09-14, so it is set
    /// under exactly that turn's condition — a FAILED call the policy had something to add to —
    /// and not on every error. Named `isToolError` and set on every error for the first day, it
    /// let `ConversationRepairService` delete a batch whose error carried no direction (a typed
    /// `ANCHOR_NOT_FOUND`) together with the successful results beside it.
    var carriesErrorDirection: Bool?
    var imageContent: [ImageContent]?
    /// The reasoning the model generated on an assistant turn, raw, as the provider streamed
    /// it — set ONLY on a `.native` turn (`LLMExecutionService.processStreamingResult`), where
    /// the structured wires have a slot for it: `reasoning_content` on `/v1/chat/completions`,
    /// `thinking` on Ollama's `/api/chat`. The prompt-taught wires flatten assistant turns into
    /// labelled text and carry none, so a prompt-taught turn records none: this struct is the
    /// record of what was SENT.
    ///
    /// Why it is sent at all: the template's replay gate — not the client — decides what the
    /// model sees again (Qwen3.5 keeps the reasoning of the turns after the last user query and
    /// drops the rest; Qwen3.8 keeps it; Gemma 4 drops it), and it can only gate a field it
    /// receives. A server whose cache cannot be trimmed (Qwen3.5's recurrent layers under LM
    /// Studio's continuous-batching kit) reuses that cache only on a byte-identical continuation
    /// of prompt + generated tokens, and the template re-renders the generated turn
    /// byte-identically only when handed the reasoning it generated. Measured 2026-09-14,
    /// `qwythos-9b` at 19.9k tokens: 0.39 s to first token with the field, 13.28 s without.
    /// Never content text (playbook A6.16 / R2.3.1): the gate cannot act on text it does not
    /// recognise as reasoning. `nil` — not `""` — when the turn had none.
    var reasoning: String?

    init(
        role: MessageRole,
        content: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [ChatToolCall]? = nil,
        carriesErrorDirection: Bool? = nil,
        imageContent: [ImageContent]? = nil,
        reasoning: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.carriesErrorDirection = carriesErrorDirection
        self.imageContent = imageContent
        self.reasoning = reasoning
    }

    enum CodingKeys: String, CodingKey {
        case role, content, reasoning
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
        case carriesErrorDirection = "carries_error_direction"
        case imageContent = "image_content"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolCalls = try container.decodeIfPresent([ChatToolCall].self, forKey: .toolCalls)
        // A transcript written on 2026-09-14 before the fix carries `is_tool_error`, set on EVERY
        // error — deliberately not read: under that key the flag meant the superset.
        carriesErrorDirection = try container.decodeIfPresent(Bool.self, forKey: .carriesErrorDirection)
        imageContent = try container.decodeIfPresent([ImageContent].self, forKey: .imageContent)
        // Absent on every transcript written before 2026-09-14; the replay then sends what
        // that step always sent.
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
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
