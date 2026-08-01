import Foundation

/// Byte-level line indexing and ASCII substring matching for `SearchExecutor`.
///
/// Replaces the `content.components(separatedBy: .newlines)` +
/// `line.localizedCaseInsensitiveContains(query)` pair that dominated search cost: the split
/// allocated one `String` per line of every file (330k allocations / ~115 ms on a 1500-file tree)
/// and the ICU call ran once per line per query (~256 ms per query). Both are replaced by one
/// pass over the raw UTF-8 bytes, with `String` materialised only for lines that are actually
/// reported or that need the ICU fallback.
///
/// ## The two correctness rules
///
/// **1. Case folding is `A-Z -> a-z` and nothing else.** The tempting `byte | 0x20` also maps
/// `[`→`{`, `@`→`` ` ``, `^`→`~` and NUL→space. In a code search that makes `foo{` match `foo[`.
///
/// **2. A byte scan is authoritative ONLY for pure-ASCII input.** On a line containing any byte
/// >= 0x80 it disagrees with `localizedCaseInsensitiveContains` in BOTH directions:
///
/// | line | query | ICU | bytes |
/// |---|---|---|---|
/// | `cafe` + U+0301 | `cafe` | no | yes — false positive |
/// | `straße` | `strasse` | yes | no — false negative (ß folds to ss) |
/// | U+212A + `elvin` | `kelvin` | yes | no — false negative (KELVIN SIGN folds to k) |
///
/// So such lines go to ICU regardless of what the byte scan said. The decision is per LINE, not
/// per file: 86% of files in this repo contain at least one non-ASCII line, but only 6% of lines
/// do — a per-file rule would send almost everything down the slow path.
///
/// Symmetrically, a NON-ASCII needle can legitimately match ASCII content (U+212A → `k`,
/// U+017F ſ → `s`), so it must always take the ICU path.
nonisolated enum LineScanner {

    /// ASCII lowercase fold: only `A-Z` move, every other byte maps to itself.
    ///
    /// The wraparound trick (`c - 'A' < 26` on unsigned bytes) is branch-free and covers exactly
    /// `0x41...0x5A`; anything below `A` underflows to a large value and fails the test.
    @inline(__always)
    static func fold(_ c: UInt8) -> UInt8 {
        (c &- 0x41) < 26 ? c &+ 0x20 : c
    }

    /// A query prepared once per `run()` rather than re-inspected per line.
    nonisolated struct CompiledNeedle {
        /// Verbatim query — the operand handed to ICU on the slow path.
        let original: String
        /// `"abc".localizedCaseInsensitiveContains("")` is FALSE, while a byte scan would report a
        /// match at offset 0. Reachable through a mixed query array such as `["foo", ""]`, which
        /// is not list mode.
        let isEmpty: Bool
        /// Whether the byte fast path is even a candidate for this needle.
        let isASCII: Bool
        /// ASCII-lowercased bytes; empty when `!isASCII`.
        let foldedBytes: [UInt8]

        init(_ query: String) {
            original = query
            let utf8 = Array(query.utf8)
            isEmpty = utf8.isEmpty
            isASCII = utf8.allSatisfy { $0 < 0x80 }
            foldedBytes = isASCII ? utf8.map { LineScanner.fold($0) } : []
        }
    }

    /// Whether a scalar starting with this byte forces the ICU path.
    ///
    /// **Any non-ASCII scalar does.** That is deliberately blunt, and it was measured rather than
    /// assumed: a script-aware version — treating Cyrillic (`0xD0...0xD3`) and CJK
    /// (`0xE4...0xED`) as byte-decidable, since neither can fold or decompose into ASCII — was
    /// implemented, tested and then reverted, because on this corpus it removed only **5%** of
    /// ICU calls (18,464 → 17,531). The lines that need ICU here are overwhelmingly ordinary
    /// prose punctuation — em-dashes and arrows in comments and docs (`0xE2`) — which is
    /// genuinely folding-sensitive and stays on the slow path either way.
    ///
    /// Deriving the safe set reliably also proved harder than it looks. Two attempts were wrong:
    /// the ﬁ ligature DOES expand to `fi` under ICU (caught by
    /// `LineScannerDifferentialTests`), and a probe that tested only single-character ASCII
    /// needles missed ß→`ss` entirely and reported Latin-1 as safe. A 5% gain does not justify a
    /// hand-maintained table whose failure mode is a search silently missing hits.
    @inline(__always)
    static func leadByteNeedsICU(_ c: UInt8) -> Bool {
        c >= 0x80
    }

    /// Byte spans of each line, with the separator EXCLUDED from the span.
    ///
    /// Parallel arrays rather than an array of structs: this is built for every scanned file and
    /// the fields are consumed independently.
    nonisolated struct LineIndex {
        /// Byte offset of each line's first byte.
        var starts: [Int32] = []
        /// Byte offset one past each line's last content byte.
        var ends: [Int32] = []
        /// Per line: true when a byte scan decides this line correctly — i.e. it contains no
        /// scalar that could fold or decompose into ASCII. See `leadByteNeedsICU`.
        var byteAuthoritative: [Bool] = []
        /// True when EVERY line is byte-authoritative, so a whole-file prefilter miss proves the
        /// file cannot match at all.
        var fileIsByteAuthoritative = true
        /// False when the buffer is not well-formed UTF-8 — the caller treats that as binary.
        ///
        /// Validated here rather than by `String(data:encoding:.utf8)` because that call copies
        /// and validates the whole file just to produce a `String` the scanner never needs: line
        /// text is decoded lazily, per reported line, straight from the byte spans.
        var isValidUTF8 = true

        var count: Int { starts.count }
    }

    /// Length in bytes of the UTF-8 scalar starting at `c`, or 0 when `c` cannot start one.
    @inline(__always)
    private static func utf8SequenceLength(_ c: UInt8) -> Int {
        if c < 0x80 { return 1 }
        if c >= 0xC2 && c <= 0xDF { return 2 }
        if c >= 0xE0 && c <= 0xEF { return 3 }
        if c >= 0xF0 && c <= 0xF4 { return 4 }
        return 0  // continuation byte in lead position, or 0xC0/0xC1/0xF5+ (overlong / out of range)
    }

    /// Validates the continuation bytes of one scalar, including the range restrictions that
    /// reject overlong encodings and surrogates.
    @inline(__always)
    private static func utf8SequenceIsValid(
        _ base: UnsafePointer<UInt8>, _ i: Int, _ length: Int
    ) -> Bool {
        let c = base[i]
        let b1 = base[i + 1]
        switch length {
        case 2:
            return b1 >= 0x80 && b1 <= 0xBF
        case 3:
            let lo: UInt8 = (c == 0xE0) ? 0xA0 : 0x80
            let hi: UInt8 = (c == 0xED) ? 0x9F : 0xBF   // 0xED: reject UTF-16 surrogates
            let b2 = base[i + 2]
            return b1 >= lo && b1 <= hi && b2 >= 0x80 && b2 <= 0xBF
        default:
            let lo: UInt8 = (c == 0xF0) ? 0x90 : 0x80
            let hi: UInt8 = (c == 0xF4) ? 0x8F : 0xBF   // 0xF4: cap at U+10FFFF
            let b2 = base[i + 2], b3 = base[i + 3]
            return b1 >= lo && b1 <= hi
                && b2 >= 0x80 && b2 <= 0xBF && b3 >= 0x80 && b3 <= 0xBF
        }
    }

    /// Splits `[base, base+count)` into lines using EXACTLY the separator set of
    /// `CharacterSet.newlines`, which `components(separatedBy:)` used:
    ///
    ///   U+000A LF, U+000B VT, U+000C FF, U+000D CR, U+0085 NEL, U+2028 LS, U+2029 PS
    ///
    /// CR and LF are INDEPENDENT separators, so a CRLF pair yields an empty line between them and
    /// the following line is numbered +2, not +1. A `\n`-only splitter silently renumbers every
    /// CRLF file — and `SearchMatch.line` is what the model feeds straight into `read_lines`.
    ///
    /// A trailing separator therefore produces a final EMPTY line, and empty input is one empty
    /// line. Both are relied on by the context-window clamping tests.
    ///
    /// Multi-byte separators can only begin at 0xC2 / 0xE2, and 0x0A–0x0D never appear as a UTF-8
    /// continuation byte, so no split can land mid-scalar: every span is independently valid UTF-8.
    static func buildIndex(_ base: UnsafePointer<UInt8>, count: Int) -> LineIndex {
        var index = LineIndex()
        // ~32 bytes per line is a reasonable guess for source text; over-reserving a little is
        // far cheaper than repeated growth.
        let reserve = max(8, count / 32)
        index.starts.reserveCapacity(reserve)
        index.ends.reserveCapacity(reserve)
        index.byteAuthoritative.reserveCapacity(reserve)

        var lineStart = 0
        var lineByteAuthoritative = true
        var i = 0

        @inline(__always)
        func closeLine(contentEnd: Int) {
            index.starts.append(Int32(lineStart))
            index.ends.append(Int32(contentEnd))
            index.byteAuthoritative.append(lineByteAuthoritative)
            if !lineByteAuthoritative { index.fileIsByteAuthoritative = false }
            lineByteAuthoritative = true
        }

        while i < count {
            let c = base[i]
            if c < 0x80 {
                if c >= 0x0A && c <= 0x0D {
                    // LF / VT / FF / CR — one byte each, each its own separator.
                    closeLine(contentEnd: i)
                    i += 1
                    lineStart = i
                    continue
                }
                i += 1
                continue
            }
            // Multi-byte scalar: validate it, classify it, and skip it whole. Advancing by the
            // full sequence is what keeps `leadByteNeedsICU` off continuation bytes — judging
            // those would mark every multi-byte scalar as ICU-needing, since 0x80...0xBF falls
            // outside both safe ranges.
            let length = utf8SequenceLength(c)
            guard length >= 2, i + length <= count, utf8SequenceIsValid(base, i, length) else {
                index.isValidUTF8 = false
                return index  // caller treats this as binary; no point indexing further
            }

            if length == 2, c == 0xC2, base[i + 1] == 0x85 {
                // U+0085 NEL
                closeLine(contentEnd: i)
                i += 2
                lineStart = i
                continue
            }
            if length == 3, c == 0xE2, base[i + 1] == 0x80,
               base[i + 2] == 0xA8 || base[i + 2] == 0xA9 {
                // U+2028 LINE SEPARATOR / U+2029 PARAGRAPH SEPARATOR
                closeLine(contentEnd: i)
                i += 3
                lineStart = i
                continue
            }
            if leadByteNeedsICU(c) { lineByteAuthoritative = false }
            i += length
        }

        // Final line after the last separator — possibly empty, always present.
        closeLine(contentEnd: count)
        return index
    }

    /// Case-insensitive ASCII substring search over raw bytes.
    ///
    /// `needle` must already be folded (see `CompiledNeedle.foldedBytes`); the haystack is folded
    /// on the fly. Uses pointer arithmetic rather than `UnsafeBufferPointer` subscripting because
    /// Debug builds compile at `-Onone` (`SWIFT_OPTIMIZATION_LEVEL` in the project), where bounds
    /// checks on the inner loop are not optimised away.
    @inline(__always)
    static func asciiContains(
        haystack: UnsafePointer<UInt8>, count: Int,
        needle: UnsafePointer<UInt8>, needleCount: Int
    ) -> Bool {
        if needleCount == 0 { return false }
        if count < needleCount { return false }
        let first = needle[0]
        var i = 0
        let last = count - needleCount
        while i <= last {
            if fold(haystack[i]) == first {
                var k = 1
                while k < needleCount, fold(haystack[i + k]) == needle[k] { k += 1 }
                if k == needleCount { return true }
            }
            i += 1
        }
        return false
    }

    /// True when `Locale.current` folds ASCII the same way a plain `A-Z -> a-z` table does.
    ///
    /// `localizedCaseInsensitiveContains` passes `Locale.current`, and Turkish/Azerbaijani apply
    /// the dotless-i rule, under which `I` and `i` are NOT case variants. Rather than model that,
    /// the byte fast path is disabled wholesale in those locales.
    static var asciiFoldMatchesLocale: Bool {
        let code = Locale.current.language.languageCode?.identifier.lowercased() ?? ""
        return code != "tr" && code != "az"
    }
}
