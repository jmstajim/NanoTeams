import XCTest
@testable import NanoTeams

final class SkillMetadataExtractorTests: XCTestCase {

    // MARK: - Frontmatter

    func testFrontmatter_plainScalar() {
        let text = "---\nname: code-review\ndescription: Reviews code\n---\nbody"
        let fields = SkillMetadataExtractor.frontmatterFields(["name", "description"], in: text)
        XCTAssertEqual(fields["name"], "code-review")
        XCTAssertEqual(fields["description"], "Reviews code")
    }

    func testFrontmatter_doubleQuoted() {
        let text = "---\ndescription: \"Reviews code carefully\"\n---\nbody"
        XCTAssertEqual(SkillMetadataExtractor.frontmatterFields(["description"], in: text)["description"], "Reviews code carefully")
    }

    func testFrontmatter_singleQuoted() {
        let text = "---\ndescription: 'Reviews code'\n---\nbody"
        XCTAssertEqual(SkillMetadataExtractor.frontmatterFields(["description"], in: text)["description"], "Reviews code")
    }

    func testFrontmatter_none_returnsEmpty() {
        let text = "# Just a heading\nno frontmatter here"
        XCTAssertTrue(SkillMetadataExtractor.frontmatterFields(["name"], in: text).isEmpty)
    }

    func testFrontmatter_unterminated_returnsEmpty() {
        let text = "---\nname: x\ndescription: y\n(no closing delimiter)"
        XCTAssertTrue(SkillMetadataExtractor.frontmatterFields(["name", "description"], in: text).isEmpty)
    }

    func testFrontmatter_valueContainingColon() {
        let text = "---\ndescription: \"use foo: bar syntax\"\n---\nbody"
        XCTAssertEqual(SkillMetadataExtractor.frontmatterFields(["description"], in: text)["description"], "use foo: bar syntax")
    }

    func testFrontmatter_CRLF() {
        let text = "---\r\nname: winapp\r\ndescription: For Windows\r\n---\r\nbody"
        let fields = SkillMetadataExtractor.frontmatterFields(["name", "description"], in: text)
        XCTAssertEqual(fields["name"], "winapp")
        XCTAssertEqual(fields["description"], "For Windows")
    }

    func testFrontmatter_leadingBOM() {
        let text = "\u{FEFF}---\nname: withbom\n---\nbody"
        XCTAssertEqual(SkillMetadataExtractor.frontmatterFields(["name"], in: text)["name"], "withbom")
    }

    func testFrontmatter_blockNotAtLineOne_rejected() {
        let text = "some preamble\n---\nname: x\n---\n"
        XCTAssertTrue(SkillMetadataExtractor.frontmatterFields(["name"], in: text).isEmpty)
    }

    func testFrontmatter_blockScalarValue_ignored() {
        let text = "---\ndescription: |\n  multi\n  line\n---\nbody"
        XCTAssertNil(SkillMetadataExtractor.frontmatterFields(["description"], in: text)["description"])
    }

    func testFrontmatter_indentedKey_ignored() {
        let text = "---\nmeta:\n  description: nested\n---\nbody"
        XCTAssertNil(SkillMetadataExtractor.frontmatterFields(["description"], in: text)["description"])
    }

    func testFrontmatter_emptyValue_omitted() {
        let text = "---\nname: x\ndescription:\n---\nbody"
        let fields = SkillMetadataExtractor.frontmatterFields(["name", "description"], in: text)
        XCTAssertEqual(fields["name"], "x")
        XCTAssertNil(fields["description"])
    }

    // MARK: - TOML

    func testToml_doubleQuoted() {
        let text = "description = \"Run the thing\"\nprompt = \"do X\"\n"
        XCTAssertEqual(SkillMetadataExtractor.tomlDescription(in: text), "Run the thing")
    }

    func testToml_tripleQuoted_firstLine() {
        let text = "description = \"\"\"First line\nSecond line\"\"\"\n"
        XCTAssertEqual(SkillMetadataExtractor.tomlDescription(in: text), "First line")
    }

    func testToml_tripleQuoted_singleLine() {
        let text = "description = \"\"\"all on one line\"\"\"\n"
        XCTAssertEqual(SkillMetadataExtractor.tomlDescription(in: text), "all on one line")
    }

    func testToml_missing_returnsNil() {
        let text = "prompt = \"only a prompt\"\n"
        XCTAssertNil(SkillMetadataExtractor.tomlDescription(in: text))
    }

    func testToml_commented_ignored() {
        let text = "# description = \"a comment\"\nprompt = \"x\"\n"
        XCTAssertNil(SkillMetadataExtractor.tomlDescription(in: text))
    }

    func testToml_insideTable_ignored() {
        let text = "[meta]\ndescription = \"in a table\"\n"
        XCTAssertNil(SkillMetadataExtractor.tomlDescription(in: text))
    }

    func testToml_noSpacesAroundEquals() {
        let text = "description=\"tight\"\n"
        XCTAssertEqual(SkillMetadataExtractor.tomlDescription(in: text), "tight")
    }

    func testToml_indentedKey_stillRead() {
        let text = "  description = \"indented\"\n"
        XCTAssertEqual(SkillMetadataExtractor.tomlDescription(in: text), "indented")
    }

    func testFrontmatter_commentLineWithColon_ignored() {
        let text = "---\n# note: this is a comment\nname: real\n---\nbody"
        let fields = SkillMetadataExtractor.frontmatterFields(["name", "note"], in: text)
        XCTAssertEqual(fields["name"], "real")
        XCTAssertNil(fields["note"])
    }

    func testFrontmatter_onlyRequestedKeysReturned() {
        let text = "---\nname: x\ndescription: y\nversion: 3\n---\nbody"
        let fields = SkillMetadataExtractor.frontmatterFields(["name"], in: text)
        XCTAssertEqual(fields, ["name": "x"])
    }

    func testFrontmatter_emptyDocument_returnsEmpty() {
        XCTAssertTrue(SkillMetadataExtractor.frontmatterFields(["name"], in: "").isEmpty)
    }
}
