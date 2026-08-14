import AppKit
import XCTest

@testable import NanoTeams

/// `PlaceholderParser.convertTypedPlaceholders(in:placeholders:)` was at 0%
/// coverage — the one direction of the chip round-trip nothing exercised. It
/// backs live typing in `PromptTemplateEditor`: as the user types `{roleName}`,
/// this turns it into a chip in place.
///
/// The load-bearing detail is that it walks matches in REVERSE. Each
/// replacement changes the storage's length, so a forward walk would invalidate
/// every later match range and corrupt the text. A test that only ever supplies
/// one placeholder cannot see that, which is why the multi-match cases below
/// assert the surviving literal text and not just the chip count.
///
/// `PlaceholderParser` is a `nonisolated enum` and `PlaceholderAttachment` is
/// constructible headless (see `PlaceholderAttachmentEqualityTests`), so this
/// class stays nonisolated.
final class PlaceholderParserTypedTests: XCTestCase {

    private typealias Placeholder = (key: String, label: String, category: String)

    private let known: [Placeholder] = [
        (key: "roleName", label: "Role Name", category: "role"),
        (key: "teamName", label: "Team Name", category: "team"),
        (key: "toolList", label: "Tool List", category: "tools"),
    ]

    /// The character `NSAttributedString(attachment:)` occupies in the backing
    /// string. Counting these is how we count chips.
    private static let attachmentChar = "\u{FFFC}"

    private func storage(_ s: String) -> NSTextStorage {
        NSTextStorage(string: s)
    }

    private func chipCount(_ storage: NSTextStorage) -> Int {
        storage.string.filter { String($0) == Self.attachmentChar }.count
    }

    private func attachments(_ storage: NSTextStorage) -> [PlaceholderAttachment] {
        var found: [PlaceholderAttachment] = []
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let a = value as? PlaceholderAttachment { found.append(a) }
        }
        return found
    }

    // MARK: - No-op arms

    func testConvert_emptyStorage_reportsNoChange() {
        let s = storage("")
        XCTAssertFalse(PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known))
        XCTAssertEqual(s.string, "")
    }

    func testConvert_plainTextWithNoBraces_reportsNoChange() {
        let s = storage("You are a helpful assistant.")
        XCTAssertFalse(PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known))
        XCTAssertEqual(s.string, "You are a helpful assistant.")
    }

    func testConvert_unknownKey_isLeftAsLiteralText() {
        // An unrecognised `{key}` must survive as text: the user may be part-way
        // through typing, and silently deleting it would eat their keystrokes.
        let s = storage("Hello {nobodyKnowsMe} there")
        XCTAssertFalse(PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known))
        XCTAssertEqual(s.string, "Hello {nobodyKnowsMe} there")
        XCTAssertEqual(chipCount(s), 0)
    }

    func testConvert_emptyPlaceholderList_convertsNothing() {
        let s = storage("Hi {roleName}")
        XCTAssertFalse(PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: []))
        XCTAssertEqual(s.string, "Hi {roleName}")
    }

    /// The pattern is `\{([a-zA-Z]+)\}` — letters only. Anything else is text.
    func testConvert_nonAlphabeticKeys_doNotMatchThePattern() {
        for text in ["{role_name}", "{role1}", "{}", "{ roleName }", "{roleName", "roleName}"] {
            let s = storage(text)
            XCTAssertFalse(
                PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known),
                "\(text) must not be treated as a placeholder")
            XCTAssertEqual(s.string, text)
        }
    }

    // MARK: - Conversion

    func testConvert_singleKnownKey_becomesOneChipCarryingItsMetadata() throws {
        let s = storage("Hi {roleName}!")
        XCTAssertTrue(PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known))

        XCTAssertEqual(chipCount(s), 1)
        let chip = try XCTUnwrap(attachments(s).first)
        XCTAssertEqual(chip.key, "roleName")
        XCTAssertEqual(chip.label, "Role Name")
        XCTAssertEqual(chip.category, "role")

        // The braces are gone and the surrounding text is intact.
        XCTAssertEqual(s.string.replacingOccurrences(of: Self.attachmentChar, with: "|"), "Hi |!")
    }

    /// The reverse walk exists for exactly this case. Replacing forward would
    /// shift every later match and splice a chip into the middle of the text.
    func testConvert_threeKeys_allBecomeChipsAndTheLiteralTextSurvives() {
        let s = storage("A {roleName} B {teamName} C {toolList} D")
        XCTAssertTrue(PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known))

        XCTAssertEqual(chipCount(s), 3)
        XCTAssertEqual(
            s.string.replacingOccurrences(of: Self.attachmentChar, with: "|"),
            "A | B | C | D",
            "a forward walk corrupts this into misplaced chips and leftover braces")
        XCTAssertEqual(attachments(s).map(\.key), ["roleName", "teamName", "toolList"],
                       "document order must be preserved despite the reverse walk")
    }

    func testConvert_adjacentKeysWithNoSeparator_bothConvert() {
        let s = storage("{roleName}{teamName}")
        XCTAssertTrue(PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known))
        XCTAssertEqual(chipCount(s), 2)
        XCTAssertEqual(s.string.count, 2, "nothing but the two chips should remain")
        XCTAssertEqual(attachments(s).map(\.key), ["roleName", "teamName"])
    }

    func testConvert_repeatedKey_convertsEveryOccurrence() {
        let s = storage("{roleName} and {roleName}")
        XCTAssertTrue(PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known))
        XCTAssertEqual(chipCount(s), 2)
        XCTAssertEqual(
            s.string.replacingOccurrences(of: Self.attachmentChar, with: "|"), "| and |")
    }

    /// A known key next to an unknown one is the realistic mid-typing state.
    /// The unknown must survive verbatim while the known converts.
    func testConvert_mixedKnownAndUnknown_convertsOnlyTheKnownOne() {
        let s = storage("{unknownOne} {roleName} {unknownTwo}")
        XCTAssertTrue(PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known))
        XCTAssertEqual(chipCount(s), 1)
        XCTAssertEqual(
            s.string.replacingOccurrences(of: Self.attachmentChar, with: "|"),
            "{unknownOne} | {unknownTwo}")
    }

    func testConvert_isIdempotent_secondPassFindsNothingLeftToDo() {
        let s = storage("Hi {roleName}")
        XCTAssertTrue(PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known))
        XCTAssertFalse(
            PlaceholderParser.convertTypedPlaceholders(in: s, placeholders: known),
            "a converted chip carries no braces, so re-running must report no change")
        XCTAssertEqual(chipCount(s), 1)
    }

    /// Round-trip against the other direction of the pair: rendering a template
    /// to chips and typing the same template must agree on chip count and keys.
    func testConvert_agreesWithAttributedStringRendering() {
        let template = "A {roleName} B {teamName}"
        let rendered = PlaceholderParser.attributedString(from: template, placeholders: known)

        let typed = storage(template)
        PlaceholderParser.convertTypedPlaceholders(in: typed, placeholders: known)

        XCTAssertEqual(typed.string, rendered.string,
                       "the typed path and the rendered path must produce the same backing string")
    }
}
