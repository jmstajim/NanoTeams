import SwiftUI

/// Pure data + presentation for Watchtower's "Setup" shelf.
///
/// Owns the four predicates that decide which tip cards are visible, plus the
/// visual SwiftUI shelf. Lives in its own subview so its `LLMStatusMonitor`
/// observation doesn't force the rest of `WatchtowerView` to re-evaluate on
/// every reachability poll.
struct WatchtowerSetupSection: View {
    @Environment(StoreConfiguration.self) private var config
    @Environment(LLMStatusMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage(UserDefaultsKeys.selectedSettingsTab)
    private var selectedSettingsTab: SettingsView.SettingsTab = .llm

    var body: some View {
        let visible = Self.visibleTips(
            llmReachable: monitor.isReachable,
            exploratorySearchEnabled: config.exploratorySearchEnabled,
            visionConfigured: config.isVisionConfigured,
            dictationLocalesEmpty: config.dictationLocaleIdentifiers.isEmpty,
            dismissed: config.dismissedFeatureTipIDs
        )

        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                NTMSSectionHeader(title: "Setup", systemImage: "sparkles")
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: Spacing.m),
                              GridItem(.flexible(), spacing: Spacing.m)],
                    spacing: Spacing.m
                ) {
                    ForEach(visible, id: \.self) { tip in
                        tipCard(for: tip)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func tipCard(for tip: FeatureTipID) -> some View {
        let copy = Self.copy(for: tip)
        WatchtowerFeatureTipCard(
            icon: copy.icon,
            title: copy.title,
            description: copy.description,
            tint: copy.tint,
            action: { openSettings(tab: copy.tab) },
            onDismiss: { config.dismiss(tip) }
        )
    }

    private func openSettings(tab: SettingsView.SettingsTab) {
        selectedSettingsTab = tab
        openWindow(id: "settings")
    }

    // MARK: - Pure helpers (unit-testable)

    /// Returns the ordered list of tips that should currently be shown.
    /// Order matches `FeatureTipID.allCases` (LLM first, per design).
    static func visibleTips(
        llmReachable: Bool,
        exploratorySearchEnabled: Bool,
        visionConfigured: Bool,
        dictationLocalesEmpty: Bool,
        dismissed: Set<String>
    ) -> [FeatureTipID] {
        FeatureTipID.allCases.filter { tip in
            guard !dismissed.contains(tip.rawValue) else { return false }
            switch tip {
            case .llm: return !llmReachable
            case .exploratorySearch: return !exploratorySearchEnabled
            case .vision: return !visionConfigured
            case .dictation: return dictationLocalesEmpty
            }
        }
    }

    struct Copy {
        let icon: String
        let title: String
        let description: String
        let tint: Color
        let tab: SettingsView.SettingsTab
    }

    static func copy(for tip: FeatureTipID) -> Copy {
        switch tip {
        case .llm:
            return Copy(
                icon: "brain.head.profile",
                title: "LLM",
                description: "Connect to an LM Studio server and pick a model — every role uses it.",
                tint: Colors.accent,
                tab: .llm
            )
        case .exploratorySearch:
            return Copy(
                icon: "binoculars",
                title: "Exploratory Search",
                description: "Index your work folder so roles can find code and docs by meaning, not just keywords.",
                tint: Colors.purple,
                tab: .exploratorySearch
            )
        case .vision:
            return Copy(
                icon: "eye",
                title: "Vision",
                description: "Let roles analyze screenshots and images using a vision-capable LLM.",
                tint: Colors.info,
                tab: .vision
            )
        case .dictation:
            return Copy(
                icon: "mic",
                title: "Dictation",
                description: "Speak tasks and answers — transcription runs entirely on-device.",
                tint: Colors.success,
                tab: .dictation
            )
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var monitor = LLMStatusMonitor()
    WatchtowerSetupSection()
        .environment(config)
        .environment(monitor)
        .padding(Spacing.l)
        .background(Colors.surfacePrimary)
}
