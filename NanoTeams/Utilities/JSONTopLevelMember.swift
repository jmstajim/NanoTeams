import Foundation

/// One member of a JSON object's TOP level, found in the document's text — so that member alone
/// can be read or rewritten and every other byte of the document is kept.
///
/// A decode–encode round trip is not a substitute: it reorders keys, and `task_result` orders its
/// `data` on purpose — the path index first, so a client that cuts a long result from the tail
/// still keeps every deliverable's path. Rewriting the envelope's `next` hint for an external
/// agent (`HostedMCPNextHintCompletion`) must leave that order exactly as the handler wrote it.
///
/// Found once: the member knows where its value lies, so reading it (`value`) and writing it back
/// (`replacingValue(with:)`) are two looks at one scan, and the rewrite cannot fail to find what
/// the read found. Until 2026-11-08 the two were separate static scans of the same text, and the
/// second's `nil` — unreachable once the first had answered — was a branch its caller had to write.
///
/// The scan walks the UTF-8 bytes. Every structural character of JSON is ASCII and no byte of a
/// multi-byte character is, so the walk never lands inside one; strings are skipped whole, escapes
/// included, so a key spelled in text or a brace inside a string is not structure.
///
/// The whole top level is read before anything is answered: one object — quoted keys, colons,
/// values, commas — closed by its brace with nothing but whitespace after it. So text that stops
/// anywhere answers `nil`, whether it stops inside the member, after it or past it, and so does a
/// bare number, `true`, `false` or `null` with no `,` or `}` after it: such a value ends where its
/// delimiter is, and `{"next":12` may have been `{"next":123}`. Until 2026-11-08 the scan answered
/// as soon as it reached the member, and returned `1` for `{"next":1`. What is NOT checked is
/// everything below the top level — a container is matched by its brackets, not parsed — and the
/// spelling of a bare value: this finds a member in a document a JSON encoder wrote, it does not
/// validate one.
nonisolated struct JSONTopLevelMember {
    private let bytes: [UInt8]
    private let range: Range<Int>

    /// The first `key` member of `json`'s top level, or `nil` when `json` is not one whole object
    /// or has no such member. A key that occurs only deeper down is not a member; of two members
    /// with the same name the first is the one found, as `JSONSerialization` reads it.
    init?(named key: String, in json: String) {
        let bytes = Array(json.utf8)
        guard let range = Self.valueByteRange(of: key, in: bytes) else { return nil }
        self.bytes = bytes
        self.range = range
    }

    /// The raw JSON text of the member's value.
    var value: String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    /// The document with this member's value replaced by `newValue` — which the caller supplies
    /// as JSON text. Nothing else changes.
    func replacingValue(with newValue: String) -> String {
        var out = Array(bytes[..<range.lowerBound])
        out.append(contentsOf: newValue.utf8)
        out.append(contentsOf: bytes[range.upperBound...])
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Scan

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let colon = UInt8(ascii: ":")
    private static let comma = UInt8(ascii: ",")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// The first `key` member's value range — answered only once the scan has reached the
    /// object's closing brace and found nothing but whitespace after it.
    private static func valueByteRange(of key: String, in bytes: [UInt8]) -> Range<Int>? {
        var index = 0
        func skipWhitespace() {
            while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        }
        skipWhitespace()
        guard index < bytes.count, bytes[index] == openBrace else { return nil }
        index += 1
        skipWhitespace()
        var member: Range<Int>?
        // One member per pass, entered where its key should begin: after the brace, or after the
        // comma that ended the member before. The object's closing brace ends the scan from inside.
        while index < bytes.count {
            guard bytes[index] == quote, let keyEnd = endOfString(in: bytes, from: index) else { return nil }
            let name = decodedKey(bytes[index..<keyEnd])
            index = keyEnd
            skipWhitespace()
            guard index < bytes.count, bytes[index] == colon else { return nil }
            index += 1
            skipWhitespace()
            let valueStart = index
            guard let valueEnd = endOfValue(in: bytes, from: valueStart) else { return nil }
            if member == nil, name == key { member = valueStart..<valueEnd }
            index = valueEnd
            skipWhitespace()
            // Every value — a bare one above all, which ends only where its delimiter is — must be
            // followed by the next member or by the end of the object.
            guard index < bytes.count else { return nil }
            if bytes[index] == comma {
                index += 1
                skipWhitespace()
                continue
            }
            guard bytes[index] == closeBrace else { return nil }
            index += 1
            skipWhitespace()
            return index == bytes.count ? member : nil
        }
        // The text stopped where a key should begin.
        return nil
    }

    /// The index just past the quote that closes the string opening at `start`.
    private static func endOfString(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case backslash: index += 2
            case quote: return index + 1
            default: index += 1
            }
        }
        return nil
    }

    /// The index just past the value starting at `start`: a string, a container with everything
    /// inside it, or a bare number, `true`, `false` or `null` up to the next delimiter.
    private static func endOfValue(in bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case quote:
            return endOfString(in: bytes, from: start)
        case openBrace, openBracket:
            var depth = 0
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case quote:
                    guard let end = endOfString(in: bytes, from: index) else { return nil }
                    index = end
                    continue
                case openBrace, openBracket:
                    depth += 1
                case closeBrace, closeBracket:
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return nil
        default:
            var index = start
            while index < bytes.count,
                  !isWhitespace(bytes[index]),
                  bytes[index] != comma, bytes[index] != closeBrace, bytes[index] != closeBracket {
                index += 1
            }
            return index > start ? index : nil
        }
    }

    /// A key's text with its quotes removed — through the JSON reader when it carries an escape.
    private static func decodedKey(_ quoted: ArraySlice<UInt8>) -> String? {
        let inner = quoted.dropFirst().dropLast()
        guard inner.contains(backslash) else { return String(decoding: inner, as: UTF8.self) }
        return (try? JSONSerialization.jsonObject(with: Data(quoted), options: [.fragmentsAllowed])) as? String
    }
}
