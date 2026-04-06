import SwiftUI

// MARK: - Sidebar Footer

/// Now-playing-bar style footer: settings on left, LLM status pill on right.
struct SidebarFooter: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.s) {
                Button {
                    openWindow(id: "settings")
                } label: {
                    Image(systemName: "gearshape")
                        .font(Typography.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                .fill(Colors.surfaceCard)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")

                Spacer(minLength: 0)

                LLMStatusIndicator()
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
        }
        .background(Colors.surfaceBackground)
    }
}

/// LLM reachability indicator. Tapping opens Settings at the LLM tab.
struct LLMStatusIndicator: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(LLMStatusMonitor.self) private var monitor
    @AppStorage(UserDefaultsKeys.selectedSettingsTab)
    private var selectedSettingsTab: SettingsView.SettingsTab = .llm

    var body: some View {
        let isReachable = monitor.isReachable
        Button {
            selectedSettingsTab = .llm
            openWindow(id: "settings")
        } label: {
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(isReachable ? Colors.success : Colors.error)
                    .frame(width: 6, height: 6)
                Text(isReachable ? "Online" : "Offline")
                    .font(Typography.caption)
                    .foregroundStyle(isReachable ? Colors.success : Colors.error)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(
                Capsule(style: .continuous).fill(isReachable ? Colors.successTint : Colors.errorTint)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isReachable ? "LLM is online" : "LLM is offline — click to configure")
        .accessibilityLabel("LLM status: \(isReachable ? "Online" : "Offline")")
    }
}

// MARK: - Previews

#Preview("Footer — LLM Online") {
    @Previewable @State var monitor = LLMStatusMonitor()
    SidebarFooter()
        .environment(monitor)
        .frame(width: 260)
}
