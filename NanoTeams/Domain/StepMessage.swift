import Foundation

nonisolated struct StepMessage: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var role: Role
    var content: String
    /// Who wrote a `.supervisor` message — a restart comment, revision feedback, a correction —
    /// recorded on the message itself, as `LLMMessage` records it on a Supervisor turn
    /// (DEBTS D-M15). `authorLabel` is the external agent's display label; `nil` for the
    /// person, the built-in Autovisor manager and the app's own notices.
    var authorLabel: String?
    /// `true` when an automated path (the Autovisor — built-in manager or external agent) wrote
    /// this `.supervisor` message, `false` when the person did. `nil` on a role's own message,
    /// on the app's notices (amendments, upstream changes), and on a message persisted before
    /// 2026-11-07, which did not record its author. Never on the wire: `PromptBuilder` relays
    /// `content` alone.
    var isFromAutomatedSupervisor: Bool?

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        role: Role,
        content: String,
        authorLabel: String? = nil,
        isFromAutomatedSupervisor: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.role = role
        self.content = content
        self.authorLabel = authorLabel
        self.isFromAutomatedSupervisor = isFromAutomatedSupervisor
    }
}
