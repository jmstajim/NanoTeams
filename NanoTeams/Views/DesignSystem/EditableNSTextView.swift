import AppKit

/// Editable NSTextView subclass with placeholder rendering and a
/// responder-state bridge.
///
/// Construction goes through `init(frame:textContainer:)` — the convenience
/// `NSTextView()` initializer can opt into TextKit 2 where `layoutManager`
/// is nil, which breaks both placeholder drawing and height measurement.
final class EditableNSTextView: NSTextView {

    /// Hint string painted by `draw(_:)` while the field is empty.
    ///
    /// The `didSet` is load-bearing. `EditableMessageTextView.updateNSView`
    /// re-assigns this on every SwiftUI render, but when ONLY the placeholder
    /// changed nothing else marks the view dirty: the Coordinator's `applyText`
    /// early-returns on unchanged text, and the field is empty in exactly the
    /// state where the placeholder is the only thing on screen. Without it the
    /// pixels stay frozen on the OLD string until something unrelated repaints
    /// (click-to-focus, window resize) — which left `TeamActivityComposer`'s
    /// "No active recipient…" painted over a composer that had already gone live,
    /// and froze `QuickCaptureFormView`'s queued-message hint the same way.
    ///
    /// The `!= oldValue` guard is load-bearing in the other direction:
    /// `updateNSView` runs on EVERY parent re-render (many per second while an
    /// LLM streams into the feed above the composer), so an unconditional
    /// `needsDisplay = true` would repaint this NSScrollView-backed
    /// representable per frame — the exact cost CLAUDE.md #50 is about.
    ///
    /// Do NOT add `shouldDrawPlaceholder()` to the guard: it reads the NEW
    /// value, so clearing the placeholder while the field is empty would skip
    /// the repaint and leave the old string on screen.
    var placeholderText: String? {
        didSet {
            guard placeholderText != oldValue else { return }
            invalidatePlaceholderDisplay()
        }
    }

    /// When true, user-originated edits (keystrokes, paste, delete, smart
    /// substitutions) are refused via `shouldChangeText(in:replacementString:)`
    /// — the single funnel every interactive mutation passes through.
    /// Programmatic writes (`textView.string =` from the Coordinator's
    /// `applyText`) bypass that funnel, so the live "improve" stream still
    /// lands while manual input is locked. `isEditable` stays `true` so
    /// focus / caret / selection / copy keep working (and the QuickCapture
    /// panel's focusable-field walker, which keys on `isEditable`, isn't
    /// tripped mid-stream).
    var isInputLocked: Bool = false

    /// Called from `becomeFirstResponder` / `resignFirstResponder` with
    /// the resulting responder state.
    var focusUpdateHandler: ((Bool) -> Void)?

    /// When true, the view requests first-responder status the first
    /// time it's added to a window. Self-attached lifecycle — defers
    /// until `viewDidMoveToWindow` fires with a non-nil window, so an
    /// NSPanel that isn't key-ordered yet at `makeNSView` time still
    /// gets the caret once the panel is shown.
    var autofocusOnFirstWindow: Bool = false
    private var didAutofocus: Bool = false

    #if DEBUG
    /// Test hook: latest placeholder-draw decision. Lets tests assert
    /// the decision matrix without an active `NSGraphicsContext`.
    private(set) var _didDrawPlaceholderForTesting: Bool = false

    /// Test hook: number of placeholder-driven display invalidations (see
    /// `invalidatePlaceholderDisplay`). `NSView.needsDisplay` is NOT assertable
    /// here — it never latches on a view with no window, and a freshly hosted
    /// view already reads `true` before anything sets it, so both naive test
    /// shapes stay green regardless of the fix. This counter is the only
    /// deterministic evidence the repaint was requested. Pins both edges: a
    /// CHANGED placeholder invalidates, a re-assigned identical one does not.
    private(set) var _placeholderInvalidationCountForTesting: Int = 0
    #endif

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — EditableNSTextView is built programmatically.")
    }

    // MARK: - Window lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard autofocusOnFirstWindow, !didAutofocus, let window else { return }
        didAutofocus = true
        // Defer one runloop tick: `makeFirstResponder` races window-key
        // transitions even after the window is non-nil.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window === self.window else { return }
            _ = window.makeFirstResponder(self)
        }
    }

    // MARK: - Input lock

    /// Canonical gate for ALL interactive text mutations. Refusing here blocks
    /// keyboard, paste, delete, and smart-substitution edits without touching
    /// `isEditable`. Programmatic `.string =` assignments do not route through
    /// `shouldChangeText`, so the improve stream is unaffected.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isInputLocked { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    // MARK: - Responder bridge

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            focusUpdateHandler?(true)
            needsDisplay = true
        }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            focusUpdateHandler?(false)
            needsDisplay = true
        }
        return didResign
    }

    // MARK: - Placeholder

    /// Single funnel for placeholder-driven repaints. `needsDisplay = true` and
    /// the debug counter must stay in ONE body — the counter is the tests' only
    /// proxy for the invalidation, so splitting them would let a regression drop
    /// the repaint while the test still passes.
    private func invalidatePlaceholderDisplay() {
        needsDisplay = true
        #if DEBUG
        _placeholderInvalidationCountForTesting &+= 1
        #endif
    }

    /// True when the empty / placeholder-present preconditions are met.
    /// Extracted so tests exercise the decision without a live drawing
    /// context. Placeholder stays visible while focused (matches
    /// SwiftUI `TextField` placeholder behavior the field was replacing —
    /// hiding it on focus made the composer feel mute when the panel
    /// opens with the field already first-responder via
    /// `autofocusOnAppear`).
    func shouldDrawPlaceholder() -> Bool {
        guard let placeholder = placeholderText, !placeholder.isEmpty else { return false }
        return string.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if shouldDrawPlaceholder(), let placeholder = placeholderText {
            // Placeholder font falls back to mono if the host hasn't pinned one
            // — matches `EditableMessageTextView.defaultFont` so the placeholder
            // sits on the same mono grid as the typed text.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.monospacedSystemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .regular
                ),
                .foregroundColor: Colors.nsTextSecondary
            ]
            let attributed = NSAttributedString(string: placeholder, attributes: attributes)
            let padding = textContainer?.lineFragmentPadding ?? 0
            let origin = NSPoint(
                x: textContainerInset.width + padding,
                y: textContainerInset.height
            )
            attributed.draw(at: origin)
            #if DEBUG
            _didDrawPlaceholderForTesting = true
            #endif
        } else {
            #if DEBUG
            _didDrawPlaceholderForTesting = false
            #endif
        }
    }

    #if DEBUG
    /// Test-only: re-evaluates the placeholder decision and flips the
    /// debug flag without going through a real `draw(_:)` cycle (which
    /// requires an active `NSGraphicsContext`).
    func testHooks_drawForTesting() {
        _didDrawPlaceholderForTesting = shouldDrawPlaceholder()
    }
    #endif
}
