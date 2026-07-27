import SwiftUI

/// Tri-state provider row for LLM override surfaces: inherit the global
/// provider (`nil`) or pin the override to a specific one. Needed when an
/// override URL points at a different provider's server than the global chat
/// LLM (e.g. global on LM Studio, one role on Ollama) — the provider decides
/// which wire format `LLMClientRouter` speaks to that URL.
struct LLMProviderOverridePicker: View {
    @Binding var selection: LLMProvider?

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text("Provider")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            TerminalSegmentedPicker(
                selection: $selection,
                options: [(nil, "Global")] + LLMProvider.allCases.map { ($0, $0.displayName) }
            )
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
    }
}
