import SwiftUI

// MARK: - Role Node Visual Styling

/// Visual styling for a role node based on its execution status.
struct RoleNodeStyle {
    let borderColor: Color
    let borderWidth: CGFloat
    let backgroundColor: Color
    let opacity: Double
}

extension RoleExecutionStatus {
    /// Each status has a unique, visually distinct color.
    // Key paths, NOT resolved `Color`s. A `static let` holding `Colors.x` is evaluated ONCE, on
    // first access, and freezes whatever theme was active at that moment — every later theme
    // switch leaves it stale until relaunch. Measured 2026-09-09: with the app opened under
    // `rose` and switched to `cobalt`, `Colors.warning` correctly returned #F2E85C while the
    // status map still handed out #A29DCE. The same staleness was diagnosed and fixed for the
    // NSColor accessors in `Colors.swift` (see the note above `nsTextPrimary`); these maps were
    // missed. Storing the key path keeps the lookup static and moves resolution to call time,
    // where `Colors.themed` already memoizes per theme.
    private static let colorMap: [RoleExecutionStatus: KeyPath<ThemePalette, UInt64>] = [
        .idle: \.neutral,          // gray — not started
        .ready: \.cyan,             // cyan — deps met, can start
        .working: \.info,           // blue — LLM executing
        .needsAcceptance: \.purple, // purple — Supervisor review
        .accepted: \.emerald,       // emerald — Supervisor approved
        .revisionRequested: \.yellow, // yellow — changes requested
        .done: \.success,           // green — completed
        .failed: \.error,           // red — error
        .skipped: \.dim,            // dim — observer
    ]
    var color: Color { Colors.themed(Self.colorMap[self] ?? \.neutral) }

    /// Contextual display name with meeting/paused overrides.
    func displayName(isInMeeting: Bool, isPaused: Bool) -> String {
        if isInMeeting { return "In Meeting" }
        if isPaused && self == .working { return "Paused" }
        return displayName
    }

    /// Contextual display color with meeting/paused overrides.
    func displayColor(isInMeeting: Bool, isPaused: Bool) -> Color {
        if isInMeeting { return Colors.purple }
        if isPaused && self == .working { return Colors.warning }
        return color
    }

    var nodeStyle: RoleNodeStyle {
        let recipe = Self.nodeStyleMap[self]
            ?? NodeStyleRecipe(border: \.neutral, borderWidth: 1, background: \.neutralTint, opacity: 0.6)
        return RoleNodeStyle(
            borderColor: Colors.themed(recipe.border),
            borderWidth: recipe.borderWidth,
            backgroundColor: Colors.themed(recipe.background),
            opacity: recipe.opacity
        )
    }

    /// The theme-independent half of a node's look: which TOKENS it uses, plus the widths.
    /// Colours are resolved in `nodeStyle`, never stored — see the note on `colorMap`.
    private struct NodeStyleRecipe {
        let border: KeyPath<ThemePalette, UInt64>
        let borderWidth: CGFloat
        let background: KeyPath<ThemePalette, UInt64>
        let opacity: Double
    }

    private static let nodeStyleMap: [RoleExecutionStatus: NodeStyleRecipe] = [
        .idle: NodeStyleRecipe(border: \.neutral, borderWidth: 0.5, background: \.neutralTint, opacity: 0.8),
        .ready: NodeStyleRecipe(border: \.cyan, borderWidth: 1, background: \.cyanTint, opacity: 1.0),
        .working: NodeStyleRecipe(border: \.info, borderWidth: 1, background: \.infoTint, opacity: 1.0),
        .needsAcceptance: NodeStyleRecipe(border: \.purple, borderWidth: 1.5, background: \.purpleTint, opacity: 1.0),
        .accepted: NodeStyleRecipe(border: \.emerald, borderWidth: 1, background: \.emeraldTint, opacity: 1.0),
        .revisionRequested: NodeStyleRecipe(border: \.yellow, borderWidth: 1, background: \.yellowTint, opacity: 1.0),
        .done: NodeStyleRecipe(border: \.success, borderWidth: 1, background: \.successTint, opacity: 1.0),
        .failed: NodeStyleRecipe(border: \.error, borderWidth: 1, background: \.errorTint, opacity: 1.0),
        .skipped: NodeStyleRecipe(border: \.dim, borderWidth: 0, background: \.dimTint, opacity: 0.35),
    ]
}
