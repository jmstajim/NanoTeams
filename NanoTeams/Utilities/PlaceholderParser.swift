import AppKit
import SwiftUI

// MARK: - Placeholder Parser

/// Stateless parser for `{placeholder}` template syntax.
/// Converts between plain template strings and attributed strings with chip attachments.
enum PlaceholderParser {

    private static let pattern = "\\{([a-zA-Z]+)\\}"

    /// Convert a plain template string (with `{key}` placeholders) to an attributed string with chips.
    static func attributedString(
        from template: String,
        placeholders: [(key: String, label: String, category: String)]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: defaultFont,
            .foregroundColor: Colors.nsTextPrimary,
        ]

        var remaining = template
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: template, attributes: defaultAttrs)
        }

        while !remaining.isEmpty {
            let nsRemaining = remaining as NSString
            let searchRange = NSRange(location: 0, length: nsRemaining.length)
            guard let match = regex.firstMatch(in: remaining, range: searchRange),
                  match.numberOfRanges >= 2 else {
                result.append(NSAttributedString(string: remaining, attributes: defaultAttrs))
                break
            }

            let matchRange = match.range
            let keyRange = match.range(at: 1)
            let key = nsRemaining.substring(with: keyRange)

            if matchRange.location > 0 {
                let prefix = nsRemaining.substring(to: matchRange.location)
                result.append(NSAttributedString(string: prefix, attributes: defaultAttrs))
            }

            if let placeholder = placeholders.first(where: { $0.key == key }) {
                let attachment = PlaceholderAttachment(key: key, label: placeholder.label, category: placeholder.category)
                result.append(NSAttributedString(attachment: attachment))
            } else {
                let text = nsRemaining.substring(with: matchRange)
                result.append(NSAttributedString(string: text, attributes: defaultAttrs))
            }

            let afterMatch = matchRange.location + matchRange.length
            remaining = nsRemaining.substring(from: afterMatch)
        }

        return result
    }

    /// Convert an attributed string (with chip attachments) back to a plain template string.
    static func plainString(from attributed: NSAttributedString) -> String {
        var result = ""
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? PlaceholderAttachment {
                result += "{\(attachment.key)}"
            } else {
                result += (attributed.string as NSString).substring(with: range)
            }
        }
        return result
    }

    /// Convert typed `{key}` patterns in a text storage into visual chips.
    /// Returns `true` if any replacements were made.
    @discardableResult
    static func convertTypedPlaceholders(
        in storage: NSTextStorage,
        placeholders: [(key: String, label: String, category: String)]
    ) -> Bool {
        let fullText = storage.string
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }

        let nsRange = NSRange(location: 0, length: (fullText as NSString).length)
        let matches = regex.matches(in: fullText, range: nsRange).reversed()

        var didChange = false
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let keyRange = match.range(at: 1)
            let key = (fullText as NSString).substring(with: keyRange)

            guard let placeholder = placeholders.first(where: { $0.key == key }) else { continue }

            let attachment = PlaceholderAttachment(key: key, label: placeholder.label, category: placeholder.category)
            let attachmentString = NSAttributedString(attachment: attachment)
            storage.replaceCharacters(in: match.range, with: attachmentString)
            didChange = true
        }

        return didChange
    }

    /// Try to parse a `{key}` string and create a chip attachment.
    /// Returns `nil` if the string doesn't match a known placeholder.
    static func parseChip(
        from text: String,
        placeholders: [(key: String, label: String, category: String)]
    ) -> NSAttributedString? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges >= 2 else { return nil }

        let key = (text as NSString).substring(with: match.range(at: 1))
        guard let placeholder = placeholders.first(where: { $0.key == key }) else { return nil }

        let attachment = PlaceholderAttachment(key: key, label: placeholder.label, category: placeholder.category)
        return NSAttributedString(attachment: attachment)
    }
}
