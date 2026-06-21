import SwiftUI

/// 5-tier corner radius system — near-sharp (a terminal is a grid of cells).
/// Progression: 1 → 2 → 2 → 3 → 4.
nonisolated enum CornerRadius {
    /// Accent radius (1pt) — decorative accent bars, thin edge strips
    static let accent: CGFloat = 1
    /// Micro radius (2pt) — graph labels, tiny inline pills
    static let micro: CGFloat = 2
    /// Small radius (2pt) — badges, pills, inputs, buttons, inner card sections
    static let small: CGFloat = 2
    /// Medium radius (3pt) — cards, panels, banners (workhorse)
    static let medium: CGFloat = 3
    /// Large radius (4pt) — role nodes, modals, prominent elements
    static let large: CGFloat = 4
}

// MARK: - Squircle Convenience

extension RoundedRectangle {
    /// Squircle-style rounded rectangle (continuous curve).
    /// Preferred over `RoundedRectangle(cornerRadius:)` for consistent squircle corners.
    static func squircle(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
