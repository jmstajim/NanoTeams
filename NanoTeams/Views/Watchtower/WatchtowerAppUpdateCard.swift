import SwiftUI

// MARK: - Watchtower App Update Card

/// Card shown on the Watchtower when `AppUpdateState.availableRelease` is
/// non-nil. Click `Update` → opens the GitHub release page in the default
/// browser (we don't auto-install; install flow is manual per the plan's
/// "safe, native" constraint). Click X → records the tag in
/// `StoreConfiguration.skippedAppUpdateTags`.
///
/// Visual style mirrors `WatchtowerNotificationBanner` (colored tint + header
/// row + dismiss) so the card sits naturally alongside other Watchtower
/// notifications.
struct WatchtowerAppUpdateCard: View {
    let release: AppUpdateChecker.Release
    let onUpdate: () -> Void
    let onSkip: () -> Void

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
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(Colors.accent)

                Text("Update available: \(release.tag)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    onUpdate()
                } label: {
                    Text("Update")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                SkipButton(onSkip: onSkip)
            }

            if !trimmedBodyLines.isEmpty {
                // Two-line teaser from the release notes — full notes live on
                // the GitHub page the Update button opens.
                Text(trimmedBodyLines.prefix(2).joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Colors.accentTint)
        )
    }
}

// MARK: - Skip Button

private struct SkipButton: View {
    let onSkip: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            onSkip()
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isHovered || isFocused ? .primary : .secondary)
                .padding(6)
                .background(Circle().fill(isHovered || isFocused ? Colors.surfaceCard : Colors.surfaceHover))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip this update")
        .help("Skip this version")
        .focusable()
        .focused($isFocused)
        .trackHover($isHovered)
    }
}

// MARK: - Preview

#Preview("App Update Card") {
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
}
