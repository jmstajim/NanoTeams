import SwiftUI

/// Full-size editor for the Work Folder Context, presented as a sheet from the
/// read-only preview card in `WorkFolderSettingsView`. Chrome mirrors the house
/// editor sheets (`ArtifactEditorSheet` / `PromptPreviewSheet`): a `MonoLabel`
/// header bar + `TerminalDivider` + content. Pure `@Binding` — it mutates the
/// parent's draft; the parent owns the debounced autosave, so dismissal is
/// non-destructive and Escape ≡ Done.
struct WorkFolderContextEditorSheet: View {
    @Binding var contextDraft: String
    /// Whether the debounced save has not yet caught up with the draft
    /// (`WorkFolderContextDraftSync.hasUnsavedEdits`).
    let isSaving: Bool
    /// Another writer replaced the stored text while this draft held unsaved edits; the
    /// autosave waits for the person's choice (`WorkFolderContextDraftSync.replacement`).
    let replacedWhileEditing: Bool
    let onUseNewText: () -> Void
    let onKeepMine: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            TerminalDivider()

            VStack(alignment: .leading, spacing: Spacing.s) {
                if replacedWhileEditing {
                    WorkFolderContextReplacedBanner(onUseNewText: onUseNewText, onKeepMine: onKeepMine)
                }

                Text("Roles read it on every team whose prompt includes it. Describe what this folder is and how the team should work in it.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)

                TextEditor(text: $contextDraft)
                    .font(Typography.termBase)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .inputSurface(.editor) { PromptMarker() }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Colors.surfacePrimary)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var headerBar: some View {
        HStack(spacing: Spacing.s) {
            MonoLabel(text: "Work Folder Context", marker: true)

            Spacer()

            // Autosave makes dismissal non-destructive; the hint just tells the
            // user the last keystrokes are still in flight. A replacement waiting
            // for a choice is said by the banner, not by a spinner that never ends.
            if isSaving && !replacedWhileEditing { SavingIndicator() }

            // `.cancelAction` wires Escape to Done — safe because autosave
            // already persisted the edits (Escape ≡ Done here).
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.terminalSecondary)
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.m)
    }
}

/// The choice the page offers when the Work Folder Context was replaced — by Generate, the
/// Autovisor or an external agent — while the person's draft held edits not yet saved. Shown in
/// the editor sheet and on the card, so a sheet closed with the choice pending still offers it.
struct WorkFolderContextReplacedBanner: View {
    let onUseNewText: () -> Void
    let onKeepMine: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            StatusGlyph(glyph: TerminalGlyph.review, color: Colors.warning)
            Text("The context was replaced while you were editing. Your edits wait until you choose.")
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Use the new text", action: onUseNewText)
                .buttonStyle(.terminalSecondary)
            Button("Keep mine", action: onKeepMine)
                .buttonStyle(.terminalPrimary)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.warningTint))
    }
}

#Preview("Context editor") {
    @Previewable @State var draft = "A Swift 6 macOS app. Build with xcodebuild; tests mirror the source tree."
    WorkFolderContextEditorSheet(
        contextDraft: $draft, isSaving: false, replacedWhileEditing: false,
        onUseNewText: {}, onKeepMine: {})
}

#Preview("Context editor — replaced while editing") {
    @Previewable @State var draft = "A Swift 6 macOS app. Build with xcodebuild; tests mirror the source"
    WorkFolderContextEditorSheet(
        contextDraft: $draft, isSaving: true, replacedWhileEditing: true,
        onUseNewText: {}, onKeepMine: {})
}
