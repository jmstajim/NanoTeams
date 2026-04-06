import SwiftUI

/// Quick action button for Watchtower (New Task, Resume, Pause, etc.).
struct WatchtowerQuickActionButton: View {
    let title: String
    var subtitle: String?
    let icon: String
    let color: Color
    var isPrimary: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isPrimary ? .white : color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isPrimary ? .white : .primary)
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isPrimary ? Colors.textSecondary : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                    .fill(isPrimary
                        ? color
                        : isHovered
                            ? Colors.surfaceElevated
                            : Colors.surfaceCard)
            )
            .shadow(.card)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? .none : Animations.quick) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
        .help(subtitle ?? title)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        WatchtowerQuickActionButton(
            title: "New Task",
            subtitle: "Create a new task",
            icon: "plus.circle.fill",
            color: Colors.accent,
            isPrimary: true,
            action: {}
        )
        WatchtowerQuickActionButton(
            title: "Resume",
            subtitle: "Continue paused task",
            icon: "play.circle.fill",
            color: Colors.success,
            action: {}
        )
        WatchtowerQuickActionButton(
            title: "Pause",
            subtitle: "Pause running task",
            icon: "pause.circle.fill",
            color: Colors.warning,
            action: {}
        )
        WatchtowerQuickActionButton(
            title: "Accept Task",
            subtitle: "Review and close",
            icon: "checkmark.circle.fill",
            color: Colors.purple,
            action: {}
        )
    }
    .padding()
    .frame(width: 300)
    .background(Colors.surfacePrimary)
}
