import SwiftUI

// MARK: - Editor Sheet Close Policy (pure, testable)

/// What Cancel does in a Team Editor sheet — the button, and Escape through its `.cancelAction`
/// shortcut — for the Role Editor and the Artifact Editor alike. Until 2026-11-08 both dismissed
/// with no question, so one key could throw away a ticked tool or a typed description.
/// Pure so the rule is tested without a SwiftUI host (`RoleEditorSaveAndCloseTests`).
nonisolated enum EditorSheetClosePolicy {

    enum Decision: Equatable {
        /// Nothing would be lost.
        case close
        /// The draft holds edits Save would store: ask before throwing them away.
        case confirmDiscard
        /// A Save is waiting for its write: closing would hide the answer it was pressed for.
        case ignore
    }

    static func onCancel(hasUnsavedChanges: Bool, isSaving: Bool) -> Decision {
        if isSaving { return .ignore }
        return hasUnsavedChanges ? .confirmDiscard : .close
    }
}

// MARK: - What both sheets show around it

/// Why the last Save did not land — the line a sheet that stayed open shows above its content,
/// so it stays in view whatever the person scrolls to.
struct EditorSheetSaveErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            StatusGlyph(glyph: TerminalGlyph.failed, color: Colors.error)
            Text(message)
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.errorTint))
    }
}

extension View {
    /// The question `EditorSheetClosePolicy.Decision.confirmDiscard` asks — the same words in
    /// every Team Editor sheet, naming what would be thrown away ("role", "artifact").
    func discardChangesConfirmation(
        of subject: String,
        isPresented: Binding<Bool>,
        onDiscard: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Discard your changes to this \(subject)?", isPresented: isPresented, titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive, action: onDiscard)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("They have not been saved.")
        }
    }
}
