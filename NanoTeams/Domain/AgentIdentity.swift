import Foundation

/// Stable identity of an external agent authorized to drive or inspect a work folder.
nonisolated struct AgentIdentity: Codable, Hashable, Sendable {
    var id: UUID
    var label: String

    init(id: UUID = UUID(), label: String) {
        self.id = id
        self.label = label
    }
}
