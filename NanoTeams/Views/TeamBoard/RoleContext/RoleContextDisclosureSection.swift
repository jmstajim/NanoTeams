import SwiftUI

/// Expandable disclosure section used inside `RoleContextBanner` for consultations and scratchpad.
struct RoleContextDisclosureSection<Content: View>: View {
    let title: String
    let count: Int?
    let icon: String
    let color: Color
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(color)
                    Text(title)
                        .font(Typography.caption.weight(.medium))
                    if let count {
                        Text("(\(count))")
                            .font(Typography.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, Spacing.standard)
                .padding(.vertical, Spacing.s)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
    }
}
