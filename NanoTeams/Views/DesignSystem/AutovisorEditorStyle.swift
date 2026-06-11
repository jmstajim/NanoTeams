import SwiftUI

/// Shared look for the Autovisor goal/memory `TextEditor`s — a body-font,
/// elevated-surface box. `TextEditor` (not a plain `TextField(axis: .vertical)`,
/// which treats Enter as end-editing — see CLAUDE.md #32) gives native
/// newline-on-Enter and caret tracking. Used by both Settings → Autovisor and the
/// Watchtower Autovisor card so the two surfaces stay visually identical.
/// `minHeight` reserves the initial size; the enclosing `ScrollView` handles overflow.
struct AutovisorEditorStyle: ViewModifier {
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(.body))
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.surfaceElevated)
            )
    }
}

extension View {
    func autovisorEditorStyle(minHeight: CGFloat) -> some View {
        modifier(AutovisorEditorStyle(minHeight: minHeight))
    }
}
