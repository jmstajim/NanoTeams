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
    @State private var generationTask: Task<Void, Never>?
    @State private var idleContentHeight: CGFloat = 332
    @FocusState private var isFocused: Bool

    private var canSubmit: Bool {
        !taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    var body: some View {
        Group {
            if isGenerating {
                generatingBody
            } else {
                idleBody
            }
        }
        .padding(Spacing.l)
        .frame(width: 380)
        .background(Colors.surfaceBackground)
        .task { isFocused = true }
        .background {
            Button("", action: cancel)
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .animation(Animations.quick, value: isGenerating)
        .onChange(of: isGenerating) { _, newValue in
            if !newValue { isFocused = true }
        }
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            inputField
            if let errorMessage {
                errorBanner(errorMessage)
            }
            actionBar
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            idleContentHeight = newHeight
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Generate a team")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Colors.textPrimary)

                Text("Describe what you need the team for — a task, a project, or a goal.")
                    .font(.caption)
                    .foregroundStyle(Colors.textSecondary)
            }
            Spacer(minLength: 0)
            CloseButton(action: cancel)
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

            DictationMicButton(text: $taskDescription)

            Button {
                submit()
            } label: {
                Text("Generate")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canSubmit ? Colors.textOnAccent : Colors.textTertiary)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.vertical, Spacing.s)
                    .background(
                        Capsule()
                            .fill(canSubmit ? Colors.accent : Colors.surfaceElevated)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
            .animation(Animations.quick, value: canSubmit)
        }
    }

    // MARK: - Generating

    private var generatingBody: some View {
        VStack(spacing: Spacing.m) {
            Spacer(minLength: 0)
            NTMSLoader(.large)
            Text("Generating team…")
                .font(Typography.captionSemibold)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            capsuleCancelButton
        }
        .frame(maxWidth: .infinity, minHeight: idleContentHeight)
    }

    private var capsuleCancelButton: some View {
        Button(action: cancel) {
            Text("Cancel")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Colors.textSecondary)
                .padding(.horizontal, Spacing.standard)
                .padding(.vertical, Spacing.s)
                .background(Capsule().fill(Colors.surfaceElevated))
        }
        .buttonStyle(.plain)
    }

    private func cancel() {
        // `isGenerating = false` doubles as a sentinel read by the
        // `flushAndThen` closure in `submit()` — if cancel fires during the
        // dictation flush before `generationTask` is assigned, the closure
        // bails and never starts the request.
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        dictation.stop()
        dismiss()
    }

    private func submit() {
        let text = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        errorMessage = nil
        isGenerating = true

        // Flush pending dictation so the last spoken words land in
        // `taskDescription` before we read it.
        dictation.flushAndThen {
            guard isGenerating else {
                print("[GenerateTeamSheet] Submit aborted: cancelled during dictation flush")
                return
            }
            let finalText = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else {
                isGenerating = false
                errorMessage = "Description is empty after dictation flushed. Please type or speak it again."
                return
            }

            generationTask = Task {
                defer {
                    isGenerating = false
                    generationTask = nil
                }
                let error = await onGenerate(finalText)
                if Task.isCancelled {
                    if let error {
                        print("[GenerateTeamSheet] Dropping error after cancel: \(error)")
                    }
                    return
                }
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
