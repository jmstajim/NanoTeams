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
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: "sparkles")
                    .font(Typography.termXl)
                    .foregroundStyle(Colors.accent)
                    .symbolEffect(.pulse)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("NanoTeams \(release.tag) is ready")
                        .font(Typography.subheadlineSemibold)
                        .foregroundStyle(Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Release notes and downloads are on GitHub")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer()

                Button {
                    onUpdate()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.up.right.circle")
                            .font(Typography.caption)
                        Text("Open on GitHub")
                            .font(Typography.captionSemibold)
                    }
                    .foregroundStyle(Colors.textOnAccent)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.accent))
                    .scaleEffect(isUpdateHovered ? 1.03 : 1.0)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .trackHover($isUpdateHovered)
                .animation(Animations.quick, value: isUpdateHovered)

            }
            .padding(.trailing, Spacing.standard)

            if !trimmedBodyLines.isEmpty {
                Text(trimmedBodyLines.prefix(7).joined(separator: "\n"))
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .lineLimit(7)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle()
                .fill(Colors.accentBorder)
                .frame(height: 1)
                .padding(.horizontal, Spacing.xs)

            StarOnGitHubBanner()
        }
        .padding(Spacing.standard)
        .background(
            RoundedRectangle.squircle(CornerRadius.medium)
                .fill(Colors.accentTint)
        )
        .overlay(alignment: .topTrailing) {
            SkipButton(onSkip: onSkip)
        }
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovered ? Colors.textPrimary : Colors.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(Spacing.xs)
        .accessibilityLabel("Skip this version")
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
    .frame(width: 400)
    .background(Colors.surfacePrimary)
    .environment(store)
}
