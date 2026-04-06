import SwiftUI

/// 5-tier corner radius system.
/// Progression: 2 → 4 → 6 → 10 → 14 (clear perceptual hierarchy).
enum CornerRadius {
    /// Accent radius (2pt) — decorative accent bars, thin edge strips
    static let accent: CGFloat = 2
    /// Micro radius (4pt) — graph labels, tiny inline pills
    static let micro: CGFloat = 4
    /// Small radius (6pt) — badges, pills, text editors, inner card sections
    static let small: CGFloat = 6
    /// Medium radius (10pt) — cards, panels, banners (workhorse)
    static let medium: CGFloat = 10
    /// Large radius (14pt) — role nodes, action bar cards, prominent elements
    static let large: CGFloat = 14
}

// MARK: - Squircle Convenience

extension RoundedRectangle {
    /// Squircle-style rounded rectangle (continuous curve).
    /// Preferred over `RoundedRectangle(cornerRadius:)` for consistent squircle corners.
    static func squircle(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
