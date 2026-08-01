import XCTest
@testable import NanoTeams

/// Differential tests for the byte fast path.
///
/// `localizedCaseInsensitiveContains` is the ORACLE. Every case below asserts agreement with it
/// rather than a hand-written expectation, so the old behavior — not my guess about it — is what
/// the scanner is held to.
///
/// This is the test that licenses `LineScanner.leadByteNeedsICU`. Admitting any scalar to the
/// byte path without re-running it would be a silent correctness change, and the failure mode —
/// a search quietly missing hits — is invisible in production.
final class LineScannerDifferentialTests: XCTestCase {

    /// Runs the same fast/slow decision `SearchExecutor` makes for one line.
    private func byteScanResult(line: String, query: String) -> Bool? {
        let needle = LineScanner.CompiledNeedle(query)
        guard needle.isASCII, !needle.isEmpty, LineScanner.asciiFoldMatchesLocale else { return nil }

        var bytes = Array(line.utf8)
        let authoritative = bytes.allSatisfy { !LineScanner.leadByteNeedsICU($0) }
        guard authoritative else { return nil }

        return bytes.withUnsafeMutableBufferPointer { hb in
            needle.foldedBytes.withUnsafeBufferPointer { nb in
                LineScanner.asciiContains(
                    haystack: hb.baseAddress!, count: hb.count,
                    needle: nb.baseAddress!, needleCount: nb.count)
            }
        }
    }

    private func assertAgreesWithICU(
        line: String, query: String, file: StaticString = #filePath, line srcLine: UInt = #line
    ) {
        guard let byte = byteScanResult(line: line, query: query) else { return }  // deferred to ICU
        let icu = line.localizedCaseInsensitiveContains(query)
        XCTAssertEqual(
            byte, icu,
            "byte scan and ICU disagree for line \(line.debugDescription) / query \(query.debugDescription)",
            file: file, line: srcLine
        )
    }

    // MARK: - Agreement with the oracle

    /// Cyrillic lines route to ICU, and this pins that the result is still correct. Cyrillic is
    /// ~75% of the non-ASCII bytes in this repo, so it is the case a future narrowing attempt
    /// would target first — these pairs are the ones such an attempt must keep green.
    func testCyrillicLines_agreeWithICU() {
        let lines = [
            "Привет мир",
            "let счётчик = 0  // TODO: rename",
            "ПРИВЕТ world",
            "func обработать(_ x: Int) -> Bool",
            "// Ключ: value",
            "Ёжик и Йод",
            "смешанный mixed текст text",
        ]
        let queries = ["world", "func", "TODO", "let", "value", "mixed", "text", "x", "zzz", "="]

        // Non-ASCII lines defer to ICU by design, so these pairs assert the ORACLE stays
        // reachable rather than that the fast path handles them. See
        // `LineScanner.leadByteNeedsICU` for why the safe-script narrowing was reverted.
        for line in lines {
            XCTAssertNil(byteScanResult(line: line, query: "zzz"),
                         "\(line.debugDescription) contains non-ASCII, so ICU decides")
        }

        for line in lines {
            for query in queries {
                assertAgreesWithICU(line: line, query: query)
            }
        }
    }

    func testCJKLines_agreeWithICU() {
        let lines = [
            "日本語テスト test",
            "配置ファイル config.json",
            "한국어 hangul",
            "中文 comment // note",
        ]
        for line in lines {
            for query in ["test", "config", "note", "hangul", "JSON", "zzz"] {
                assertAgreesWithICU(line: line, query: query)
            }
        }
    }

    /// Pure ASCII is the base case — including the punctuation that a naive `| 0x20` fold
    /// corrupts (`[`/`{`, `@`/backtick, `^`/`~`, NUL/space).
    func testASCIILines_decidedByBytes_agreeWithICU() {
        let lines = [
            "let a = arr[0]",
            "dict{key}",
            "@objc func foo()",
            "a ^ b",
            "MiXeD CaSe TeXt",
            "",
            "x",
        ]
        let queries = ["arr[0]", "arr{0}", "dict{key}", "dict[key]", "@objc", "`objc",
                       "a ^ b", "a ~ b", "mixed", "MIXED", "x", "zzz"]
        for line in lines {
            for query in queries {
                assertAgreesWithICU(line: line, query: query)
            }
        }
    }

    // MARK: - Scalars the fast path must REFUSE

    /// Each of these must be routed to ICU. If `leadByteNeedsICU` ever admits them, the byte
    /// scan would answer — and answer wrongly. The assertion is on the ROUTING, because that is
    /// the invariant; the wrongness of the byte answer is shown alongside it.
    func testFoldingSensitiveScripts_areRoutedToICU() {
        let cases: [(line: String, query: String, icu: Bool)] = [
            // ß folds to ss — ICU matches, bytes do not.
            ("straße", "strasse", true),
            // Combining acute makes a distinct grapheme — ICU does NOT match, bytes would.
            ("cafe\u{0301}", "cafe", false),
            // U+212A KELVIN SIGN folds to k.
            ("\u{212A}elvin", "kelvin", true),
            // Precomposed Latin-1.
            ("na\u{00EF}ve", "naive", false),
            // Fullwidth forms do NOT fold — width insensitivity is a separate option ICU is not
            // given here.
            ("\u{FF21}BC", "abc", false),
            // The ﬁ ligature DOES expand to "fi" under full case folding, so this is a
            // false-NEGATIVE for the byte scan. (Verified against ICU — my first guess here was
            // `false`, and this test is what caught it.)
            ("\u{FB01}le", "file", true),
        ]
        for c in cases {
            XCTAssertNil(
                byteScanResult(line: c.line, query: c.query),
                "\(c.line.debugDescription) must defer to ICU, not be decided by bytes"
            )
            XCTAssertEqual(
                c.line.localizedCaseInsensitiveContains(c.query), c.icu,
                "ICU oracle drifted for \(c.line.debugDescription)"
            )
        }
    }

    /// A non-ASCII QUERY always goes to ICU, whatever the line looks like — full case folding
    /// maps U+212A→`k` and U+017F ſ→`s`, so it can legitimately match pure-ASCII content.
    func testNonASCIIQuery_neverTakesTheFastPath() {
        for query in ["\u{212A}elvin", "стр", "日本", "café"] {
            XCTAssertNil(byteScanResult(line: "kelvin plain ascii", query: query))
        }
    }

    /// An empty needle matches nothing under ICU; a byte scan would report offset 0.
    func testEmptyQuery_neverTakesTheFastPath() {
        XCTAssertNil(byteScanResult(line: "anything", query: ""))
        XCTAssertFalse("anything".localizedCaseInsensitiveContains(""))
    }

    // MARK: - Fuzz

    /// Agreement sweep over mixed ASCII / Cyrillic / CJK lines. Deterministic by construction —
    /// index arithmetic, no RNG — so a failure reproduces exactly.
    func testSweep_mixedScriptLines_agreeWithICU() {
        let alphabets = [
            Array("abcXYZ_-.[]{}@^`~/ 09"),
            Array("привет МИР ёжик"),
            Array("日本語한국어"),
        ]
        var lines: [String] = []
        // Deterministic pseudo-random mixing: index arithmetic, no RNG.
        for i in 0..<200 {
            var s = ""
            for j in 0..<24 {
                let alphabet = alphabets[(i + j) % alphabets.count]
                s.append(alphabet[(i &* 7 &+ j &* 13) % alphabet.count])
            }
            lines.append(s)
        }
        let queries = ["abc", "XYZ", "[]", "{}", "@^", "0", " ", "z_", "..", "мир", "ab"]

        for line in lines {
            for query in queries where query.utf8.allSatisfy({ $0 < 0x80 }) {
                assertAgreesWithICU(line: line, query: query)
            }
        }
    }
}
