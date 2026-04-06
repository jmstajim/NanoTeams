import SwiftUI

// MARK: - Connection Status

/// Shared state enum for LLM server connection checks — rendered by `LLMConnectionStatusPill`.
enum LLMConnectionStatus {
    case idle
    case checking
    case success
    case failure

    private static let badgeMap: [LLMConnectionStatus: (label: String, icon: String, color: Color, tint: Color)] = [
        .success: ("Connected", "checkmark.circle.fill", Colors.success, Colors.successTint),
        .failure: ("Failed", "xmark.circle.fill", Colors.error, Colors.errorTint),
    ]

    var badgeMetadata: (label: String, icon: String, color: Color, tint: Color)? { Self.badgeMap[self] }
}

struct LLMConnectionStatusPill: View {
    let status: LLMConnectionStatus

    var body: some View {
        if let meta = status.badgeMetadata {
            HStack(spacing: Spacing.xs) {
                Image(systemName: meta.icon)
                Text(meta.label)
            }
            .font(Typography.captionSemibold)
            .foregroundStyle(meta.color)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background(Capsule(style: .continuous).fill(meta.tint))
        }
    }
}

// MARK: - Stepper Row

/// Reusable stepper row: label + "Unlimited"/value + Stepper + optional caption.
struct LLMStepperSettingsRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(title)
                    .font(Typography.subheadline)

                Spacer()

                HStack(spacing: 4) {
                    Text(value == 0 ? "Unlimited" : "\(value)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 60, alignment: .trailing)
                    Stepper("", value: $value, in: range, step: step)
                        .labelsHidden()
                }
            }

            if let caption {
                Text(caption)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
        }
    }
}

// MARK: - Model Picker

/// Reusable model picker with fetch error display, refresh button, and auto-fetch on appear.
struct LLMModelPickerSection: View {
    @Binding var modelName: String
    let availableModels: [String]
    let fetchError: String?
    let isFetching: Bool
    var emptyLabel: String = "Select a model"
    let onFetch: () -> Void

    var body: some View {
        HStack {
            Picker("Model", selection: $modelName) {
                if modelName.isEmpty {
                    Text(emptyLabel).tag("")
                }
                if !modelName.isEmpty && !availableModels.contains(modelName) {
                    Text(modelName).tag(modelName)
                }
                ForEach(availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)

            Spacer()

            SettingsPillButton(
                title: availableModels.isEmpty ? "Fetch Models" : "Refresh",
                icon: "arrow.clockwise",
                isLoading: isFetching,
                action: onFetch
            )
            .disabled(isFetching)
        }
        .onAppear {
            if availableModels.isEmpty && !isFetching {
                onFetch()
            }
        }

        if let error = fetchError {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Colors.warning)
                    .font(Typography.caption)
                Text(error)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Elevated Text Field

/// TextField with surfaceElevated background, used inside settings cards.
struct LLMElevatedTextField: View {
    let label: String
    @Binding var text: String
    var prompt: String?

    init(_ label: String, text: Binding<String>, prompt: String? = nil) {
        self.label = label
        self._text = text
        self.prompt = prompt
    }

    var body: some View {
        TextField(label, text: $text, prompt: prompt.map { Text($0) })
            .textFieldStyle(.plain)
            .textContentType(.URL)
            .autocorrectionDisabled()
            .padding(Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                    .fill(Colors.surfaceElevated)
            )
    }
}
