import XCTest

@testable import NanoTeams

/// The one table of how the model reads a result block's fields — shared by the mapper that
/// cleans and the client that scrubs, so the two cannot disagree about a field's final form.
final class MCPResultFieldReadingTests: XCTestCase {

    func testEachFieldTheMapperReadsHasItsReading() {
        XCTAssertEqual(MCPResultFieldReading(field: "text"), .data)
        XCTAssertEqual(MCPResultFieldReading(field: "description"), .prose)
        for field in ["uri", "name", "mimeType", "type"] {
            XCTAssertEqual(MCPResultFieldReading(field: field), .line, field)
        }
        XCTAssertEqual(MCPResultFieldReading(field: "data"), .binary)
        XCTAssertEqual(MCPResultFieldReading(field: "blob"), .binary)
        XCTAssertEqual(MCPResultFieldReading(field: "_meta"), .data, "an unread field is still data")
    }

    func testEachReadingCleansAsItsPassDoes() {
        let raw = "  a\u{200B}b\u{202E}\n\n\n\tc  "
        XCTAssertEqual(MCPResultFieldReading.data.cleaned(raw), MCPTextSanitizer.sanitizeData(raw))
        XCTAssertEqual(MCPResultFieldReading.prose.cleaned(raw), MCPTextSanitizer.sanitize(raw))
        XCTAssertEqual(MCPResultFieldReading.line.cleaned(raw), MCPTextSanitizer.singleLine(raw))
        XCTAssertEqual(MCPResultFieldReading.binary.cleaned(raw), raw)
    }

    func testReadTakesTheFieldsOwnReadingAndOnlyAString() {
        let block: [String: JSONValue] = [
            "uri": .string("https://h/\u{200B}x\n"), "text": .string(" t\u{200B} "), "n": .int(1),
        ]
        XCTAssertEqual(MCPResultFieldReading.read("uri", of: block), "https://h/x")
        XCTAssertTrue(
            MCPResultFieldReading.read("text", of: block)?.unicodeScalars
                .elementsEqual(" t\u{200B} ".unicodeScalars) ?? false,
            "data keeps its spaces and its zero-width space")
        XCTAssertNil(MCPResultFieldReading.read("n", of: block))
        XCTAssertNil(MCPResultFieldReading.read("absent", of: block))
    }
}
