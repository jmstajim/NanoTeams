import SwiftUI

// MARK: - Help Settings View

struct HelpSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                SettingsCard(header: "Keyboard Shortcuts", systemImage: "command") {
                    KeyboardShortcutsSheetView(embedInSettings: true)
                }

                SettingsCard(header: "Resources", systemImage: "link") {
                    VStack(spacing: 0) {
                        ResourceLinkRow(
                            title: "GitHub Repository",
                            icon: "arrow.up.right.square",
                            url: AppURLs.githubRepository
                        )
                        ResourceLinkRow(
                            title: "Documentation",
                            icon: "book",
                            url: AppURLs.documentation
                        )
                        ResourceLinkRow(
                            title: "Support",
                            icon: "lifepreserver",
                            url: AppURLs.support
                        )
                    }
                }

                SettingsCard(header: "About", systemImage: "info.circle") {
                    VStack(spacing: Spacing.s) {
                        aboutRow("Version", value: AppVersion.current)
                        aboutRow("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                    }
                }
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }

    private func aboutRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(Typography.subheadline)
            Spacer()
            Text(value)
                .font(Typography.subheadline)
                .foregroundStyle(Colors.textSecondary)
                .monospacedDigit()
        }
    }
}

/// Resource link row for Help section
struct ResourceLinkRow: View {
    let title: String
    let icon: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            rowContent
        }
        .buttonStyle(.plain)
    }

    private var rowContent: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: icon)
                .foregroundStyle(Colors.textSecondary)
                .frame(width: 20)
            Text(title)
                .font(Typography.subheadline)
                .foregroundStyle(Colors.textPrimary)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Spacing.xs)
    }
}

#Preview {
    HelpSettingsView()
        .frame(width: 500, height: 500)
}
