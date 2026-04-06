import SwiftUI

/// Opacity constants for runtime-dynamic colors (notification.color, task.status.tintColor)
/// where pre-computed adaptive colors are not possible.
enum DynamicTintOpacity {
    /// Background tint for dynamic-color cards (subtle fill behind content)
    static let background: Double = 0.08
    /// Badge/pill background for dynamic colors
    static let badge: Double = 0.15
    /// Stroke overlay for dynamic colors (graph labels, etc.)
    static let stroke: Double = 0.3
}
