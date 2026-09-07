import SwiftUI

/// App-wide instruction text injected into every LLM system prompt that has a
/// tool loop (step execution, consultation, meeting, planning). Lives in
/// `StoreConfiguration.globalContext`.
///
/// The shipped default is empty (`AppDefaults.globalContext`): the slot belongs to
/// the user, and the one-tool rule that used to live here rides the `## Tool Calling`
/// body instead (`NativeLMStudioClient.oneToolPerResponseRule`), so it reaches only
/// calls that carry tools. A blank field emits no `## Global guidance` section at
/// all (the header is stripped, not left dangling) and costs zero tokens.
///
/// Reset goes through `StoreConfiguration.resetGlobalContextToDefault()`, never a
/// direct assignment: assigning the default persists a COPY of it and pins the
/// install to today's text forever after.
///
/// Edits take effect on the next request — the composed system prompt is built
/// per call, so an in-flight step picks up the new value on its next iteration.
struct GlobalContextCard: View {
    @Bindable var config: StoreConfiguration

    var body: some View {
        SettingsCard(
            header: "Global Context",
            systemImage: "text.book.closed",
            footer: "Empty by default — a blank field emits no Global guidance section at all. The one-tool-per-response rule ships inside the Tool Calling section of every call that has tools."
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Added to every LLM system prompt that has a tool loop (step execution, teammate consultation, team meetings). Use this for cross-cutting instructions you want every role to follow. Edits apply to new sessions — running steps keep the value cached at start.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $config.globalContext)
                    .font(.system(.callout, design: .monospaced))
                    .inputSurface(.editor, minHeight: 160) { PromptMarker() }

                HStack {
                    Button {
                        // NOT `config.globalContext = AppDefaults.globalContext`:
                        // that assignment's `didSet` persists a copy of the default
                        // and pins this install to today's text, which is exactly
                        // the cohort `purgeStaleDefaultGlobalContext` exists to
                        // unwind. The helper assigns, then drops the stored key.
                        config.resetGlobalContextToDefault()
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
