import SwiftUI

/// Card body for `ActivityNotificationType.failed` — shows the error message and a
/// "check role details" hint.
struct FailedNotificationCard: View {
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let error = errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text("Check role details for more information.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
