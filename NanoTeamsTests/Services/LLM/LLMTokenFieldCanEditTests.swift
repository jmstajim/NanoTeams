import XCTest

@testable import NanoTeams

/// Pins the rule that drives `LLMTokenField.canEdit` — the SwiftUI gate that
/// decides between the editable SecureField and the "Inherits the token…"
/// hint. The rule is the actual user-facing UX boundary, so we pin it as a
/// pure function rather than mounting SwiftUI.
@MainActor
final class LLMTokenFieldCanEditTests: XCTestCase {

    func testCanEdit_isEnabled_andNonEmptyURL_true() {
        XCTAssertTrue(LLMTokenField.canEdit(isEnabled: true, baseURL: "http://localhost:1234"))
    }

    func testCanEdit_isDisabled_alwaysFalse() {
        XCTAssertFalse(LLMTokenField.canEdit(isEnabled: false, baseURL: "http://localhost:1234"))
        XCTAssertFalse(LLMTokenField.canEdit(isEnabled: false, baseURL: ""))
    }

    func testCanEdit_emptyURL_isFalse() {
        XCTAssertFalse(LLMTokenField.canEdit(isEnabled: true, baseURL: ""))
    }

    func testCanEdit_whitespaceOnlyURL_isFalse() {
        // Defense against a user typing a stray space and getting their token
        // saved under " " key.
        XCTAssertFalse(LLMTokenField.canEdit(isEnabled: true, baseURL: " "))
        XCTAssertFalse(LLMTokenField.canEdit(isEnabled: true, baseURL: "   \n\t  "))
    }

    func testCanEdit_urlWithLeadingTrailingWhitespace_isTrue() {
        // Trim is content-only; the URL still exists.
        XCTAssertTrue(LLMTokenField.canEdit(isEnabled: true, baseURL: "  http://x:1  "))
    }
}
