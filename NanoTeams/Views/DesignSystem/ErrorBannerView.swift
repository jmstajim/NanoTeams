import SwiftUI

// MARK: - Error Banner View

/// Floating banner — appears at the top center like an iPhone notification.
/// Auto-dismisses after a timeout. Tap to dismiss immediately.
struct ErrorBannerView: View {
    let message: String
    var style: Style = .error
    var onDismiss: () -> Void = {}

    enum Style {
        case error, info

        var icon: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .info: "info.circle.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .error: Colors.error
            case .info: Colors.neutral
            }
        }

        var fill: Color {
            switch self {
            case .error: Colors.errorTint
            case .info: Colors.neutralTint
            }
        }

        var border: Color {
            switch self {
            case .error: Colors.errorBorder
            case .info: Colors.neutralBorder
            }
        }
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: style.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(style.iconColor)

            Text(message)
                .font(Typography.subheadlineMedium)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.m)
        .background(
            RoundedRectangle.squircle(CornerRadius.large)
                .fill(style.fill)
        )
        .overlay {
            RoundedRectangle.squircle(CornerRadius.large)
                .strokeBorder(style.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style == .error ? "Error: " : "")\(message)")
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
    @State private var displayedStyle: ErrorBannerView.Style = .error
    @State private var dismissTask: Task<Void, Never>?

    private let autoDismissSeconds: Double = 4

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message = displayedMessage {
                    ErrorBannerView(message: message, style: displayedStyle) {
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
                show(newValue, style: .error)
            }
            .onChange(of: store.lastInfoMessage) { _, newValue in
                guard let newValue, !newValue.isEmpty else { return }
                store.lastInfoMessage = nil
                show(newValue, style: .info)
            }
    }

    private func show(_ message: String, style: ErrorBannerView.Style) {
        dismissTask?.cancel()
        displayedStyle = style
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
