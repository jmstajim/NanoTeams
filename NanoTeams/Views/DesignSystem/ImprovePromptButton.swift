import SwiftUI

/// "Improve this prompt" affordance. Streams the LLM rewrite live into the
/// bound `text` field (Apple Writing Tools style) — no popover, nothing to
/// keep open. While streaming the button is a stop control; after completion
/// a "Revert" chip restores the original.
///
/// All lifecycle lives in `PromptImprovementSession` (a testable state
/// machine); this view is a thin control over it. Config is read from the
/// app-wide `StoreConfiguration` environment (`globalLLMConfig`), so the
/// button stays a leaf and needs no orchestrator.
///
/// `isImproving` is an optional host mirror (precedent: `filePickerBinding`
/// in `MessageComposer`): hosts use it to gate submit and lock the field
/// while the stream runs.
struct ImprovePromptButton: View {

    @Binding var text: String
    var isImproving: Binding<Bool>? = nil

    @Environment(StoreConfiguration.self) private var config
    @Environment(DictationService.self) private var dictation

    @State private var session = PromptImprovementSession()

    /// Improve is available only when there's text to work on and dictation
    /// isn't writing into the same binding (mutual exclusion — both stream
    /// into `text`). Stays available while improving so the button can stop.
    private var canImprove: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !dictation.isListening
    }

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if session.canRevert {
                revertChip
            }
            mainButton
        }
        .animation(Animations.quick, value: session.canRevert)
        .onChange(of: text) { _, newValue in
            session.noteFieldTextChanged(newValue)
        }
        .onChange(of: session.isImproving) { _, improving in
            isImproving?.wrappedValue = improving
        }
        .onDisappear { session.handleDisappear() }
    }

    // MARK: - Main button (improve / stop / retry)

    private var mainButton: some View {
        Button(action: primaryAction) {
            Image(systemName: session.isImproving ? "stop.fill" : "sparkles")
                .font(Typography.termBase.weight(.medium))
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 24)
                .symbolEffect(.pulse, options: .repeating, isActive: session.isImproving)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!session.isImproving && !canImprove)
        .help(helpText)
        .accessibilityLabel(session.isImproving ? "Stop improving" : "Improve prompt")
    }

    private var iconTint: Color {
        if session.isImproving { return Colors.accent }
        if session.errorMessage != nil { return Colors.error }
        return canImprove ? Colors.accent : Colors.textTertiary
    }

    private var helpText: String {
        if session.isImproving { return "Stop improving" }
        if let error = session.errorMessage { return "\(error) — click to retry" }
        if dictation.isListening { return "Stop dictation before improving" }
        return "Improve this prompt with AI"
    }

    private func primaryAction() {
        if session.isImproving {
            session.stop()
        } else {
            session.start(
                config: config.globalLLMConfig,
                read: { text },
                write: { text = $0 }
            )
        }
    }

    // MARK: - Revert chip

    private var revertChip: some View {
        Button { session.revert() } label: {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "arrow.uturn.backward")
                Text("Revert")
                    .lineLimit(1)
            }
            .font(Typography.captionSemibold)
            .foregroundStyle(Colors.textSecondary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.surfaceElevated)
                    .overlay(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .strokeBorder(Colors.borderSubtle, lineWidth: 1)
                    )
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .help("Restore the original prompt")
        .accessibilityLabel("Revert improved prompt")
        .transition(.opacity)
    }
}

#Preview("Improve Prompt Button") {
    @Previewable @State var text = "make a calc"
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    HStack {
        ImprovePromptButton(text: $text)
    }
    .padding()
    .environment(store.configuration)
    .environment(DictationService())
}
