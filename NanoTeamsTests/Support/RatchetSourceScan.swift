import Foundation

/// The primitives every source-scanning pin in `Ratchet/` repeats — and, since the Benchmark
/// row-interaction work, tests under `NanoTeamsTests/` too.
///
/// The HOME is load-bearing, not tidiness: `NanoTeamsTests/` syncs to the public mirror,
/// `Ratchet/` deliberately does not (the mirror has no such directory and its pbxproj no such
/// group). While this file lived in `Ratchet/`, the first `NanoTeamsTests` consumer compiled
/// here and arrived in the mirror without its definition — five test files red with
/// `Cannot find 'RatchetSourceScan' in scope` (2026-08-22). Anything under `NanoTeamsTests/`
/// may only reference symbols that TRAVEL with it, so the shared scanner lives on the synced
/// side of the boundary; the pins in `Ratchet/` reach it fine (same target, one project).
/// Moving it "back where the pins are" recreates exactly that breakage.
///
/// Extracted when the seventh consumer arrived (`NativeControlStylePinTests`). Until then the
/// comment-stripper existed SIX times, in two spellings that had already drifted apart, and
/// nothing said which was which: quote-aware in `PreviewLocationPinTests` and
/// `OrchestratorTestConstructionPinTests`, first-`//`-wins in `CoverageBaselinePinTests`,
/// `DefaultArgumentIsolationPinTests`, `IndentationHygienePinTests` and
/// `TestLifecycleIsolationPinTests`. Writing a seventh copy is the forgetting these pins exist to
/// prevent (CLAUDE.md #51).
///
/// Both spellings survive here under names that say what they do, rather than one silently
/// replacing the other: the four naive callers count braces and fences on the stripped text, so
/// keeping more of a string literal changes what they measure. That swap needs its own evidence
/// and is not this extraction's business — what the extraction buys is that the difference is
/// now visible in one file instead of invisible across six.
///
/// `repoRoot` was identical in all TWELVE pins here, character for character, and every one now
/// reads it from this single place: a broken ladder is then one red across the directory rather
/// than twelve independent ways to silently scan nothing.
enum RatchetSourceScan {

    /// The repository root, derived from THIS file's location. `#filePath` is evaluated where it
    /// is written (here, `NanoTeamsTests/Support/RatchetSourceScan.swift`), never at the call
    /// site, so the three hops are correct for every consumer regardless of where it sits — and
    /// the hop count is tied to THIS file's depth: moving the file means re-counting it.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // NanoTeamsTests
            .deletingLastPathComponent()   // repo root
    }

    /// Everything before `//`, line by line, so a comment that legitimately NAMES the thing a pin
    /// searches for is not mistaken for the thing itself.
    ///
    /// This is load-bearing in every consumer, and each has a real line that proves it:
    /// `NTMSOrchestrator.swift` carries `// … inside SidebarView.swift #Preview at line 477`
    /// (a cross-reference, not a preview); `GeneralSettingsView.swift` carries
    /// `// .toggleStyle(.switch) here would override that …` (an explanation of what NOT to do);
    /// `TerminalControls.swift` documents the native `.textFieldStyle(.roundedBorder)` its own
    /// chrome replaces. Without stripping, all three read as violations.
    ///
    /// Quotes are respected — a `//` inside a string literal is code, not a comment. The escape
    /// test is the single-character one (`previous != "\"`), which mis-reads a literal ending in
    /// an escaped backslash; no line in this tree does, and the stricter scanner is not worth the
    /// state machine until one does.
    static func strippingLineComments(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .map(strippingLineComment(inLine:))
            .joined(separator: "\n")
    }

    /// The older, cheaper spelling: everything before the FIRST `//`, string literals included.
    ///
    /// Kept because four pins measure structure on the stripped text — brace balance
    /// (`DefaultArgumentIsolationPinTests`), leading whitespace (`IndentationHygienePinTests`),
    /// fence counts, declaration heads — where a `//` inside a literal is vanishingly rare and
    /// truncating early is harmless. Prefer `strippingLineComments(_:)` for anything that
    /// searches for a NEEDLE, since a needle is usually spelled as a string literal and this
    /// spelling would eat it.
    static func strippingLineCommentsNaively(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let range = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }

    private static func strippingLineComment(inLine line: String) -> String {
        var out = ""
        var inString = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" { inString.toggle() }
            if !inString, character == "/", previous == "/" {
                return String(out.dropLast())
            }
            out.append(character)
            previous = character
            index = line.index(after: index)
        }
        return out
    }

    /// Every `.swift` file under `root`, in filesystem order.
    ///
    /// Returns `[]` for a missing root rather than throwing: a pin that walks nothing must fail on
    /// its own anti-vacuity assertion (which names the count it expected), not on an I/O error
    /// whose message says nothing about which invariant stopped being checked.
    static func swiftFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: nil)
        else { return [] }
        var out: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            out.append(url)
        }
        return out
    }

    /// `url` as a repo-relative path, for offender messages a reader can paste into an editor.
    static func relativePath(of url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }

    /// The brace-balanced body that opens after `signature`.
    ///
    /// Anchored on the DECLARATION rather than on something inside it: searching backwards from a
    /// line in the middle finds the nearest `{`, which for anything inside a SwiftUI `Grid` is the
    /// enclosing `GridRow` — a scope that excludes the very rows a table pin exists to read.
    ///
    /// Extracted from the two Benchmark pin suites, where it existed twice byte-for-byte
    /// (CLAUDE.md #51 — the same forgetting `strippingLineComments` was extracted for). Feed it
    /// comment-stripped text: a `{` in prose unbalances the count.
    static func functionBody(after signature: String, in code: String) -> String? {
        guard let anchor = code.range(of: signature) else { return nil }
        guard let open = code.range(of: "{", range: anchor.upperBound..<code.endIndex)
        else { return nil }
        var depth = 1
        var i = open.upperBound
        while i < code.endIndex, depth > 0 {
            if code[i] == "{" { depth += 1 }
            if code[i] == "}" { depth -= 1 }
            i = code.index(after: i)
        }
        return String(code[open.upperBound..<i])
    }

    /// The balanced argument list of every call whose name ends with `marker` (pass the marker
    /// WITH its opening parenthesis, e.g. `"decorate("`). Same provenance and same
    /// stripped-text precondition as `functionBody(after:in:)`.
    static func argumentLists(after marker: String, in code: String) -> [String] {
        var results: [String] = []
        var search = code.startIndex
        while let start = code.range(of: marker, range: search..<code.endIndex) {
            var depth = 1
            var i = start.upperBound
            while i < code.endIndex, depth > 0 {
                if code[i] == "(" { depth += 1 }
                if code[i] == ")" { depth -= 1 }
                i = code.index(after: i)
            }
            if depth == 0 { results.append(String(code[start.upperBound..<i])) }
            search = start.upperBound
        }
        return results
    }

    // MARK: - SwiftUI expression walking

    /// The index just past the delimiter matching the one that opened at `index`.
    /// String literals are skipped whole, so a `(` or `}` inside one does not unbalance the count
    /// — `TextField("Name (optional)", text: $x)` closes at the right paren, not the one in the
    /// placeholder (CLAUDE.md #89: the prose and the literals are where a needle goes wrong).
    ///
    /// Extracted from `InputSurfacePinTests` when `IconButtonHitAreaPinTests` became the second
    /// consumer — the extraction threshold this file's own history documents.
    static func balanced(_ code: String, from index: String.Index,
                         open: Character, close: Character) -> String.Index {
        var depth = 1
        var i = index
        while i < code.endIndex, depth > 0 {
            let c = code[i]
            if c == "\"" {
                i = code.index(after: i)
                while i < code.endIndex {
                    if code[i] == "\"", code[code.index(before: i)] != "\\" { break }
                    i = code.index(after: i)
                }
            } else if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
            }
            if i < code.endIndex { i = code.index(after: i) }
        }
        return i
    }

    /// The trailing modifier chain that belongs to the construct ending at `index` — `.foo`,
    /// `.foo(…)`, `.foo(…) { … }`, across newlines, stopping at the first token that is not a
    /// leading dot.
    ///
    /// The walker's failure modes are asymmetric, and that asymmetry is why every consumer must
    /// assert a COMPLIANT floor beside its offender list: a walker that OVERRUNS its expression
    /// sweeps up the next statement's modifiers, marks every site compliant, and the pin is green
    /// forever over any drift. A walker that terminates early makes everything an offender —
    /// loud, and someone fixes it within the hour.
    static func chain(in code: String, after index: String.Index) -> String {
        var i = index
        while true {
            var j = i
            while j < code.endIndex, code[j].isWhitespace { j = code.index(after: j) }
            guard j < code.endIndex, code[j] == "." else { break }
            var k = code.index(after: j)
            guard k < code.endIndex, code[k].isLetter || code[k] == "_" else { break }
            while k < code.endIndex, code[k].isLetter || code[k].isNumber || code[k] == "_" {
                k = code.index(after: k)
            }
            if k < code.endIndex, code[k] == "(" {
                k = balanced(code, from: code.index(after: k), open: "(", close: ")")
            }
            var m = k
            while m < code.endIndex, code[m] == " " || code[m] == "\t" { m = code.index(after: m) }
            if m < code.endIndex, code[m] == "{" {
                k = balanced(code, from: code.index(after: m), open: "{", close: "}")
            }
            i = k
        }
        return String(code[index..<i])
    }

    /// `true` when `needle` at `index` is a construct rather than a longer identifier ending in
    /// one — `SearchFieldView(` must not read as `Field(`, and `.textField(` is a modifier.
    static func isStandaloneOccurrence(_ code: String, at index: String.Index) -> Bool {
        guard index > code.startIndex else { return true }
        let previous = code[code.index(before: index)]
        return !(previous.isLetter || previous.isNumber || previous == "_" || previous == ".")
    }
}
