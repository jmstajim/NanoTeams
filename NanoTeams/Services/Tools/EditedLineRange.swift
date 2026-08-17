import Foundation

/// Which lines an `edit_file` call actually changed, derived by comparing the file before
/// and after the write.
///
/// **Why a diff instead of threading a range out of the handler.** `EditFileTool` produces
/// its new content by three different routes — an exact single splice (which does hold a
/// `Range<String.Index>`), an exact `replacingOccurrences` under `replace_all` (which holds
/// nothing), and the whitespace-tolerant window path (which works in its own line-array
/// space and returns no position at all). Threading a range out of all three would mean
/// three implementations that can disagree; comparing the two strings is ONE implementation
/// that is correct for every route by construction, including any route added later. The
/// cost is a linear scan of a string the tool has just read and written in full, so the O(n)
/// is already paid.
///
/// **Why the line model is `.newlines` and not `"\n"`.** The number exists to be usable: a
/// human reads it and opens that line, and a model would pass it to `read_lines`. Those
/// read `components(separatedBy: .newlines)` (`FileReadHandlers`), which splits on all seven
/// Unicode line separators, whereas `EditFileTool`'s own internal line arrays split on
/// `"\n"` alone and carry `\r` as a trailing character. Measured on macOS 26, the two
/// disagree on any file that is not pure-LF — for `"a\r\nb\r\nc"`, `.newlines` yields five
/// components and `"\n"` yields three, and bare `\r`, U+2028 and U+0085 split under one and
/// not the other. Counting in the handler's model would therefore print a number that lands
/// on the wrong line in the very tool the reader would use next, so this counts separators
/// the `.newlines` way and is pinned against `read_lines` on a CRLF fixture.
///
/// **Known limit, deliberately not special-cased.** `EditFileTool` reads raw UTF-8, while
/// `read_lines` routes `.rtf`/`.rtfd` through `DocumentTextExtractor` — so for those the
/// tools number different texts (markup source vs extracted body) and this number is not
/// usable in `read_lines`. Pre-existing and narrow; an extension check here would be a
/// second line model by another name, which is the defect this type exists to prevent.
nonisolated enum EditedLineRange {

    /// One-based, inclusive, in the numbering of the file AS IT IS NOW.
    ///
    /// The *new* file's numbering, deliberately: the reader's next action is to look at what
    /// is on disk, and an edit that changes the line count makes the old numbering wrong the
    /// moment it lands.
    nonisolated struct Span: Equatable {
        let startLine: Int
        let endLine: Int
    }

    /// `nil` when the two strings are identical — a real outcome, not a failure: the
    /// whitespace-tolerant tiers can match a window and splice back bytes equal to what was
    /// there, which `EditFileTool` already reports as "the edit left the file unchanged".
    /// There is no line to point at, and inventing one would contradict that warning.
    static func compute(before: String, after: String) -> Span? {
        guard before != after else { return nil }

        // Longest common prefix. Ends wherever the first difference is, which may be
        // mid-line — that line is the one the change starts on.
        var b = before.startIndex
        var a = after.startIndex
        while b < before.endIndex, a < after.endIndex, before[b] == after[a] {
            before.formIndex(after: &b)
            after.formIndex(after: &a)
        }

        // Longest common suffix, stopped at the prefix so the two regions cannot overlap
        // (they would for a change that is a pure repetition, e.g. "ab" → "aab").
        //
        // The `> b` / `> a` bounds are load-bearing, not tidiness: they are the only reason
        // `after[a..<aEnd]` below is a well-formed range. Measured — relaxing them to
        // `startIndex` makes a duplicate-line insertion walk the suffix back PAST the prefix
        // and trap with "Range requires lowerBound <= upperBound".
        //
        // Prefix first, then suffix. The opposite order is equally self-consistent and gives
        // a DIFFERENT answer when the change duplicates adjacent text, so this is a decision:
        // prefix-first matches `diff`'s "where does it first differ" convention, which is
        // what a reader of a line number expects.
        var bEnd = before.endIndex
        var aEnd = after.endIndex
        while bEnd > b, aEnd > a {
            let bPrev = before.index(before: bEnd)
            let aPrev = after.index(before: aEnd)
            guard before[bPrev] == after[aPrev] else { break }
            bEnd = bPrev
            aEnd = aPrev
        }

        let startLine = 1 + measure(before[before.startIndex..<b]).separators

        // The changed region as it now exists. A pure deletion leaves this empty, which
        // correctly collapses the span onto the single line the removal happened on.
        //
        // A separator TERMINATES the line it ends, so it must not be counted as opening
        // another one. Without this, inserting a whole line — `"y\n"`, the single
        // commonest edit there is — reports two lines, the second of which is the
        // untouched line that merely got pushed down.
        let changed = measure(after[a..<aEnd])
        let endLine = startLine + changed.separators - (changed.endsWithSeparator ? 1 : 0)
        return Span(startLine: startLine, endLine: endLine)
    }

    /// Separator count in the `components(separatedBy: .newlines)` sense, plus whether the
    /// region ends on one. Counted over unicode scalars rather than by splitting — the
    /// prefix can be the whole file, and splitting it would allocate one String per line
    /// just to produce an integer.
    ///
    /// Scalar-wise counting matches Foundation exactly, CRLF included: `.newlines` treats
    /// CR and LF as two separators (measured — `"a\r\nb"` yields three components), so
    /// counting both scalars reproduces the same total. `CharacterSet.newlines` is consulted
    /// directly rather than an inlined scalar switch: a hand-written set is faster and can
    /// silently drift from what `read_lines` splits on, which is the one defect this type
    /// exists to prevent.
    private static func measure(_ text: Substring) -> (separators: Int, endsWithSeparator: Bool) {
        var separators = 0
        var endsWithSeparator = false
        for scalar in text.unicodeScalars {
            if newlines.contains(scalar) {
                separators += 1
                endsWithSeparator = true
            } else {
                endsWithSeparator = false
            }
        }
        return (separators, endsWithSeparator)
    }

    /// Stored once — `CharacterSet.newlines` is a computed property and this is consulted
    /// per scalar of a potentially whole-file prefix.
    private static let newlines = CharacterSet.newlines
}
