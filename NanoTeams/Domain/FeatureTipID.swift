import Foundation

/// Identifies a feature-tip card shown in Watchtower's "Setup" section.
///
/// Persisted by raw value inside `StoreConfiguration.dismissedFeatureTipIDs`.
/// New tips are appended to this enum without breaking back-compat — unknown
/// raw strings already in `Set<String>` are simply ignored, never decoded.
enum FeatureTipID: String, CaseIterable, Hashable, Sendable {
    case llm
    case exploratorySearch
    case vision
    case dictation
}
