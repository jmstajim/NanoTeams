import SwiftUI

/// Unified Enter-to-send keyboard handling for answer text fields.
///
/// Two modes (controlled by `enterSendsMessage`):
/// - **Enter-sends** (default): Enter alone submits, Shift/Cmd+Enter inserts newline.
/// - **Normal**: Enter inserts newline, Cmd+Enter submits.
struct EnterSendsMessageModifier: ViewModifier {
    let enterSendsMessage: Bool
    let canSubmit: Bool
    let isSubmitting: Bool
    let onSubmit: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.return, phases: .down) { press in
                if enterSendsMessage {
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.command) {
                        insertNewline()
                    } else if canSubmit && !isSubmitting {
                        onSubmit()
                    }
                } else {
                    if press.modifiers.contains(.command) {
                        if canSubmit && !isSubmitting { onSubmit() }
                    } else {
                        insertNewline()
                    }
                }
                return .handled
            }
    }

    private func insertNewline() {
        NSApp.sendAction(
            #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)),
            to: nil,
            from: nil
        )
    }
}

extension View {
    func enterSendsMessage(
        _ enabled: Bool,
        canSubmit: Bool,
        isSubmitting: Bool = false,
        onSubmit: @escaping () -> Void
    ) -> some View {
        modifier(EnterSendsMessageModifier(
            enterSendsMessage: enabled,
            canSubmit: canSubmit,
            isSubmitting: isSubmitting,
            onSubmit: onSubmit
        ))
    }
}
