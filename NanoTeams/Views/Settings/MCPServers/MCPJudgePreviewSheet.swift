import AppKit
import SwiftUI

/// Read-only sheet showing the exact system prompt and user message template
/// sent to the MCP Auto approval judge (`MCPJudgeService`).
struct MCPJudgePreviewSheet: View {
    let strictness: MCPJudgeStrictness

    @Environment(\.dismiss) private var dismiss

    nonisolated static let sampleCall = MCPJudgeCall(
        serverDisplayName: "<server_name>",
        toolName: "mcp__<server_slug>__<tool_name>",
        toolTitle: "<tool_title>",
        toolDescription: "<approved_tool_description>",
        outgoing: MCPDynamicTool.OutgoingCall(
            arguments: .object(["<arg>": .string("<value>")]),
            headerParameters: ["Mcp-Param-Account": "<account_id>"]),
        annotations: .specDefaults,
        priorServerNames: [])

    nonisolated static func systemPrompt(strictness: MCPJudgeStrictness) -> String {
        MCPJudgeService.systemPrompt(strictness: strictness)
    }

    nonisolated static var userMessageTemplate: String {
        MCPJudgeService.userPrompt(call: sampleCall)
    }

    nonisolated static func renderedPrompt(strictness: MCPJudgeStrictness) -> String {
        MCPJudgeService.judgePromptPreview(strictness: strictness, call: sampleCall)
    }

    var body: some View {
        let rendered = Self.renderedPrompt(strictness: strictness)
        VStack(spacing: 0) {
            HStack {
                MonoLabel(text: "MCP Judge Prompt Preview", marker: true)

                TerminalStatusBadge.tag(label: "Auto · \(strictness.displayName)")

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rendered, forType: .string)
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

            ScrollView {
                Text(rendered)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Colors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Spacing.standard)
            }
            .background(Colors.surfacePrimary)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}
