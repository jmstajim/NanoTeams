import SwiftUI

/// Squared `xmark` close button used by overlay surfaces (Quick Capture panel,
/// modal sheets). Visually a small 18×18 tile in `Colors.surfaceElevated`.
/// Terminal-aesthetic squircle replaces what used to be a circular dot —
/// the DS mandates radius ≤ 4pt for all chrome (a terminal is a grid).
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(Typography.term2xs.weight(.semibold))
                .foregroundStyle(Colors.textSecondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceElevated))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

#Preview {
    CloseButton(action: {})
        .padding()
}
