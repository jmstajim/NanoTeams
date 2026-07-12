import XCTest

@testable import NanoTeams

final class ContextOverflowClassifierTests: XCTestCase {

    /// The verbatim message observed in production (folder CastleSurvivors).
    private let productionMessage =
        "The number of tokens to keep from the initial prompt is greater than the context length. "
        + "Try to load the model with a larger context length, or provide a shorter input"

    func testProductionMessage_asProviderError_matches() {
        XCTAssertTrue(
            ContextOverflowClassifier.isContextOverflow(LLMClientError.providerError(productionMessage))
        )
    }

    func testProductionMessage_asBadHTTPStatus_matches() {
        XCTAssertTrue(
            ContextOverflowClassifier.isContextOverflow(LLMClientError.badHTTPStatus(400, productionMessage))
        )
    }

    func testProductionMessage_caseInsensitive() {
        XCTAssertTrue(ContextOverflowClassifier.matches(productionMessage.uppercased()))
        XCTAssertTrue(ContextOverflowClassifier.matches(productionMessage.lowercased()))
    }

    func testStrongSignature_matches() {
        XCTAssertTrue(ContextOverflowClassifier.matches("Error: context overflow detected"))
    }

    func testContextLengthWithoutQualifier_doesNotMatch() {
        // "context length" alone is too weak — must be paired with a qualifier.
        XCTAssertFalse(ContextOverflowClassifier.matches("adjusting the context length setting"))
    }

    func testUnrelatedContextError_doesNotMatch() {
        XCTAssertFalse(ContextOverflowClassifier.matches("context deadline exceeded"))
        XCTAssertFalse(ContextOverflowClassifier.matches("the request context was cancelled"))
    }

    func testCancellationError_doesNotMatch() {
        XCTAssertFalse(ContextOverflowClassifier.isContextOverflow(CancellationError()))
    }

    func testGenericProviderError_doesNotMatch() {
        XCTAssertFalse(
            ContextOverflowClassifier.isContextOverflow(LLMClientError.providerError("Model crashed unexpectedly"))
        )
    }

    func testBadHTTPStatusWithNilBody_doesNotMatch() {
        XCTAssertFalse(ContextOverflowClassifier.isContextOverflow(LLMClientError.badHTTPStatus(500, nil)))
    }

    // MARK: - Corner cases

    func testEachQualifier_pairedWithContextLength_matches() {
        for qualifier in ["greater than", "exceed", "larger", "shorter input", "tokens to keep"] {
            XCTAssertTrue(
                ContextOverflowClassifier.matches("the context length is \(qualifier) the limit"),
                "Qualifier '\(qualifier)' paired with 'context length' must classify as overflow."
            )
        }
    }

    func testEmptyString_doesNotMatch() {
        XCTAssertFalse(ContextOverflowClassifier.matches(""))
    }

    func testOtherLLMClientErrorCases_doNotMatch() {
        XCTAssertFalse(ContextOverflowClassifier.isContextOverflow(LLMClientError.invalidBaseURL("x")))
        XCTAssertFalse(ContextOverflowClassifier.isContextOverflow(LLMClientError.missingResponse))
    }

    func testQualifierWithoutContextLength_doesNotMatch() {
        // A qualifier alone (no "context length") is not enough.
        XCTAssertFalse(ContextOverflowClassifier.matches("the value is greater than expected"))
    }
}
