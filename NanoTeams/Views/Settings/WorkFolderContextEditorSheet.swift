import SwiftUI

/// Full-size editor for the Work Folder Context, presented as a sheet from the
/// read-only preview card in `WorkFolderSettingsView`. Chrome mirrors the house
/// editor sheets (`ArtifactEditorSheet` / `PromptPreviewSheet`): a `MonoLabel`
/// header bar + `TerminalDivider` + content. Pure `@Binding` — it mutates the
/// parent's `contextDraft`; the parent owns the debounced autosave, so
/// dismissal is non-destructive and Escape ≡ Done.
struct WorkFolderContextEditorSheet: View {
    @Binding var contextDraft: String
    /// Whether the debounced save has not yet caught up with the draft — the
    /// parent computes `store.workFolder?.settings.context != contextDraft`.
    let isSaving: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            TerminalDivider()

            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Sent to all AI roles. Describe what this folder is and how the team should work in it.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)

                HStack(alignment: .top, spacing: Spacing.xs) {
                    PromptMarker()
                    TextEditor(text: $contextDraft)
                        .font(Typography.termBase)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(Colors.surfaceElevated)
                )
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
            // user the last keystrokes are still in flight.
            if isSaving { SavingIndicator() }

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
