import SwiftUI

/// Sheet for restarting a role with optional instructions.
/// Used in both `TeamBoardView` (graph node context menu) and `ChatPanelView` (role detail panel).
struct RestartRoleSheet: View {
    let roleName: String
    @Binding var comment: String
    @Binding var isPresented: Bool
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SheetHeader(
                title: "Restart Role",
                subtitle: "This will reset \(roleName) and all downstream roles back to idle",
                systemImage: "arrow.counterclockwise"
            )

            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Instructions (optional)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                TextEditor(text: $comment)
                    .frame(height: SheetLayout.textEditorHeight)
                    .borderedTextEditorStyle()
                    .accessibilityLabel("Instructions for restart")

                Text("Provide instructions for the role on restart.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button("Cancel") {
                    comment = ""
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Restart") {
                    onRestart()
                    comment = ""
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Colors.warning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.l)
        .frame(width: SheetLayout.standardWidth)
    }
}

#Preview("Empty") {
    @Previewable @State var comment = ""
    @Previewable @State var isPresented = true
    RestartRoleSheet(
        roleName: "Software Engineer",
        comment: $comment,
        isPresented: $isPresented,
        onRestart: {}
    )
}

#Preview("With Instructions") {
    @Previewable @State var comment = "Please focus on error handling this time. The previous implementation was missing try/catch blocks around the network calls."
    @Previewable @State var isPresented = true
    RestartRoleSheet(
        roleName: "Software Engineer",
        comment: $comment,
        isPresented: $isPresented,
        onRestart: {}
    )
}

#Preview("Long Role Name") {
    @Previewable @State var comment = ""
    @Previewable @State var isPresented = true
    RestartRoleSheet(
        roleName: "Senior Principal Staff Software Engineer",
        comment: $comment,
        isPresented: $isPresented,
        onRestart: {}
    )
}
