import SwiftUI

/// Unified design tokens for Team Activity Feed cards.
enum ActivityCardTokens {
    /// Avatar size for all card types
    static let avatarSize: CGFloat = 32
    /// Card outer padding
    static let cardPadding: CGFloat = Spacing.m  // 12pt
    /// Inner content padding (collapsible sections)
    static let innerPadding: CGFloat = 10
    /// Spacing between content elements
    static let contentSpacing: CGFloat = Spacing.s  // 8pt
    /// Background opacity for dynamic-color tinted cards
    static let backgroundOpacity: Double = DynamicTintOpacity.background
    /// Card corner radius
    static let cornerRadius: CGFloat = CornerRadius.medium  // 10pt
    /// Inner section corner radius
    static let innerCornerRadius: CGFloat = CornerRadius.small  // 6pt
    /// Maximum height for expanded thinking sections (~5 lines of .callout text)
    static let thinkingMaxHeight: CGFloat = 90
    /// Maximum height for tool call arguments ScrollView
    static let toolArgsMaxHeight: CGFloat = 160
    /// Maximum height for tool call result ScrollView
    static let toolResultMaxHeight: CGFloat = 200
    /// Maximum height for artifact content ScrollView
    static let artifactContentMaxHeight: CGFloat = 300
}
