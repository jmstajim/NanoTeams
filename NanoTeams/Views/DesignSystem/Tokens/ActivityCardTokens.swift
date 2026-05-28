import SwiftUI

/// Unified design tokens for Team Activity Feed cards.
enum ActivityCardTokens {
    /// Avatar size for all card types
    static let avatarSize: CGFloat = 32
    /// Card outer padding
    static let cardPadding: CGFloat = Spacing.m  // 12pt
    /// Spacing between content elements
    static let contentSpacing: CGFloat = Spacing.s  // 8pt
    /// Background opacity for dynamic-color tinted cards
    static let backgroundOpacity: Double = DynamicTintOpacity.background
    /// Card corner radius
    static let cornerRadius: CGFloat = CornerRadius.medium  // 10pt
}
