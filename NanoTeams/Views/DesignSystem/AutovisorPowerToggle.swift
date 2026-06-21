import SwiftUI

/// Squared on/off control for the Autovisor. Green filled tile with a power
/// glyph when on (glowing while a review is running), dim outlined tile when
/// off. Was circular pre-Pass 18 — switched to a squircle to match the DS
/// sharp-corners rule (radius ≤ 4pt). The "power button" affordance still
/// reads through the `power` SF Symbol + green/dim color contrast.
struct AutovisorPowerToggle: View {
    let isOn: Bool
    let isRunning: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 46

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle.squircle(CornerRadius.large)
                    .fill(isOn ? Colors.success : Colors.surfaceElevated)
                    .overlay(
                        RoundedRectangle.squircle(CornerRadius.large)
                            .strokeBorder(isOn ? Color.clear : Colors.borderSubtle, lineWidth: 1)
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
            .contentShape(RoundedRectangle.squircle(CornerRadius.large))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Autovisor is on" : "Autovisor is off")
        .accessibilityHint("Turns the per-folder automated supervisor on or off")
    }
}
