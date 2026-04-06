import SwiftUI

// MARK: - Template Placeholder Highlighter

/// Shared utility that resolves `{placeholder}` patterns in a template string into an `AttributedString`
/// where resolved values are colored by category (matching `PlaceholderAttachment` chip colors)
/// and plain text remains unstyled monospaced.
///
/// Used by both `TemplatePreviewSheet` and `PromptPreviewSheet`.
enum TemplatePlaceholderHighlighter {

    private static let monoFont = Font.system(.body, design: .monospaced)

    /// Resolves `{key}` placeholders in `template` using `values`, coloring each resolved value
    /// with the category color from `definitions`. Plain text stays unstyled.
    static func resolve(
        template: String,
        values: [String: String],
        definitions: [(key: String, label: String, category: String)]
    ) -> AttributedString {
        var result = AttributedString()

        var remaining = template
        let pattern = "\\{([a-zA-Z]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            var plain = AttributedString(template)
            plain.font = monoFont
            return plain
        }

        while !remaining.isEmpty {
            let nsRemaining = remaining as NSString
            let searchRange = NSRange(location: 0, length: nsRemaining.length)
            guard let match = regex.firstMatch(in: remaining, range: searchRange),
                  match.numberOfRanges >= 2 else {
                var plain = AttributedString(remaining)
                plain.font = monoFont
                result.append(plain)
                break
            }

            let matchRange = match.range
            let keyRange = match.range(at: 1)
            let key = nsRemaining.substring(with: keyRange)

            // Append text before this match
            if matchRange.location > 0 {
                let prefix = nsRemaining.substring(to: matchRange.location)
                var prefixAttr = AttributedString(prefix)
                prefixAttr.font = monoFont
                result.append(prefixAttr)
            }

            // Resolve and highlight
            if let value = values[key] {
                let category = definitions.first(where: { $0.key == key })?.category ?? ""
                let color = placeholderColor(for: category)
                var valueAttr = AttributedString(value)
                valueAttr.font = monoFont
                valueAttr.foregroundColor = color
                valueAttr.backgroundColor = color.opacity(0.12)
                result.append(valueAttr)
            } else {
                // Unknown placeholder — keep as {key}
                let text = nsRemaining.substring(with: matchRange)
                var unknownAttr = AttributedString(text)
                unknownAttr.font = monoFont
                result.append(unknownAttr)
            }

            remaining = nsRemaining.substring(from: matchRange.location + matchRange.length)
        }

        return result
    }

    /// Returns the SwiftUI Color for a placeholder category, matching `PlaceholderAttachment.colorMap`.
    private static func placeholderColor(for category: String) -> Color {
        Color(nsColor: PlaceholderAttachment.color(for: category))
    }
}
