import SwiftUI

/// Circular on/off control for the Autovisor. Green filled
/// circle with a power glyph when on (glowing while a review is running), dim
/// outlined circle when off. Strictly in design tokens.
struct AutovisorPowerToggle: View {
    let isOn: Bool
    let isRunning: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 46

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isOn ? Colors.success : Colors.surfaceElevated)
                    .overlay(
                        Circle().strokeBorder(isOn ? Color.clear : Colors.borderSubtle, lineWidth: 1)
                    )
                Image(systemName: "power")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(isOn ? Colors.surfaceBackground : Colors.textSecondary)
            }
            .frame(width: size, height: size)
            .shadow(color: (isOn && isRunning) ? Colors.success : .clear, radius: 9)
            .scaleEffect((isOn && isRunning) ? 1.05 : 1.0)
            .animationWithReduceMotion(Animations.spring, value: isOn)
            .animationWithReduceMotion(Animations.spring, value: isRunning)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Autovisor is on" : "Autovisor is off")
        .accessibilityHint("Turns the per-folder automated supervisor on or off")
    }
}
