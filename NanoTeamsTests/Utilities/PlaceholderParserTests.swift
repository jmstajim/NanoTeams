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
}
