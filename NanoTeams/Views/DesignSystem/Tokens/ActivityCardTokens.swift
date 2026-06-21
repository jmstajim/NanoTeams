import SwiftUI

/// Unified design tokens for Team Activity Feed cards.
enum ActivityCardTokens {
    /// Avatar size for all card types
    static let avatarSize: CGFloat = 22
    /// Avatar icon glyph size — pinned to `Typography.termSm` (12pt) so every
    /// role avatar renders its SF Symbol at the same point size regardless of
    /// the glyph's intrinsic metrics.
    static let avatarIconSize: CGFloat = 12
    /// Card outer padding
    static let cardPadding: CGFloat = Spacing.m  // 12pt
    /// Spacing between content elements
    static let contentSpacing: CGFloat = Spacing.s  // 8pt
    /// Background opacity for dynamic-color tinted cards
    static let backgroundOpacity: Double = DynamicTintOpacity.background
    /// Card corner radius
    static let cornerRadius: CGFloat = CornerRadius.medium  // 10pt
}
