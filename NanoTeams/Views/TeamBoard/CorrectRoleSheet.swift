import SwiftUI

/// Sheet for correcting an active role mid-pause. The role resumes with the
/// Supervisor's guidance applied — prior conversation, artifacts, and session
/// are preserved. Used from `RoleContextBanner` and graph node context menus
/// when the task is paused.
struct CorrectRoleSheet: View {
    let roleName: String
    @Binding var comment: String
    @Binding var isPresented: Bool
    let onSubmit: () -> Void

    @Environment(DictationService.self) private var dictation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SheetHeader(
                title: "Correct Role",
                subtitle: "\(roleName) will resume with your guidance applied",
                systemImage: "arrow.uturn.backward.circle.fill"
            )

            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Guidance")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                TextEditor(text: $comment)
                    .frame(height: SheetLayout.textEditorHeight)
                    .borderedTextEditorStyle()
                    .accessibilityLabel("Correction text")
            }

            HStack {
                Button("Cancel") {
                    dictation.stop()
                    comment = ""
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Spacer()

                DictationMicButton(text: $comment)

                Button("Apply & Resume") {
                    dictation.flushAndThen {
                        onSubmit()
                        comment = ""
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.l)
        .frame(width: SheetLayout.standardWidth)
    }
}

#Preview("Empty") {
    @Previewable @State var comment = ""
    @Previewable @State var isPresented = true
    CorrectRoleSheet(
        roleName: "Product Manager",
        comment: $comment,
        isPresented: $isPresented,
        onSubmit: {}
    )
    .environment(DictationService())
}
