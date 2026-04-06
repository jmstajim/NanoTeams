import Foundation

/// Persistent per-role chat used for team collaboration (consultations, meetings, change requests).
/// Each role has at most one consultation chat per run. The chat accumulates context across
/// multiple interactions — the role remembers all previous questions and answers.
///
/// Separate from the role's artifact chat (step execution). Only final answers/decisions
/// are returned to the requesting role's artifact chat as tool results.
struct RoleConsultationChat: Codable, Identifiable, Hashable {
    /// Role base ID (e.g., "productManager", custom UUID string).
    var id: String

    /// Session ID for stateful LM Studio sessions.
    /// Used as `previous_response_id` to continue the conversation server-side.
    /// May become invalid after app restart — falls back to stateless (full history).
    var sessionID: String?

    /// Full conversation history for stateless fallback and persistence.
    /// Includes system prompt, context messages, all Q/A pairs.
    var messages: [LLMMessage]

    /// Artifact IDs already injected into this chat (for incremental context updates).
    /// When new artifacts become available, only the delta is injected.
    var injectedArtifactIDs: Set<String>

    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        sessionID: String? = nil,
        messages: [LLMMessage] = [],
        injectedArtifactIDs: Set<String> = [],
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.messages = messages
        self.injectedArtifactIDs = injectedArtifactIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Convert stored LLMMessages to ChatMessages for sending to the LLM client.
    func toChatMessages() -> [ChatMessage] {
        messages.compactMap { msg in
            guard let role = MessageRole(rawValue: msg.role.rawValue) else { return nil }
            return ChatMessage(role: role, content: msg.content)
        }
    }

    /// Get messages to send based on session state.
    /// Stateful: only new messages since last assistant response.
    /// Stateless: full history.
    func messagesToSend(session: LLMSession?) -> [ChatMessage] {
        if session != nil {
            // Stateful: only send messages after the last assistant message
            let allChat = toChatMessages()
            if let lastAssistantIdx = allChat.lastIndex(where: { $0.role == .assistant }) {
                return Array(allChat[(lastAssistantIdx + 1)...])
            }
            return allChat
        } else {
            return toChatMessages()
        }
    }
}
