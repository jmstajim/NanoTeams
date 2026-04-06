import SwiftUI

/// Icon-based avatar for activity feed items (notifications, change requests).
/// For role-based avatars, use ``ActivityFeedRoleAvatar`` instead.
struct ActivityFeedIconAvatar: View {
    let icon: String
    let color: Color
    var size: CGFloat = ActivityCardTokens.avatarSize

    @ScaledMetric(relativeTo: .caption) private var iconScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(DynamicTintOpacity.badge))
                .frame(width: size, height: size)
            Image(systemName: icon)
                .font(.system(size: size * 0.4 * iconScale, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

#Preview("Status Variants") {
    let items: [(String, String, Color)] = [
        ("questionmark.bubble.fill", "Question", Colors.warning),
        ("exclamationmark.triangle.fill", "Error", Colors.error),
        ("arrow.triangle.2.circlepath", "Change", Colors.info),
        ("checkmark.circle.fill", "Done", Colors.success),
    ]
    HStack(spacing: 16) {
        ForEach(items, id: \.0) { icon, label, color in
            VStack(spacing: 6) {
                ActivityFeedIconAvatar(icon: icon, color: color)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    .padding()
    .background(Colors.surfacePrimary)
}

#Preview("Size Variants") {
    HStack(spacing: 16) {
        VStack(spacing: 6) {
            ActivityFeedIconAvatar(icon: "bell.fill", color: Colors.info, size: 20)
            Text("20pt").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            ActivityFeedIconAvatar(icon: "exclamationmark.triangle.fill", color: Colors.warning)
            Text("Default").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            ActivityFeedIconAvatar(icon: "checkmark.seal.fill", color: Colors.success, size: 40)
            Text("40pt").font(.caption2).foregroundStyle(.secondary)
        }
    }
    .padding()
    .background(Colors.surfacePrimary)
}
