import Foundation

/// Edge trigger for AppKit colour re-stamping.
///
/// `updateNSView` runs many times per second while an LLM streams above the composer, and an
/// unconditional re-stamp there is exactly the per-frame cost CLAUDE.md #50 is about — the same
/// reason `EditableNSTextView.placeholderText` carries a `!= oldValue` guard.
///
/// Why a re-stamp is needed at all: AppKit caches resolved `NSColor`s per `NSAppearance`, so a
/// palette swap WITHIN one colour scheme (Terminal → OLED, both dark) never invalidates it on its
/// own. The fresh instance `Colors.nsThemed` mints per theme is what makes the re-stamp effective;
/// this is what makes it happen once.
///
/// Extracted from `PromptTemplateEditor.Coordinator.lastAppliedTheme`, which invented it.
/// `EditableMessageTextView` had no equivalent and survived theme switches only because every one
/// of its hosts happens to sit under an `.id(activeTheme)` rebuild — a property of ten call sites,
/// not of the primitive, and therefore not something the next host inherits.
nonisolated struct ThemeStampLatch {
    private var lastStampedTheme: String?

    /// `true` exactly once per distinct theme value. Starts `nil`, so the first call after
    /// `makeNSView` also fires — harmless, it re-stamps what wiring already wrote.
    mutating func shouldStamp(_ theme: String) -> Bool {
        guard lastStampedTheme != theme else { return false }
        lastStampedTheme = theme
        return true
    }
}
