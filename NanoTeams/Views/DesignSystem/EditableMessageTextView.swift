import AppKit
import SwiftUI

/// Bounded-height multi-line editor backed by `NSScrollView + NSTextView`.
///
/// Pure rendering primitive: emits a raw return-key signal via
/// `onReturnKey` and bridges first-responder transitions through
/// `$isFocused`. Submit semantics belong to the caller.
///
/// NSTextView calls `scrollRangeToVisible(selectedRange())` natively on
/// every selection / text change — the caret stays visible regardless of
/// where the user is editing. SwiftUI's `TextField(axis: .vertical)`
/// exposes no caret coordinates, so a bounded-height SwiftUI host can't
/// achieve the same effect without per-character offsets.
struct EditableMessageTextView: NSViewRepresentable {

    @Binding var text: String

    /// AppKit first-responder → SwiftUI bridge. Updated through the
    /// Coordinator's idempotent setter on responder-chain transitions.
    @Binding var isFocused: Bool

    let placeholder: String
    let maxHeight: CGFloat
    /// Minimum visible line count when the field is empty. Clamped to
    /// at least one line so an empty field doesn't collapse.
    let minLineCount: Int
    let autofocusOnAppear: Bool

    /// Return `true` to consume the Return key (caller handled it —
    /// submit / no-op). Return `false` to let `NSTextView` insert a
    /// newline at the caret natively.
    let onReturnKey: (_ hasShift: Bool, _ hasCommand: Bool) -> Bool

    /// Locks manual input while the "improve prompt" stream writes into the
    /// binding (defaulted + declared last so existing call sites — which pass
    /// `onReturnKey` as the final argument — are untouched). Enforced at the
    /// `EditableNSTextView.shouldChangeText` funnel — see its doc.
    var isInputLocked: Bool = false

    // Monospaced system font (SF Mono) — pinned at the AppKit boundary so the
    // composer's typed text stays on the same mono grid as the rest of the DS
    // (DS "Mono everywhere" rule). SwiftUI's `.fontDesign(.monospaced)` does
    // NOT route into `NSTextView` — same crossing as `SelectableMessageText`.
    static let defaultFont: NSFont = .monospacedSystemFont(
        ofSize: NSFont.systemFontSize,
        weight: .regular
    )
    static var defaultTextColor: NSColor { Colors.nsTextPrimary }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        return wire(coordinator: context.coordinator)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        applyUpdate(to: scrollView, coordinator: context.coordinator)
    }

    /// Shared body for production `updateNSView` and the `#if DEBUG` test seam
    /// below; both delegate here. Mirrors the `wire(coordinator:)` /
    /// `computeSize(proposal:nsView:coordinator:)` split already in this file.
    @MainActor
    private func applyUpdate(to scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? EditableNSTextView else {
            assertionFailure("scrollView.documentView is not EditableNSTextView — only makeNSView constructs the view")
            return
        }
        // Re-bind every render: SwiftUI rebuilds the representable
        // struct on every parent update, so the closures we captured may
        // have re-pointed.
        coordinator.configure(
            textBinding: $text,
            isFocusedBinding: $isFocused,
            onReturnKey: onReturnKey
        )
        // Assigning this is what keeps the on-screen hint honest — the property's
        // own `didSet` requests the repaint (see `EditableNSTextView`).
        textView.placeholderText = placeholder
        // Clear the undo stack on unlock: the improve stream wrote via
        // `.string =`, which doesn't register undo actions, so a Cmd+Z after
        // a stream would surface incoherent partial states. The Revert chip
        // is the sanctioned undo for an improve.
        if textView.isInputLocked && !isInputLocked {
            textView.undoManager?.removeAllActions()
        }
        textView.isInputLocked = isInputLocked
        coordinator.applyText(text, to: textView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        return computeSize(proposal: proposal, nsView: nsView, coordinator: context.coordinator)
    }

    /// Shared body for production `sizeThatFits` and the `#if DEBUG`
    /// test seam; both delegate here.
    @MainActor
    private func computeSize(proposal: ProposedViewSize, nsView: NSScrollView, coordinator: Coordinator) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        guard let textView = nsView.documentView as? EditableNSTextView else {
            assertionFailure("scrollView.documentView is not EditableNSTextView — only makeNSView constructs the view")
            return nil
        }
        guard let storage = textView.textStorage else { return nil }
        let insetX = textView.textContainerInset.width * 2
        let insetY = textView.textContainerInset.height * 2
        let interior = width - insetX
        // Pathological proposal — the cache key would otherwise store a
        // zero-width entry that legitimate later proposals at width 0
        // would hit incorrectly. Fall back to intrinsic.
        guard interior > 0 else { return nil }
        // Persistent measure-cache: never mutates the live container, so
        // a speculative SwiftUI proposal can't leave the editor at a
        // stale width.
        let usedHeight = coordinator.measureCache.measure(
            textStorage: storage,
            width: interior
        )
        let lineHeight = (textView.font?.ascender ?? 0) - (textView.font?.descender ?? 0) + 2
        let lines = max(minLineCount, 1)
        let minHeight = lineHeight * CGFloat(lines) + insetY
        let clamped = min(max(usedHeight + insetY, minHeight), maxHeight)
        return CGSize(width: width, height: clamped)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // Detach measure-LM so it doesn't outlive the textStorage.
        coordinator.measureCache.dismantle()
    }

    // MARK: - Builders

    private static func buildScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        // Critical: NSClipView (scrollView.contentView) defaults to
        // `drawsBackground = true` with `NSColor.controlBackgroundColor`,
        // which paints an opaque dark-grey rectangle over the host's
        // layer background. Disabling it lets the host's layer show
        // through inside the scroll-view's viewport.
        scrollView.contentView.drawsBackground = false
        return scrollView
    }

    private static func buildTextView() -> EditableNSTextView {
        // Hand-built TextKit 1 stack — convenience `NSTextView()` may opt
        // into TextKit 2 (nil `layoutManager`), which silently breaks
        // placeholder drawing and height measurement.
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)

        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let textView = EditableNSTextView(frame: .zero, textContainer: container)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isFieldEditor = false
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = defaultFont
        textView.textColor = defaultTextColor
        textView.insertionPointColor = Colors.nsTextPrimary
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        // Smart-substitutions corrupt programmatic edits coming from
        // dictation and from binding round-trips.
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        return textView
    }

    // MARK: - Wiring

    /// Shared construction body for `makeNSView` and the `#if DEBUG`
    /// test seam below. Builds the scroll-view + text-view pair, hands
    /// the coordinator its bindings and initial-text baseline, and wires
    /// the focus bridge. Kept private so the only public entry points
    /// remain `makeNSView` (SwiftUI lifecycle) and `testHooks_makeNSView`
    /// (test seam without `Context`).
    @MainActor
    private func wire(coordinator: Coordinator) -> NSScrollView {
        let scrollView = Self.buildScrollView()
        let textView = Self.buildTextView()
        textView.string = text
        textView.placeholderText = placeholder
        textView.isInputLocked = isInputLocked
        textView.delegate = coordinator

        coordinator.configure(
            textBinding: $text,
            isFocusedBinding: $isFocused,
            onReturnKey: onReturnKey
        )
        coordinator.absorbInitialText(text)

        textView.focusUpdateHandler = { [weak coordinator] focused in
            coordinator?.updateFocusBinding(focused)
        }
        textView.autofocusOnFirstWindow = autofocusOnAppear

        scrollView.documentView = textView
        return scrollView
    }

    // MARK: - Test seam

    #if DEBUG
    /// Mirrors `makeNSView` without a SwiftUI `Context`. Tests use this
    /// to exercise the wiring directly.
    @MainActor
    func testHooks_makeNSView(coordinator: Coordinator) -> NSScrollView {
        return wire(coordinator: coordinator)
    }

    /// Mirrors `sizeThatFits` without a SwiftUI `Context`. Tests use this
    /// to drive the size-computation path directly.
    @MainActor
    func testHooks_sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, coordinator: Coordinator) -> CGSize? {
        return computeSize(proposal: proposal, nsView: nsView, coordinator: coordinator)
    }

    /// Mirrors `updateNSView` without a SwiftUI `Context`. Tests use this to
    /// drive the per-render path — the one that has to keep re-applying the
    /// placeholder, since dropping that assignment silently re-freezes the hint.
    @MainActor
    func testHooks_updateNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        applyUpdate(to: scrollView, coordinator: coordinator)
    }
    #endif
}
