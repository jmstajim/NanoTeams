import SwiftUI

/// Sheet for requesting changes to a role's output with feedback text.
/// Used in `TeamActivityFeedView` when a role needs revision.
struct RevisionSheet: View {
    let roleName: String
    @Binding var comment: String
    @Binding var isPresented: Bool
    let onSubmit: () -> Void

    @Environment(DictationService.self) private var dictation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SheetHeader(
                title: "Request Changes",
                subtitle: "Provide feedback for \(roleName) to address",
                systemImage: "exclamationmark.bubble.fill"
            )

            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Feedback")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                TextEditor(text: $comment)
                    .frame(height: SheetLayout.textEditorHeight)
                    .borderedTextEditorStyle()
                    .accessibilityLabel("Feedback text")
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

                Button("Submit Feedback") {
                    // Flush pending dictation so the final transcript lands
                    // in `comment` before `onSubmit` reads it upstream.
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
    RevisionSheet(
        roleName: "Product Manager",
        comment: $comment,
        isPresented: $isPresented,
        onSubmit: {}
    )
    .environment(DictationService())
}

#Preview("With Feedback") {
    @Previewable @State var comment = "The requirements are missing non-functional requirements. Please add sections for:\n- Performance targets (response time, throughput)\n- Security requirements (authentication, authorization)\n- Scalability constraints"
    @Previewable @State var isPresented = true
    RevisionSheet(
        roleName: "Product Manager",
        comment: $comment,
        isPresented: $isPresented,
        onSubmit: {}
    )
    .environment(DictationService())
}

#Preview("Disabled Submit") {
    @Previewable @State var comment = "   "
    @Previewable @State var isPresented = true
    RevisionSheet(
        roleName: "UX Designer",
        comment: $comment,
        isPresented: $isPresented,
        onSubmit: {}
    )
    .environment(DictationService())
}
