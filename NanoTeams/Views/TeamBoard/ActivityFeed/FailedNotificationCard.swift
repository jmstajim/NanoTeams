import SwiftUI

/// Card body for `ActivityNotificationType.failed` — shows the error message and a
/// "check role details" hint.
struct FailedNotificationCard: View {
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let error = errorMessage, !error.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    StatusGlyph(glyph: TerminalGlyph.failed, color: Colors.error)
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                        .lineLimit(3)
                }
            }
            Text("Check role details for more information.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
        }
    }
}
