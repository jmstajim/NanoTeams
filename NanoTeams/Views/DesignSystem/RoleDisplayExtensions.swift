import SwiftUI

// View-layer display extensions on Domain types.
// Separated from design tokens (Colors, Spacing, etc.) per SRP.

// MARK: - Role Display Extensions

extension Role {
    // Key paths, NOT resolved `Color`s. A `static let` holding `Colors.x` is evaluated ONCE, on
    // first access, and freezes whatever theme was active at that moment — every later theme
    // switch leaves it stale until relaunch. Measured 2026-09-09: with the app opened under
    // `rose` and switched to `cobalt`, `Colors.warning` correctly returned #F2E85C while the
    // status map still handed out #A29DCE. The same staleness was diagnosed and fixed for the
    // NSColor accessors in `Colors.swift` (see the note above `nsTextPrimary`); these maps were
    // missed. Storing the key path keeps the lookup static and moves resolution to call time,
    // where `Colors.themed` already memoizes per theme.
    private static let tintColorMap: [Role: KeyPath<ThemePalette, UInt64>] = [
        .supervisor: \.indigo,
        .productManager: \.teal,
        .uxResearcher: \.purple,
        .uxDesigner: \.pink,
        .techLead: \.cyan,
        .softwareEngineer: \.success,
        .codeReviewer: \.info,
        .sre: \.mint,
        .tpm: \.warning,
        .loreMaster: \.brown,
        .npcCreator: \.purple,
        .encounterArchitect: \.error,
        .rulesArbiter: \.yellow,
        .questMaster: \.indigo,
        .theAgreeable: \.teal,
        .theOpen: \.pink,
        .theConscientious: \.cyan,
        .theExtrovert: \.warning,
        .theNeurotic: \.purple,
        .assistant: \.teal,
        .codingAssistant: \.purple,
        .codingAgent: \.purple,
        .autovisor: \.cyan,
        .changePlanner: \.teal,
        .briefCritic: \.yellow,
        .solutionArchitect: \.cyan,
        .pragmaticArchitect: \.indigo,
        .specCritic: \.warning,
        .regressionCritic: \.error,
        .changeEngineer: \.success,
        .diffReviewer: \.emerald,
        .changeVerifier: \.mint,
    ]

    var tintColor: Color {
        if case .custom = self { return Colors.neutral }
        return Colors.themed(Self.tintColorMap[self] ?? \.neutral)
    }
}

// MARK: - TeamRoleDefinition Color Extensions

/// Color properties kept in Views layer so the domain model stays free of SwiftUI dependencies.
extension TeamRoleDefinition {

    /// Display color for the role's completion type badge.
    var completionTypeDisplayColor: Color { completionType.displayColor }

    /// Resolved icon foreground color from hex string.
    ///
    /// `iconColor` is a user-editable persisted hex, so a malformed value really does reach
    /// the fallback. `textOnAccent` is theme-determined contrast for a glyph sitting on an
    /// accent fill — which is this glyph's job; a hardcoded `.white` is wrong on the light
    /// and paper themes.
    var resolvedIconColor: Color {
        Color(hex: iconColor) ?? Colors.textOnAccent
    }

    /// Resolved icon background color from hex string.
    var resolvedIconBackground: Color {
        Color(hex: iconBackground) ?? Colors.accent
    }

    /// Resolved tint color for role identity across the app (activity feed, graph, etc.).
    var resolvedTintColor: Color {
        Color(hex: iconBackground) ?? Colors.neutral
    }
}

extension Array where Element == TeamRoleDefinition {
    /// Resolve display name for a role ID with built-in fallback.
    nonisolated func roleName(for roleID: String) -> String {
        first(where: { $0.id == roleID })?.name
            ?? first(where: { $0.systemRoleID == roleID })?.name
            ?? Role.builtInRole(for: roleID)?.displayName
            ?? roleID
    }
}

/// Renders a role label with team-scoping for delegated child team items.
///
/// Returns `"\(roleName).\(teamName)"` for items that originate from a non-active
/// (child / descendant) team — disambiguates collisions like two teams that both
/// expose a "Software Engineer" role. Active-team items keep the bare role name.
///
/// Used by both the activity feed (per-item header labels) and the runtime
/// team graph (child-layer node labels).
@inline(__always)
func displayRoleLabel(roleName: String, teamName: String?, isChildTeam: Bool) -> String {
    guard isChildTeam, let teamName, !teamName.isEmpty else { return roleName }
    // U+00B7 MIDDLE DOT with surrounding spaces — reads as a clean separator
    // ("Engineer · Engineering Team") versus the prior "Engineer.Engineering
    // Team" which looked like a code-style member access. The graph nodes
    // pass `teamLabelSuffix: nil` so this only applies to the activity
    // feed, where there's no boundary band to carry the team name.
    return "\(roleName) · \(teamName)"
}

/// Renders an activity-feed role label as a two-tone `Text`: the role name
/// in `tintColor` (semibold), followed by an optional ` from <Team>` suffix
/// in secondary gray (regular weight). The suffix lets the user see which
/// child team an item came from without the role name itself fading out.
///
/// Returns a plain `Text(roleName)` when `teamSuffix` is `nil`/empty —
/// active-team items keep the bare role name, no suffix wired in.
@inline(__always)
func roleNameText(roleName: String, teamSuffix: String?, tintColor: Color) -> Text {
    let base = Text(roleName)
        .font(Typography.captionSemibold)
        .foregroundStyle(tintColor)
    guard let teamSuffix, !teamSuffix.isEmpty else { return base }
    return base + Text(" from \(teamSuffix)")
        .font(Typography.caption.weight(.regular))
        .foregroundStyle(Colors.textSecondary)
}

// MARK: - RoleCompletionType Display Extensions

extension RoleCompletionType {
    private static let displayColorMap: [RoleCompletionType: KeyPath<ThemePalette, UInt64>] = [
        .producing: \.success,
        .advisory: \.teal,
        .observer: \.textSecondary,
    ]

    var displayColor: Color { Colors.themed(Self.displayColorMap[self] ?? \.textSecondary) }
}

// MARK: - ChangeRequestStatus Display Extensions

extension ChangeRequestStatus {
    private static let statusColorMap: [ChangeRequestStatus: KeyPath<ThemePalette, UInt64>] = [
        .pending: \.neutral,
        .approved: \.success,
        .rejected: \.error,
        .escalated: \.warning,
        .supervisorApproved: \.success,
        .supervisorRejected: \.error,
        .failed: \.error,
    ]

    var statusColor: Color { Colors.themed(Self.statusColorMap[self] ?? \.neutral) }

    /// Pre-computed tint fill paired with ``statusColor``, for the status badge behind the
    /// label.
    ///
    /// A map rather than `statusColor.opacity(...)`: this is a CLOSED set of seven statuses
    /// resolving to four tokens, not a runtime-supplied colour, so the tints are known ahead
    /// of time and the design system already ships them. `DynamicTintOpacity` is for colours
    /// that arrive as a parameter (`ActivityFeedIconAvatar`'s `color`), and reaching for it
    /// here produced a hand-rolled tint over a theme-ignoring `.secondary`.
    private static let statusTintColorMap: [ChangeRequestStatus: KeyPath<ThemePalette, UInt64>] = [
        .pending: \.neutralTint,
        .approved: \.successTint,
        .rejected: \.errorTint,
        .escalated: \.warningTint,
        .supervisorApproved: \.successTint,
        .supervisorRejected: \.errorTint,
        .failed: \.errorTint,
    ]

    var statusTintColor: Color { Colors.themed(Self.statusTintColorMap[self] ?? \.neutralTint) }
}
