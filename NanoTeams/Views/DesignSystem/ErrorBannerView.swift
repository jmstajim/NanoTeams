import SwiftUI

// MARK: - Error Banner View

/// Floating error banner — appears at the top center like an iPhone notification.
/// Auto-dismisses after a timeout. Tap to dismiss immediately.
struct ErrorBannerView: View {
    let message: String
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Colors.error)

            Text(message)
                .font(Typography.subheadlineMedium)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.m)
        .background(
            RoundedRectangle.squircle(CornerRadius.large)
                .fill(Colors.errorTint)
        )
        .overlay {
            RoundedRectangle.squircle(CornerRadius.large)
                .strokeBorder(Colors.errorBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Tap to dismiss")
    }
}

// MARK: - Error Banner Modifier

/// ViewModifier that observes `NTMSOrchestrator.lastErrorMessage` and shows a floating
/// error banner at the top center with auto-dismiss.
struct ErrorBannerModifier: ViewModifier {
    @Environment(NTMSOrchestrator.self) private var store

    @State private var displayedMessage: String?
    @State private var dismissTask: Task<Void, Never>?

    private let autoDismissSeconds: Double = 4

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message = displayedMessage {
                    ErrorBannerView(message: message) {
                        dismiss()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, Spacing.l)
                }
            }
            .animation(Animations.spring, value: displayedMessage)
            .onChange(of: store.lastErrorMessage) { _, newValue in
                guard let newValue, !newValue.isEmpty else { return }
                store.lastErrorMessage = nil
                show(newValue)
            }
    }

    private func show(_ message: String) {
        dismissTask?.cancel()
        displayedMessage = message
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoDismissSeconds))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        displayedMessage = nil
    }
}

// MARK: - View Extension

extension View {
    /// Adds a floating error banner that appears when `store.lastErrorMessage` is set.
    func errorBanner() -> some View {
        modifier(ErrorBannerModifier())
    }
}
