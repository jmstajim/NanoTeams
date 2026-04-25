import SwiftUI

/// Mic button bound to the shared `DictationService`. Routes the user to
/// Settings → Dictation when no language is configured.
struct DictationMicButton: View {

    @Binding var text: String
    @Environment(DictationService.self) private var dictation
    @Environment(\.openWindow) private var openWindow
    @AppStorage(UserDefaultsKeys.selectedSettingsTab)
    private var selectedSettingsTab: SettingsView.SettingsTab = .llm

    @State private var ownerID = UUID()
    @State private var anchorOffset: Int?
    @State private var lastPartialLength: Int = 0

    private var isActiveOwner: Bool { dictation.activeOwnerID == ownerID }
    private var isListeningHere: Bool { isActiveOwner && dictation.isListening }

    /// Dictation requires macOS 26+ (SpeechAnalyzer + DictationTranscriber).
    /// On older hosts we disable the button outright — tooltip explains why.
    private var isAvailable: Bool {
        if #available(macOS 26, iOS 26, visionOS 26, *) { return true }
        return false
    }

    private var iconTint: Color {
        if !isAvailable { return Colors.textTertiary }
        if dictation.lastErrorMessage != nil && !isListeningHere { return Colors.error }
        if isListeningHere { return Colors.error }
        return Colors.accent
    }

    var body: some View {
        Button(action: handleTap) {
            Image(systemName: isListeningHere ? "mic.circle.fill" : "mic.circle")
                .font(.title2)
                .foregroundStyle(iconTint)
                .symbolEffect(.pulse, options: .repeating, isActive: isListeningHere)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help(tooltip)
        .accessibilityLabel("Dictate")
        .onChange(of: dictation.transcript) { _, newPartial in
            guard isListeningHere, anchorOffset != nil else { return }
            applyPartial(newPartial)
        }
        .onChange(of: dictation.activeOwnerID) { _, newOwner in
            if newOwner == ownerID {
                // We became active — anchor at current end.
                anchorOffset = text.count
                lastPartialLength = 0
            } else {
                anchorOffset = nil
                lastPartialLength = 0
            }
        }
    }

    // MARK: - Tap handling

    /// listening → stop · no language → open Settings → Dictation · else → start.
    private func handleTap() {
        if isListeningHere {
            Task { await dictation.toggle(ownerID: ownerID) }
        } else if !dictation.hasUserSelectedLocales {
            selectedSettingsTab = .dictation
            openWindow(id: "settings")
        } else {
            Task { await dictation.toggle(ownerID: ownerID) }
        }
    }

    // MARK: - Text mutation

    /// Delegates the anchor/replace computation to the pure `DictationTextInserter`
    /// (tested separately) and applies the outcome. If the inserter reports
    /// drift — i.e. the user edited the dictated tail out from under us —
    /// reset the anchor so the next partial starts a fresh region rather than
    /// silently overwriting unrelated text.
    private func applyPartial(_ partial: String) {
        guard let anchor = anchorOffset else { return }
        let outcome = DictationTextInserter.apply(
            partial: partial,
            to: text,
            anchor: anchor,
            lastLength: lastPartialLength
        )
        text = outcome.newText
        lastPartialLength = outcome.newLength
        if outcome.drifted {
            anchorOffset = text.count
            lastPartialLength = 0
        }
    }

    // MARK: - Tooltip

    private var tooltip: String {
        if !isAvailable { return "Dictation requires macOS 26 or later." }
        if let error = dictation.lastErrorMessage { return error }
        if isListeningHere { return "Tap to stop dictation" }
        if !dictation.hasUserSelectedLocales {
            return "No dictation language selected — tap to choose one in Settings"
        }
        if dictation.activeLocales.isEmpty { return "Tap to dictate" }
        let codes = dictation.activeLocales
            .map { $0.identifier.replacingOccurrences(of: "_", with: "-") }
            .joined(separator: ", ")
        return "Dictate in: \(codes)"
    }
}

#Preview("Idle") {
    @Previewable @State var text = ""
    DictationMicButton(text: $text)
        .padding()
        .environment(DictationService())
}

#Preview("With existing text") {
    @Previewable @State var text = "Some text already typed"
    DictationMicButton(text: $text)
        .padding()
        .environment(DictationService())
}
