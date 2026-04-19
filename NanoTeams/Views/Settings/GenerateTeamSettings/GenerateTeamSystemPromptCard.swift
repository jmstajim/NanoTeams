import SwiftUI

/// Custom system-prompt card for team generation. Empty string = use built-in
/// `TeamGenerationService.defaultSystemPrompt`. When the user starts editing,
/// "Load Built-in Default" seeds the editor with the full default so it can be
/// modified.
struct GenerateTeamSystemPromptCard: View {
    @Bindable var config: StoreConfiguration

    private var isUsingDefault: Bool { config.teamGenSystemPromptOrNil == nil }

    var body: some View {
        SettingsCard(
            header: "System Prompt",
            systemImage: "text.quote",
            footer: "Empty = use the built-in team generation prompt."
        ) {
            Toggle(isOn: Binding(
                get: { isUsingDefault },
                set: { newValue in
                    if newValue {
                        config.teamGenSystemPrompt = ""
                    } else if config.teamGenSystemPrompt.isEmpty {
                        config.teamGenSystemPrompt = TeamGenerationService.defaultSystemPrompt
                    }
                }
            )) {
                Text("Use built-in default prompt")
                    .font(Typography.subheadline)
            }

            if !isUsingDefault {
                TextEditor(text: $config.teamGenSystemPrompt)
                    .font(Typography.caption)
                    .frame(minHeight: 280)
                    .borderedTextEditorStyle()

                HStack {
                    SettingsPillButton(title: "Load Built-in Default", icon: "doc.on.doc") {
                        config.teamGenSystemPrompt = TeamGenerationService.defaultSystemPrompt
                    }

                    Spacer()

                    Text("\(config.teamGenSystemPrompt.count) chars")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                        .monospacedDigit()
                }
            }
        }
    }
}

#Preview("System Prompt – default") {
    ScrollView {
        GenerateTeamSystemPromptCard(config: StoreConfiguration())
            .padding()
    }
    .background(Colors.surfacePrimary)
}
