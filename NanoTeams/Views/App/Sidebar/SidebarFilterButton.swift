import SwiftUI

/// Filter chip: text-only, capsule shape, no icons to save space.
struct SidebarFilterButton: View {
    let title: String
    let icon: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.captionSemibold)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, Spacing.xs)
                .foregroundStyle(isSelected ? Colors.surfaceBackground : .secondary)
                .background(
                    Capsule(style: .continuous).fill(
                        isSelected
                            ? Colors.accent
                            : isHovered
                                ? Colors.surfaceElevated
                                : Colors.surfaceCard
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(title), \(count) tasks")
    }
}

// MARK: - Previews

#Preview("Filter Buttons — All Selected") {
    HStack(spacing: Spacing.xs) {
        SidebarFilterButton(title: "All", icon: "tray.full", count: 8, isSelected: true, action: {})
        SidebarFilterButton(title: "Active", icon: "circle.inset.filled", count: 3, isSelected: false, action: {})
        SidebarFilterButton(title: "Done", icon: "checkmark.circle", count: 5, isSelected: false, action: {})
    }
    .padding(.horizontal, Spacing.m)
    .padding(.vertical)
    .frame(width: 260)
    .background(Colors.surfaceBackground)
}

#Preview("Filter Buttons — Active Selected") {
    HStack(spacing: Spacing.xs) {
        SidebarFilterButton(title: "All", icon: "tray.full", count: 8, isSelected: false, action: {})
        SidebarFilterButton(title: "Active", icon: "circle.inset.filled", count: 3, isSelected: true, action: {})
        SidebarFilterButton(title: "Done", icon: "checkmark.circle", count: 5, isSelected: false, action: {})
    }
    .padding(.horizontal, Spacing.m)
    .padding(.vertical)
    .frame(width: 260)
    .background(Colors.surfaceBackground)
}
