import XCTest
@testable import NanoTeams

final class PlaceholderParserTests: XCTestCase {

    private let samplePlaceholders: [(key: String, label: String, category: String)] = [
        (key: "roleName", label: "Role Name", category: "role"),
        (key: "teamRoles", label: "Team Roles", category: "team"),
        (key: "toolList", label: "Tool List", category: "tools"),
    ]

    // MARK: - attributedString

    func testAttributedString_knownPlaceholder_createsAttachment() {
        let result = PlaceholderParser.attributedString(
            from: "Hello {roleName}!",
            placeholders: samplePlaceholders
        )
        // The result should contain an attachment for the placeholder
        var foundAttachment = false
        result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { attrs, _, _ in
            if attrs[.attachment] is PlaceholderAttachment {
                foundAttachment = true
            }
        }
        XCTAssertTrue(foundAttachment, "Known placeholder should create a PlaceholderAttachment")
    }

    func testAttributedString_unknownPlaceholder_leftAsText() {
        let result = PlaceholderParser.attributedString(
            from: "Hello {unknownKey}!",
            placeholders: samplePlaceholders
        )
        let plainText = result.string
        XCTAssertTrue(plainText.contains("{unknownKey}"))
    }

    func testAttributedString_multiplePlaceholders() {
        let result = PlaceholderParser.attributedString(
            from: "{roleName} has {toolList}",
            placeholders: samplePlaceholders
        )
        var attachmentCount = 0
        result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { attrs, _, _ in
            if attrs[.attachment] is PlaceholderAttachment {
                attachmentCount += 1
            }
        }
        XCTAssertEqual(attachmentCount, 2)
    }

    func testAttributedString_noPlaceholders() {
        let result = PlaceholderParser.attributedString(
            from: "Plain text only",
            placeholders: samplePlaceholders
        )
        XCTAssertEqual(result.string, "Plain text only")
    }

    func testAttributedString_emptyString() {
        let result = PlaceholderParser.attributedString(from: "", placeholders: samplePlaceholders)
        XCTAssertEqual(result.length, 0)
    }

    // MARK: - plainString roundtrip

    func testPlainString_roundtrip_preservesTemplate() {
        let original = "You are {roleName} with access to {toolList}."
        let attributed = PlaceholderParser.attributedString(from: original, placeholders: samplePlaceholders)
        let restored = PlaceholderParser.plainString(from: attributed)
        XCTAssertEqual(restored, original)
    }

    func testPlainString_noAttachments() {
        let attributed = NSAttributedString(string: "No placeholders here")
        let result = PlaceholderParser.plainString(from: attributed)
        XCTAssertEqual(result, "No placeholders here")
    }

    // MARK: - parseChip

    func testParseChip_knownPlaceholder_returnsAttachment() {
        let result = PlaceholderParser.parseChip(from: "{roleName}", placeholders: samplePlaceholders)
        XCTAssertNotNil(result)
    }

    func testParseChip_unknownPlaceholder_returnsNil() {
        let result = PlaceholderParser.parseChip(from: "{unknown}", placeholders: samplePlaceholders)
        XCTAssertNil(result)
    }

    func testParseChip_invalidFormat_returnsNil() {
        XCTAssertNil(PlaceholderParser.parseChip(from: "roleName", placeholders: samplePlaceholders))
        XCTAssertNil(PlaceholderParser.parseChip(from: "{}", placeholders: samplePlaceholders))
        XCTAssertNil(PlaceholderParser.parseChip(from: "", placeholders: samplePlaceholders))
    }

    func testParseChip_textWithExtraContent_matchesFirstOccurrence() {
        // parseChip uses firstMatch, so "{roleName} extra" should match {roleName}
        let result = PlaceholderParser.parseChip(from: "{roleName} extra", placeholders: samplePlaceholders)
        XCTAssertNotNil(result, "Should match the first placeholder in the text")
    }

    // MARK: - attributedString(...:resolvedValues:)

    func testResolvedValues_withValue_rendersColoredTextNoChip() {
        // value present + known key → colored text, NO chip attachment.
        let result = PlaceholderParser.attributedString(
            from: "Role: {roleName}",
            placeholders: samplePlaceholders,
            resolvedValues: ["roleName": "Coding Agent"]
        )
        XCTAssertEqual(result.string, "Role: Coding Agent")
        XCTAssertFalse(containsChip(result), "Resolved value must not duplicate as a chip")
        XCTAssertTrue(hasCategoryForeground(result, value: "Coding Agent", category: "role"),
                      "Resolved value must carry the category foreground color")
    }

    func testResolvedValues_withoutValue_rendersChipAlone() {
        // value missing + known key → chip alone, no value text.
        let result = PlaceholderParser.attributedString(
            from: "Role: {roleName} ok",
            placeholders: samplePlaceholders,
            resolvedValues: [:]
        )
        XCTAssertTrue(containsChip(result), "Missing value with known key must render a chip")
        XCTAssertEqual(PlaceholderParser.plainString(from: result), "Role: {roleName} ok",
                       "Chip plainString reconstruction must match the original token")
    }

    func testResolvedValues_unknownKey_noDefinition_rendersLiteralBraces() {
        // No value AND no definition → literal `{key}` plain text — the "something's wrong" signal.
        let result = PlaceholderParser.attributedString(
            from: "Hello {mystery}!",
            placeholders: samplePlaceholders,
            resolvedValues: [:]
        )
        XCTAssertEqual(result.string, "Hello {mystery}!", "Unknown key stays literal")
        XCTAssertFalse(containsChip(result), "Unknown key must not render a chip")
    }

    func testResolvedValues_valueWithoutDefinition_rendersPlainText() {
        // Orphan value (key in resolvedValues but not in placeholders) — render as plain text.
        let result = PlaceholderParser.attributedString(
            from: "Hello {orphan}!",
            placeholders: samplePlaceholders,
            resolvedValues: ["orphan": "World"]
        )
        XCTAssertEqual(result.string, "Hello World!")
        XCTAssertFalse(containsChip(result))
    }

    func testResolvedValues_emptyTemplate_returnsEmptyAttributedString() {
        let result = PlaceholderParser.attributedString(
            from: "",
            placeholders: samplePlaceholders,
            resolvedValues: ["roleName": "X"]
        )
        XCTAssertEqual(result.length, 0)
    }

    func testResolvedValues_multiplePlaceholders_mixedResolutionPaths() {
        // {roleName} resolved → colored text; {toolList} unresolved → chip; {orphan} unknown literal.
        let result = PlaceholderParser.attributedString(
            from: "{roleName} uses {toolList} and {orphan}.",
            placeholders: samplePlaceholders,
            resolvedValues: ["roleName": "Coding Agent"]
        )
        let plain = PlaceholderParser.plainString(from: result)
        XCTAssertEqual(plain, "Coding Agent uses {toolList} and {orphan}.")
        XCTAssertEqual(chipCount(result), 1, "Only the unresolved-with-definition key gets a chip")
    }

    func testResolvedValues_adjacentPlaceholders_renderInOrder() {
        // Edge case: zero-gap adjacency like `{a}{b}`. The regex-driven
        // while loop re-runs on the suffix after each match — confirm no
        // spacing or ordering is dropped.
        let result = PlaceholderParser.attributedString(
            from: "{roleName}{toolList}",
            placeholders: samplePlaceholders,
            resolvedValues: ["roleName": "X", "toolList": "Y"]
        )
        XCTAssertEqual(result.string, "XY",
            "Adjacent placeholders must concatenate in order with no inserted whitespace")
    }

    func testResolvedValues_emptyStringValue_rendersEmptyColoredRunNotChip() {
        // `.some("")` lands on the value+definition branch — empty string
        // is a real value, not a missing one. Renders empty colored run
        // (no chip). Without this pin a future "fix" that omits empty
        // strings would silently start showing chips for legitimately
        // empty fields like `expectedArtifacts` on advisory roles.
        let result = PlaceholderParser.attributedString(
            from: "Artifacts: {toolList}",
            placeholders: samplePlaceholders,
            resolvedValues: ["toolList": ""]
        )
        XCTAssertEqual(result.string, "Artifacts: ")
        XCTAssertEqual(chipCount(result), 0,
            "Empty-string value must NOT trigger the chip fallback — that's reserved for omitted keys")
    }

    // MARK: - Helpers

    private func containsChip(_ attributed: NSAttributedString) -> Bool {
        chipCount(attributed) > 0
    }

    private func chipCount(_ attributed: NSAttributedString) -> Int {
        var count = 0
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, _, _ in
            if attrs[.attachment] is PlaceholderAttachment {
                count += 1
            }
        }
        return count
    }

    /// Verifies the substring `value` in `attributed` carries an
    /// `.foregroundColor` whose `usingColorSpace(.deviceRGB)` representation
    /// matches `PlaceholderAttachment.color(for: category)` in the same
    /// appearance — comparing the dynamic-color CGColor identity directly is
    /// unreliable because `color(for:)` returns a fresh dynamic NSColor each
    /// call.
    private func hasCategoryForeground(_ attributed: NSAttributedString, value: String, category: String) -> Bool {
        let ns = attributed.string as NSString
        let range = ns.range(of: value)
        guard range.location != NSNotFound else { return false }
        let expected = PlaceholderAttachment.color(for: category).usingColorSpace(.deviceRGB)
        var matched = false
        attributed.enumerateAttribute(.foregroundColor, in: range, options: []) { value, _, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.deviceRGB) else { return }
            if let expected,
               abs(color.redComponent - expected.redComponent) < 0.001,
               abs(color.greenComponent - expected.greenComponent) < 0.001,
               abs(color.blueComponent - expected.blueComponent) < 0.001 {
                matched = true
            }
        }
        return matched
    }
}
