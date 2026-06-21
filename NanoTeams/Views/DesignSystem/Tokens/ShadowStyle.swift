import SwiftUI

/// Composite shadow token — bundles (color, radius, x, y) together so call sites
/// can't mix-and-match components from different shadow styles.
struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    // Flat terminal: depth comes from borders + the surface ladder, not blur.
    // Only modals/popovers keep a real drop shadow.

    /// Near-flat hairline — default resting card (depth is the border, not this)
    static let card = ShadowStyle(color: .black.opacity(0.35), radius: 1, x: 0, y: 1)
    /// Elevated — modals, popovers, dragging
    static let elevated = ShadowStyle(color: .black.opacity(0.45), radius: 12, x: 0, y: 8)
    /// Key shadow for keyboard-like elements
    static let key = ShadowStyle(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
    /// Minimal UI shadow (theme preview thumbnails)
    static let ui = ShadowStyle(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
    /// Floating notification banner — softer than `.elevated` (lower opacity,
    /// smaller y-offset) so it doesn't overpower the always-visible chrome below.
    static let banner = ShadowStyle(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
}

extension View {
    /// Apply a shadow style token.
    func shadow(_ style: ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}
