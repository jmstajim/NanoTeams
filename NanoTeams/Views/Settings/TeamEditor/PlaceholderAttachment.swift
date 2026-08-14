import AppKit
import SwiftUI

// MARK: - Placeholder Attachment

/// An NSTextAttachment that renders as a colored chip with the placeholder label.
/// Pre-renders the chip image in init so it works with both TextKit 1 and TextKit 2.
nonisolated final class PlaceholderAttachment: NSTextAttachment {
    let key: String
    let label: String
    let category: String

    // Memoize semantic theme-aware NSColors per category. Categories map to
    // design-system tokens (Color Rule #7: no hardcoded hex in views) — every
    // chip now tracks both the dark/light appearance and the active theme.
    // Caching matters: each `Colors.nsThemed(...)` call mints a fresh
    // dynamic `NSColor(name: nil) { ... }` that compares unequal by identity
    // even when the resolved RGB matches, which breaks `NSAttributedString.isEqual`
    // (used as the change-detection short-circuit in
    // `ResolvedPromptView.updateNSView`) and forces a full
    // `setAttributedString` + NSTextView relayout on every SwiftUI body
    // invocation, including scroll-driven re-renders. Caching here makes
    // the foreground-color attribute a stable singleton so `isEqual` fires.
    private static let dynamicColors: [String: NSColor] = [
        "role":      Colors.nsThemed(\.accent),
        "context":   Colors.nsThemed(\.success),
        "tools":     Colors.nsThemed(\.warning),
        "artifacts": Colors.nsThemed(\.artifact),
    ]

    // Cache pre-rasterized chip bitmaps by `(label, category)`. The
    // previous implementation used the handler-based
    // `NSImage(size:flipped:_:)` whose drawing closure Apple documents as
    // "may be called at any time" — and in practice NSTextView re-invoked
    // it on every visible chip on every scroll frame, even after caching
    // the NSImage *instance*. Switching to an explicit `NSBitmapImageRep`
    // means the chip is rendered once per `(label, category)` at init time
    // and NSTextView just blits the pixels on scroll. Trade-off: the bitmap
    // is captured at one appearance — Dark/Light switch keeps showing the
    // pre-switch colors until the next `clearChipCache()` (typically app
    // restart). Acceptable for chips (small surface, rare appearance flips).
    nonisolated(unsafe) private static let imageCache = NSCache<NSString, NSImage>()

    /// What the rendered chip actually depends on. Deliberately NOT `key`: two slots naming the
    /// same placeholder with the same label and category render identical pixels, and paying for
    /// that render twice is the cost this cache exists to avoid.
    ///
    /// Extracted so the contract is pinnable purely. The test that used to state it asserted that
    /// two lookups return the SAME `NSImage` instance — which asks `NSCache` for a guarantee it
    /// does not make: eviction is legal at any moment, and under a coverage-instrumented parallel
    /// run it happens, so the assertion failed intermittently and cost a five-minute measurement
    /// each time. The key is the part that is actually ours to get right.
    static func imageCacheKey(label: String, category: String) -> NSString {
        "\(label)|\(category)" as NSString
    }

    init(key: String, label: String, category: String) {
        self.key = key
        self.label = label
        self.category = category
        super.init(data: nil, ofType: nil)

        let cacheKey = Self.imageCacheKey(label: label, category: category)
        let chipImage: NSImage
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            chipImage = cached
        } else {
            chipImage = Self.renderChipImage(label: label, category: category)
            Self.imageCache.setObject(chipImage, forKey: cacheKey)
        }

        self.image = chipImage
        self.bounds = CGRect(origin: .init(x: 0, y: -4), size: chipImage.size)
    }

    private static func renderChipImage(label: String, category: String) -> NSImage {
        // Monospaced — chips sit inside a mono `NSTextView` (prompt template
        // editor), so a mono chip face keeps the cell grid stable.
        let chipFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let chipColor = color(for: category)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: chipFont,
            .foregroundColor: chipColor,
        ]
        let textSize = (label as NSString).size(withAttributes: textAttrs)
        let horizontalPadding: CGFloat = 16
        let chipWidth = ceil(textSize.width + horizontalPadding)
        let chipHeight: CGFloat = 20
        let chipSize = NSSize(width: chipWidth, height: chipHeight)
        // Near-sharp corners — design system reserves full-pill radii for
        // legacy contexts; `CornerRadius.micro` is the token for "tiny
        // inline pills" (graph labels & co.). Keeps the chip aligned with
        // the terminal-grid aesthetic instead of looking like a stranger
        // pill in a square-cornered surface.
        let cornerRadius = CornerRadius.micro

        // Render once into a retina-scale bitmap rep. NSTextView blits the
        // resulting pixels on every draw call with no closure invocation.
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(chipWidth * scale),
            pixelsHigh: Int(chipHeight * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            // Fallback: zero-byte placeholder (shouldn't happen for tiny sizes).
            return NSImage(size: chipSize)
        }
        rep.size = chipSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: chipSize)
        }
        NSGraphicsContext.current = ctx

        let rect = NSRect(origin: .zero, size: chipSize)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        chipColor.withAlphaComponent(DynamicTintOpacity.badge).setFill()
        path.fill()

        chipColor.withAlphaComponent(DynamicTintOpacity.stroke).setStroke()
        path.lineWidth = 1
        path.stroke()

        let textRect = CGRect(
            x: (chipWidth - textSize.width) / 2,
            y: (chipHeight - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        (label as NSString).draw(in: textRect, withAttributes: textAttrs)

        let image = NSImage(size: chipSize)
        image.addRepresentation(rep)
        return image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // Value equality keyed on `(key, label, category)` — without this, every
    // SwiftUI re-render of a chip-bearing `NSAttributedString` produces fresh
    // PlaceholderAttachment instances that compare unequal under NSObject's
    // default identity-based `isEqual`. That defeated the change-detection
    // short-circuit in `ResolvedPromptView.updateNSView`.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PlaceholderAttachment else { return false }
        return other.key == key && other.label == label && other.category == category
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(key)
        hasher.combine(label)
        hasher.combine(category)
        return hasher.finalize()
    }

    static func color(for category: String) -> NSColor {
        dynamicColors[category] ?? Colors.nsTextSecondary
    }
    nonisolated deinit {}
}
