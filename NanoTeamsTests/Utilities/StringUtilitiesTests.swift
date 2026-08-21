import XCTest

@testable import NanoTeams

final class StringUtilitiesTests: XCTestCase {

    func testNormalizedUnique_trimsDedupsAndSorts() {
        let input = ["  Banana ", "apple", "banana", " Cherry ", "apple", ""]
        let result = input.normalizedUnique()

        // Dedup is case-sensitive: "Banana" and "banana" are distinct
        // Sort is case-insensitive
        XCTAssertEqual(result, ["apple", "Banana", "banana", "Cherry"])
    }

    func testNormalizedUnique_emptyAndWhitespaceOnly() {
        let input = ["", "   ", "\n", "\t"]
        let result = input.normalizedUnique()

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - endpointHostLabel

    func testEndpointHostLabel_dropsSchemeAndTrailingSlash() {
        XCTAssertEqual("http://127.0.0.1:1234/".endpointHostLabel, "127.0.0.1:1234")
        XCTAssertEqual("  http://192.168.1.9:11434  ".endpointHostLabel, "192.168.1.9:11434")
    }

    /// RED: drop the port branch → two servers on one host collapse to the same label, which is
    /// exactly the pair the benchmark keeps as separate rows.
    func testEndpointHostLabel_keepsThePort() {
        XCTAssertEqual("http://localhost:1234".endpointHostLabel, "localhost:1234")
        XCTAssertNotEqual(
            "http://localhost:1234".endpointHostLabel, "http://localhost:11434".endpointHostLabel)
    }

    /// A URL with no explicit port has none to show — inventing the scheme's default would state
    /// something the user never typed.
    func testEndpointHostLabel_omitsAPortThatWasNeverGiven() {
        XCTAssertEqual("https://example.com".endpointHostLabel, "example.com")
    }

    /// RED: return a placeholder (or an empty string) on the unparseable branch → the one name that
    /// endpoint has disappears, and a row can no longer say which server produced it.
    func testEndpointHostLabel_unparseableInputSurvivesVerbatim() {
        XCTAssertEqual("not a url".endpointHostLabel, "not a url")
        XCTAssertEqual("  ".endpointHostLabel, "")
    }

    /// The bare `host:port` form users actually paste has no scheme, so `URL` finds no host — and
    /// the fallback must leave it alone rather than mangling it.
    func testEndpointHostLabel_schemelessHostPortIsLeftAlone() {
        XCTAssertEqual("127.0.0.1:1234".endpointHostLabel, "127.0.0.1:1234")
    }
}
