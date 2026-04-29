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

/// LLM-card stepper row: label + `SettingsStepperControl` + optional caption.
/// No leading icon and no hover shell — that's the General-card style covered
/// by `SettingsStepperRow`. The only LLM-specific bit here is the inline
/// caption support; the value cell + Stepper come from the shared atom.
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

                SettingsStepperControl(value: $value, range: range, step: step)
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

/// Reusable model picker with a Refresh button.
///
/// Pure presentation — does NOT auto-fetch on appear. The parent card is
/// responsible for triggering `loadIfNeeded` via `.task(id:)` (so the
/// shared `ModelCatalog` can dedupe across surfaces). The Refresh button
/// always force-refreshes. When the user has picked a non-default model,
/// an inline X reset button appears next to the picker to restore the
/// default — mirrors the inline-clear pattern on URL / token fields.
struct LLMModelPickerSection: View {
    @Binding var modelName: String
    let availableModels: [String]
    let isFetching: Bool
    var emptyLabel: String = "Select a model"
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Picker("Model", selection: $modelName) {
                if modelName.isEmpty {
                    Text(emptyLabel).font(Typography.mono).tag("")
                }
                if !modelName.isEmpty && !availableModels.contains(modelName) {
                    Text(modelName).font(Typography.mono).tag(modelName)
                }
                ForEach(availableModels, id: \.self) { model in
                    Text(model).font(Typography.mono).tag(model)
                }
            }
            .pickerStyle(.menu)

            if !modelName.isEmpty {
                Button {
                    modelName = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Use default model")
                .accessibilityLabel("Reset to default model")
            }

            Spacer()

            SettingsPillButton(
                title: "Refresh",
                icon: "arrow.clockwise",
                isLoading: isFetching,
                action: onRefresh
            )
            .disabled(isFetching)
        }
    }
}

// MARK: - Elevated Text Field

/// TextField with surfaceElevated background and an inline reset button
/// (Spotify-style) shown when the field's value differs from
/// `defaultValue`. Used inside settings cards for the Server URL field.
///
/// Two modes via `defaultValue`:
/// - `""` (default): the field's "default" is empty (= inherit from a
///   broader scope, e.g. override cards inheriting from global). The X
///   clears the field.
/// - non-empty: the field has a meaningful canonical default (e.g. the
///   global LLM URL has `http://127.0.0.1:1234`). The X restores that
///   value — the field is never genuinely empty in practice.
struct LLMElevatedTextField: View {
    let label: String
    @Binding var text: String
    var prompt: String?
    var defaultValue: String
    /// Fired on focus loss or Return — used by the global LLM card to
    /// auto-test connection so the user doesn't need to click Test
    /// Connection after editing the URL. The closure runs even when text
    /// hasn't changed (cheap; status pill confirms current reachability).
    var onCommit: (() -> Void)?

    @FocusState private var isFocused: Bool

    init(
        _ label: String,
        text: Binding<String>,
        prompt: String? = nil,
        defaultValue: String = "",
        onCommit: (() -> Void)? = nil
    ) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.defaultValue = defaultValue
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            TextField(label, text: $text, prompt: prompt.map { Text($0) })
                .textFieldStyle(.plain)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .font(Typography.mono)
                .focused($isFocused)
                .onSubmit { onCommit?() }
                .onChange(of: isFocused) { _, focused in
                    // Focus left the field — treat as a commit. Skip when
                    // gaining focus.
                    if !focused { onCommit?() }
                }

            if text != defaultValue {
                Button {
                    text = defaultValue
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help(defaultValue.isEmpty ? "Use default" : "Reset to \(defaultValue)")
                .accessibilityLabel("Reset to default")
            }
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                .fill(Colors.surfaceElevated)
        )
    }
}
