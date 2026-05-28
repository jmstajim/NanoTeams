import AppKit
import Foundation

// MARK: - MessageTextLayoutCache

/// Persistent measure-side `NSLayoutManager` + `NSTextContainer` pair that
/// memoizes `usedRect(for:)` height by `(textStorage.length, ceil(width))`.
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
/// Invalidation:
/// - Width change → re-ensureLayout with the new container size.
/// - `textStorage.length` change → re-ensureLayout, natural cost.
/// - Sub-string-equivalent edits at the same length wrap differently
///   but share the `(length, width)` key. Append-only callers never
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

    private let measureLayoutManager: NSLayoutManager
    private let measureContainer: NSTextContainer
    private weak var attachedStorage: NSTextStorage?

    private var lastLength: Int = -1
    private var lastWidth: CGFloat = -1
    private var lastHeight: CGFloat = 0

    #if DEBUG
    private(set) var computeCount: Int = 0
    private(set) var hitCount: Int = 0
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
    /// rebinds (and resets the height cache) if a different storage is
    /// passed.
    func measure(textStorage: NSTextStorage, width: CGFloat) -> CGFloat {
        if attachedStorage !== textStorage {
            attachedStorage?.removeLayoutManager(measureLayoutManager)
            textStorage.addLayoutManager(measureLayoutManager)
            attachedStorage = textStorage
            // Invalidate height cache — new storage means a different
            // string and probably a different length.
            lastLength = -1
            lastWidth = -1
        }

        let snappedWidth = ceil(width)
        let currentLength = textStorage.length

        if lastLength == currentLength, lastWidth == snappedWidth {
            #if DEBUG
            hitCount += 1
            #endif
            return lastHeight
        }

        #if DEBUG
        computeCount += 1
        #endif

        if measureContainer.size.width != snappedWidth {
            measureContainer.size = NSSize(
                width: snappedWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        measureLayoutManager.ensureLayout(for: measureContainer)
        let height = ceil(measureLayoutManager.usedRect(for: measureContainer).height)

        lastLength = currentLength
        lastWidth = snappedWidth
        lastHeight = height
        return height
    }

    /// Invalidates the memoized height so the next `measure` call
    /// re-runs `ensureLayout` even if `(length, width)` haven't changed.
    ///
    /// Read-only callers (streaming bubbles) edit append-only — length
    /// always changes — so the `lastLength` check alone protects them.
    /// Editable callers can perform sub-string-equivalent rewrites
    /// (paste, replace selection) where the new string wraps differently
    /// at the same length, and need an explicit invalidation hook to
    /// avoid stale heights surviving the edit.
    func markStale() {
        lastLength = -1
        lastWidth = -1
        lastHeight = 0
    }

    /// Detaches the measure-LM from its bound `textStorage`. Called from
    /// `SelectableMessageText.dismantleNSView`.
    func dismantle() {
        if let storage = attachedStorage {
            storage.removeLayoutManager(measureLayoutManager)
        }
        attachedStorage = nil
        lastLength = -1
        lastWidth = -1
        lastHeight = 0
    }
}
