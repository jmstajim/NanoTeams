import Foundation

/// NanoTeams Team Identifier — a human-readable, deterministic string derived from the team name.
/// Examples: `"faang"`, `"personal_assistant"`, `"my_custom_team"`.
/// For template teams, equals the `templateID`. For custom teams, derived via `NTMSID.from(name:)`.
typealias NTMSID = String

extension NTMSID {
    /// Derives a stable team ID from a display name: lowercased, spaces/colons → underscores, non-alphanumeric stripped.
    /// Example: `"Personal Assistant"` → `"personal_assistant"`, `"faang:PM"` → `"faang_pm"`
    static func from(name: String) -> NTMSID {
        name.lowercased()
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
