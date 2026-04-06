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
}
