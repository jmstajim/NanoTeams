import SwiftUI

/// App-wide instruction text appended to every LLM system prompt that has a
/// tool loop (step execution, consultation, meeting, planning). Lives in
/// `StoreConfiguration.globalContext`. Empty value disables the append.
///
/// Edits take effect on fresh sessions only — LM Studio caches `system_prompt`
/// in the response chain via `previous_response_id`, so an in-flight step keeps
/// the value baked in at session start.
struct GlobalContextCard: View {
    @Bindable var config: StoreConfiguration

    var body: some View {
        SettingsCard(
            header: "Global Context",
            systemImage: "text.book.closed"
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Appended to every LLM system prompt that has a tool loop (step, consultation, meeting, planning). Use this for cross-cutting instructions you want every role to follow. Edits apply to new sessions — running steps keep the value cached at start.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $config.globalContext)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .padding(Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                            .fill(Colors.surfaceElevated)
                    )

                HStack {
                    Button {
                        config.globalContext = AppDefaults.globalContext
                    } label: {
                        Text("Reset to Default")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(config.globalContext == AppDefaults.globalContext)

                    Spacer()

                    Text("\(config.globalContext.count) chars")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                }
            }
        }
    }
}
