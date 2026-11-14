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

    /// Line comments removed AND every string literal's CONTENTS blanked, keeping the quotes.
    ///
    /// For needles that would otherwise read a fixture as code. Measured: a preview in
    /// `TeamBoardView+Previews` passes fake file content to a tool-summary fixture, and that
    /// content spells `static let primary: Color = .blue` — which `DesignTokenPinTests`' value
    /// needle read as a live violation. A pin that reports a string literal teaches its readers
    /// to add opt-out markers to prose, which is how a gate stops meaning anything.
    ///
    /// Quotes are kept so column-ish structure survives; only what is between them goes. Same
    /// single-character escape test as `strippingLineComments`, and the same reason.
    static func strippingStringLiterals(_ source: String) -> String {
        strippingLineComments(source)
            .components(separatedBy: "\n")
            .map { line -> String in
                var out = ""
                var inString = false
                var previous: Character?
                for character in line {
                    if character == "\"", previous != "\\" {
                        inString.toggle()
                        out.append(character)
                    } else if !inString {
                        out.append(character)
                    }
                    previous = character
                }
                return out
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

// MARK: - One read of the tree per process

/// The tree as the pins read it, read ONCE per test process, plus the memo a pin class keeps its
/// own scan in.
///
/// Every source-scan pin used to walk and read its roots in every test that needed them — the
/// rule, its anti-vacuity twin and the reachability check each paid the same read, and most the
/// same scan, again — and a dozen pins read the same `NanoTeams/` tree on their own. Measured
/// 2026-10-28, each class alone: `InputSurfacePinTests` ran its one scan five times (3.5 s),
/// `NativeControlStylePinTests` three times (3.5 s), `DesignTokenPinTests` twice (30.7 s, most of
/// it in the per-line walk the pin now gates).
///
/// The cache is sound because nothing under a scanned root changes while the tests run — a test
/// that wrote a `.swift` file into the tree would already make every pin that scans it flaky. It
/// changes no answer: `sources(under:)` walks in `swiftFiles(under:)` order and keeps each read's
/// outcome — the text, or the error `String(contentsOf:encoding:)` threw — so a caller that
/// `try`s or skips decides exactly what it decided before.
extension RatchetSourceScan {

    /// One `.swift` file: where it is, its repo-relative path, and what reading it gave.
    final class SourceFile: @unchecked Sendable {
        let url: URL
        let relativePath: String
        private let read: Result<String, any Error>
        private let lock = NSLock()
        private var stripped: Result<String, any Error>?

        init(url: URL) {
            self.url = url
            relativePath = RatchetSourceScan.relativePath(of: url)
            read = Result { try String(contentsOf: url, encoding: .utf8) }
        }

        /// The file's text, or the error its read threw — the same one, every time.
        func text() throws -> String { try read.get() }

        /// `strippingLineComments(text())`, computed on first use and kept: most pins strip the
        /// same files the same way.
        func commentStrippedText() throws -> String {
            lock.lock()
            defer { lock.unlock() }
            if let stripped { return try stripped.get() }
            let result = read.map(RatchetSourceScan.strippingLineComments)
            stripped = result
            return try result.get()
        }
    }

    private static let sourcesLock = NSLock()
    nonisolated(unsafe) private static var sourcesByRoot: [String: [SourceFile]] = [:]

    /// Every `.swift` file under `root` with its text, in `swiftFiles(under:)` order — read the
    /// first time any pin in this process asks for `root`, and handed out from memory after that.
    /// A missing root is `[]`, as for `swiftFiles(under:)`, and is not remembered: an empty answer
    /// must stay as cheap to re-derive as it is to trust.
    static func sources(under root: URL) -> [SourceFile] {
        let key = root.standardizedFileURL.path
        sourcesLock.lock()
        defer { sourcesLock.unlock() }
        if let cached = sourcesByRoot[key] { return cached }
        let files = swiftFiles(under: root).map(SourceFile.init(url:))
        if !files.isEmpty { sourcesByRoot[key] = files }
        return files
    }

    /// `(relativePath, text)` for every `.swift` file under `roots`, sorted by path, read through
    /// `sources(under:)` — the walk the target-wide pins (indentation, test lifecycle, default
    /// arguments) each spelled as a private `swiftFiles()` plus a `String(contentsOf:)` per test.
    /// The first unreadable file throws its read's error, as their `try` did.
    static func sortedSources(under roots: [URL]) throws -> [(relativePath: String, text: String)] {
        try roots.flatMap { sources(under: $0) }
            .sorted { $0.relativePath < $1.relativePath }
            .map { ($0.relativePath, try $0.text()) }
    }

    /// Whether `needle`'s bytes occur in `text`'s UTF-8: a plain byte search (`memmem`) — no
    /// Character walk, no tokenizing. Two pins lean on it, for two different reasons:
    /// `DesignTokenPinTests` GATES its Character walk with it (a byte match is a necessary
    /// condition there, never a sufficient one), and `NewFileHasATestPinTests` uses it as the
    /// raw-scan ORACLE its identifier index is checked against. `memmem` because both run it
    /// thousands of times, in a test build no optimiser touches.
    static func utf8(_ text: String, contains needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        var text = text
        return text.withUTF8 { haystack in
            needle.withUnsafeBytes { little in
                memmem(haystack.baseAddress, haystack.count, little.baseAddress, little.count) != nil
            }
        }
    }

    /// A value a pin class computes once per process — the scan its rule, its anti-vacuity twin
    /// and its reachability check all read. A thrown error is kept too, so every test of the class
    /// fails the way the first one did instead of re-running a scan that cannot succeed.
    final class Memo<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Value, any Error>?

        init() {}

        func value(_ compute: () throws -> Value) throws -> Value {
            lock.lock()
            defer { lock.unlock() }
            if let stored { return try stored.get() }
            let result = Result(catching: compute)
            stored = result
            return try result.get()
        }
    }
}
