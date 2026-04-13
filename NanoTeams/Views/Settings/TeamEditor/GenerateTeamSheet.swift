import SwiftUI

/// Sheet for entering a task description before generating a team with AI.
struct GenerateTeamSheet: View {
    @Environment(\.dismiss) private var dismiss

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
        VStack(alignment: .leading, spacing: 0) {
            header
            inputField
            if let errorMessage {
                errorBanner(errorMessage)
            }
            Spacer(minLength: 0)
            actionBar
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(width: 480, height: 400)
        .background(Colors.surfaceBackground)
        .task { isFocused = true }
        .background {
            Button("", action: { if !isGenerating { dismiss() } })
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Generate a team")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Colors.textPrimary)
                .kerning(-0.5)

            Text("Describe your task and AI will build the team.")
                .font(.system(size: 14))
                .foregroundStyle(Colors.textSecondary)
        }
        .padding(.bottom, 28)
    }

    // MARK: - Input

    private var inputField: some View {
        TextField(
            "Build a REST API with authentication and tests…",
            text: $taskDescription,
            axis: .vertical
        )
        .lineLimit(3...6)
        .textFieldStyle(.plain)
        .font(.system(size: 15))
        .foregroundStyle(Colors.textPrimary)
        .focused($isFocused)
        .disabled(isGenerating)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(Colors.error)
            .padding(.top, Spacing.s)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 0) {
            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Colors.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            Button {
                submit()
            } label: {
                HStack(spacing: 8) {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Colors.textOnAccent)
                    }
                    Text(isGenerating ? "Generating…" : "Generate")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canSubmit || isGenerating ? Colors.textOnAccent : Colors.textTertiary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
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

    private func submit() {
        let text = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        errorMessage = nil
        isGenerating = true

        Task {
            // Always reset the in-flight flag before returning, even on cancellation,
            // so the sheet's button doesn't remain stuck in "Generating…".
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

#Preview("Generate Team Sheet") {
    GenerateTeamSheet(onGenerate: { _ in nil })
}
