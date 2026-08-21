import XCTest

@testable import NanoTeams

/// Pins the DISPLAY side of the benchmark prompt: the marker placeholder, the derivation of the
/// readable text from the wire text, and the length the sheet reports.
///
/// Deliberately separate from the workload suite, which pins the fingerprint and the version. Two
/// different promises: that one says the workload cannot move without its version, this one says
/// what is shown and copied is what is sent.
final class BenchmarkPromptRenderingTests: XCTestCase {

    /// RED: re-implement `canonicalText` as its own literal and let it drift by one character →
    /// substituting a real nonce back no longer reproduces the wire prompt, which is the whole
    /// claim the sheet makes.
    func testCanonicalText_isTheWirePromptWithOnlyTheMarkerSubstituted() {
        let substituted = BenchmarkPrompt.canonicalText.replacingOccurrences(
            of: BenchmarkPrompt.noncePlaceholder, with: "abc12345")
        XCTAssertEqual(substituted, BenchmarkPrompt.prompt(nonce: "abc12345"))
    }

    /// The one string the runner sends and the one the sheet shows come from the same function.
    /// RED: build the message content separately from `prompt(nonce:)` → the two spellings can
    /// drift, and the sheet starts describing a request nobody makes.
    func testMessages_carryExactlyThePromptFunctionsOutput() {
        let messages = BenchmarkPrompt.messages(nonce: "abc12345")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, BenchmarkPrompt.prompt(nonce: "abc12345"))
    }

    /// RED: define `charactersPerSample` as `canonicalText.count` → the sheet reports six
    /// characters more than any sample ever sent, because the placeholder is longer than a nonce.
    func testCharactersPerSample_measuresTheSentPromptNotTheDisplayedOne() {
        XCTAssertEqual(
            BenchmarkPrompt.charactersPerSample,
            BenchmarkPrompt.prompt(nonce: BenchmarkPrompt.freshNonce()).count)
        XCTAssertNotEqual(BenchmarkPrompt.charactersPerSample, BenchmarkPrompt.canonicalText.count)
    }

    /// RED: drop `.lowercased()` or change the width → the placeholder arithmetic above stops
    /// describing a real sample, and the nonce stops being the fixed-width field it is documented
    /// as.
    func testFreshNonce_isFixedWidthLowercaseHex() {
        let nonce = BenchmarkPrompt.freshNonce()
        XCTAssertEqual(nonce.count, BenchmarkPrompt.nonceLength)
        XCTAssertTrue(
            nonce.allSatisfy { "0123456789abcdef".contains($0) }, nonce)
    }

    /// RED: return a constant → every sample after the first hits the server's prompt-prefix
    /// cache, and the prefill column measures a cache lookup instead of prompt processing.
    func testFreshNonce_differsAcrossCalls() {
        let nonces = Set((0..<16).map { _ in BenchmarkPrompt.freshNonce() })
        XCTAssertGreaterThan(nonces.count, 1)
    }

    /// RED: set the placeholder to eight hex characters → what the sheet shows becomes
    /// indistinguishable from a marker that was really sent, which is the single failure this
    /// whole rendering path is built to avoid.
    func testNoncePlaceholder_cannotBeMistakenForARealMarker() {
        XCTAssertNotEqual(BenchmarkPrompt.noncePlaceholder.count, BenchmarkPrompt.nonceLength)
        XCTAssertFalse(
            BenchmarkPrompt.noncePlaceholder.allSatisfy { "0123456789abcdef".contains($0) },
            BenchmarkPrompt.noncePlaceholder)
    }

    /// The marker leads the prompt on purpose: a cache matches on the PREFIX, so a marker at the
    /// end would leave the whole body reusable. RED: move the marker after `text` → the prefill
    /// figure silently becomes a cache measurement again.
    func testTheMarkerLeadsThePrompt() {
        XCTAssertTrue(
            BenchmarkPrompt.prompt(nonce: "abc12345").hasPrefix("Request abc12345."),
            String(BenchmarkPrompt.prompt(nonce: "abc12345").prefix(40)))
    }
}
