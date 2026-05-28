import Foundation

/// Pure decision-function for what should happen when the user presses
/// **Return** in a message-composer field. Single source of truth for the
/// `Enter / Shift+Enter / Cmd+Enter` semantics used by every composer
/// surface (Activity feed, Watchtower banner, QuickCapture overlay).
///
/// Foundation-only by design: no SwiftUI, no AppKit, no `@MainActor`. The
/// view layer (`EditableMessageTextView`'s Coordinator) reads modifier
/// flags off the live AppKit event and feeds them here; this enum decides;
/// the caller actuates.
///
/// Two modes, controlled by the user's `Enter sends message` preference:
/// - **Enter-sends**: bare Enter submits, Shift+Enter / Cmd+Enter / both
///   insert a newline. iMessage-style chat input.
/// - **Normal**: bare Enter and Shift+Enter insert a newline, Cmd+Enter
///   submits. Mail/text-editor style.
///
/// `Shift+Enter` always inserts a newline regardless of `canSubmit` — it's
/// an explicit "don't send" gesture; the user expects a line break even
/// when the form can't submit yet.
nonisolated enum MessageKeyPolicy {

    /// What the caller should do with the Return key press.
    enum KeyAction: Equatable {
        /// Caller should invoke its submit handler.
        case submit
        /// Caller should insert a literal newline at the caret. In AppKit
        /// land this means letting NSTextView's default `insertNewline:`
        /// run — the Coordinator returns `false` from `doCommandBy:` so
        /// AppKit performs the insertion natively.
        case insertNewline
        /// Caller should consume the key (so AppKit's default newline
        /// insertion is suppressed) but take no further action. Reached
        /// only in submit-eligible paths when the form is invalid or
        /// already submitting — we don't want stray newlines in that case.
        case ignore
    }

    /// - parameter enterSendsMessage: user's `Enter sends message` preference.
    /// - parameter hasShift / hasCommand: modifier flags on the Return press.
    /// - parameter canSubmit: form-validity gate (text non-empty, etc.).
    /// - parameter isSubmitting: re-entry gate; suppresses double-submit
    ///   while an in-flight send is still resolving.
    static func resolveReturnKey(
        enterSendsMessage: Bool,
        hasShift: Bool,
        hasCommand: Bool,
        canSubmit: Bool,
        isSubmitting: Bool
    ) -> KeyAction {
        let submittable = canSubmit && !isSubmitting
        if enterSendsMessage {
            if hasShift || hasCommand { return .insertNewline }
            return submittable ? .submit : .ignore
        } else {
            if hasCommand { return submittable ? .submit : .ignore }
            return .insertNewline
        }
    }
}
