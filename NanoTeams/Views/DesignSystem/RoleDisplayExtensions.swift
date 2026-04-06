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
    func roleName(for roleID: String) -> String {
        first(where: { $0.id == roleID })?.name
            ?? first(where: { $0.systemRoleID == roleID })?.name
            ?? Role.builtInRole(for: roleID)?.displayName
            ?? roleID
    }
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
