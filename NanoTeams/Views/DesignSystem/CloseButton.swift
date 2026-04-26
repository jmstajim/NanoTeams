import SwiftUI

/// Circular `xmark` close button used by overlay surfaces (Quick Capture panel,
/// modal sheets). Visually a small 18×18 dot in `Colors.surfaceElevated`.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Colors.surfaceElevated))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

#Preview {
    CloseButton(action: {})
        .padding()
}
