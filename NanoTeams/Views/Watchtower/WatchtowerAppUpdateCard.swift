import SwiftUI

// MARK: - Watchtower App Update Card

/// Watchtower card surfaced when `AppUpdateState.availableRelease` is non-nil.
/// Update → opens the GitHub release page (no auto-install). X → records the
/// tag in `StoreConfiguration.skippedAppUpdateTags`.
struct WatchtowerAppUpdateCard: View {
    let release: AppUpdateChecker.Release
    let onUpdate: () -> Void
    let onSkip: () -> Void

    @State private var isUpdateHovered = false

    /// Pure — exposed for testing the CRLF / whitespace handling.
    static func trimmedBodyLines(_ body: String) -> [String] {
        body
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var trimmedBodyLines: [String] {
        Self.trimmedBodyLines(release.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Colors.accent)
                    .symbolEffect(.pulse)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Update available")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Colors.textPrimary)

                    Text(release.tag)
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(Colors.accent)
                }

                Spacer()

                Button {
                    onUpdate()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                        Text("Update")
                            .font(Typography.captionSemibold)
                    }
                    .foregroundStyle(Colors.textOnAccent)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(Capsule(style: .continuous).fill(Colors.accent))
                    .scaleEffect(isUpdateHovered ? 1.03 : 1.0)
                }
                .buttonStyle(.plain)
                .trackHover($isUpdateHovered)
                .animation(Animations.quick, value: isUpdateHovered)

                SkipButton(onSkip: onSkip)
            }

            if !trimmedBodyLines.isEmpty {
                Text(trimmedBodyLines.prefix(2).joined(separator: "\n"))
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle()
                .fill(Colors.accentBorder)
                .frame(height: 1)
                .padding(.horizontal, Spacing.xs)

            StarOnGitHubBanner(size: .compact)
        }
        .padding(Spacing.standard)
        .background(
            RoundedRectangle.squircle(CornerRadius.medium)
                .fill(Colors.accentTint)
        )
    }
}

// MARK: - Skip Button

private struct SkipButton: View {
    let onSkip: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onSkip()
        } label: {
            Image(systemName: "xmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isHovered ? Colors.textPrimary : Colors.textTertiary)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(isHovered ? Colors.surfaceHover : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("Skip this update")
        .help("Skip this version")
        .trackHover($isHovered)
        .animation(Animations.quick, value: isHovered)
    }
}

// MARK: - Preview

#Preview("App Update Card") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    VStack(spacing: Spacing.m) {
        WatchtowerAppUpdateCard(
            release: .init(
                tag: "v1.2.0",
                htmlURL: URL(string: "https://github.com/jmstajim/NanoTeams/releases/tag/v1.2.0")!,
                body: "Added hash-based reconciliation of system templates.\nFixed a bug with deleted teams re-appearing on launch."
            ),
            onUpdate: {},
            onSkip: {}
        )
    }
    .padding()
    .frame(width: 600)
    .background(Colors.surfacePrimary)
    .environment(store)
}
