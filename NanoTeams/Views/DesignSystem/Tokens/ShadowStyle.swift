import SwiftUI

/// Composite shadow token — bundles (color, radius, x, y) together so call sites
/// can't mix-and-match components from different shadow styles.
struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    /// Subtle card shadow (default resting state)
    static let card = ShadowStyle(color: .black.opacity(0.2), radius: 8, x: 0, y: 2)
    /// Elevated card shadow (dragging, hover)
    static let elevated = ShadowStyle(color: .black.opacity(0.3), radius: 14, x: 0, y: 0)
    /// Key shadow for keyboard-like elements
    static let key = ShadowStyle(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
    /// Minimal UI shadow (theme preview thumbnails)
    static let ui = ShadowStyle(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
}

extension View {
    /// Apply a shadow style token.
    func shadow(_ style: ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}
