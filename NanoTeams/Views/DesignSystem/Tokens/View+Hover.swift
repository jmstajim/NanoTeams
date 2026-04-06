import SwiftUI

// MARK: - Hover Tracking

extension View {
    /// Binds a Bool state variable to the view's hover state.
    /// Replaces the repetitive `.onHover { isHovered = $0 }` pattern.
    func trackHover(_ isHovered: Binding<Bool>) -> some View {
        onHover { isHovered.wrappedValue = $0 }
    }
}
