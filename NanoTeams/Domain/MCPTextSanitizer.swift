import Foundation

/// Strips the characters a foreign server can put in its text that a reader — human or
/// model — cannot see.
///
/// Server text reaches two readers: a system prompt (the tool's description and schema) and
/// the model's tool results, and beside both a person — the review sheet, the approval card.
/// Three documented families make those readers disagree, which is exactly what a poisoning
/// payload needs:
///
///  - **Zero-width characters** (U+200B–U+200D, U+2060, U+FEFF) hide text from the human
///    while the model still reads it.
///  - **Bidirectional overrides** (U+202A–U+202E, U+2066–U+2069) reorder a rendered line,
///    so the card can show `read a file` for a description that says the opposite.
///  - **C0/C1 controls and ANSI escapes** rewrite a terminal's display and can erase the
///    lines above them; `\u{1B}[2J` in a description clears the reviewer's screen.
///
/// **Two sanitizers, because there are two kinds of text** (2026-09-23). A DESCRIPTION is
/// prose this app lays out: it loses every family above, blank-line padding and surrounding
/// whitespace. A tool result is DATA — a file's contents, a message someone wrote — and is not
/// this app's to lay out: `sanitizeData` removes only what makes a renderer lie (bidi
/// embeddings, overrides and isolates; tag characters; C0/C1 controls and the escape sequences
/// they start) and keeps every other byte, so a CRLF file, its indentation, its page breaks
/// (form feed, vertical tab, NEL), the directional marks (LRM, RLM, ALM) and the joiner inside
/// an emoji come back as sent. Until then one function served both, and a file the model
/// wrote back from a tool result came back de-indented, LF-only and with its emoji broken.
///
/// **A third reading, for IDENTIFIERS** (`isNameSafe`, `valueLine`): a property name the
/// model sends back as a key, and an `enum`/`const`/`default` value it sends back as a value.
/// Those cannot be cleaned without changing what the server accepts, so a name is refused
/// unless it hides nothing — with ONE exception, ZWNJ/ZWJ between two visible characters,
/// which is Persian orthography and emoji construction rather than a hiding place.
///
/// **Two quieter families** (2026-09-23). A VARIATION SELECTOR picks a glyph for the character
/// before it, and a run of them is a byte channel no reader sees — the supplementary block
/// (U+E0100–E01EF) encodes one byte each, the tag characters' trick again. Prose, names and
/// what a person is shown keep only the emoji presentation selector on an emoji (`❤️`); data
/// keeps one selector per visible character, which is all legitimate text ever has
/// (`SelectorRule`). HANGUL FILLERS are letters that draw nothing: prose loses them and a name
/// refuses them, while data keeps them, because old-Hangul text is spelled with two of them.
///
/// Nothing is truncated. A long description is a long description — the house rule is that
/// tool text is the model's documentation, and cutting it is how a model ends up guessing
/// at the half it was not shown.
nonisolated enum MCPTextSanitizer {

    /// Removes invisible and display-rewriting characters, keeping paragraph structure.
    /// Line breaks survive (collapsed to at most one blank line) because the review sheet
    /// shows the description as the server wrote it.
    static func sanitize(_ text: String) -> String {
        laidOut(filtered(text, dropping: isStripped, selectors: .emojiPresentation))
    }

    /// Sanitizes and flattens to one line — the form a tool or parameter description takes
    /// in a rendered prompt, where the surrounding list is line-oriented and a stray
    /// newline would read as the end of the entry.
    static func singleLine(_ text: String) -> String {
        flattened(sanitize(text))
    }

    /// Text cut to `limit` characters, with `…` saying so. For a server string QUOTED inside a
    /// message — a refusal, a status row — never for a description or a result, which are not
    /// cut (see the type's doc).
    static func capped(_ text: String, at limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    // MARK: - Names and values the model sends back

    /// ONE rule for a server string the model sends back VERBATIM as a key — a property name,
    /// a `required` entry. Such a string cannot be cleaned (cleaning renames the argument), so
    /// it is accepted only when it hides nothing: no C0/C1 control (a tab included), no line or
    /// paragraph separator, no bidi embedding, override, isolate or mark (LRM, RLM, ALM), no tag
    /// character, no zero-width space, BOM, word joiner or other invisible formatting (Unicode
    /// category Cf), no Hangul filler, no variation selector but the emoji presentation one on
    /// an emoji, and no surrounding whitespace. What it refuses, `visibleLine` spells out — one
    /// predicate (`isHidden`), so a refused name never reads as the clean name it imitates.
    ///
    /// The one exception is ZWNJ (U+200C) and ZWJ (U+200D) BETWEEN two visible characters:
    /// ZWNJ is standard Persian orthography (`نام‌خانوادگی`) and ZWJ builds an emoji (`👨‍💻`).
    /// Leading, trailing, doubled or beside anything invisible, a joiner joins nothing and is
    /// refused like the rest. Until 2026-09-23 the rule was "the one-line form leaves it
    /// alone", which strips every joiner, and a Persian or emoji name refused its whole tool.
    static func isNameSafe(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        if scalars.first?.properties.isWhitespace == true || scalars.last?.properties.isWhitespace == true {
            return false
        }
        return scalars.indices.allSatisfy { index in
            isJoiner(scalars[index])
                ? isJoinable(at: index - 1, in: scalars) && isJoinable(at: index + 1, in: scalars)
                : !isHidden(scalars[index], after: index > 0 ? scalars[index - 1] : nil)
        }
    }

    /// `singleLine` for a VALUE the model may send back — an `enum` member, a `const`, the
    /// `default` it is told about: the same cleaning, except that a joiner between two visible
    /// characters stays, by the rule `isNameSafe` keeps it. So the value the model reads is the
    /// value the server accepts. A value that needed any OTHER cleaning is one the server will
    /// refuse when it comes back — loudly, as `-32602`, which is the right way for a disguised
    /// value to fail.
    static func valueLine(_ text: String) -> String {
        flattened(laidOut(filtered(
            text, dropping: isStripped, keepingInteriorJoiners: true, selectors: .emojiPresentation)))
    }

    /// Whether the text carried anything worth telling the reviewer about. The review sheet
    /// says so beside the description: a description that needed cleaning is a signal in
    /// itself, and hiding the cleaning would hide the signal. "Carried" is what the prose pass
    /// DROPS — a detached variation selector included — not the layout it tidies.
    static func containsStrippedCharacters(_ text: String) -> Bool {
        !filtered(text, dropping: isStripped, selectors: .emojiPresentation)
            .unicodeScalars.elementsEqual(text.unicodeScalars)
    }

    /// The same question over a whole JSON document — every key and every string, at every
    /// depth. A tool is more than its description: its name, its annotations and every
    /// string of its schemas reach a prompt or a sheet, and "the server sent hidden
    /// characters in this tool" is only true if all of them were looked at.
    static func containsStrippedCharacters(in value: JSONValue) -> Bool {
        switch value {
        case .string(let text):
            return containsStrippedCharacters(text)
        case .array(let elements):
            return elements.contains(where: containsStrippedCharacters(in:))
        case .object(let members):
            return members.contains { containsStrippedCharacters($0.key) || containsStrippedCharacters(in: $0.value) }
        case .null, .bool, .int, .double:
            return false
        }
    }

    // MARK: - Diff Sanitization

    struct DiffSanitizationResult: Sendable, Equatable {
        let text: String
        let hadStripped: Bool
        init(text: String, hadStripped: Bool) {
            self.text = text
            self.hadStripped = hadStripped
        }
    }

    /// Diff text for code review: nothing is removed — every character that hides becomes a
    /// visible `<U+XXXX>` tag (an escape, `<ESC>`), and `hadStripped` says there was one.
    ///
    /// "Hides" is ONE predicate with what a name may not carry (`isInvisibleInName`: zero-width,
    /// bidi, tag characters, C0/C1 controls, Hangul fillers, the soft hyphen and every other
    /// format character, line and paragraph separators) widened by Unicode's default-ignorable
    /// set (the combining grapheme joiner, U+FFF0…), because a diff is read for what it does,
    /// not for how it draws. Until 2026-11-12 it tagged only the stripped families, and a run of
    /// supplementary variation selectors — a byte per selector — reached the reviewer untagged
    /// and unwarned (S4). Kept as they are, because legitimate text has them:
    ///  - `\n` and `\t`, and `\r` before `\n` — a lone `\r` rewrites a terminal line and is tagged;
    ///  - ONE variation selector on a visible character (`❤️`, `葛󠄀`), the data rule — a second
    ///    one on the same character is tagged;
    ///  - ZWNJ/ZWJ between two visible characters (`👨‍💻`, Persian), the name rule;
    ///  - a BOM that opens a file — the first line of a hunk starting at line 1.
    static func sanitizeDiff(_ text: String) -> DiffSanitizationResult {
        tagged(text, layout: .diff)
    }

    /// A file name as `task_changes` shows it: every hidden character tagged, line breaks and
    /// tabs included, so a name stays on its line and hides nothing — and the spelling a
    /// `file_path` filter accepts back.
    static func taggedName(_ text: String) -> DiffSanitizationResult {
        tagged(text, layout: .name)
    }

    private enum TagLayout { case diff, name }

    private static func tagged(_ text: String, layout: TagLayout) -> DiffSanitizationResult {
        let scalars = Array(text.unicodeScalars)
        let openingBOMs = layout == .diff ? fileOpeningBOMs(in: scalars) : []
        // A diff line's first scalar is its marker (`+`, `-`, ` `), not text: nothing it carries
        // attaches to it, and a joiner right after it joins nothing.
        let markers: Set<Int> = layout == .diff
            ? Set(scalars.indices.filter { $0 == 0 || scalars[$0 - 1] == "\n" })
            : []
        func joinable(_ index: Int) -> Bool {
            !markers.contains(index) && isJoinable(at: index, in: scalars)
        }
        var out = String.UnicodeScalarView()
        var hadHidden = false
        /// The input scalar just kept, when a variation selector may attach to it.
        var selectorBase: Unicode.Scalar?

        func tag(_ scalar: Unicode.Scalar) {
            hadHidden = true
            let tag = String(format: scalar.value > 0xFFFF ? "<U+%05X>" : "<U+%04X>", scalar.value)
            out.append(contentsOf: tag.unicodeScalars)
            selectorBase = nil
        }
        func keep(_ scalar: Unicode.Scalar, base: Bool) {
            out.append(scalar)
            selectorBase = base ? scalar : nil
        }

        for (index, scalar) in scalars.enumerated() {
            switch scalar {
            case "\u{1B}":
                hadHidden = true
                out.append(contentsOf: "<ESC>".unicodeScalars)
                selectorBase = nil
            case "\n" where layout == .diff, "\t" where layout == .diff:
                keep(scalar, base: false)
            case "\r" where layout == .diff && index + 1 < scalars.count && scalars[index + 1] == "\n":
                keep(scalar, base: false)
            case "\u{FEFF}" where openingBOMs.contains(index):
                keep(scalar, base: false)
            default:
                if isVariationSelector(scalar) {
                    if let base = selectorBase, SelectorRule.onePerCharacter.attaches(scalar, to: base) {
                        keep(scalar, base: false)
                    } else {
                        tag(scalar)
                    }
                } else if isJoiner(scalar) {
                    if joinable(index - 1) && joinable(index + 1) {
                        keep(scalar, base: false)
                    } else {
                        tag(scalar)
                    }
                } else if isInvisibleInName(scalar) || scalar.properties.isDefaultIgnorableCodePoint {
                    tag(scalar)
                } else {
                    keep(scalar, base: !markers.contains(index))
                }
            }
        }
        return DiffSanitizationResult(text: String(out), hadStripped: hadHidden)
    }

    /// The indices of a BOM that opens a file in a unified diff: the first scalar after the
    /// marker of the first content line of a hunk that starts at line 1 of that side.
    private static func fileOpeningBOMs(in scalars: [Unicode.Scalar]) -> Set<Int> {
        var allowed = Set<Int>()
        var oldOpens = false
        var newOpens = false
        var lineStart = 0
        while lineStart < scalars.count {
            var lineEnd = lineStart
            while lineEnd < scalars.count && scalars[lineEnd] != "\n" { lineEnd += 1 }
            let marker = scalars[lineStart]
            let line = String(String.UnicodeScalarView(scalars[lineStart..<lineEnd]))
            if line.hasPrefix("@@ -") {
                let starts = hunkStarts(line)
                oldOpens = starts.old == 1
                newOpens = starts.new == 1
            } else if marker == "+" || marker == "-" || marker == " " {
                let opens = (marker == "+" && newOpens) || (marker == "-" && oldOpens)
                    || (marker == " " && oldOpens && newOpens)
                if opens, lineStart + 1 < lineEnd, scalars[lineStart + 1] == "\u{FEFF}" {
                    allowed.insert(lineStart + 1)
                }
                if marker != "-" { newOpens = false }
                if marker != "+" { oldOpens = false }
            } else if marker != "\\" {
                oldOpens = false
                newOpens = false
            }
            lineStart = lineEnd + 1
        }
        return allowed
    }

    /// The old and new start lines of a hunk header `@@ -a[,b] +c[,d] @@`.
    private static func hunkStarts(_ header: String) -> (old: Int?, new: Int?) {
        func number(after marker: String) -> Int? {
            guard let range = header.range(of: marker) else { return nil }
            return Int(header[range.upperBound...].prefix { $0.isASCII && $0.isNumber })
        }
        return (number(after: "@@ -"), number(after: " +"))
    }

    // MARK: - Data

    /// A tool result's text: drops only bidi controls, tag characters and C0/C1 controls
    /// other than `\t` `\n` `\r` (with the escape sequences they introduce), and never trims,
    /// collapses, normalises a line ending or drops a joiner. See the type's doc for why.
    static func sanitizeData(_ text: String) -> String {
        filtered(text, dropping: isStrippedFromData, selectors: .onePerCharacter)
    }

    /// `sanitizeData`, and the directional marks too — LRM U+200E, RLM U+200F, ALM U+061C — for
    /// a text a person reads RENDERED while a model reads its characters: the Work Folder Context,
    /// in the Settings editor and in every reading role's prompt. A mark hides no character and
    /// moves none, but it is a strong one: around each word of a left-to-right line it makes the
    /// line a right-to-left paragraph, and "production not staging" lays out as "staging not
    /// production" (an `NSLayoutManager` layout, review 2026-11-13) while the model reads it as
    /// sent. Data keeps the marks because a file's text is what it is; here nothing needs them —
    /// a model reads the words without, and the joiners, which shape a Persian word or an emoji
    /// and move nothing, stay.
    static func sanitizeDisplayedData(_ text: String) -> String {
        filtered(text, dropping: isStrippedFromDisplayedData, selectors: .onePerCharacter)
    }

    /// `sanitizeData` over every key and every string of a JSON document; numbers, booleans
    /// and null pass as they are. `structuredContent` is read by the model exactly as a text
    /// block is, so it takes the same cleaning.
    static func sanitizeData(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(sanitizeData(text))
        case .array(let elements):
            return .array(elements.map(sanitizeData))
        case .object(let members):
            return .object(sanitizedMembers(members))
        case .null, .bool, .int, .double:
            return value
        }
    }

    /// Keys are cleaned like values, and two keys that differ only by stripped characters
    /// would fold into one and silently drop a value. So: a key that needed no cleaning keeps
    /// its name whatever a look-alike does; among the rest the first in scalar order takes the
    /// folded name; any other takes its VISIBLE spelling (`escapeHidden`), which says why the
    /// second key exists; and a spelling taken even so gets a numbered suffix. Nothing is
    /// dropped, and the outcome does not depend on dictionary order.
    private static func sanitizedMembers(_ members: [String: JSONValue]) -> [String: JSONValue] {
        let ordered = members.keys.sorted { lhs, rhs in
            let lhsClean = sanitizeData(lhs) == lhs
            if lhsClean != (sanitizeData(rhs) == rhs) { return lhsClean }
            return lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
        }
        var out: [String: JSONValue] = [:]
        for key in ordered {
            guard let value = members[key] else { continue }
            var name = sanitizeData(key)
            if out[name] != nil { name = escapeHidden(key).display }
            let base = name
            var ordinal = 2
            while out[name] != nil {
                name = "\(base) (\(ordinal))"
                ordinal += 1
            }
            out[name] = sanitizeData(value)
        }
        return out
    }

    // MARK: - Visible escapes

    /// Text as a person must see it before approving something: every character `sanitize`
    /// would strip, rendered as a visible `\u{XXXX}` escape instead of removed.
    struct EscapedText: Hashable, Sendable {
        /// The text with each hidden character spelled out. Never shorter than what it shows.
        let display: String
        /// Whether anything was hidden — the one bit a surface needs to warn on.
        let hadHidden: Bool
    }

    /// Which of a text's line and paragraph breaks are its layout — `\n`, `\r`, `\t`, U+2028,
    /// U+2029 — and what `escapeHidden` does with the rest.
    enum Layout: Sendable {
        /// A document as it came: every break is layout, kept, and never counted hidden.
        case document
        /// Text the APP laid out with "\n" alone — a pretty-printed arguments box, whose printer
        /// escapes a value's own "\n", "\r" and "\t" and writes no other break. "\n" is the one
        /// layout character; any other break in such text came from a value, draws as a line
        /// break (or a tab stop) nothing tells from a soft wrap, and can forge a line — so it is
        /// spelled out and counted hidden. U+0085 is a control character and hidden in every
        /// layout.
        case appLaidOut
        /// One line: every break spelled out, none counted hidden — a NAME, or anything printed
        /// inside app text (`visibleLine`).
        case singleLine
    }

    /// Shows what hides — everything `sanitize` strips (zero-width, bidi, tag characters,
    /// C0/C1 controls, Hangul fillers, a detached variation selector) and every other character
    /// a name may not carry (`isHidden`: the soft hyphen, the rest of Unicode's invisible
    /// formatting) — as `\u{XXXX}`, and reports whether there was any. Nothing is removed and
    /// nothing cut: the approval card uses this so a person reads the arguments that will
    /// actually be sent. What happens to a line or paragraph break is `layout`'s.
    static func escapeHidden(_ text: String, layout: Layout = .document) -> EscapedText {
        var display = ""
        display.reserveCapacity(text.unicodeScalars.count)
        var hadHidden = false
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            let isBreak = scalar == "\n" || scalar == "\r" || scalar == "\t"
                || scalar == "\u{2028}" || scalar == "\u{2029}"
            if isBreak {
                switch layout {
                case .document:
                    display.unicodeScalars.append(scalar)
                    continue
                case .appLaidOut where scalar == "\n":
                    display.unicodeScalars.append(scalar)
                    continue
                case .appLaidOut:
                    hadHidden = true
                case .singleLine:
                    break
                }
            } else if isHidden(scalar, after: previous) {
                hadHidden = true
            } else {
                display.unicodeScalars.append(scalar)
                continue
            }
            display += String(format: "\\u{%04X}", scalar.value)
        }
        return EscapedText(display: display, hadHidden: hadHidden)
    }

    /// A server string printed INSIDE app text — a tool's name in a Settings row, in a
    /// refusal, in the review sheet's origin card: `escapeHidden` with line breaks spelled out
    /// too, so it stays on its line and hides nothing. The one spelling every such surface
    /// uses; the stored value stays as the server sent it.
    static func visibleLine(_ text: String) -> String {
        escapeHidden(text, layout: .singleLine).display
    }

    // MARK: - Scanning

    /// Every scalar of `text` that `drop` keeps, with each escape sequence removed as a unit.
    /// Dropping the ESC alone would leave `[2J` as visible noise. A variation selector is kept
    /// when `selectors` says it selects a glyph for the scalar kept right before it.
    ///
    /// `keepingInteriorJoiners` keeps a ZWNJ/ZWJ that ends up between two visible scalars of
    /// the OUTPUT, each ADJACENT to it in the input — so a joiner on either side of a dropped
    /// character or an escape sequence joins nothing and goes, as `isNameSafe` would refuse it.
    private static func filtered(
        _ text: String, dropping drop: (Unicode.Scalar) -> Bool, keepingInteriorJoiners: Bool = false,
        selectors: SelectorRule
    ) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = FilteredScalars()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\u{1B}" {
                index = endOfEscapeSequence(in: scalars, startingAt: index)
                out.breakJoin()
                continue
            }
            if isVariationSelector(scalar) {
                out.offerSelector(scalar, by: selectors)
            } else if keepingInteriorJoiners, isJoiner(scalar) {
                out.offerJoiner(scalar)
            } else if drop(scalar) {
                out.breakJoin()
            } else {
                out.append(scalar)
            }
            index += 1
        }
        out.breakJoin()
        return String(out.scalars)
    }

    /// The output of `filtered`. It remembers the input scalar just kept — what a joiner or a
    /// selector attaches to — and holds back an offered joiner until the scalar after it says
    /// whether it joins two visible characters.
    private struct FilteredScalars {
        private(set) var scalars = String.UnicodeScalarView()
        /// The previous INPUT scalar when it was kept; `nil` after anything dropped, an escape
        /// sequence or a joiner. Reading `scalars.last` instead let a joiner right after a
        /// dropped character attach to the visible one before it (until 2026-09-23).
        private var keptBefore: Unicode.Scalar?
        private var pendingJoiner: Unicode.Scalar?

        mutating func append(_ scalar: Unicode.Scalar) {
            if let joiner = pendingJoiner, MCPTextSanitizer.isJoinable(scalar) {
                scalars.append(joiner)
            }
            pendingJoiner = nil
            scalars.append(scalar)
            keptBefore = scalar
        }

        /// Held only right after a kept visible scalar — so the second joiner of a run, which
        /// follows a joiner, drops the first with it.
        mutating func offerJoiner(_ joiner: Unicode.Scalar) {
            pendingJoiner = keptBefore.map(MCPTextSanitizer.isJoinable) == true ? joiner : nil
            keptBefore = nil
        }

        mutating func offerSelector(_ selector: Unicode.Scalar, by rule: SelectorRule) {
            if let base = keptBefore, rule.attaches(selector, to: base) {
                append(selector)
            } else {
                breakJoin()
            }
        }

        mutating func breakJoin() {
            pendingJoiner = nil
            keptBefore = nil
        }
    }

    /// Flattens laid-out text to one line: every line break becomes one space, and blank or
    /// whitespace-only lines vanish.
    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Filtered text laid out as prose: blank-line runs collapsed, the ends trimmed.
    private static func laidOut(_ kept: String) -> String {
        collapseBlankLines(kept).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The index just past the escape sequence whose ESC sits at `start`.
    ///
    /// - A CSI (`ESC [`) is parameter and intermediate bytes (0x20…0x3F) and one final byte
    ///   (0x40…0x7E). Any other scalar ends it WITHOUT being consumed: until 2026-09-23 only a
    ///   final byte ended it, so an `ESC [` before non-ASCII text swallowed every letter up to
    ///   the next Latin one.
    /// - An OSC (`ESC ]`) ends at BEL or at the string terminator `ESC \`; its payload is
    ///   printable ASCII, so any other scalar ends it unconsumed, and an ESC that does not
    ///   terminate it starts the next sequence.
    /// - Any other ESC is dropped alone and the scalar after it is read as text.
    private static func endOfEscapeSequence(in scalars: [Unicode.Scalar], startingAt start: Int) -> Int {
        let introducer = start + 1
        guard introducer < scalars.count else { return introducer }
        switch scalars[introducer] {
        case "[":
            var index = introducer + 1
            while index < scalars.count, (0x20...0x3F).contains(scalars[index].value) { index += 1 }
            if index < scalars.count, (0x40...0x7E).contains(scalars[index].value) { index += 1 }
            return index
        case "]":
            var index = introducer + 1
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\u{07}" { return index + 1 }
                if scalar == "\u{1B}" {
                    let isTerminator = index + 1 < scalars.count && scalars[index + 1] == "\\"
                    return isTerminator ? index + 2 : index
                }
                guard (0x20...0x7E).contains(scalar.value) else { return index }
                index += 1
            }
            return index
        default:
            return introducer
        }
    }

    // MARK: - Classification

    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        if isStrippedFromData(scalar) { return true }
        switch scalar.value {
        case 0x0B, 0x0C, 0x85:
            return true                       // VT, FF, NEL: layout in a file, not in prose
        case 0x061C:
            return true                       // Arabic letter mark, the RLM's sibling
        case 0x200B...0x200F:
            return true                       // zero width space/joiners, LRM/RLM
        case 0x2060...0x2064:
            return true                       // word joiner and invisible operators
        case 0xFEFF:
            return true                       // BOM used mid-string
        case 0x115F, 0x1160, 0x3164, 0xFFA0:
            return true                       // Hangul fillers: letters that draw nothing
        default:
            return false
        }
    }

    /// The subset data loses: what makes a renderer show something other than the bytes
    /// (bidi embeddings, overrides and isolates; tag characters) and what a terminal acts on
    /// (C0/C1 controls). The joiners and marks `isStripped` adds are part of the text they sit
    /// in, and so are VT, FF and NEL — the page breaks of an RFC or a GNU source file, which
    /// no terminal acts on destructively (until 2026-09-23 data lost them too).
    private static func isStrippedFromData(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0E...0x1F, 0x7F:
            return true                       // C0 controls and DEL; \t \n \v \f \r survive
        case 0x80...0x84, 0x86...0x9F:
            return true                       // C1 controls; NEL survives
        case 0x202A...0x202E:
            return true                       // bidi embedding and override
        case 0x2066...0x2069:
            return true                       // bidi isolates
        case 0xE0000...0xE007F:
            return true                       // tag characters — an invisible second channel
        default:
            return false
        }
    }

    /// `isStrippedFromData` and the three directional marks (`sanitizeDisplayedData`).
    private static func isStrippedFromDisplayedData(_ scalar: Unicode.Scalar) -> Bool {
        if isStrippedFromData(scalar) { return true }
        switch scalar.value {
        case 0x200E, 0x200F, 0x061C:
            return true                       // LRM, RLM, ALM: they reorder what a person sees
        default:
            return false
        }
    }

    private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{200C}" || scalar == "\u{200D}"
    }

    /// What hides: one predicate for the name rule that refuses it and the visible spelling
    /// that shows it. A variation selector hides unless it is the emoji presentation selector
    /// on the emoji `previous`.
    private static func isHidden(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar?) -> Bool {
        isVariationSelector(scalar)
            ? !(previous.map { SelectorRule.emojiPresentation.attaches(scalar, to: $0) } ?? false)
            : isInvisibleInName(scalar)
    }

    /// Selects a glyph for the character before it. The supplementary block encodes a byte per
    /// selector, which is what makes a run of them a channel.
    private static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x180B...0x180D, 0x180F, 0xFE00...0xFE0F, 0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    /// Where a variation selector survives. Either way it needs a visible base right before
    /// it that is not itself a selector — so a run keeps at most its first.
    private enum SelectorRule {
        /// Prose, names, what a person is shown: the emoji presentation selectors, on an emoji.
        case emojiPresentation
        /// Data: one selector on the character before it, as an ideographic variation
        /// sequence (`葛󠄀`) or an emoji has.
        case onePerCharacter

        func attaches(_ selector: Unicode.Scalar, to base: Unicode.Scalar) -> Bool {
            guard !MCPTextSanitizer.isVariationSelector(base), MCPTextSanitizer.isJoinable(base) else {
                return false
            }
            switch self {
            case .emojiPresentation:
                return (selector == "\u{FE0E}" || selector == "\u{FE0F}") && base.properties.isEmoji
            case .onePerCharacter:
                return true
            }
        }
    }

    /// What a name may not carry: everything prose loses, and every other control, format
    /// character (Unicode Cf — the soft hyphen, the deprecated format controls) and line or
    /// paragraph separator.
    private static func isInvisibleInName(_ scalar: Unicode.Scalar) -> Bool {
        if isStripped(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// A scalar a joiner may sit against: visible, and not itself a joiner.
    private static func isJoinable(_ scalar: Unicode.Scalar) -> Bool {
        !isJoiner(scalar) && !isInvisibleInName(scalar) && !scalar.properties.isWhitespace
    }

    private static func isJoinable(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        index >= 0 && index < scalars.count && isJoinable(scalars[index])
    }

    /// Two consecutive newlines is a paragraph break; more is padding that pushes the rest
    /// of a card out of view.
    private static func collapseBlankLines(_ text: String) -> String {
        var out = ""
        var consecutiveNewlines = 0
        for character in text {
            if character.isNewline {
                consecutiveNewlines += 1
                if consecutiveNewlines <= 2 { out.append("\n") }
            } else {
                consecutiveNewlines = 0
                out.append(character)
            }
        }
        return out
    }
}
