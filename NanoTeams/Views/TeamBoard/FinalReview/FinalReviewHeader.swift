import SwiftUI

// MARK: - Final Review Header

/// Header bar for the Supervisor final review sheet with progress, close, and accept controls.
struct FinalReviewHeader: View {
    let taskTitle: String
    let progress: (ready: Int, total: Int, missing: Int)
    @Binding var isAcceptingTask: Bool
    let onAcceptTask: () async -> Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Supervisor Final Review")
                    .font(.title3.weight(.semibold))

                Text(taskTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: Spacing.s) {
                Image(systemName: progress.missing == 0 ? "checkmark.circle.fill" : "checklist")
                    .foregroundStyle(progress.missing == 0 ? Colors.success : Colors.warning)
                    .font(.caption)
                Text("\(progress.ready)/\(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if progress.missing > 0 {
                Text("\(progress.missing) missing")
                    .font(.caption)
                    .foregroundStyle(Colors.warning)
            }

            Button("Close") {
                onClose()
            }
            .buttonStyle(.bordered)
            .help("Close without accepting")

            Button {
                Task {
                    isAcceptingTask = true
                    let success = await onAcceptTask()
                    isAcceptingTask = false
                    if success {
                        onClose()
                    }
                }
            } label: {
                if isAcceptingTask {
                    NTMSLoader(.small)
                } else {
                    Label("Accept Task", systemImage: "checkmark.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Colors.emerald)
            .disabled(isAcceptingTask)
            .help("Accept the completed task and mark as Done")
        }
        .padding()
    }
}

#Preview("All Ready") {
    @Previewable @State var accepting = false
    FinalReviewHeader(
        taskTitle: "Implement notification system",
        progress: (ready: 3, total: 3, missing: 0),
        isAcceptingTask: $accepting,
        onAcceptTask: { true },
        onClose: {}
    )
    .background(Colors.surfacePrimary)
}

#Preview("Missing Artifacts") {
    @Previewable @State var accepting = false
    FinalReviewHeader(
        taskTitle: "Implement notification system",
        progress: (ready: 1, total: 3, missing: 2),
        isAcceptingTask: $accepting,
        onAcceptTask: { true },
        onClose: {}
    )
    .background(Colors.surfacePrimary)
}
