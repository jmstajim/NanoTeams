import SwiftUI

/// Expandable "Thinking" disclosure section for a message bubble.
/// Auto-expands on appear when streaming and `expandedByDefault` is true.
struct MessageThinkingSection: View {
    let thinking: String
    let messageID: UUID
    let isStreaming: Bool
    let expandedByDefault: Bool
    @Binding var thinkingExpanded: Set<UUID>

    var body: some View {
        let isExpanded = thinkingExpanded.contains(messageID)

        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                if isStreaming {
                    NTMSLoader(.mini)
                        .frame(width: 14, height: 12)
                } else {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                Text(isStreaming ? "Thinking..." : "Thinking")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            if isExpanded {
                Text(thinking)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Spacing.s)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Colors.neutral)
                            .frame(width: 1.5)
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    thinkingExpanded.remove(messageID)
                } else {
                    thinkingExpanded.insert(messageID)
                }
            }
        }
        .onAppear {
            if isStreaming && expandedByDefault && !thinkingExpanded.contains(messageID) {
                thinkingExpanded.insert(messageID)
            }
        }
    }
}
