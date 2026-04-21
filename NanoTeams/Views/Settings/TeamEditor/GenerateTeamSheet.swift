import SwiftUI

/// Sheet for entering a task description before generating a team with AI.
struct GenerateTeamSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DictationService.self) private var dictation

    /// Callback invoked with the task description. Returns nil on success, an error message on failure.
    let onGenerate: (String) async -> String?

    @State private var taskDescription = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var canSubmit: Bool {
        !taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            inputField
            if let errorMessage {
                errorBanner(errorMessage)
            }
            actionBar
        }
        .padding(Spacing.l)
        .frame(width: 380)
        .background(Colors.surfaceBackground)
        .task { isFocused = true }
        .background {
            Button("", action: { if !isGenerating { cancel() } })
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Generate a team")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Colors.textPrimary)

            Text("Describe what you need the team for — a task, a project, or a goal.")
                .font(.caption)
                .foregroundStyle(Colors.textSecondary)
        }
    }

    // MARK: - Input

    private var inputField: some View {
        TextField(
            "e.g. Build a REST API with auth, or A team for weekly content planning…",
            text: $taskDescription,
            axis: .vertical
        )
        .lineLimit(5...15)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(Colors.textPrimary)
        .padding(Spacing.s)
        .frame(minHeight: 220, alignment: .topLeading)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevated)
        )
        .focused($isFocused)
        .disabled(isGenerating)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption2)
            .foregroundStyle(Colors.error)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: Spacing.s) {
            Spacer()

            Button {
                cancel()
            } label: {
                Text("Cancel")
                    .font(.subheadline)
                    .foregroundStyle(Colors.textSecondary)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            DictationMicButton(text: $taskDescription)

            Button {
                submit()
            } label: {
                HStack(spacing: 6) {
                    if isGenerating {
                        NTMSLoader(.inline)
                    }
                    Text(isGenerating ? "Generating…" : "Generate")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(canSubmit || isGenerating ? Colors.textOnAccent : Colors.textTertiary)
                }
                .padding(.horizontal, Spacing.standard)
                .padding(.vertical, Spacing.s)
                .background(
                    Capsule()
                        .fill(canSubmit || isGenerating ? Colors.accent : Colors.surfaceElevated)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
            .animation(Animations.quick, value: canSubmit)
            .animation(Animations.quick, value: isGenerating)
        }
    }

    private func cancel() {
        dictation.stop()
        dismiss()
    }

    private func submit() {
        // Flush pending dictation so the last spoken words land in
        // `taskDescription` before we read it.
        dictation.flushAndThen {
            let text = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isGenerating else { return }
            errorMessage = nil
            isGenerating = true

            Task {
                defer { isGenerating = false }
                let error = await onGenerate(text)
                if let error {
                    errorMessage = error
                } else {
                    dismiss()
                }
            }
        }
    }
}

#Preview("Generate Team Sheet") {
    GenerateTeamSheet(onGenerate: { _ in nil })
        .environment(DictationService())
}
