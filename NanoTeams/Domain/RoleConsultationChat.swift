import Foundation

/// Persistent per-role chat used for team collaboration (consultations, meetings, change requests).
/// Each role has at most one consultation chat per run. The chat accumulates context across
/// multiple interactions — the role remembers all previous questions and answers.
///
/// Separate from the role's artifact chat (step execution). Only final answers/decisions
/// are returned to the requesting role's artifact chat as tool results.
nonisolated struct RoleConsultationChat: Codable, Identifiable, Hashable {
    /// Role base ID (e.g., "productManager", custom UUID string).
    var id: String

    /// Full conversation history — the chat IS the request on every call.
    /// Includes system prompt, context messages, all Q/A pairs.
    var messages: [LLMMessage]

    /// Artifact IDs already injected into this chat (for incremental context updates).
    /// When new artifacts become available, only the delta is injected.
    var injectedArtifactIDs: Set<String>

    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        messages: [LLMMessage] = [],
        injectedArtifactIDs: Set<String> = [],
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now()
    ) {
        self.id = id
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

    /// Messages to send on the next call: the FULL history, always. Every request
    /// is self-contained; the provider's prompt-prefix cache — not a server-side
    /// chain — is what makes the resend cheap.
    func messagesToSend() -> [ChatMessage] {
        toChatMessages()
    }
}
