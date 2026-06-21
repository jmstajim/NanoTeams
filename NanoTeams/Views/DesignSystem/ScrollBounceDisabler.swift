import AppKit
import SwiftUI

/// Disables elastic (rubber-band) scrolling on the enclosing macOS `NSScrollView`.
///
/// SwiftUI's `ScrollView` is `NSScrollView`-backed on macOS but exposes no
/// elasticity control. `.scrollBounceBehavior(.basedOnSize)` only suppresses
/// bounce when the content already fits — overflowing content (the activity
/// feed) still rubber-bands. This zero-impact probe finds the enclosing scroll
/// view and pins both axes to `.none`.
///
/// Placement: attach via `.background(ScrollBounceDisabler())` on the scroll
/// CONTENT (e.g. the `LazyVStack`), NOT on the `ScrollView` itself — a background
/// on the ScrollView renders as a SIBLING of the `NSScrollView`, so
/// `enclosingScrollView` returns nil. A background on the content is a descendant
/// of the document view (and, unlike a lazy top row, is always materialized
/// regardless of scroll offset). The probe is invisible and transparent to
/// hit-testing, so it never intercepts clicks or scroll-wheel events.
struct ScrollBounceDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollBounceProbeView { ScrollBounceProbeView() }

    // SwiftUI calls `updateNSView` after the view is in the hierarchy and laid
    // out — a second chance to resolve `enclosingScrollView` if it wasn't wired
    // yet at `viewDidMoveToWindow` time. Both calls are idempotent.
    func updateNSView(_ nsView: ScrollBounceProbeView, context: Context) {
        nsView.disableBounce()
    }
}

/// Invisible, non-interactive `NSView` that pins its enclosing scroll view's
/// elasticity to `.none`. Internal (not private) so it is reachable from tests.
final class ScrollBounceProbeView: NSView {
    // Transparent to hit-testing: a full-size background view must never swallow
    // clicks or scroll-wheel events meant for the feed content behind it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disableBounce()
        // The enclosing scroll view may not be wired into the view hierarchy yet on
        // the first move-to-window (SwiftUI hosting can attach the document subtree
        // a runloop later). Re-attempt once on the next runloop. Idempotent, and
        // `weak` so it never extends the probe's lifetime.
        DispatchQueue.main.async { [weak self] in self?.disableBounce() }
    }

    func disableBounce() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
    }
}
