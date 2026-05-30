import SwiftUI

// MARK: - Task Filter

enum TaskFilter: String, CaseIterable, Hashable {
    case all
    case running
    case done
    case recurring

    private static let metadata: [TaskFilter: (displayName: String, icon: String)] = [
        .running:   ("Active",    "circle.inset.filled"),
        .done:      ("Done",      "checkmark.circle.fill"),
        .all:       ("All",       "tray.full.fill"),
        .recurring: ("Recurring", "repeat"),
    ]

    var displayName: String { Self.metadata[self]!.displayName }
    var icon: String { Self.metadata[self]!.icon }
    /// The recurring filter renders as an icon-only chip; the rest are text.
    var isIconOnly: Bool { self == .recurring }
}


