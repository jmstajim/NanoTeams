import SwiftUI

/// Horizontal Setup-shelf card promoting an unconfigured Settings feature.
/// Small filled tinted glyph inline with the title, description below.
/// Tap opens the feature's Settings tab; X persists a dismiss.
struct WatchtowerFeatureTipCard: View {
    let icon: String
    let title: String
    let description: String
    let tint: Color
    let action: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Deliberately NOT @ScaledMetric: on macOS 26.5 (SwiftUICore 7.5.3) the wrapper's
    // compiler-generated initializeWithCopy crashes with EXC_BAD_ACCESS (swift_retain on a
    // garbage pointer) the moment this view value is copied inside WatchtowerSetupSection's
    // ViewBuilder — the app dies at launch. Crash report 2026-07-02 19:09; see the CLAUDE.md
    // gotcha before re-adding Dynamic-Type scaling here.
    private static let glyphSize: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: Self.glyphSize, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Typography.subheadlineSemibold)
                    .foregroundStyle(Colors.textPrimary)
                    .lineLimit(1)
            }
            .padding(.trailing, Spacing.standard) // keep clear of the dismiss X
            Text(description)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
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
