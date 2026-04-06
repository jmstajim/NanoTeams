import Foundation

// MARK: - Meeting Tool Summary

/// Lightweight record of a tool call made during a meeting turn.
struct MeetingToolSummary: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var toolName: String
    var arguments: String
    var result: String
    var isError: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        toolName: String,
        arguments: String,
        result: String,
        isError: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.isError = isError
    }
}
