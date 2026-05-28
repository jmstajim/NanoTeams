import SwiftUI

// View-layer display extensions on Domain types.
// Separated from design tokens (Colors, Spacing, etc.) per SRP.

// MARK: - Role Display Extensions

extension Role {
    private static let tintColorMap: [Role: Color] = [
        .supervisor: Colors.indigo,
        .productManager: Colors.teal,
        .uxResearcher: Colors.purple,
        .uxDesigner: Colors.pink,
        .techLead: Colors.cyan,
        .softwareEngineer: Colors.success,
        .codeReviewer: Colors.info,
        .sre: Colors.mint,
        .tpm: Colors.warning,
        .loreMaster: Colors.brown,
        .npcCreator: Colors.purple,
        .encounterArchitect: Colors.error,
        .rulesArbiter: Colors.yellow,
        .questMaster: Colors.indigo,
        .theAgreeable: Colors.teal,
        .theOpen: Colors.pink,
        .theConscientious: Colors.cyan,
        .theExtrovert: Colors.warning,
        .theNeurotic: Colors.purple,
        .assistant: Colors.teal,
        .codingAssistant: Colors.purple,
        .codingAgent: Colors.purple,
    ]

    var tintColor: Color {
        if case .custom = self { return Colors.neutral }
        return Self.tintColorMap[self] ?? Colors.neutral
    }
}

// MARK: - TeamRoleDefinition Color Extensions

/// Color properties kept in Views layer so the domain model stays free of SwiftUI dependencies.
extension TeamRoleDefinition {

    /// Display color for the role's completion type badge.
    var completionTypeDisplayColor: Color { completionType.displayColor }

    /// Resolved icon foreground color from hex string.
    var resolvedIconColor: Color {
        Color(hex: iconColor) ?? .white
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
        .font(.caption.weight(.semibold))
        .foregroundStyle(tintColor)
    guard let teamSuffix, !teamSuffix.isEmpty else { return base }
    return base + Text(" from \(teamSuffix)")
        .font(.caption.weight(.regular))
        .foregroundStyle(.secondary)
}

// MARK: - RoleCompletionType Display Extensions

extension RoleCompletionType {
    private static let displayColorMap: [RoleCompletionType: Color] = [
        .producing: Colors.success,
        .advisory: Colors.teal,
        .observer: .secondary,
    ]

    var displayColor: Color { Self.displayColorMap[self] ?? .secondary }
}

// MARK: - ChangeRequestStatus Display Extensions

extension ChangeRequestStatus {
    private static let statusColorMap: [ChangeRequestStatus: Color] = [
        .pending: .secondary,
        .approved: Colors.success,
        .rejected: Colors.error,
        .escalated: Colors.warning,
        .supervisorApproved: Colors.success,
        .supervisorRejected: Colors.error,
        .failed: Colors.error,
    ]

    var statusColor: Color { Self.statusColorMap[self] ?? .secondary }
}

// MARK: - TeamMessageType Display Extensions

extension TeamMessageType {
    private static let iconMap: [TeamMessageType: String] = [
        .discussion: "bubble.left",
        .question: "questionmark.circle",
        .proposal: "lightbulb",
        .objection: "exclamationmark.triangle",
        .agreement: "hand.thumbsup",
        .summary: "doc.text",
        .conclusion: "checkmark.seal",
    ]

    var icon: String { Self.iconMap[self] ?? "bubble.left" }
}
