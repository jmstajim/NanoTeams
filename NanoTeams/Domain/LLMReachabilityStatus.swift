import Foundation

nonisolated struct LLMReachabilityStatus: Sendable, Equatable {
    var reachable: Bool?
    var checkedAt: Date?

    init(reachable: Bool? = nil, checkedAt: Date? = nil) {
        self.reachable = reachable
        self.checkedAt = checkedAt
    }
}
