import Foundation

/// Selects which driver acts as the work folder's Autovisor when `autovisorEnabled` is on.
nonisolated enum AutovisorDriver: String, Codable, CaseIterable, Hashable, Sendable {
    case builtInModel
    case externalAgent
}
