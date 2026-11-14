import SwiftUI

/// One connection fact as the agent sheet draws it: the title, Copy beside it, the value in a
/// code box a person can select, and the words under it. Every fact is an agent's own, with
/// nothing left to fill in, so every one has Copy — until 2026-11-12 the Settings page drew the
/// same row for nobody, and withheld Copy from a value with `<agent-id>` still in it.
struct ExternalAgentsConnectionFactRow: View {
    let field: ExternalAgentsConnectionFacts.Field
    let isCopied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(field.title)
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Colors.textPrimary)
                Spacer(minLength: 0)
                SettingsPillButton(
                    title: isCopied ? "Copied" : "Copy",
                    icon: isCopied ? "checkmark" : "doc.on.doc",
                    action: copy)
            }
            Text(field.value)
                .font(Typography.termSm)
                .foregroundStyle(Colors.textPrimary)
                .textSelection(.enabled)
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceElevated))
            Text(field.caption)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
