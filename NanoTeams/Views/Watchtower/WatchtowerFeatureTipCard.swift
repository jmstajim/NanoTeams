import SwiftUI

/// Horizontal Setup-shelf card promoting an unconfigured Settings feature.
/// Small square gradient cover on the leading edge, title + description fill
/// the trailing side. Tap opens the feature's Settings tab; X persists a dismiss.
struct WatchtowerFeatureTipCard: View {
    let icon: String
    let title: String
    let description: String
    let tint: Color
    let action: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let coverSize: CGFloat = 56
    private static let glyphSize: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            cover

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.subheadlineSemibold)
                    .foregroundStyle(Colors.textPrimary)
                    .lineLimit(1)
                Text(description)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle.squircle(CornerRadius.medium)
                .fill(isHovered ? Colors.surfaceHover : Colors.surfaceCard)
        )
        .overlay(alignment: .topTrailing) { dismissButton }
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : Animations.quick) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(description)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Dismiss")) { onDismiss() }
        .help(description)
    }

    private var cover: some View {
        // Solid tint (no gradient) — DS monochrome+1 prefers flat color tiles
        // over decorative gradients. The icon glyph already provides the
        // visual interest; gradients here read as marketing flourish.
        Rectangle()
            .fill(tint)
            .frame(width: Self.coverSize, height: Self.coverSize)
            .clipShape(RoundedRectangle.squircle(CornerRadius.small))
        .overlay {
            Image(systemName: icon)
                .font(.system(size: Self.glyphSize, weight: .semibold))
                .foregroundStyle(Colors.textOnAccent)
                .accessibilityHidden(true)
        }
    }

    private var dismissButton: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Colors.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(Spacing.xs)
        .accessibilityLabel("Dismiss tip")
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: Spacing.m) {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.m) {
            WatchtowerFeatureTipCard(
                icon: "brain.head.profile",
                title: "LLM",
                description: "Connect to an LM Studio server and pick a model — every role uses it.",
                tint: Colors.accent,
                action: {},
                onDismiss: {}
            )
            WatchtowerFeatureTipCard(
                icon: "binoculars",
                title: "Exploratory Search",
                description: "Index your work folder so roles can find code and docs by meaning, not just keywords.",
                tint: Colors.purple,
                action: {},
                onDismiss: {}
            )
            WatchtowerFeatureTipCard(
                icon: "eye",
                title: "Vision",
                description: "Let roles analyze screenshots and images using a vision-capable LLM.",
                tint: Colors.info,
                action: {},
                onDismiss: {}
            )
            WatchtowerFeatureTipCard(
                icon: "mic",
                title: "Dictation",
                description: "Speak tasks and answers — transcription runs entirely on-device.",
                tint: Colors.success,
                action: {},
                onDismiss: {}
            )
        }
    }
    .padding(Spacing.l)
    .frame(width: 600)
    .background(Colors.surfacePrimary)
}
