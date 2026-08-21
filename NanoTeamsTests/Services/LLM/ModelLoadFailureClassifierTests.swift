import XCTest

@testable import NanoTeams

/// `ModelLoadFailureClassifier` — recognizes "LM Studio has no free memory to
/// load this model", which arrives as an HTTP 500 but can NEVER clear by
/// waiting.
///
/// The bug it exists to stop: `LLMRetryPolicy` treated every 5xx as transient
/// without inspecting the body, and `defaultMaxLLMRetries = 0` means unlimited
/// — so this failure produced an unbounded 0.1 Hz retry loop. The step never
/// reached `.failed`, so no error bubble was ever produced; the user saw
/// "attempt N … Retrying in 10s" forever.
final class ModelLoadFailureClassifierTests: XCTestCase {

    /// Verbatim body observed in production on 2026-07-19, switching the global
    /// model to `google/gemma-4-26b-a4b` with two chat models already resident.
    /// Kept literal on purpose — a paraphrase would stop pinning the real wire
    /// format.
    private let productionBody = """
    {
      "error": {
        "type": "model_load_failed",
        "message": "Failed to load LLM 'google/gemma-4-26b-a4b': Error: Model loading was \
    stopped due to insufficient system resources. Continuing to load the model would likely \
    overload your system and cause it to freeze. If you think this is incorrect, you can \
    adjust the model loading guardrails in settings."
      }
    }
    """

    // MARK: - Positive

    func testMatches_productionBody() {
        XCTAssertTrue(ModelLoadFailureClassifier.matches(productionBody))
    }

    func testIsInsufficientResources_viaBadHTTPStatus() {
        XCTAssertTrue(ModelLoadFailureClassifier.isInsufficientResources(
            LLMClientError.badHTTPStatus(500, productionBody)))
    }

    /// The same condition can arrive mid-stream as an SSE error event.
    func testIsInsufficientResources_viaProviderError() {
        XCTAssertTrue(ModelLoadFailureClassifier.isInsufficientResources(
            LLMClientError.providerError(productionBody)))
    }

    /// The strong signature is the envelope's `type` field, not the prose —
    /// vendor UI copy gets reworded between releases.
    func testMatches_typeFieldAlone_withoutTheProse() {
        XCTAssertTrue(ModelLoadFailureClassifier.matches(#"{"type":"model_load_failed"}"#))
    }

    func testMatches_isCaseInsensitive() {
        XCTAssertTrue(ModelLoadFailureClassifier.matches("MODEL_LOAD_FAILED"))
        XCTAssertTrue(ModelLoadFailureClassifier.matches("Failed to LOAD: INSUFFICIENT memory"))
    }

    /// Qualifier coverage — each must independently license the weak marker.
    func testMatches_eachQualifier() {
        for qualifier in ["insufficient", "overload", "guardrail", "out of memory", "not enough memory"] {
            XCTAssertTrue(
                ModelLoadFailureClassifier.matches("could not load model: \(qualifier)"),
                "qualifier '\(qualifier)' must license the weak 'load' marker")
        }
    }

    // MARK: - Negative

    /// The weak marker alone is not enough — this is an ordinary failure that
    /// SHOULD keep retrying.
    func testMatches_loadMarkerWithoutQualifier_isFalse() {
        XCTAssertFalse(ModelLoadFailureClassifier.matches("failed to load file from disk"))
    }

    func testMatches_unrelatedServerError_isFalse() {
        XCTAssertFalse(ModelLoadFailureClassifier.matches("internal server error"))
        XCTAssertFalse(ModelLoadFailureClassifier.matches(""))
    }

    func testIsInsufficientResources_nonMatchingErrorShapes_areFalse() {
        XCTAssertFalse(ModelLoadFailureClassifier.isInsufficientResources(
            LLMClientError.badHTTPStatus(500, nil)))
        XCTAssertFalse(ModelLoadFailureClassifier.isInsufficientResources(
            LLMClientError.missingResponse))
        XCTAssertFalse(ModelLoadFailureClassifier.isInsufficientResources(CancellationError()))
    }

    /// The two classifiers must not overlap: a context-overflow message is a
    /// DIFFERENT recovery (retry with a smaller prompt, handled by
    /// `WorkFolderContextService`), so misclassifying it here would turn a
    /// recoverable condition into a hard failure.
    func testDoesNotOverlapWithContextOverflowClassifier() {
        let overflow = "The number of tokens to keep from the initial prompt is greater than "
            + "the context length. Try to load the model with a larger context length, or "
            + "provide a shorter input"

        XCTAssertTrue(ContextOverflowClassifier.matches(overflow))
        XCTAssertFalse(
            ModelLoadFailureClassifier.matches(overflow),
            "A context overflow must stay retryable-with-a-smaller-prompt, not become terminal")
        XCTAssertFalse(
            ContextOverflowClassifier.matches(productionBody),
            "A resource exhaustion must not be mistaken for a prompt that is too long")
    }

    // MARK: - Model name extraction

    func testQuotedModelName_extractsFromProductionBody() {
        XCTAssertEqual(
            ModelLoadFailureClassifier.quotedModelName(in: productionBody),
            "google/gemma-4-26b-a4b")
    }

    func testQuotedModelName_degenerateInputs() {
        XCTAssertNil(ModelLoadFailureClassifier.quotedModelName(in: "no quotes here"))
        XCTAssertNil(ModelLoadFailureClassifier.quotedModelName(in: "unterminated 'quote"))
        XCTAssertNil(ModelLoadFailureClassifier.quotedModelName(in: "empty ''"))
        XCTAssertNil(ModelLoadFailureClassifier.quotedModelName(in: "'"))
        XCTAssertNil(ModelLoadFailureClassifier.quotedModelName(in: ""))
    }

    // MARK: - Wiring

    /// One place, every surface (mirrors the auth classifier): the step bubble,
    /// the settings banner and the status pill all read `errorDescription`.
    func testErrorDescription_replacesTheRawEnvelopeWithSomethingActionable() {
        let described = LLMClientError.badHTTPStatus(500, productionBody).errorDescription ?? ""

        XCTAssertTrue(described.contains("google/gemma-4-26b-a4b"), described)
        XCTAssertTrue(described.lowercased().contains("memory"), described)
        XCTAssertFalse(described.contains("model_load_failed"),
                       "The raw envelope must not reach the user: \(described)")
    }

    /// An ordinary 500 keeps its raw body — we only special-case what we can
    /// give the user a move on.
    func testErrorDescription_ordinary500_keepsRawBody() {
        let described = LLMClientError.badHTTPStatus(500, "boom").errorDescription ?? ""
        XCTAssertTrue(described.contains("boom"), described)
    }
}
