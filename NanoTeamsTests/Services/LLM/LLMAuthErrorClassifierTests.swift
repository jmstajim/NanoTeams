import XCTest

@testable import NanoTeams

final class LLMAuthErrorClassifierTests: XCTestCase {

    func testIsAuthFailure_401_true() {
        XCTAssertTrue(LLMAuthErrorClassifier.isAuthFailure(status: 401))
    }

    func testIsAuthFailure_403_true() {
        XCTAssertTrue(LLMAuthErrorClassifier.isAuthFailure(status: 403))
    }

    func testIsAuthFailure_400_false() {
        XCTAssertFalse(LLMAuthErrorClassifier.isAuthFailure(status: 400))
    }

    func testIsAuthFailure_404_false() {
        XCTAssertFalse(LLMAuthErrorClassifier.isAuthFailure(status: 404))
    }

    func testIsAuthFailure_500_false() {
        XCTAssertFalse(LLMAuthErrorClassifier.isAuthFailure(status: 500))
    }

    func testMessage_401_mentionsTokenAndSettings() {
        let msg = LLMAuthErrorClassifier.message(forStatus: 401, body: nil)
        XCTAssertTrue(msg.contains("Authentication required"))
        XCTAssertTrue(msg.contains("Settings"))
        XCTAssertTrue(msg.contains("401"))
    }

    func testMessage_500_omitsAuthGuidance() {
        let msg = LLMAuthErrorClassifier.message(forStatus: 500, body: nil)
        XCTAssertFalse(msg.contains("Authentication required"))
        XCTAssertTrue(msg.contains("500"))
    }

    func testMessage_500_withBody_includesBody() {
        let msg = LLMAuthErrorClassifier.message(forStatus: 500, body: "Model crashed")
        XCTAssertTrue(msg.contains("Model crashed"))
    }

    func testMessage_500_withWhitespaceBody_omitsBody() {
        let msg = LLMAuthErrorClassifier.message(forStatus: 500, body: "   \n\t  ")
        XCTAssertFalse(msg.contains("\n"), "Whitespace-only body should not bleed into the message")
    }
}
