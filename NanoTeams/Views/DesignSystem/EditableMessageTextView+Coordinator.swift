import AppKit
import SwiftUI

extension EditableMessageTextView {

    /// Owns mutable state and bridging callbacks for the
    /// `NSViewRepresentable`. The struct is rebuilt on every parent
    /// re-render; the Coordinator survives those rebuilds so it's the
    /// right home for `lastAppliedText` (the binding-write baseline) and
    /// for the captured closures.
    ///
    /// Not annotated `@MainActor` because `NSViewRepresentable.makeCoordinator`
    /// is not main-actor-isolated in the SwiftUI protocol. Mutations
    /// happen through the AppKit lifecycle (delegate callbacks, responder
    /// chain), which is main-thread by construction.
    final class Coordinator: NSObject, NSTextViewDelegate {

        /// Last text that either landed in NSTextView via `applyText` or
        /// was absorbed from it via `textDidChange`. Read by `applyText`
        /// to skip the SwiftUI round-trip write that would otherwise
        /// reset `selectedRange` to `text.count` after every keystroke.
        private(set) var lastAppliedText: String = ""

        /// Edge trigger for the `InputSurface.stamp` re-run in `updateNSView`. Without it this
        /// view survived theme switches only because every one of its ten hosts happens to sit
        /// under an `.id(activeTheme)` rebuild — a property of the call sites, not of the view.
        var themeLatch = ThemeStampLatch()

        private(set) var textBinding: Binding<String>?
        private(set) var isFocusedBinding: Binding<Bool>?
        private(set) var onReturnKey: ((_ hasShift: Bool, _ hasCommand: Bool) -> Bool)?

        /// Persistent measure-side `NSLayoutManager` + `NSTextContainer`
        /// pair. Mutating the live container from `sizeThatFits` would
        /// leave it at a speculative SwiftUI width and re-shape the
        /// whole string on every layout proposal.
        let measureCache = MessageTextLayoutCache()

        // MARK: - Configuration

        /// Single write path for the closures + bindings the
        /// representable carries. Funneling all writes here prevents
        /// foreign code from nilling a binding or swapping the submit
        /// closure mid-flight, and groups three coupled fields so they
        /// can only update together.
        func configure(
            textBinding: Binding<String>,
            isFocusedBinding: Binding<Bool>,
            onReturnKey: @escaping (_ hasShift: Bool, _ hasCommand: Bool) -> Bool
        ) {
            self.textBinding = textBinding
            self.isFocusedBinding = isFocusedBinding
            self.onReturnKey = onReturnKey
        }

        /// Sync the `lastAppliedText` baseline with text already on the
        /// NSTextView. Lets the first `applyText` skip a redundant write
        /// that would reset the caret to the end on initial render.
        func absorbInitialText(_ text: String) {
            lastAppliedText = text
        }

        // MARK: - Text sync

        /// Push binding-side text into the NSTextView. Skipped when the
        /// view already shows the target string — re-setting `.string`
        /// resets `selectedRange` to the end, which would jump the
        /// caret on every SwiftUI round-trip re-render.
        ///
        /// Compares against `lastAppliedText` (a Swift `String` we own)
        /// rather than `textView.string` (which would force an
        /// NSString → Swift String bridge copy of the entire textStorage
        /// on every keystroke — perceptible per-keystroke lag once the
        /// field grows past a few hundred chars). The baseline is
        /// authoritative: `textDidChange` updates it synchronously
        /// before SwiftUI re-renders, so drift is unreachable in
        /// practice.
        ///
        /// On a real edit, marks `measureCache` stale — same-length
        /// substring replacements wrap differently at the same width
        /// and the cache's `(length, width)` key would otherwise return
        /// the pre-edit height.
        func applyText(_ text: String, to textView: NSTextView) {
            if text == lastAppliedText { return }
            textView.string = text
            lastAppliedText = text
            measureCache.markStale()
        }

        /// Mirror NSTextView edits back into the SwiftUI binding. Records
        /// the baseline so the subsequent SwiftUI re-render triggered by
        /// this write takes the early-return branch in `applyText`.
        /// Invalidates `measureCache` so a same-length edit (paste-replace,
        /// IME composition) doesn't return a stale wrap height —
        /// length-changed edits would invalidate the key naturally, but
        /// the cost of `markStale` (three Int writes) is below the
        /// threshold worth conditional-ing on.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                assertionFailure("textDidChange received a non-NSTextView object — delegate misrouted")
                return
            }
            let newText = textView.string
            lastAppliedText = newText
            measureCache.markStale()
            textBinding?.wrappedValue = newText
        }

        // MARK: - Return-key dispatch

        /// Intercepts `Return` so the caller's `onReturnKey` decides
        /// submit vs newline. Other commands fall through to NSTextView's
        /// defaults by returning `false`.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            return handleReturnKey(
                hasShift: mods.contains(.shift),
                hasCommand: mods.contains(.command)
            )
        }

        /// Testable seam: production reads modifiers off
        /// `NSApp.currentEvent` and forwards here; tests drive it with
        /// synthetic flags.
        ///
        /// The `onReturnKey == nil` branch is structurally unreachable in
        /// production: `wire(coordinator:)` calls `configure(...)` before
        /// the textView's `documentView` slot is filled, so by the time
        /// the responder chain can route a keystroke, the closure is
        /// non-nil. Consume (`true`) — matches `MessageKeyPolicy.ignore`
        /// semantics so a test-only path reads the same as a legitimate
        /// "form not ready" outcome.
        func handleReturnKey(hasShift: Bool, hasCommand: Bool) -> Bool {
            guard let onReturnKey else { return true }
            return onReturnKey(hasShift, hasCommand)
        }

        // MARK: - Focus bridge

        /// Idempotent setter for the focus binding. The no-write-when-equal
        /// guard prevents `.onChange(of: isFocused)` observers (the
        /// paste-monitor gate) from re-firing on every internal AppKit
        /// responder query.
        func updateFocusBinding(_ value: Bool) {
            guard let binding = isFocusedBinding else { return }
            guard binding.wrappedValue != value else { return }
            binding.wrappedValue = value
        }
    }
}
