import SwiftUI

// MARK: - Final Review Header

/// Header bar for the Supervisor final review sheet — modelled on
/// `TeamBoardTopBar`'s terminal-style navbar. `task/<title>` ribbon on the left,
/// progress badge + Close/Accept controls on the right.
struct FinalReviewHeader: View {
    let taskTitle: String
    let progress: (ready: Int, total: Int, missing: Int)
    @Binding var isAcceptingTask: Bool
    let onAcceptTask: () async -> Bool
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            titleColumn

            Spacer(minLength: Spacing.m)

            progressBadge

            if progress.missing > 0 {
                missingPill
            }

            Button("Close") { onClose() }
                .buttonStyle(.terminalSecondary)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .help("Close without accepting")

            Button {
                Task {
                    isAcceptingTask = true
                    let success = await onAcceptTask()
                    isAcceptingTask = false
                    if success { onClose() }
                }
            } label: {
                if isAcceptingTask {
                    NTMSLoader(.small)
                } else {
                    Text("Accept Task")
                }
            }
            .buttonStyle(.terminalPrimary)
            .controlSize(.small)
            .disabled(isAcceptingTask || progress.missing > 0)
            .keyboardShortcut(.defaultAction)
            .help(progress.missing > 0
                ? "All required artifacts must be ready before accepting"
                : "Accept the completed task and mark as Done"
            )
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity)
        .background(Colors.surfaceBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Colors.borderSubtle).frame(height: 1)
        }
    }

    // MARK: - Title column

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: 0) {
                Text("task/")
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textTertiary)
                Text(taskTitle)
                    .font(Typography.termBase)
                    .fontWeight(.semibold)
                    .foregroundStyle(Colors.textPrimary)
            }
            .lineLimit(1)
            .truncationMode(.tail)

            Text("FINAL REVIEW")
                .font(Typography.term2xs)
                .tracking(Typography.labelTracking)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Status badges

    private var progressBadge: some View {
        let color = progress.missing == 0 ? Colors.success : Colors.warning
        let glyph = progress.missing == 0 ? TerminalGlyph.done : TerminalGlyph.review

        return HStack(spacing: Spacing.xxs) {
            Text(glyph)
                .font(Typography.termSm)
                .foregroundStyle(color)
            Text("\(progress.ready)/\(progress.total)")
                .font(Typography.term2xs.monospacedDigit())
                .tracking(Typography.labelTracking)
                .foregroundStyle(color)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(
            RoundedRectangle.squircle(CornerRadius.micro)
                .fill(color.opacity(DynamicTintOpacity.background))
        )
        .overlay(
            RoundedRectangle.squircle(CornerRadius.micro)
                .strokeBorder(color.opacity(DynamicTintOpacity.stroke), lineWidth: 1)
        )
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.ready) of \(progress.total) artifacts ready")
    }

    private var missingPill: some View {
        Text("\(progress.missing) MISSING")
            .font(Typography.term2xs)
            .tracking(Typography.labelTracking)
            .foregroundStyle(Colors.warning)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(
                RoundedRectangle.squircle(CornerRadius.micro)
                    .fill(Colors.warningTint)
            )
            .fixedSize()
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

#Preview("Accepting") {
    @Previewable @State var accepting = true
    FinalReviewHeader(
        taskTitle: "Implement notification system",
        progress: (ready: 3, total: 3, missing: 0),
        isAcceptingTask: $accepting,
        onAcceptTask: { try? await Task.sleep(for: .seconds(1)); return true },
        onClose: {}
    )
    .background(Colors.surfacePrimary)
}
