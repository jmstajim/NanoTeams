import AppKit
import SwiftUI

/// Read-only preview of the exact prompt the `bash` Auto judge receives — system
/// guidance (carrying the current restriction level) plus the user turn for a
/// sample command. Mirrors `PromptPreviewSheet`'s header / Copy / Done chrome.
/// The sample command is editable so the user can see how any command is framed.
struct BashJudgePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StoreConfiguration.self) private var config

    @State private var sampleCommand: String = "rm -rf build && npm install"
    @State private var workingDirectory: String = ""

    private var renderedPrompt: String {
        let trimmedDir = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return BashJudgeService.judgePromptPreview(
            policy: config.bashPolicy,
            command: sampleCommand,
            workingDirectory: trimmedDir.isEmpty ? nil : trimmedDir)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MonoLabel(text: "Judge Prompt Preview", marker: true)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(renderedPrompt, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(Typography.caption)
                }
                .buttonStyle(.terminalSecondary)
                .controlSize(.small)

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.terminalSecondary)
                    .controlSize(.small)
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.m)

            TerminalDivider()

            VStack(alignment: .leading, spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Sample command")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                    TextField("", text: $sampleCommand)
                        .textFieldStyle(.plain)
                        .terminalField()
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Working directory")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                    TextField("(project root)", text: $workingDirectory)
                        .textFieldStyle(.plain)
                        .terminalField()
                }
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.s)

            TerminalDivider()

            ScrollView {
                Text(renderedPrompt)
                    .font(Typography.monoCaption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Spacing.s)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
