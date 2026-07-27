import SwiftUI

/// Reusable animation presets (respect Reduce Motion when applied via modifier).
enum Animations {
    /// Standard spring animation - primary interaction feedback
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    /// Quick animation for micro-interactions
    static let quick = Animation.easeOut(duration: 0.15)
    /// Reduced motion alternative - simple fade
    static let reducedMotion = Animation.easeInOut(duration: 0.2)
}

// MARK: - Reduce Motion Animation Modifier

/// Animation modifier that respects the Reduce Motion accessibility setting
struct ReduceMotionAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content
            .animation(
                reduceMotion ? Animations.reducedMotion : animation,
                value: value
            )
    }
}

extension View {
    /// Apply animation that respects Reduce Motion accessibility setting
    func animationWithReduceMotion<V: Equatable>(
        _ animation: Animation = Animations.spring,
        value: V
    ) -> some View {
        modifier(ReduceMotionAnimationModifier(animation: animation, value: value))
    }
}
