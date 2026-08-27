import SwiftUI

// MARK: - Star on GitHub Banner

/// Star-on-GitHub prompt shown on the Watchtower app-update card and in Settings →
/// Updates. Message on the left, accent-filled "Star on GitHub" capsule CTA
/// on the right (matches the sibling "Open on GitHub" / "Update Now" CTAs).
/// Tapping the CTA opens the repo.
struct StarOnGitHubBanner: View {
    @Environment(NTMSOrchestrator.self) private var store
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Enjoying NanoTeams? Give it a star")
                    .font(Typography.subheadlineSemibold)
                    .foregroundStyle(Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("The easiest way to support a free app and it helps others find it.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Button {
                URLOpener.open(AppURLs.githubRepository) { store.lastErrorMessage = $0 }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "star")
                        .font(Typography.caption)
                    Text("Star on GitHub")
                        .font(Typography.captionSemibold)
                }
                .foregroundStyle(Colors.textOnAccent)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.xs)
                .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.accent))
                .scaleEffect(isHovered ? 1.03 : 1.0)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .trackHover($isHovered)
            .animation(Animations.quick, value: isHovered)
        }
        .padding(Spacing.standard)
        .background(
            RoundedRectangle.squircle(CornerRadius.medium)
                .fill(Colors.surfaceCard)
        )
    }
}

// MARK: - Preview

#Preview("Star on GitHub Banner") {
    @Previewable @State var store = PreviewStore.make()
    StarOnGitHubBanner()
        .padding()
        .frame(width: 600)
        .background(Colors.surfacePrimary)
        .environment(store)
}
