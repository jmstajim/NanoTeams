import SwiftUI

// MARK: - Star on GitHub Banner

/// Gratitude row shown on the Watchtower app-update card and in Settings →
/// Updates. Message on the left, accent-filled "Star on GitHub" capsule CTA
/// on the right. Tapping the CTA opens the repo.
///
/// Two size variants:
/// - `.regular` — standalone card with accent-gradient background
///   (Settings → Updates, stands alone above the sections).
/// - `.compact` — inline row, no background (sits inside the Watchtower card
///   which already has its own accent tint).
struct StarOnGitHubBanner: View {
    enum Size {
        case regular
        case compact
    }

    let size: Size
    @Environment(NTMSOrchestrator.self) private var store
    @State private var isHovered = false

    init(size: Size = .regular) {
        self.size = size
    }

    var body: some View {
        HStack(spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Text("⭐")
                    .font(size == .regular ? .title3 : .callout)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Your stars motivate me to keep going")
                        .font(titleFont)
                        .foregroundStyle(Colors.textPrimary)
                    if size == .regular {
                        Text("Thank you for supporting NanoTeams!")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                URLOpener.open(AppURLs.githubRepository) { store.lastErrorMessage = $0 }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                    Text("Star on GitHub")
                        .font(ctaFont)
                }
                .foregroundStyle(Colors.textPrimary)
                .padding(.horizontal, ctaHorizontalPadding)
                .padding(.vertical, ctaVerticalPadding)
                .background(Capsule(style: .continuous).fill(Colors.gold))
                .scaleEffect(isHovered ? 1.03 : 1.0)
            }
            .buttonStyle(.plain)
            .trackHover($isHovered)
            .animation(Animations.quick, value: isHovered)
        }
        .padding(.horizontal, outerPadding)
        .padding(.vertical, outerPadding)
        .background(backgroundShape)
    }

    // MARK: - Per-size styling

    private var titleFont: Font {
        switch size {
        case .regular: .callout.weight(.medium)
        case .compact: Typography.caption
        }
    }

    private var ctaFont: Font {
        switch size {
        case .regular: Typography.captionSemibold
        case .compact: .caption2.weight(.bold)
        }
    }

    private var ctaHorizontalPadding: CGFloat {
        switch size {
        case .regular: Spacing.standard
        case .compact: Spacing.m
        }
    }

    private var ctaVerticalPadding: CGFloat {
        switch size {
        case .regular: Spacing.s
        case .compact: Spacing.xs
        }
    }

    private var outerPadding: CGFloat {
        switch size {
        case .regular: Spacing.standard
        case .compact: 0
        }
    }

    @ViewBuilder
    private var backgroundShape: some View {
        switch size {
        case .regular:
            RoundedRectangle.squircle(CornerRadius.medium)
                .fill(Colors.accentTintStrong)
        case .compact:
            Color.clear
        }
    }
}

// MARK: - Preview

#Preview("Star on GitHub Banner") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    VStack(spacing: Spacing.l) {
        StarOnGitHubBanner(size: .regular)
        StarOnGitHubBanner(size: .compact)
    }
    .padding()
    .frame(width: 600)
    .background(Colors.surfacePrimary)
    .environment(store)
}
