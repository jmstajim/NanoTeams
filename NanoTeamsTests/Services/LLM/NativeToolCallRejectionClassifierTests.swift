import XCTest

@testable import NanoTeams

/// The classifier behind `LLMClientError.nativeToolCallRejected`: a server that could not
/// parse the model's NATIVE call is reporting on the model's turn, not on its own health, so
/// the step nudges instead of resending a byte-identical prompt (`LLMRetryPolicy`).
final class NativeToolCallRejectionClassifierTests: XCTestCase {

    private func isRejection(_ message: String, sawGeneration: Bool = false, toolsDeclared: Bool = true) -> Bool {
        NativeToolCallRejectionClassifier.isRejection(
            message: message, sawGeneration: sawGeneration, toolsDeclared: toolsDeclared)
    }

    func testDocumentedPhrase_isARejection_caseInsensitively_evenBeforeAnyToken() {
        for message in [
            "tool call does not match the expected peg-native format",
            "PEG-NATIVE parse failed",
            "Failed to parse tool call: unexpected token",
            "Invalid tool call in response",
        ] {
            XCTAssertTrue(isRejection(message, sawGeneration: false, toolsDeclared: false), message)
        }
    }

    /// The signal that survives a reworded message: tokens were streamed BEFORE the error, on
    /// a request that declared tools.
    func testGeneratedTokensBeforeTheError_areARejection_whateverTheWording() {
        XCTAssertTrue(isRejection("internal server error", sawGeneration: true))
        XCTAssertTrue(isRejection("", sawGeneration: true))
    }

    /// A request that declared no tools armed no grammar — there was no call to reject. The
    /// step's `.native` stamp reaches tool-less callers unchanged (the auto-answer, a meeting
    /// speaker with no tools), and their mid-stream errors keep the old meaning.
    func testGeneratedTokens_withoutDeclaredTools_areNotARejection() {
        XCTAssertFalse(isRejection("internal server error", sawGeneration: true, toolsDeclared: false))
    }

    /// A server OUTAGE reported on the open stream is the server's health, whatever streamed
    /// before it: the retry policy owns it. Classifying it as the model's rejected call cost
    /// three "your call syntax is wrong" nudges per runner crash.
    func testAnOutageWording_isNeverARejection_evenAfterTokens() {
        for message in [
            "an error was encountered while running the model: CUDA error",
            "model runner has unexpectedly stopped",
            "Out of memory while decoding",
            "Model unloaded",
            "model is not loaded",
            "model_load_failed: unable to load model", // the model-load family
        ] {
            XCTAssertFalse(isRejection(message, sawGeneration: true), message)
            XCTAssertFalse(isRejection(message, sawGeneration: false), message)
        }
    }

    /// A false positive would turn a real outage into a nudge to the model.
    func testAnOutageBeforeAnyToken_isNotARejection() {
        for message in ["", "context length exceeded", "the model `x` was not found"] {
            XCTAssertFalse(isRejection(message, sawGeneration: false), message)
        }
    }

    /// The match lowercases the message, so the phrases must already be lowercase — and
    /// short enough to survive a reworded sentence while long enough not to match an outage.
    func testPhrases_areLowercase_andDistinctive() {
        XCTAssertFalse(NativeToolCallRejectionClassifier.rejectionPhrases.isEmpty)
        XCTAssertFalse(NativeToolCallRejectionClassifier.outagePhrases.isEmpty)
        for phrase in NativeToolCallRejectionClassifier.rejectionPhrases + NativeToolCallRejectionClassifier.outagePhrases {
            XCTAssertEqual(phrase, phrase.lowercased(), phrase)
            XCTAssertGreaterThanOrEqual(phrase.count, 9, "too short to be distinctive: \(phrase)")
        }
        for outage in NativeToolCallRejectionClassifier.outagePhrases {
            XCTAssertFalse(NativeToolCallRejectionClassifier.rejectionPhrases.contains { outage.contains($0) },
                           "an outage wording must not also read as a rejection: \(outage)")
        }
    }

    /// The error the user sees when a rejection surfaces anyway (a log line, a banner) quotes
    /// the server's sentence — the one diagnosis there is.
    func testErrorDescription_quotesTheServersSentence() {
        let description = LLMClientError.nativeToolCallRejected("peg-native mismatch").errorDescription ?? ""
        XCTAssertTrue(description.contains("could not parse"), description)
        XCTAssertTrue(description.hasSuffix("peg-native mismatch"), description)
    }
}
