import SwiftUI

// MARK: - Help Settings View

struct HelpSettingsView: View {
    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                KeyboardShortcutsSheetView(embedInSettings: true)
            }

            Section("Resources") {
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

            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Build") {
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    }

    private var rowContent: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

#Preview {
    HelpSettingsView()
        .frame(width: 500, height: 500)
}
