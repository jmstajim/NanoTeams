import XCTest

@testable import NanoTeams

/// Pins the windowed pre-marker detection (`StreamMarkerWindow`) against the
/// whole-buffer oracle it replaced.
///
/// The defect class (CLAUDE.md #106): the old per-delta gate normalized and
/// searched the ENTIRE accumulated `uiBuffer` on every content delta — the gate
/// deciding whether to do expensive work itself cost O(buffer), Θ(N²/|delta|)
/// across a stream. The window keeps detection byte-equivalent: every needle is
/// at most `needleSpan` characters, adjacent windows overlap by `needleSpan - 1`,
/// so a needle wholly inside the buffer lies wholly inside at least one window.
///
/// Every fixture asserts TWO postconditions (CLAUDE.md #67): parity with the
/// old whole-buffer decision at EVERY delta, and the expected final decision —
/// so the oracle itself cannot rot into vacuous agreement.
final class StreamMarkerWindowTests: XCTestCase {

    /// The decision the old code made on every delta, verbatim:
    /// normalize the whole buffer, then search it for all three markers.
    private func wholeBufferOracle(_ buffer: String) -> Bool {
        let normalized = HarmonySentinelNormalizer.normalize(buffer)
        return HarmonyToolCallParser.harmonyMarkers.contains(where: { normalized.contains($0) })
    }

    /// Feeds `deltas` one by one, asserting windowed == oracle after every append.
    /// Returns the final decision so callers can pin the expected outcome too.
    @discardableResult
    private func assertParity(_ deltas: [String], file: StaticString = #filePath,
                              line: UInt = #line) -> Bool {
        var buffer = ""
        var last = false
        for (i, delta) in deltas.enumerated() {
            buffer += delta
            let windowed = StreamMarkerWindow.harmonyNeedleArrived(
                buffer: buffer, newDeltaCount: delta.count)
            let oracle = wholeBufferOracle(buffer)
            XCTAssertEqual(windowed, oracle,
                           "delta \(i) (\(delta.prefix(30))…): windowed=\(windowed) oracle=\(oracle)",
                           file: file, line: line)
            last = windowed
        }
        return last
    }

    // MARK: - Verbatim markers

    func testMarkerWhollyInsideOneDelta() {
        XCTAssertTrue(assertParity(["Hello ", "world <|call|>{\"a\":1}"]))
    }

    func testMarkerSplitAcrossTwoDeltas() {
        XCTAssertTrue(assertParity(["prose <|ca", "ll|>{}"]))
    }

    func testMarkerSplitAcrossThreeDeltas() {
        XCTAssertTrue(assertParity(["x<|", "cal", "l|>"]))
    }

    func testChannelMarkerSplit() {
        XCTAssertTrue(assertParity(["text <|chan", "nel|>analysis"]))
    }

    func testDeltaLongerThanWindow() {
        let long = String(repeating: "a", count: 5_000)
        XCTAssertTrue(assertParity([long + "<|start|>" + long]))
    }

    func testBufferShorterThanNeedleSpan() {
        XCTAssertFalse(assertParity(["<|c"]))
        XCTAssertTrue(assertParity(["<|c", "all|>"]))
    }

    func testMarkerStartsExactlyAtOldBufferBoundary() {
        // Prior content ends; the marker's first byte is the next delta's first byte.
        XCTAssertTrue(assertParity(["some prose that ends here", "<|call|>{}"]))
    }

    /// One-character deltas force the window to its minimum size at every step —
    /// the needle is only ever whole on its final character's window.
    func testSingleCharacterDeltas() {
        XCTAssertTrue(assertParity("prose <|start|>".map(String.init)))
    }

    // MARK: - Grapheme clusters

    func testEmojiBeforeMarker() {
        XCTAssertTrue(assertParity(["👨‍👩‍👧‍👦 family émoji ", "<|start|>"]))
    }

    func testMarkerSplitRightAfterCombiningCluster() {
        // é as e + combining acute — the cluster must not eat the window budget.
        XCTAssertTrue(assertParity(["caf\u{0065}\u{0301}<|ca", "ll|>"]))
    }

    // MARK: - Mangled (alien) sentinel

    func testMangledSentinelWhollyInOneDelta() {
        XCTAssertTrue(assertParity(["x <|tool_call>call|>{\"path\":\"a\"}"]))
    }

    /// The debris run CARRIES the call's identity (`>call:edit_file`) — the
    /// 2026-08-14 lesson: no normalizer fixture carried a name inside the debris,
    /// and the replacement silently dropped `edit_file`. Split across deltas here
    /// so the window must see prefix + debris + `{` reassembled whole.
    func testMangledSentinelWithToolNameInDebrisSplitAcrossDeltas() {
        XCTAssertTrue(assertParity(["<|tool_call>call:ed", "it_file{\"path\":\"x\"}"]))
    }

    func testMangledSentinelBraceArrivesAsItsOwnDelta() {
        XCTAssertTrue(assertParity(["<|tool_call>call_multiple", "{\"calls\":[]}"]))
    }

    // MARK: - Negatives (must not fire, and must agree with the oracle)

    func testProseAboutTheSentinelWithoutPayloadNeverFires() {
        XCTAssertFalse(assertParity(["writing about <|tool_call tokens ", "and more prose"]))
    }

    func testDebrisRunOverCapNeverFires() {
        // 26 debris characters between the prefix and the brace: over maxDebrisRun.
        XCTAssertFalse(assertParity(["<|tool_call>" + String(repeating: "x", count: 25) + "{"]))
    }

    func testEndMarkerAloneIsNotAnOpeningNeedle() {
        XCTAssertFalse(assertParity(["envelope tail <|e", "nd|> prose"]))
    }

    func testPlainProseNeverFires() {
        XCTAssertFalse(assertParity(["The quick brown fox ", "jumps over ", "the lazy dog."]))
    }

    // MARK: - The window itself

    func testTailCoversDeltaPlusOverlap() {
        let buffer = String(repeating: "a", count: 100) + "XYZ"
        let tail = StreamMarkerWindow.tail(of: buffer, newDeltaCount: 3, needleSpan: 8)
        XCTAssertEqual(tail.count, 10)  // 3 + (8 - 1)
        XCTAssertTrue(tail.hasSuffix("XYZ"))
    }

    func testTailOfShortBufferIsTheWholeBuffer() {
        let tail = StreamMarkerWindow.tail(of: "abc", newDeltaCount: 1, needleSpan: 32)
        XCTAssertEqual(String(tail), "abc")
    }

    /// The composed needle span must cover BOTH needle families — shrinking it
    /// below the longest needle is the mutation that re-introduces missed
    /// detections (RED: change `+ 1` to `- 1` in `maxNeedleSpan` and the
    /// split-sentinel fixtures above go red).
    // MARK: - ChatML wrapper (2026-09-07)

    /// A wrapped envelope must fire exactly as an unwrapped one does. It fires on the
    /// MARKER, which the first line of `harmonyNeedleArrived` already sees — the wrapper
    /// branch inside `hasNormalizableOccurrence` never gets to decide, and that is the
    /// whole reason `maxNeedleSpan` did not have to grow.
    func testChatMLWrappedMarkerFiresAndAgreesWithOracle() {
        XCTAssertTrue(assertParity(["prose.<tool_call>\n", "<|call|>{\"a\":1}"]))
    }

    /// The tag ALONE must never fire. If it did, the latch would close on prose: visible
    /// content would freeze mid-reply, `pendingUI` would be discarded, and the model would
    /// get a `.noCallEnvelope` nudge for a turn it never framed as a call.
    func testChatMLTagAloneNeverFires() {
        XCTAssertFalse(assertParity(["prose <tool_call>", " and more prose"]))
    }

    /// Tag and marker both split across delta boundaries — detection must not depend on
    /// how the server happened to chunk the stream.
    func testChatMLWrappedMarkerSplitAcrossDeltas() {
        XCTAssertTrue(assertParity(["prose.<tool_c", "all>\n<|ca", "ll|>{\"a\":1}"]))
    }

    /// The wrapper branch adds no needle the window must hold: every one of its positives
    /// CONTAINS a needle that fires on its own (a whole marker at 11, or an existing
    /// mangled sentinel at 32). Pinned as a number so a future edit that grows the span
    /// "just in case" has to explain why the argument above stopped holding.
    func testNeedleSpanIsUnchangedByTheWrapperBranch() {
        XCTAssertEqual(HarmonySentinelNormalizer.maxNeedleSpan, 32)
        XCTAssertEqual(StreamMarkerWindow.harmonyNeedleSpan, 32)
    }

    func testNeedleSpanCoversBothNeedleFamilies() {
        let longestMarker = HarmonyToolCallParser.harmonyMarkers.map(\.count).max() ?? 0
        XCTAssertGreaterThanOrEqual(StreamMarkerWindow.harmonyNeedleSpan, longestMarker)
        XCTAssertGreaterThanOrEqual(StreamMarkerWindow.harmonyNeedleSpan,
                                    HarmonySentinelNormalizer.maxNeedleSpan)
    }

    // MARK: - Truncated sentinel with a whitespace gap (task 39 run 8, 2026-09-06)

    /// `<|call| {` — the 2026-09-05 family plus a space. It must arm the latch on the
    /// delta that completes it, however the server chunked the stream, or the repair
    /// depends on chunking.
    func testTruncatedSentinelWithGapSplitAcrossDeltas() {
        XCTAssertTrue(assertParity(["Let me read it.\n<|call|", " {\"name\":\"bash\"}"]))
        XCTAssertTrue(assertParity(["Let me read it.\n<|call| ", "{\"name\":\"bash\"}"]))
        XCTAssertTrue(assertParity(["<|call|", "\n", "{\"name\":\"bash\"}"]))
    }

    /// The gap does not move the span either: the truncated family's worst case is
    /// `<|call|` + `maxTruncatedGap` + `{` = 12, well under the alien family's 32, which
    /// is what sets the maximum. Asserted as the arithmetic rather than as a second
    /// literal so a change to either cap is visible here.
    func testNeedleSpanIsUnchangedByTheTruncatedGap() {
        XCTAssertEqual(HarmonySentinelNormalizer.maxNeedleSpan, 32)
        XCTAssertTrue(assertParity(["<|call|    ", "{\"a\":1}"]),
                      "a gap at the cap must still be detected within one window")
    }
}
