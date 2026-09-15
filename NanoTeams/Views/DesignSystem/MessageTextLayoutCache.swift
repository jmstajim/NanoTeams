import AppKit
import Foundation

// MARK: - MessageTextLayoutCache

/// Persistent measure-side `NSLayoutManager` + `NSTextContainer` pair that
/// memoizes `usedRect(for:)` height for the current `textStorage.length` at up
/// to `widthMemoCapacity` distinct `ceil(width)` values.
///
/// Used by both an append-only streaming bubble (`SelectableMessageText`)
/// and an editable composer field (`EditableMessageTextView`). One
/// instance per `NSTextView`, attached to the same `textStorage` as the
/// view's live LM. Uses a SEPARATE `NSTextContainer` with
/// `widthTracksTextView = false` so there is no feedback path to
/// `setFrameSize`'s 0.5 pt epsilon on the live container.
///
/// Why this matters: SwiftUI proposes the same width many times per
/// resize gesture (60-120 Hz). Without caching, each proposal allocates
/// a throwaway LM + container and runs TextKit shaping over the whole
/// string — see the 4.41 s `inLiveResize` hang lineage in the plan doc.
/// With this cache, the second through Nth proposal at the same width
/// hit a stored height and skip TextKit entirely.
///
/// **Why several widths, not one.** One instance is asked at more than one width
/// in ordinary layout — `sizeThatFits` at its proposal, and `intrinsicContentSize`'s
/// fallback at the feed's last real width — and a single `(length, width)` slot turns
/// every alternation into a miss: `setSize` on the measure container, then a full
/// `ensureLayout`. Measured 2026-09-15 on an idle run (no tokens arriving, so no
/// length changed): 65–110 ms/s of main thread in `measure → ensureLayout`, with
/// `-[NSTextContainer setSize:]` under it — only a width change calls that.
///
/// Invalidation:
/// - Width not in the memo → re-ensureLayout at that width; the least recently
///   used width is evicted past `widthMemoCapacity`.
/// - `textStorage.length` change → the whole memo is dropped, natural cost.
/// - Sub-string-equivalent edits at the same length wrap differently
///   but share the key. Append-only callers never
///   hit this case (length always changes). Editable callers MUST call
///   `markStale()` on every text mutation to force the next `measure`
///   to re-shape.
///
/// Isolation: explicitly `@MainActor` — `NSTextStorage` /
/// `NSLayoutManager` /`NSTextContainer` are AppKit primitives that require
/// main-thread access. The annotation makes the contract source-visible so a
/// future caller can't move cache access into `Task.detached` without a
/// compile error (under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` the
/// isolation was already implicit, but build-setting-derived isolation
/// silently degrades if someone changes that flag).
@MainActor
final class MessageTextLayoutCache {

    /// Distinct widths remembered for one length. Two is what one instance is asked
    /// at in steady state; the headroom absorbs a transient proposal (a scroller
    /// appearing, a split-view drag settling) without evicting either of those.
    static let widthMemoCapacity = 4

    private struct Measurement {
        let width: CGFloat
        let height: CGFloat
    }

    private let measureLayoutManager: NSLayoutManager
    private let measureContainer: NSTextContainer
    private weak var attachedStorage: NSTextStorage?

    /// The length every entry of `memo` was measured at; -1 = nothing memoized.
    private var memoLength: Int = -1
    /// Least recently used first.
    private var memo: [Measurement] = []

    #if DEBUG
    private(set) var computeCount: Int = 0
    private(set) var hitCount: Int = 0
    /// Every snapped width a miss measured at, in order — the evidence a layout-pass test
    /// prints when a relayout at an unchanged width measures again.
    private(set) var computedWidthsForTesting: [CGFloat] = []
    #endif

    init() {
        measureContainer = NSTextContainer(size: NSSize(
            width: 100,
            height: CGFloat.greatestFiniteMagnitude
        ))
        measureContainer.lineFragmentPadding = 0
        measureContainer.widthTracksTextView = false
        measureLayoutManager = NSLayoutManager()
        measureLayoutManager.addTextContainer(measureContainer)
    }

    /// Returns the height (ceiled) needed to render `textStorage` at
    /// `width`. Idempotent: attaches to `textStorage` on first call,
    /// rebinds (and resets the memo) if a different storage is passed.
    func measure(textStorage: NSTextStorage, width: CGFloat) -> CGFloat {
        if attachedStorage !== textStorage {
            attachedStorage?.removeLayoutManager(measureLayoutManager)
            textStorage.addLayoutManager(measureLayoutManager)
            attachedStorage = textStorage
            // New storage means a different string and probably a different length.
            forget()
        }

        let snappedWidth = ceil(width)
        let currentLength = textStorage.length

        if memoLength != currentLength {
            memo.removeAll(keepingCapacity: true)
            memoLength = currentLength
        }

        if let index = memo.firstIndex(where: { $0.width == snappedWidth }) {
            #if DEBUG
            hitCount += 1
            #endif
            let hit = memo.remove(at: index)
            memo.append(hit)
            return hit.height
        }

        #if DEBUG
        computeCount += 1
        computedWidthsForTesting.append(snappedWidth)
        #endif

        if measureContainer.size.width != snappedWidth {
            measureContainer.size = NSSize(
                width: snappedWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        measureLayoutManager.ensureLayout(for: measureContainer)
        let height = ceil(measureLayoutManager.usedRect(for: measureContainer).height)

        memo.append(Measurement(width: snappedWidth, height: height))
        if memo.count > Self.widthMemoCapacity {
            memo.removeFirst()
        }
        return height
    }

    /// Invalidates every memoized height so the next `measure` call
    /// re-runs `ensureLayout` even if `(length, width)` haven't changed.
    ///
    /// Read-only callers (streaming bubbles) edit append-only — length
    /// always changes — so the length check alone protects them.
    /// Editable callers can perform sub-string-equivalent rewrites
    /// (paste, replace selection) where the new string wraps differently
    /// at the same length, and need an explicit invalidation hook to
    /// avoid stale heights surviving the edit.
    func markStale() {
        forget()
    }

    /// Detaches the measure-LM from its bound `textStorage`. Called from
    /// `SelectableMessageText.dismantleNSView`.
    func dismantle() {
        if let storage = attachedStorage {
            storage.removeLayoutManager(measureLayoutManager)
        }
        attachedStorage = nil
        forget()
    }

    private func forget() {
        memoLength = -1
        memo.removeAll(keepingCapacity: true)
    }
}
