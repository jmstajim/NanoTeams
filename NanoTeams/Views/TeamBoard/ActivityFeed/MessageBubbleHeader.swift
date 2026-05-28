import SwiftUI

/// Header row for a message bubble: role name (with optional ` from <Team>`
/// suffix in secondary gray for child-team items), optional source label,
/// timestamp.
struct MessageBubbleHeader: View {
    let roleName: String
    var teamSuffix: String? = nil
    let tintColor: Color
    let sourceLabel: String?
    let timestamp: Date
    let isStreaming: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            roleNameText(roleName: roleName, teamSuffix: teamSuffix, tintColor: tintColor)
            if let sourceLabel {
                Text("(\(sourceLabel))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isStreaming {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        MessageBubbleHeader(
            roleName: "Engineer",
            tintColor: .blue,
            sourceLabel: "GPT-5",
            timestamp: .now,
            isStreaming: false
        )

        MessageBubbleHeader(
            roleName: "Reviewer",
            tintColor: .orange,
            sourceLabel: nil,
            timestamp: .now,
            isStreaming: true
        )
    }
    .padding()
    .frame(maxWidth: 420)
}
