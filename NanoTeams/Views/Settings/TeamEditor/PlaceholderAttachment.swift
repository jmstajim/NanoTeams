import AppKit
import SwiftUI

// MARK: - Placeholder Attachment

/// An NSTextAttachment that renders as a colored chip with the placeholder label.
/// Pre-renders the chip image in init so it works with both TextKit 1 and TextKit 2.
final class PlaceholderAttachment: NSTextAttachment {
    let key: String
    let label: String
    let category: String

    private static let colorMap: [String: (dark: Int, light: Int)] = [
        "role": (dark: 0x818CF8, light: 0x4F46E5),       // indigo (accent)
        "context": (dark: 0x1DB954, light: 0x16A34A),     // success green
        "tools": (dark: 0xF97316, light: 0xEA580C),       // warning orange
        "artifacts": (dark: 0x8B5CF6, light: 0x7C3AED),   // purple
    ]

    init(key: String, label: String, category: String) {
        self.key = key
        self.label = label
        self.category = category
        super.init(data: nil, ofType: nil)

        // Pre-render the chip image — required for TextKit 2 compatibility.
        // TextKit 2 (default on modern macOS) does not call the override methods
        // attachmentBounds/image(forBounds:), so we set image + bounds directly.
        let chipFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let chipColor = Self.color(for: category)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: chipFont,
            .foregroundColor: chipColor,
        ]
        let textSize = (label as NSString).size(withAttributes: textAttrs)
        let horizontalPadding: CGFloat = 16
        let chipWidth = textSize.width + horizontalPadding
        let chipHeight: CGFloat = 20
        let chipSize = NSSize(width: chipWidth, height: chipHeight)
        let cornerRadius = chipHeight / 2

        let chipImage = NSImage(size: chipSize, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: cornerRadius, yRadius: cornerRadius)

            chipColor.withAlphaComponent(0.15).setFill()
            path.fill()

            chipColor.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 1
            path.stroke()

            let textRect = CGRect(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (label as NSString).draw(in: textRect, withAttributes: textAttrs)
            return true
        }

        self.image = chipImage
        self.bounds = CGRect(origin: .init(x: 0, y: -4), size: chipSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    static func color(for category: String) -> NSColor {
        guard let pair = colorMap[category] else { return NSColor(Colors.textSecondary) }
        return NSColor(name: nil) { appearance in
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
    nonisolated deinit {}
}
