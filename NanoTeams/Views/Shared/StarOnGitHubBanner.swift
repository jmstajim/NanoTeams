import SwiftUI

// MARK: - Star on GitHub Banner

/// Gratitude row shown on the Watchtower app-update card and in Settings →
/// Updates. Message on the left, accent-filled "Star on GitHub" capsule CTA
/// on the right. Tapping the CTA opens the repo.
///
/// Two size variants:
/// - `.regular` — callout font, `accentTintStrong` rounded rectangle background
///   (Settings → Updates, stands alone above the Form sections).
/// - `.compact` — caption font, no background (sits inside the Watchtower card
///   which already has its own accent tint).
struct StarOnGitHubBanner: View {
    enum Size {
        case regular
        case compact
    }

    let size: Size

    init(size: Size = .regular) {
        self.size = size
    }

    var body: some View {
        HStack(spacing: innerSpacing) {
            Text("⭐ Your stars motivate me to keep going — thanks!")
                .font(messageFont)
                .foregroundStyle(messageColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSWorkspace.shared.open(AppURLs.githubRepository)
            } label: {
                Text("Star on GitHub")
                    .font(ctaFont)
                    .foregroundStyle(Colors.textOnAccent)
                    .padding(.horizontal, ctaHorizontalPadding)
                    .padding(.vertical, ctaVerticalPadding)
                    .background(Capsule(style: .continuous).fill(Colors.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, outerHorizontalPadding)
        .padding(.vertical, outerVerticalPadding)
        .background(backgroundShape)
    }

    // MARK: - Per-size styling

    private var innerSpacing: CGFloat {
        switch size {
        case .regular: Spacing.m
        case .compact: Spacing.s
        }
    }

    private var messageFont: Font {
        switch size {
        case .regular: .callout
        case .compact: .caption
        }
    }

    private var messageColor: Color {
        switch size {
        case .regular: .primary
        case .compact: .secondary
        }
    }

    private var ctaFont: Font {
        switch size {
        case .regular: .caption.weight(.bold)
        case .compact: .caption2.weight(.bold)
        }
    }

    private var ctaHorizontalPadding: CGFloat {
        switch size {
        case .regular: Spacing.m
        case .compact: Spacing.s
        }
    }

    private var ctaVerticalPadding: CGFloat {
        switch size {
        case .regular: Spacing.xs
        case .compact: Spacing.xxs
        }
    }

    private var outerHorizontalPadding: CGFloat {
        switch size {
        case .regular: Spacing.m
        case .compact: 0
        }
    }

    private var outerVerticalPadding: CGFloat {
        switch size {
        case .regular: Spacing.s
        case .compact: 0
        }
    }

    @ViewBuilder
    private var backgroundShape: some View {
        switch size {
        case .regular:
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Colors.accentTintStrong)
        case .compact:
            Color.clear
        }
    }
}

// MARK: - Preview

#Preview("Star on GitHub Banner") {
    VStack(spacing: Spacing.l) {
        StarOnGitHubBanner(size: .regular)
        StarOnGitHubBanner(size: .compact)
    }
    .padding()
    .frame(width: 600)
    .background(Colors.surfacePrimary)
}
