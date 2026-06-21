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
                MonoLabel(text: "Instructions (optional)", marker: true)

                TextEditor(text: $comment)
                    .frame(height: SheetLayout.textEditorHeight)
                    .borderedTextEditorStyle()
                    .accessibilityLabel("Instructions for restart")

                Text("Provide instructions for the role on restart.")
                    .font(Typography.caption2)
                    .foregroundStyle(Colors.textTertiary)
            }

            HStack {
                Button("Cancel") {
                    comment = ""
                    isPresented = false
                }
                .buttonStyle(.terminalSecondary)

                Spacer()

                Button("Restart") {
                    onRestart()
                    comment = ""
                    isPresented = false
                }
                .buttonStyle(.terminalDanger) // cascading reset of role + downstream — cautionary
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
