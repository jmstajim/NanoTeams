import XCTest

@testable import NanoTeams

/// `task_changes` shows a reviewer what hides in a diff instead of removing it (S4,
/// 2026-11-12): every character `isHidden` names — and every other default-ignorable one —
/// becomes a visible `<U+XXXX>` tag, except what legitimate text carries: one variation
/// selector on a visible character, a joiner between two visible ones, a BOM opening a file.
final class MCPTextSanitizerDiffTests: XCTestCase {

    private func diff(_ text: String) -> MCPTextSanitizer.DiffSanitizationResult {
        MCPTextSanitizer.sanitizeDiff(text)
    }

    // MARK: - Variation selectors

    func testSelectorRun_tagsEverySelectorAfterTheFirst() {
        let result = diff("+// a\u{E0100}\u{E0101}\u{E0102} note")
        XCTAssertEqual(result.text, "+// a\u{E0100}<U+E0101><U+E0102> note")
        XCTAssertTrue(result.hadStripped)
    }

    func testSelectorWithoutAVisibleBase_isTagged() {
        let result = diff("+\u{FE0F}x \u{E0100}y")
        XCTAssertEqual(result.text, "+<U+FE0F>x <U+E0100>y")
        XCTAssertTrue(result.hadStripped)
    }

    func testEmojiPresentationSelector_andIdeographicVariation_stayUntagged() {
        for text in ["+let heart = \"❤\u{FE0F}\"", "+葛\u{E0100}城"] {
            let result = diff(text)
            XCTAssertEqual(result.text, text)
            XCTAssertFalse(result.hadStripped, text)
        }
    }

    // MARK: - Other invisible characters

    func testOtherInvisibleFormatCharacters_areTagged() {
        let cases: [(String, String)] = [
            ("+pass\u{00AD}word", "+pass<U+00AD>word"),
            ("+a\u{034F}b", "+a<U+034F>b"),
            ("+a\u{180E}b", "+a<U+180E>b"),
            ("+a\u{FFF9}b\u{FFFB}", "+a<U+FFF9>b<U+FFFB>"),
            ("+a\u{2028}b", "+a<U+2028>b"),
            ("+a\u{200E}b", "+a<U+200E>b"),
            ("+a\u{3164}b", "+a<U+3164>b"),
            ("+a\u{E0041}b", "+a<U+E0041>b"),
        ]
        for (input, expected) in cases {
            let result = diff(input)
            XCTAssertEqual(result.text, expected)
            XCTAssertTrue(result.hadStripped, input)
        }
    }

    func testJoinerBetweenTwoVisibleCharacters_staysUntagged() {
        for text in ["+let dev = \"👨\u{200D}💻\"", "+نام\u{200C}خانوادگی"] {
            let result = diff(text)
            XCTAssertEqual(result.text, text)
            XCTAssertFalse(result.hadStripped, text)
        }
    }

    func testJoinerThatJoinsNothing_isTagged() {
        XCTAssertEqual(diff("+\u{200D}a").text, "+<U+200D>a")
        XCTAssertEqual(diff("+a\u{200D}\u{200D}b").text, "+a<U+200D><U+200D>b")
        XCTAssertEqual(diff("+a\u{200D}").text, "+a<U+200D>")
        XCTAssertEqual(diff("+a \u{200C}b").text, "+a <U+200C>b")
    }

    // MARK: - Byte order mark

    func testBOMOpeningTheFile_staysUntagged() {
        let added = "@@ -0,0 +1,2 @@\n+\u{FEFF}first\n+second\n"
        XCTAssertEqual(diff(added).text, added)
        XCTAssertFalse(diff(added).hadStripped)

        let changed = "@@ -1,2 +1,2 @@\n-\u{FEFF}old\n+\u{FEFF}new\n context\n"
        XCTAssertEqual(diff(changed).text, changed)
        XCTAssertFalse(diff(changed).hadStripped)

        // A file whose first line did not change: the BOM rides a CONTEXT line, which opens
        // both sides at once.
        let unchangedFirstLine = "@@ -1,2 +1,2 @@\n \u{FEFF}first\n-old\n+new\n"
        XCTAssertEqual(diff(unchangedFirstLine).text, unchangedFirstLine)
        XCTAssertFalse(diff(unchangedFirstLine).hadStripped)
        // ...and only when it opens both: a hunk whose new side starts lower is no file's start.
        XCTAssertEqual(
            diff("@@ -1,2 +2,2 @@\n \u{FEFF}first\n-old\n+new\n").text,
            "@@ -1,2 +2,2 @@\n <U+FEFF>first\n-old\n+new\n")
    }

    func testBOMAnywhereElse_isTagged() {
        XCTAssertEqual(
            diff("@@ -0,0 +1,2 @@\n+first\n+\u{FEFF}second\n").text,
            "@@ -0,0 +1,2 @@\n+first\n+<U+FEFF>second\n")
        XCTAssertEqual(diff("@@ -3,1 +3,1 @@\n+\u{FEFF}x\n").text, "@@ -3,1 +3,1 @@\n+<U+FEFF>x\n")
        XCTAssertEqual(diff("+a\u{FEFF}b").text, "+a<U+FEFF>b")
    }

    // MARK: - Layout

    func testLineEndings_crlfKept_loneCarriageReturnTagged() {
        XCTAssertEqual(diff("+abc\r\n+def\r\n").text, "+abc\r\n+def\r\n")
        XCTAssertFalse(diff("+abc\r\n").hadStripped)
        XCTAssertEqual(diff("+abc\rxyz\n").text, "+abc<U+000D>xyz\n")
        XCTAssertTrue(diff("+abc\rxyz\n").hadStripped)
        XCTAssertEqual(diff("+\tindented\n").text, "+\tindented\n")
    }

    func testEscapeAndBidi_stillTagged() {
        let result = diff("+x\u{1B}[2J\u{202E}y")
        XCTAssertEqual(result.text, "+x<ESC>[2J<U+202E>y")
        XCTAssertTrue(result.hadStripped)
    }

    func testCleanDiff_isUnchanged() {
        let text = "diff --git a/Ж.swift b/Ж.swift\n@@ -1 +1 @@\n-let a = 1\n+let a = 2 // café 🎨\n"
        XCTAssertEqual(diff(text).text, text)
        XCTAssertFalse(diff(text).hadStripped)
        XCTAssertEqual(diff("").text, "")
    }

    // MARK: - Names

    func testTaggedName_spellsOutEveryHiddenCharacterAndLineBreak() {
        let result = MCPTextSanitizer.taggedName("src/a\u{202E}b\n\t.txt")
        XCTAssertEqual(result.text, "src/a<U+202E>b<U+000A><U+0009>.txt")
        XCTAssertTrue(result.hadStripped)

        let clean = MCPTextSanitizer.taggedName("src/Проект/emoji 🎨.swift")
        XCTAssertEqual(clean.text, "src/Проект/emoji 🎨.swift")
        XCTAssertFalse(clean.hadStripped)
    }
}
