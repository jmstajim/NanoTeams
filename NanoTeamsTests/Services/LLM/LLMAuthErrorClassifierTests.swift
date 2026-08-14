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

    // MARK: - The model-facing renderer

    /// Two renderers, one owner. `message(forStatus:body:)` is read by humans (settings cards,
    /// the error banner) and correctly names the Settings pane; `modelFacingMessage` is
    /// appended to the step conversation as a `.system` turn, where a pane the model cannot
    /// open is pure noise. Keeping them on one type is what stops them drifting.
    func testModelFacingMessage_401_namesTheBlockerAndWhoCanFixItNotThePane() {
        let msg = LLMAuthErrorClassifier.modelFacingMessage(forStatus: 401)
        XCTAssertTrue(msg.contains("401"))
        XCTAssertTrue(msg.contains("credentials"))
        XCTAssertTrue(msg.contains("supervisor"), "must name a recourse the model can act on")
        XCTAssertTrue(msg.contains("retry"), "must say retrying won't help")
        XCTAssertFalse(msg.contains("Settings"), "the model cannot open a Settings pane")
    }

    func testModelFacingMessage_403_isAlsoTreatedAsAnAuthFailure() {
        XCTAssertTrue(LLMAuthErrorClassifier.modelFacingMessage(forStatus: 403).contains("credentials"))
    }

    /// The non-auth arm: a 500 is not a credentials problem, so it must NOT claim to be one —
    /// otherwise the model would stop retrying a transient server fault.
    func testModelFacingMessage_500_doesNotClaimAnAuthFailure() {
        let msg = LLMAuthErrorClassifier.modelFacingMessage(forStatus: 500)
        XCTAssertTrue(msg.contains("500"))
        XCTAssertFalse(msg.contains("credentials"))
        XCTAssertFalse(msg.contains("Settings"))
    }

    /// The human renderer is a contract surface for the settings cards — it must keep naming
    /// the pane even though its model-facing sibling must not.
    func testTheTwoRenderersDisagreeOnPurpose() {
        XCTAssertTrue(LLMAuthErrorClassifier.message(forStatus: 401, body: nil).contains("Settings → LLM"))
        XCTAssertFalse(LLMAuthErrorClassifier.modelFacingMessage(forStatus: 401).contains("Settings"))
    }
}
