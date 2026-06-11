import Foundation

// MARK: - Editor Tab

/// The tabs of the Team Editor's right pane. Top-level + `nonisolated` so the
/// visibility policy below is unit-testable without a SwiftUI host.
nonisolated enum EditorTab: String, CaseIterable, Identifiable, Hashable {
    case team
    case prompts
    case roles
    case artifacts

    var id: String { rawValue }

    private static let metadata: [EditorTab: (label: String, icon: String)] = [
        .team:      ("Settings",  "gearshape"),
        .prompts:   ("Prompts",   "text.bubble"),
        .roles:     ("Roles",     "person.text.rectangle"),
        .artifacts: ("Artifacts", "doc.text"),
    ]

    var label: String { Self.metadata[self]!.label }
    var icon: String { Self.metadata[self]!.icon }
}

// MARK: - Tab Visibility Policy (pure, testable)

/// Pure policy for which editor tabs a team exposes and how to recover when the
/// selected tab becomes hidden (e.g. switching to the Autovisor managed singleton,
/// which hides Artifacts). See `TeamEditorTabPolicyTests`.
nonisolated enum TeamEditorTabPolicy {

    /// The managed singleton (Autovisor) keeps Settings + Prompts + Roles (the latter
    /// read-only) but hides Artifacts — its single artifact dependency is structural.
    static func availableTabs(isManagedSingleton: Bool) -> [EditorTab] {
        isManagedSingleton ? [.team, .prompts, .roles] : EditorTab.allCases
    }

    /// Keeps the current tab when still available, else falls back to the first
    /// available (Settings) so the user is never stranded on a hidden pane.
    static func clamp(_ selected: EditorTab, available: [EditorTab]) -> EditorTab {
        available.contains(selected) ? selected : (available.first ?? .team)
    }
}
