import SwiftUI

/// Expansion toggle buttons shown in the activity feed header.
/// Receives state via bindings (Low Coupling — no direct @Environment dependency).
struct ActivityFeedExpansionControls: View {
    @Binding var thinkingExpanded: Bool
    @Binding var toolCallsExpanded: Bool
    @Binding var artifactsExpanded: Bool
    @Binding var debugEnabled: Bool

    var onThinkingToggle: () -> Void
    var onToolCallsToggle: () -> Void
    var onArtifactsToggle: () -> Void
    var onDebugToggle: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Button {
                thinkingExpanded.toggle()
                onThinkingToggle()
            } label: {
                Image(systemName: thinkingExpanded ? "brain.head.profile.fill" : "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(thinkingExpanded ? Colors.purple : Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help(thinkingExpanded ? "Collapse thinking sections" : "Expand thinking sections")

            Button {
                toolCallsExpanded.toggle()
                onToolCallsToggle()
            } label: {
                Image(systemName: toolCallsExpanded ? "terminal.fill" : "terminal")
                    .font(.caption)
                    .foregroundStyle(toolCallsExpanded ? Colors.info : Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help(toolCallsExpanded ? "Collapse tool calls" : "Expand tool calls")

            Button {
                artifactsExpanded.toggle()
                onArtifactsToggle()
            } label: {
                Image(systemName: artifactsExpanded ? "doc.text.fill" : "doc.text")
                    .font(.caption)
                    .foregroundStyle(artifactsExpanded ? Colors.artifact : Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help(artifactsExpanded ? "Collapse artifacts" : "Expand artifacts")

            Rectangle()
                .fill(Colors.borderSubtle)
                .frame(width: 1, height: 12)

            Button {
                debugEnabled.toggle()
                onDebugToggle()
            } label: {
                Image(systemName: debugEnabled ? "ladybug.fill" : "ladybug")
                    .font(.caption)
                    .foregroundStyle(debugEnabled ? Colors.warning : Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help(debugEnabled ? "Hide debug info (input & artifacts)" : "Show debug info (input & artifacts)")
        }
    }
}

#Preview("Toggle States") {
    @Previewable @State var thinking = false
    @Previewable @State var tools = false
    @Previewable @State var artifacts = false
    @Previewable @State var debug = false
    @Previewable @State var thinking2 = true
    @Previewable @State var tools2 = true
    @Previewable @State var artifacts2 = true
    @Previewable @State var debug2 = true
    VStack(spacing: 16) {
        VStack(spacing: 6) {
            Text("All collapsed").font(.caption).foregroundStyle(.secondary)
            ActivityFeedExpansionControls(
                thinkingExpanded: $thinking,
                toolCallsExpanded: $tools,
                artifactsExpanded: $artifacts,
                debugEnabled: $debug,
                onThinkingToggle: {}, onToolCallsToggle: {},
                onArtifactsToggle: {}, onDebugToggle: {}
            )
        }
        VStack(spacing: 6) {
            Text("All expanded").font(.caption).foregroundStyle(.secondary)
            ActivityFeedExpansionControls(
                thinkingExpanded: $thinking2,
                toolCallsExpanded: $tools2,
                artifactsExpanded: $artifacts2,
                debugEnabled: $debug2,
                onThinkingToggle: {}, onToolCallsToggle: {},
                onArtifactsToggle: {}, onDebugToggle: {}
            )
        }
    }
    .padding()
    .background(Colors.surfacePrimary)
}
