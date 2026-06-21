import SwiftUI

/// Filter chip — terminal DS style: lowercase mono `name(count)` (or a small
/// SF Symbol for the icon-only Recurring filter). No card / no border — the
/// flat sidebar language signals selection through an accentTint fill + accent
/// text color, mirroring the row-selection chrome on the nav-rows above. The
/// inline `(N)` count rides dimmer than the name (textQuaternary) so the eye
/// lands on the name first, then the count saturates to accent on selection.
struct SidebarFilterButton: View {
    let title: String
    let icon: String
    let count: Int
    let isSelected: Bool
    /// When true, the chip shows `icon` instead of `title` (e.g. the Recurring filter).
    var iconOnly: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            chipLabel
                .lineLimit(1)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background {
                    // Squircle shape only paints when filled; an empty rest
                    // state leaves the chip visually flush with the sidebar
                    // background (no card affordance, terminal-coherent).
                    if isSelected {
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.accentTint)
                    } else if isHovered {
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.surfaceHover)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(title), \(count) tasks")
    }

    @ViewBuilder
    private var chipLabel: some View {
        if iconOnly {
            Image(systemName: icon)
                .font(Typography.captionSemibold)
                .foregroundStyle(isSelected ? Colors.accent : Colors.textTertiary)
        } else {
            // Inline `(N)` count, count dimmer than the name when unselected
            // so it reads as quiet metadata; on selection both saturate to
            // accent so the active filter glows as one unit.
            HStack(spacing: 0) {
                Text(title.lowercased())
                    .font(Typography.captionSemibold)
                    .foregroundStyle(isSelected ? Colors.accent : Colors.textTertiary)
                Text("(\(count))")
                    .font(Typography.captionSemibold)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Colors.accent : Colors.textQuaternary)
            }
        }
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
