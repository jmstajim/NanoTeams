import AppKit
import SwiftUI

// MARK: - Placeholder Attachment

/// An NSTextAttachment that renders as a colored chip with the placeholder label.
/// Pre-renders the chip image in init so it works with both TextKit 1 and TextKit 2.
nonisolated final class PlaceholderAttachment: NSTextAttachment {
    let key: String
    let label: String
    let category: String

    private static let colorMap: [String: (dark: Int, light: Int)] = [
        "role": (dark: 0x818CF8, light: 0x4F46E5),       // indigo (accent)
        "context": (dark: 0x1DB954, light: 0x16A34A),     // success green
        "tools": (dark: 0xF97316, light: 0xEA580C),       // warning orange
        "artifacts": (dark: 0x8B5CF6, light: 0x7C3AED),   // purple
    ]

    // Memoize dynamic NSColors per category. Without this, every call to
    // `color(for:)` produced a fresh `NSColor(name: nil) { ... }` instance
    // that compared unequal by identity even when the resolved RGB matched —
    // which broke `NSAttributedString.isEqual` (used as the change-detection
    // short-circuit in `ResolvedPromptView.updateNSView`) and forced a full
    // `setAttributedString` + NSTextView relayout on every SwiftUI body
    // invocation, including scroll-driven re-renders. Result: severe scroll
    // jank in the preview sheets. Caching here makes the foreground-color
    // attribute a stable singleton so `isEqual` actually fires.
    private static let dynamicColors: [String: NSColor] = {
        var dict: [String: NSColor] = [:]
        for (category, pair) in colorMap {
            dict[category] = NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let hex = isDark ? pair.dark : pair.light
                return NSColor(
                    red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                    green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                    blue: CGFloat(hex & 0xFF) / 255.0,
                    alpha: 1.0
                )
            }
        }
        return dict
    }()

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

    init(key: String, label: String, category: String) {
        self.key = key
        self.label = label
        self.category = category
        super.init(data: nil, ofType: nil)

        let cacheKey = "\(label)|\(category)" as NSString
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
        let chipFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
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
        let cornerRadius = chipHeight / 2

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
        chipColor.withAlphaComponent(0.15).setFill()
        path.fill()

        chipColor.withAlphaComponent(0.4).setStroke()
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
