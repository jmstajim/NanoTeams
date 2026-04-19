import XCTest
@testable import NanoTeams

/// Pinned body-trimming behavior for the release-notes teaser in the
/// Watchtower update card. Silent UI rot in `trimmedBodyLines` would leave
/// the card with a missing or garbled teaser; testing in isolation avoids
/// needing SwiftUI snapshot infrastructure.
final class WatchtowerAppUpdateCardTests: XCTestCase {

    func testTrimmedBodyLines_emptyBody_returnsEmpty() {
        XCTAssertEqual(WatchtowerAppUpdateCard.trimmedBodyLines(""), [])
    }

    func testTrimmedBodyLines_whitespaceOnly_returnsEmpty() {
        XCTAssertEqual(WatchtowerAppUpdateCard.trimmedBodyLines("   \n\t\n  "), [])
    }

    func testTrimmedBodyLines_stripsLeadingTrailingSpaces() {
        let out = WatchtowerAppUpdateCard.trimmedBodyLines("  first  \n\tsecond\t")
        XCTAssertEqual(out, ["first", "second"])
    }

    func testTrimmedBodyLines_handlesCRLF() {
        let out = WatchtowerAppUpdateCard.trimmedBodyLines("a\r\nb\r\nc")
        XCTAssertEqual(out, ["a", "b", "c"])
    }

    func testTrimmedBodyLines_dropsBlankLines() {
        let out = WatchtowerAppUpdateCard.trimmedBodyLines("a\n\n\nb\n\n")
        XCTAssertEqual(out, ["a", "b"])
    }
}
