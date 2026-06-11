import XCTest
@testable import NanoTeams

/// Corner-case coverage for the tail-anchored `detectTailLoop` and its three repeat
/// tiers (short / large / very-large) — the algorithm behind the production loop scan.
/// Complements `RealWorldThinkingLoopDetectionTests` (verbatim real samples) by pinning
/// the algorithm's boundaries directly.
final class DetectTailLoopCornerTests: XCTestCase {

    // A long, deterministic, NON-repeating base. Each token is unique and token
    // lengths vary, so a prefix slice of any length has no internal sub-period — the
    // detected period equals the slice length, landing it in the intended tier.
    private var base: String {
        (0..<320).map { "w\($0)x\(($0 * 37) % 100)y " }.joined()
    }

    /// A substantive block of exactly `length` chars with no internal periodicity.
    private func block(_ length: Int) -> String { String(base.prefix(length)) }

    /// Direct call to the production detector with the live `DelegationConstants` tiers.
    private func detect(_ text: String) -> MessageRepetitionDetector.Match? {
        MessageRepetitionDetector.detectTailLoop(
            text,
            minSubstringChars: DelegationConstants.repetitionMinSubstringChars,
            maxSubstringChars: DelegationConstants.repetitionMaxSubstringChars,
            minRepeats: DelegationConstants.repetitionMinRepeats,
            tailWindowChars: DelegationConstants.repetitionTailWindowChars,
            largeSubstringChars: DelegationConstants.repetitionLargeSubstringChars,
            largeBlockMinRepeats: DelegationConstants.repetitionLargeBlockMinRepeats,
            veryLargeSubstringChars: DelegationConstants.repetitionVeryLargeSubstringChars,
            veryLargeBlockMinRepeats: DelegationConstants.repetitionVeryLargeBlockMinRepeats)
    }

    // MARK: - Base sanity (the slice itself must not falsely latch)

    func testNonRepeatingBaseSlice_doesNotFire() {
        // A single non-repeated block must NOT be flagged — guards the whole suite
        // against the base accidentally containing an exact sub-period.
        XCTAssertNil(detect(block(300)), "A single non-repeating block must not fire")
        XCTAssertNil(detect(block(1200)), "A single large non-repeating block must not fire")
    }

    // MARK: - Tier boundaries (the requiredReps step function)

    /// P == largeSubstringChars (120) is the SHORT tier (check is `> largeSubstringChars`):
    /// 5 reps fire, 4 don't.
    func testTier_periodEqualsLargeThreshold_usesShortTier() {
        let p = DelegationConstants.repetitionLargeSubstringChars  // 120
        XCTAssertNotNil(detect(String(repeating: block(p), count: DelegationConstants.repetitionMinRepeats)),
                        "A \(p)-char block (== large threshold) ×\(DelegationConstants.repetitionMinRepeats) is the short tier and must fire")
        XCTAssertNil(detect(String(repeating: block(p), count: DelegationConstants.repetitionMinRepeats - 1)),
                     "Short tier needs \(DelegationConstants.repetitionMinRepeats) reps — one fewer must not fire")
    }

    /// P == largeSubstringChars + 1 (121) crosses into the LARGE tier: 5 reps no longer
    /// fire; the full largeBlockMinRepeats (8) do.
    func testTier_oneOverLargeThreshold_usesLargeTier() {
        let p = DelegationConstants.repetitionLargeSubstringChars + 1  // 121
        XCTAssertNil(detect(String(repeating: block(p), count: DelegationConstants.repetitionMinRepeats)),
                     "A \(p)-char block ×\(DelegationConstants.repetitionMinRepeats) is the large tier and must NOT fire (needs \(DelegationConstants.repetitionLargeBlockMinRepeats))")
        XCTAssertNotNil(detect(String(repeating: block(p), count: DelegationConstants.repetitionLargeBlockMinRepeats)),
                        "A \(p)-char block ×\(DelegationConstants.repetitionLargeBlockMinRepeats) must fire")
    }

    /// P == veryLargeSubstringChars (500) is still the LARGE tier (check is
    /// `> veryLargeSubstringChars`): 5 reps don't fire (needs 8), so the very-large
    /// 4-rep shortcut does NOT kick in one char too early.
    func testTier_periodEqualsVeryLargeThreshold_usesLargeTier() {
        let p = DelegationConstants.repetitionVeryLargeSubstringChars  // 500
        XCTAssertNil(detect(String(repeating: block(p), count: DelegationConstants.repetitionVeryLargeBlockMinRepeats)),
                     "A \(p)-char block (== very-large threshold) ×\(DelegationConstants.repetitionVeryLargeBlockMinRepeats) must NOT fire — still the large tier (\(DelegationConstants.repetitionLargeBlockMinRepeats) reps)")
        XCTAssertNotNil(detect(String(repeating: block(p), count: DelegationConstants.repetitionLargeBlockMinRepeats)),
                        "A \(p)-char block ×\(DelegationConstants.repetitionLargeBlockMinRepeats) must fire")
    }

    /// P == veryLargeSubstringChars + 1 (501) crosses into the VERY-LARGE tier:
    /// 4 reps fire, 3 don't.
    func testTier_oneOverVeryLargeThreshold_usesVeryLargeTier() {
        let p = DelegationConstants.repetitionVeryLargeSubstringChars + 1  // 501
        XCTAssertNotNil(detect(String(repeating: block(p), count: DelegationConstants.repetitionVeryLargeBlockMinRepeats)),
                        "A \(p)-char block ×\(DelegationConstants.repetitionVeryLargeBlockMinRepeats) is the very-large tier and must fire")
        XCTAssertNil(detect(String(repeating: block(p), count: DelegationConstants.repetitionVeryLargeBlockMinRepeats - 1)),
                     "Very-large tier needs \(DelegationConstants.repetitionVeryLargeBlockMinRepeats) reps — one fewer must not fire")
    }

    // MARK: - Phase / partial final rep

    /// The periodicity-relation scan is phase-independent: a loop whose buffer ends in
    /// the MIDDLE of a rep still fires, as long as `required` FULL reps precede it. A
    /// naive "is the last P-window a clean rep" anchor would miss this.
    func testPartialFinalRep_stillFires() {
        let unit = block(200)  // large tier → 8 reps
        let buffer = String(repeating: unit, count: DelegationConstants.repetitionLargeBlockMinRepeats)
            + String(unit.prefix(120))  // a partial 9th rep at the tail
        let match = detect(buffer)
        XCTAssertNotNil(match, "8 full reps + a partial tail rep must still fire (phase-independent)")
    }

    /// Smallest detectable period: exactly `minSubstringChars` (8) chars, ×5.
    func testMinSubstringCharsPeriod_fires() {
        XCTAssertNotNil(detect(String(repeating: block(DelegationConstants.repetitionMinSubstringChars), count: 5)),
                        "An \(DelegationConstants.repetitionMinSubstringChars)-char period (the minimum) ×5 must fire")
    }

    // MARK: - Active-loop semantic (the deliberate difference from the start-sweep)

    /// `detectTailLoop` fires ONLY when the loop reaches the live tail. A loop FOLLOWED
    /// by distinct trailing text (the model moved on / recovered) does NOT fire — this
    /// is intentional: it only interrupts an *active* loop, not one already escaped.
    func testLoopFollowedByTrailingText_doesNotFire() {
        let buffer = String(repeating: block(200), count: DelegationConstants.repetitionLargeBlockMinRepeats)
            + "All done — moving on to a completely unrelated next task now."
        XCTAssertNil(detect(buffer),
                     "a loop the model already moved past must NOT fire (not at the tail)")
    }

    // MARK: - Substring-agnostic + bounded diagnostic

    /// The detector is substring-agnostic — a non-English (Cyrillic) loop fires too.
    func testNonEnglishLoop_fires() {
        let match = detect(String(repeating: "ну так, подожди, давай попробуем снова сейчас. ", count: 6))
        XCTAssertNotNil(match, "Non-English loops must fire (the detector compares Characters, not ASCII)")
        XCTAssertTrue(match?.substring.contains("подожди") ?? false)
    }

    /// The diagnostic envelope is bounded (substring truncated to ~80) so a loop of a
    /// large paragraph doesn't blow up the paused-by-supervisor tool result.
    func testDiagnosticIsBounded_forLargeBlockLoop() {
        let match = detect(String(repeating: block(300), count: DelegationConstants.repetitionLargeBlockMinRepeats))
        XCTAssertNotNil(match)
        XCTAssertLessThanOrEqual(match?.diagnostic.count ?? 0, 250,
                                 "Diagnostic must stay compact even for a 300-char loop block (got \(match?.diagnostic.count ?? -1))")
    }

    // MARK: - Unicode / grapheme clusters

    /// Loops containing multi-scalar emoji (flags, status markers) must be detected —
    /// `Array(String)` yields grapheme `Character`s, so the periodicity compare is
    /// grapheme-correct. Mirrors the real Autovisor loop that carried ✅ / 🔄.
    func testEmojiPeriod_fires() {
        let unit = "🇺🇸🇬🇧 ✅ Step done, 🔄 retrying the same plan again now. "  // short tier
        let match = detect(String(repeating: unit, count: 8))
        XCTAssertNotNil(match, "A loop whose period contains multi-scalar emoji must fire")
        XCTAssertTrue(match?.substring.contains("retrying") ?? false,
                      "the reported substring should carry the repeating unit's text")
    }

    // MARK: - Substantive guard (no punctuation / single-char false positives)

    func testPunctuationOnlyPeriod_doesNotFire() {
        // ". " repeated is periodic but substantively empty → rejected.
        XCTAssertNil(detect(String(repeating: ". ", count: 60)),
                     "A run of '. ' is punctuation noise, not a loop")
    }

    func testSingleCharRun_doesNotFire() {
        XCTAssertNil(detect(String(repeating: "=", count: 400)),
                     "A long single-character run is not a substantive loop")
        XCTAssertNil(detect(String(repeating: " ", count: 400)),
                     "Whitespace collapses under trimming and is not a loop")
    }

    // MARK: - Ceiling (honest documentation of the exact-period limit)

    /// A period LARGER than `maxSubstringChars` (1500) cannot be tested by the
    /// exact-period detector — it returns nil. This documents the known ceiling:
    /// cycles of ~15+ varying items (> 1500 chars) escape and would need a separate
    /// fuzzy/structural detector. Guards against silently assuming full coverage.
    func testPeriodAboveMaxLen_doesNotFire() {
        let p = DelegationConstants.repetitionMaxSubstringChars + 100  // 1600 > cap
        XCTAssertGreaterThan(block(p).count, DelegationConstants.repetitionMaxSubstringChars)
        XCTAssertNil(detect(String(repeating: block(p), count: 5)),
                     "A period above maxSubstringChars is beyond the exact-period detector (known ceiling)")
    }

    // MARK: - Longest-period-wins on a tiny period

    /// A tiny period repeated many times still fires (the detector may report a
    /// MULTIPLE of the true period as the unit — "longer wins" — which is still a
    /// valid loop signal). Pins that the multiple-of-period path doesn't crash or miss.
    func testTinyPeriodManyReps_firesWithUnitMultiple() {
        let match = detect(String(repeating: "abcdefgh", count: 30))
        XCTAssertNotNil(match, "An 8-char period ×30 must fire")
        XCTAssertEqual((match?.substring.count ?? 0) % 8, 0,
                       "the reported unit is a whole multiple of the true 8-char period")
        XCTAssertTrue(match?.substring.contains("abcdefgh") ?? false)
    }

    // MARK: - Empty / too-short

    func testEmptyAndTooShort_returnNil() {
        XCTAssertNil(detect(""))
        XCTAssertNil(detect("   \n\t  "))
        XCTAssertNil(detect("Hello, world."))  // below minSubstringChars * minRepeats
    }
}
