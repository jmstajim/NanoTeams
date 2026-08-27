import SwiftUI

/// Pure data + presentation for Watchtower's "Setup" shelf.
///
/// Owns the per-tip predicates that decide which tip cards are visible, plus the
/// visual SwiftUI shelf. Lives in its own subview so its inputs don't churn the rest
/// of `WatchtowerView`: the `LLMStatusMonitor` reachability poll, and the
/// Autovisor tip's `autovisorEnabled`. The latter is snapshot-derived, so it
/// re-reads on every manager snapshot reassignment while "Reviewing…" — even though
/// the flag's value is unchanged (observation is per stored property, not per value).
/// See CLAUDE.md #11.
struct WatchtowerSetupSection: View {
    @Environment(NTMSOrchestrator.self) private var store
    @Environment(StoreConfiguration.self) private var config
    @Environment(LLMStatusMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let visible = Self.visibleTips(
            llmReachable: monitor.isReachable,
            exploratorySearchEnabled: config.exploratorySearchEnabled,
            visionConfigured: config.isVisionConfigured,
            dictationLocalesEmpty: config.dictationLocaleIdentifiers.isEmpty,
            autovisorEnabled: store.workFolder?.settings.autovisorEnabled ?? false,
            hasWorkFolder: store.hasRealWorkFolder,
            dismissed: config.dismissedFeatureTipIDs
        )

        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                MonoLabel(text: "Setup", rule: true)
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
        SettingsNavigation.open(tab: tab, using: openWindow)
    }

    // MARK: - Pure helpers (unit-testable)

    /// Returns the ordered list of tips that should currently be shown.
    /// Order matches `FeatureTipID.allCases` (LLM first, per design).
    nonisolated static func visibleTips(
        llmReachable: Bool,
        exploratorySearchEnabled: Bool,
        visionConfigured: Bool,
        dictationLocalesEmpty: Bool,
        autovisorEnabled: Bool,
        hasWorkFolder: Bool,
        dismissed: Set<String>
    ) -> [FeatureTipID] {
        FeatureTipID.allCases.filter { tip in
            guard !dismissed.contains(tip.rawValue) else { return false }
            switch tip {
            case .llm: return !llmReachable
            case .exploratorySearch: return !exploratorySearchEnabled
            case .vision: return !visionConfigured
            case .dictation: return dictationLocalesEmpty
            case .autovisor: return hasWorkFolder && !autovisorEnabled
            case .bash: return true   // always offered until dismissed; Bash is on by default
            case .computerUse: return true   // always offered until dismissed; Manual approval by default
            }
        }
    }

    nonisolated struct Copy {
        let icon: String
        let title: String
        let description: String
        let tint: Color
        let tab: SettingsView.SettingsTab
    }

    nonisolated static func copy(for tip: FeatureTipID) -> Copy {
        switch tip {
        case .llm:
            return Copy(
                icon: "brain.head.profile",
                title: "LLM",
                description: "Connect to a local LLM server (LM Studio or Ollama) and pick a model — every role uses it.",
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
        case .autovisor:
            return Copy(
                icon: AutovisorConstants.symbolName,
                title: "Autovisor",
                description: "Let an automated supervisor watch this folder's tasks, answer their questions, and advance a goal on its own.",
                tint: Colors.cyan,
                tab: .autovisor
            )
        case .bash:
            return Copy(
                icon: "terminal",
                title: "Bash",
                description: "Let roles run shell commands with sandbox confinement and the allow/ask/deny rules you control.",
                tint: Colors.warning,
                tab: .bash
            )
        case .computerUse:
            return Copy(
                icon: "cursorarrow.rays",
                title: "Computer Use",
                description: "Let roles see the screen and control the mouse and keyboard — with per-action approval.",
                tint: Colors.warning,
                tab: .computerUse
            )
        }
    }
}


// MARK: - Preview

#Preview {
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var monitor = LLMStatusMonitor()
    WatchtowerSetupSection()
        .environment(store)
        .environment(config)
        .environment(monitor)
        .padding(Spacing.l)
        .background(Colors.surfacePrimary)
}
