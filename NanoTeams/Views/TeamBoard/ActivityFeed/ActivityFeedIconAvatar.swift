import SwiftUI

/// Icon-based avatar for activity feed items (notifications, change requests).
/// For role-based avatars, use ``ActivityFeedRoleAvatar`` instead.
struct ActivityFeedIconAvatar: View {
    let icon: String
    let color: Color
    var size: CGFloat = ActivityCardTokens.avatarSize

    @ScaledMetric(relativeTo: .caption) private var iconScale: CGFloat = 1.0

    var body: some View {
        // Squared icon avatar — matches `ActivityFeedRoleAvatar` (Pass 16)
        // so notifications and role rows render on the same chrome.
        ZStack {
            RoundedRectangle.squircle(CornerRadius.small)
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
        ("questionmark.bubble", "Question", Colors.warning),
        ("exclamationmark.triangle", "Error", Colors.error),
        ("arrow.triangle.2.circlepath", "Change", Colors.info),
        ("checkmark.circle", "Done", Colors.success),
    ]
    HStack(spacing: 16) {
        ForEach(items, id: \.0) { icon, label, color in
            VStack(spacing: 6) {
                ActivityFeedIconAvatar(icon: icon, color: color)
                Text(label).font(Typography.caption2).foregroundStyle(Colors.textSecondary)
            }
        }
    }
    .padding()
    .background(Colors.surfacePrimary)
}

#Preview("Size Variants") {
    HStack(spacing: 16) {
        VStack(spacing: 6) {
            ActivityFeedIconAvatar(icon: "bell", color: Colors.info, size: 20)
            Text("20pt").font(Typography.caption2).foregroundStyle(Colors.textSecondary)
        }
        VStack(spacing: 6) {
            ActivityFeedIconAvatar(icon: "exclamationmark.triangle", color: Colors.warning)
            Text("Default").font(Typography.caption2).foregroundStyle(Colors.textSecondary)
        }
        VStack(spacing: 6) {
            ActivityFeedIconAvatar(icon: "checkmark.seal", color: Colors.success, size: 40)
            Text("40pt").font(Typography.caption2).foregroundStyle(Colors.textSecondary)
        }
    }
    .padding()
    .background(Colors.surfacePrimary)
}
