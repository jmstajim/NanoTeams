import Foundation

struct StepMessage: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var role: Role
    var content: String

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        role: Role,
        content: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.role = role
        self.content = content
    }
}
