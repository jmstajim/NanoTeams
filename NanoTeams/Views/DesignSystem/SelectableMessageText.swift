import SwiftUI
import AppKit

// MARK: - Selectable Message Text

/// Read-only `NSTextView` wrapper used for streaming/committed message
/// content in the Team Activity feed. Replaces SwiftUI `Text(content)` for
/// long bubbles where re-shaping the entire string per `TimelineView` tick
/// would saturate the UI thread, and where unstable intrinsic-height
/// reporting trips `LazyVStack`'s mismeasurement on cells taller than the
/// viewport.
///
/// Two load-bearing primitives the bubble depends on:
///
/// 1. **Append-only update path.** When the new content extends the prior
///    content as a Swift-`String` prefix-extension, only the suffix is
///    appended to `textStorage` (preserving storage identity). This is
///    the precondition for `NSLayoutManager` to extend its glyph layout
///    incrementally instead of re-shaping the whole string. Storage
///    identity + monotonic length are pinned by `SelectableMessageTextTests`;
///    incremental shaping itself is an AppKit internal not directly
///    observable from XCTest.
/// 2. **Stable view identity across commit.** The bubble dispatcher in
///    `TeamActivityFeedView.messageBubble` keeps this view at the same
///    SwiftUI structural position in both streaming and committed states,
///    so the underlying `NSTextView` instance lives on across the
///    `isStreaming` flip. `LazyVStack` requires stable per-cell height; a
///    re-mount here would briefly report 0 height and unload the cell.
///
/// Layout contract: this view drives its own height via
/// `intrinsicContentSize` after `layoutManager.ensureLayout(for:)`, with
/// `sizeThatFits` providing an explicit `(width, height)` answer for
/// concrete-width proposals (the resize path). Caller pairs with
/// `.fixedSize(horizontal: false, vertical: true)` so SwiftUI proposes a
/// width and reads the intrinsic height — same ergonomics as the SwiftUI
/// `Text` it replaces.
///
/// Correctness against AppKit canonicalization: the prefix-extension check
/// runs against `Coordinator.lastAppliedContent` (an authoritative Swift
/// `String` we own at apply-time), NOT `textView.string`. Routing through
/// `NSTextStorage` exposes the comparison to any internal canonicalization
/// AppKit applies (NFC, font-substitution paths); using our own `String`
/// keeps the prefix check grapheme-stable regardless.
struct SelectableMessageText: NSViewRepresentable {
    let content: String

    // Monospaced system font (SF Mono) — matches `Typography.termBase` (13pt)
    // so message body type stays on the same mono grid as every other row
    // label/timestamp/header in the activity feed (DS "Mono everywhere" rule).
    // SwiftUI's `.fontDesign(.monospaced)` from the window root only routes
    // SwiftUI Text; AppKit `NSTextView` is opaque to it, so the font must be
    // pinned here.
    static let defaultFont: NSFont = .monospacedSystemFont(
        ofSize: NSFont.systemFontSize,
        weight: .regular
    )
    static var defaultTextColor: NSColor { Colors.nsTextPrimary }

    static var defaultAttributes: [NSAttributedString.Key: Any] {
        [.font: defaultFont, .foregroundColor: defaultTextColor]
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SelfSizingTextView {
        let textView = SelfSizingTextView()
        Self.configure(textView)
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: content, attributes: Self.defaultAttributes)
        )
        context.coordinator.recordApplied(content)
        return textView
    }

    static func configure(_ textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = defaultFont
        textView.textColor = defaultTextColor
        textView.textContainerInset = .zero
        // Disable AppKit's auto-sync of textContainer width so we own the
        // single write path from `setFrameSize`. With both writers active,
        // a future non-zero `lineFragmentPadding` would let our manual
        // sync overwrite AppKit's correctly-padded width.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        // Let SwiftUI propose the width and read intrinsic height back.
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        let previous = context.coordinator.lastAppliedContent
        let didApply = Self.applyContent(
            content,
            previousContent: previous,
            to: textView,
            attributes: Self.defaultAttributes
        )
        // Only record on success — on the textStorage-nil release-build
        // fallback (TextKit 2 escape valve), the storage write was silently
        // dropped. Recording here would let the next streaming tick take
        // the append-only branch with a baseline that doesn't match storage,
        // creating a permanent gap that never recovers. Skip → next tick
        // sees a divergent baseline → full replace → recovers.
        if didApply {
            context.coordinator.recordApplied(content)
        }
    }

    /// Height needed to render `content` at `proposal.width`. Returns
    /// `nil` for non-finite/non-positive proposals so SwiftUI falls back
    /// to `intrinsicContentSize`.
    ///
    /// Measurement goes through the Coordinator-owned `MessageTextLayoutCache`,
    /// which holds a persistent `NSLayoutManager` + `NSTextContainer` pair
    /// attached to the live `textStorage`. Hot path: same `(content length,
    /// rounded width)` returns the cached height without re-running
    /// `ensureLayout`. Each live-resize tick previously allocated a
    /// throwaway LM/container pair and ran TextKit shaping over the entire
    /// string — see CLAUDE.md / plan doc for the 4.41 s hang lineage.
    ///
    /// Race-safety: the cache uses a SEPARATE `NSTextContainer` with
    /// `widthTracksTextView = false` — no feedback path to
    /// `setFrameSize`'s 0.5 pt epsilon on the live container. Adding a
    /// second `NSLayoutManager` to the shared `textStorage` is exactly
    /// what the pre-cache implementation did on every measure; we just
    /// keep it persistent now.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SelfSizingTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width,
              width.isFinite,
              width >= SelfSizingTextView.minMeasurementWidth,
              let textStorage = nsView.textStorage
        else { return nil }
        let height = context.coordinator.measureCache.measure(
            textStorage: textStorage,
            width: width
        )
        return CGSize(width: width, height: height)
    }

    /// Tears down the Coordinator-owned measure-LM so the persistent
    /// `NSLayoutManager` does not outlive its `textStorage`. Without this,
    /// the cache holds a non-owning attachment to `textStorage` that
    /// `NSTextStorage`'s side keeps alive via the LM array — minor leak,
    /// but tidy is better than not.
    static func dismantleNSView(_ nsView: SelfSizingTextView, coordinator: Coordinator) {
        coordinator.measureCache.dismantle()
    }

    // MARK: - Coordinator

    /// Holds the authoritative "last-applied" Swift `String` so the
    /// prefix-extension check is grapheme-correct and independent of any
    /// canonicalization that `NSTextStorage` may apply.
    ///
    /// Not annotated `@MainActor`: `NSViewRepresentable.makeCoordinator()`
    /// is not main-actor-isolated in the SwiftUI protocol; the field is
    /// value-typed and the access path runs on main via the representable
    /// lifecycle.
    final class Coordinator {
        private(set) var lastAppliedContent: String = ""
        let measureCache = MessageTextLayoutCache()

        func recordApplied(_ content: String) {
            lastAppliedContent = content
        }
    }

    // MARK: - Static content helper

    /// Applies `content` via append-only path when prefix-extending
    /// `previousContent`, else full-replaces.
    ///
    /// Returns `true` when the storage write succeeded. Returns `false`
    /// only on the `textStorage == nil` escape valve (TextKit 2 future-
    /// proofing) — the caller MUST NOT update its `previousContent`
    /// baseline in that case, or the next tick takes the append-only
    /// branch against a baseline that doesn't match storage.
    @discardableResult
    static func applyContent(
        _ content: String,
        previousContent: String,
        to textView: NSTextView,
        attributes: [NSAttributedString.Key: Any]
    ) -> Bool {
        if previousContent == content { return true }

        let didWriteStorage: Bool
        if !previousContent.isEmpty, content.hasPrefix(previousContent) {
            let suffix = content.dropFirst(previousContent.count)
            if suffix.isEmpty {
                didWriteStorage = true
            } else if let textStorage = textView.textStorage {
                let appended = NSAttributedString(string: String(suffix), attributes: attributes)
                textStorage.append(appended)
                didWriteStorage = true
            } else {
                assertionFailure("SelfSizingTextView.textStorage is nil — TextKit 2 mode? Append silently dropped.")
                didWriteStorage = false
            }
        } else if let textStorage = textView.textStorage {
            textStorage.setAttributedString(
                NSAttributedString(string: content, attributes: attributes)
            )
            didWriteStorage = true
        } else {
            assertionFailure("SelfSizingTextView.textStorage is nil — TextKit 2 mode? setAttributedString silently dropped.")
            didWriteStorage = false
        }

        // Settle layout before SwiftUI reads `intrinsicContentSize`.
        // Without this the bubble can briefly report zero height during a
        // stream tick, which trips `LazyVStack` on tall cells.
        if let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer
        {
            layoutManager.ensureLayout(for: textContainer)
            #if DEBUG
            (textView as? SelfSizingTextView)?.bumpEnsureLayoutCountForTesting()
            #endif
        }
        textView.invalidateIntrinsicContentSize()
        return didWriteStorage
    }
}

// MARK: - Self-sizing NSTextView

/// `NSTextView` subclass that drives its own intrinsic height from the
/// current frame width, forwards scroll-wheel events to its parent
/// (so a parent SwiftUI `ScrollView` can scroll across long bubbles),
/// and shows an arrow cursor instead of the default I-beam (read-only
/// display, not an editor).
///
/// Hand-builds a TextKit 1 stack via `super.init(frame:textContainer:)`
/// because the convenience `NSTextView()` initializer can opt into
/// TextKit 2, where `layoutManager` is nil and the height path silently
/// returns zero — the bubble would render empty.
final class SelfSizingTextView: NSTextView {
    /// Test hook — incremented every time `invalidateIntrinsicContentSize`
    /// fires from `setFrameSize` (epsilon-guarded path).
    #if DEBUG
    private(set) var invalidationCountForTesting: Int = 0
    /// Test hook — incremented every time `intrinsicContentSize` /
    /// `applyContent` calls `layoutManager.ensureLayout(for:)` from this
    /// view. Used to pin that the layout-during-layout path through
    /// `intrinsicContentSize` isn't amplifying into a feedback loop.
    private(set) var ensureLayoutCallCountForTesting: Int = 0
    #endif

    init() {
        // Build an explicit TextKit 1 stack so `layoutManager` /
        // `textContainer` / `textStorage` are never nil under any future
        // default-changes update from Apple.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // We never instantiate this from a coder.
        fatalError("SelfSizingTextView is not coder-instantiable; use init().")
    }

    /// Smallest width we will ever measure text at. SwiftUI proposes transient
    /// near-zero widths during a `LazyVStack` relayout / safe-area-inset settle; at
    /// such a width every line wraps to ~1 glyph and `usedRect` reports a ~10x-tall
    /// height. Across the whole feed that spiked `contentSize.height` ~9x (2700→24012),
    /// which made the auto-scroll thrash. No real bubble is narrower than this, so we
    /// keep the last good width until a plausible one arrives.
    static let minMeasurementWidth: CGFloat = 50

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let textContainer else { return }
        // Ignore transient sub-`minMeasurementWidth` frames from intermediate layout
        // passes — measuring at a near-zero width is the feed's `contentSize` 9x spike.
        guard newSize.width >= Self.minMeasurementWidth else { return }
        // Half-pixel epsilon: SwiftUI/AppKit float math can produce
        // sub-pixel deltas (e.g. 379.999... vs 380.0) that would otherwise
        // trigger spurious `invalidateIntrinsicContentSize`, and combined
        // with the bubble's TimelineView heartbeat, oscillate layout.
        if abs(textContainer.size.width - newSize.width) > 0.5 {
            textContainer.size = NSSize(
                width: newSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
            invalidateIntrinsicContentSize()
            #if DEBUG
            invalidationCountForTesting &+= 1
            #endif
        }
    }

    /// Last height measured at a plausible width. Returned by `intrinsicContentSize`
    /// when the container width is transiently sub-`minMeasurementWidth`, so a near-zero
    /// width can't report a ~10x-tall height (the feed's `contentSize` spike).
    private var lastGoodIntrinsicHeight: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            #if DEBUG
            assertionFailure("SelfSizingTextView lost its TextKit 1 stack — TextKit 2 fallback path. Bubble will render with zero height.")
            #endif
            return super.intrinsicContentSize
        }
        // The third measurement path (used when `sizeThatFits` returns nil for a tiny
        // proposal). A `textContainer.width` of ~0 — from a fresh bubble whose real
        // frame hasn't landed, or a transient relayout — wraps every line to ~1 glyph
        // and reports a ~10x-tall height. Hold the last good height until a plausible
        // width arrives, so the feed's contentSize stays stable and the auto-scroll
        // doesn't thrash.
        guard textContainer.size.width >= Self.minMeasurementWidth else {
            return NSSize(width: NSView.noIntrinsicMetric, height: lastGoodIntrinsicHeight)
        }
        layoutManager.ensureLayout(for: textContainer)
        #if DEBUG
        ensureLayoutCallCountForTesting &+= 1
        #endif
        let used = layoutManager.usedRect(for: textContainer)
        // `noIntrinsicMetric` for width tells SwiftUI "I have no
        // preferred width — use whatever the parent proposes". The
        // parent's `.frame(maxWidth: .infinity)` propagates available
        // width; our `setFrameSize` syncs `textContainer`; the next
        // `intrinsicContentSize` read returns the right height.
        let h = ceil(used.height)
        lastGoodIntrinsicHeight = h
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
    }

    #if DEBUG
    /// Test hook called from `SelectableMessageText.applyContent` when its
    /// `ensureLayout` settle-pass runs.
    func bumpEnsureLayoutCountForTesting() {
        ensureLayoutCallCountForTesting &+= 1
    }
    /// Reset both counters between test cycles.
    func resetTestCountersForTesting() {
        invalidationCountForTesting = 0
        ensureLayoutCallCountForTesting = 0
    }
    #endif

    /// Re-apply the dynamic foreground color across the entire
    /// `textStorage` on appearance changes (Light ↔ Dark switch). The
    /// dynamic NSColor in the attribute dict normally re-resolves at draw
    /// time, but capturing edge cases on appearance flips while a long
    /// bubble is on screen has historically left stale-color glyphs at
    /// the append boundary. Cheap idempotent re-stamp.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let textStorage, textStorage.length > 0 else { return }
        let range = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttribute(
            .foregroundColor,
            value: SelectableMessageText.defaultTextColor,
            range: range
        )
    }

    /// Forward scroll-wheel events to the parent so a SwiftUI `ScrollView`
    /// containing this bubble can scroll while the cursor is over the
    /// text. Without this override, NSTextView greedily consumes the
    /// event and the parent panel becomes un-scrollable across long
    /// bubbles. Selection (mousedown/drag) uses different event paths
    /// and is unaffected.
    ///
    /// Falls through to `super` when there's no `nextResponder` (responder-
    /// chain root or transient detach during view-tree mutation) so the
    /// bubble still gets native NSTextView scrolling as a fallback,
    /// instead of dropping the event silently.
    override func scrollWheel(with event: NSEvent) {
        if let next = nextResponder {
            next.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// Read-only display — show arrow cursor instead of the default
    /// I-beam, which would suggest an editor. Selection still works via
    /// mousedown/drag.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
