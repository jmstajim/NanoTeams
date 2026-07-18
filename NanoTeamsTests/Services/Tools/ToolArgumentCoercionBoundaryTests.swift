import XCTest
@testable import NanoTeams

/// Boundary sweep of the three private coercers behind `optionalInt` /
/// `requiredInt` / `optionalBool` / `optionalStringArray` / `requiredStringArray`.
///
/// The happy paths and the obvious rejections are pinned in
/// `ToolArgumentHelpersTests`. This file covers only the edges where a plausible
/// refactor changes behavior silently: the Int64 rails, the rounding *direction*,
/// what counts as trimmable whitespace on this OS, digit-shaped non-ASCII text,
/// and the `[String]`-exact vs `[Any]`-mapped asymmetry in the array coercer.
///
/// Every expectation below was verified against the real implementations before
/// being written — none of it is assumed.
final class ToolArgumentCoercionBoundaryTests: XCTestCase {

    // MARK: - Helpers

    /// Fixtures that must go through real `JSONSerialization` bridging: a Swift
    /// literal `2` is a Swift `Int`, while a parsed JSON `2` is `__NSCFNumber`,
    /// and the two take different branches through `as? Bool` / `as? Int`.
    /// A Swift-literal dictionary does NOT exercise the same cast path.
    private func parseJSON(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("fixture is not a JSON object: \(json)")
            return [:]
        }
        return dict
    }

    // MARK: - Int64 rails

    /// The exact rails must survive as themselves. If the string branch were ever
    /// reordered to try `Double` first, `Int.max` would round to 2^63 and come
    /// back nil — a silent "missing argument" for a perfectly valid number.
    func testOptionalInt_intMaxAndMinAsExactStrings_surviveIntact() {
        XCTAssertEqual(
            optionalInt(["n": "9223372036854775807"], "n"), Int.max,
            "Int.max as a string must parse exactly, not detour through Double"
        )
        XCTAssertEqual(
            optionalInt(["n": "-9223372036854775808"], "n"), Int.min,
            "Int.min as a string must parse exactly"
        )
    }

    /// One past each rail, and the two directions do NOT behave alike.
    ///
    /// Above `Int.max` the Double fallback lands on 2^63 exactly, which
    /// `Int(exactly:)` refuses -> nil. Below `Int.min` the same fallback rounds
    /// the unrepresentable value back *up* to -2^63, which is exactly `Int.min`,
    /// so it saturates instead of failing. Pinned deliberately: swapping
    /// `Int(exactly:)` for `Int(clamping:)` or `Int(truncatingIfNeeded:)` would
    /// make the positive side saturate too, turning an overflow into a wrong
    /// number that reads as success.
    func testOptionalInt_oneStepPastEachRail_failsHighButSaturatesLow() {
        XCTAssertNil(
            optionalInt(["n": "9223372036854775808"], "n"),
            "Int.max + 1 must be rejected, never clamped to Int.max"
        )
        XCTAssertEqual(
            optionalInt(["n": "-9223372036854775809"], "n"), Int.min,
            "Int.min - 1 rounds back onto Int.min through the Double fallback"
        )
    }

    /// The same rails arriving as JSON *numbers* rather than strings.
    /// `9223372036854775807.0` is not representable as a Double and rounds up to
    /// 2^63, so the honest answer is nil; the negative rail is representable and
    /// survives. A clamping refactor would return `Int.max` for the first line.
    func testOptionalInt_railValuesAsDoubles_rejectHighAcceptLow() {
        XCTAssertNil(
            optionalInt(["n": 9223372036854775807.0 as Double], "n"),
            "a Double that rounds past Int.max must not be clamped into range"
        )
        XCTAssertEqual(
            optionalInt(["n": -9223372036854775808.0 as Double], "n"), Int.min,
            "-2^63 is exactly representable and must survive"
        )
    }

    /// Sign and zero-padding forms `Int.init?(_:)` accepts for free. These would
    /// break the moment someone replaced it with a hand-rolled ASCII digit scan.
    func testOptionalInt_signedAndZeroPaddedStrings_coerce() {
        XCTAssertEqual(optionalInt(["n": "-0"], "n"), 0, "negative zero is zero")
        XCTAssertEqual(optionalInt(["n": "+501"], "n"), 501, "explicit plus sign is accepted")
        XCTAssertEqual(optionalInt(["n": "007"], "n"), 7, "leading zeros are not octal, not an error")
    }

    // MARK: - Rounding direction

    /// The single highest-value pin in this file: truncation is toward zero, for
    /// BOTH signs, through BOTH the Double and the String branch.
    ///
    /// - `.down` (floor) would turn -0.9 into -1 and -1.5 into -2.
    /// - plain `.rounded()` / round-half-away would turn 1.5 into 2 and -1.5 into -2.
    /// - `.toNearestOrEven` would turn 1.5 into 2 while leaving 2.5 at 2.
    ///
    /// Only truncation toward zero satisfies all six values, so each spelling of
    /// the mutation is caught by at least one line.
    func testOptionalInt_truncatesTowardZero_notFloorNotRoundHalf() {
        // Double branch.
        XCTAssertEqual(optionalInt(["n": -0.9], "n"), 0, "-0.9 must truncate to 0, floor would give -1")
        XCTAssertEqual(optionalInt(["n": -1.5], "n"), -1, "-1.5 must truncate to -1, floor/round-half would give -2")
        XCTAssertEqual(optionalInt(["n": 1.5], "n"), 1, "1.5 must truncate to 1, any rounding would give 2")
        XCTAssertEqual(optionalInt(["n": 2.5], "n"), 2, "2.5 must truncate to 2")

        // String branch feeds the identical rounding step — it must not drift.
        XCTAssertEqual(optionalInt(["n": "-0.9"], "n"), 0, "string form must round like the numeric form")
        XCTAssertEqual(optionalInt(["n": "-1.5"], "n"), -1, "string form must round like the numeric form")
        XCTAssertEqual(optionalInt(["n": "1.5"], "n"), 1, "string form must round like the numeric form")
        XCTAssertEqual(optionalInt(["n": "2.5"], "n"), 2, "string form must round like the numeric form")
    }

    // MARK: - Whitespace forms

    /// Verified empirically on this OS: `CharacterSet.whitespacesAndNewlines`
    /// DOES contain U+00A0 NO-BREAK SPACE (the same surprising membership that
    /// makes it contain U+200B). So an NBSP-padded number trims and coerces.
    ///
    /// This is a real proof that trimming ran, not a tautology: `Double` and
    /// `Int` both reject "\u{00A0}501" outright, so if the trim were dropped or
    /// narrowed to `.whitespaces`-minus-NBSP the value would come back nil.
    func testOptionalInt_trimsTabNewlineAndNonBreakingSpace() {
        XCTAssertEqual(optionalInt(["n": "\t501\n"], "n"), 501, "tab and newline padding must be trimmed")
        XCTAssertEqual(optionalInt(["n": "\n  501  \t"], "n"), 501, "mixed padding must be trimmed")
        XCTAssertEqual(
            optionalInt(["n": "\u{00A0}501\u{00A0}"], "n"), 501,
            "U+00A0 is a member of .whitespacesAndNewlines on this OS and must trim"
        )
        // Guards the claim above: untrimmed, this input is genuinely unparseable.
        XCTAssertNil(Int("\u{00A0}501"), "sanity: NBSP-prefixed digits are not parseable without trimming")
        XCTAssertNil(Double("\u{00A0}501"), "sanity: the Double fallback rejects it too")
    }

    // MARK: - Digit-shaped non-ASCII

    /// Arabic-indic and full-width digits look numeric to a human (and to a model
    /// emitting them) but neither `Int.init?` nor strtod accepts them, so they are
    /// nil. Pinned so a "helpful" swap to a locale-aware `NumberFormatter` — which
    /// WOULD parse these, and would also start accepting grouped forms like
    /// "1,000" — is a deliberate decision rather than an accident.
    func testOptionalInt_nonASCIIDigitStrings_returnNil() {
        XCTAssertNil(optionalInt(["n": "٥٠١"], "n"), "Arabic-indic digits are not parsed")
        XCTAssertNil(optionalInt(["n": "５０１"], "n"), "full-width digits are not parsed")
    }

    // A `requiredInt` overflow-message test was written here and removed on review:
    // an overflowing string reaches the same present-and-not-null branch as any other
    // uncoercible value, so it adds no branch over
    // `ToolArgumentHelpersTests.testRequiredInt_presentButNotANumber_...` and
    // `...hugeDouble_throwsInsteadOfTrapping`, which already pin that message pair.

    // MARK: - Bool

    /// JSON numbers other than 0/1 are ambiguous garbage and must fall through to
    /// the caller's default — asserted against BOTH polarities, because a
    /// mutation that hardcoded `false` (or that adopted C-style `!= 0`
    /// truthiness, making 2 and -1 read as true) would sail past a one-sided test.
    ///
    /// The values come from real `JSONSerialization` output: a parsed `2` is
    /// `__NSCFNumber`, which returns nil from `as? Bool` and 2 from `as? Int`.
    func testOptionalBool_jsonNumbersOtherThanZeroOne_respectBothDefaults() {
        let args = parseJSON(#"{"two": 2, "neg": -1}"#)

        XCTAssertTrue(optionalBool(args, "two", default: true), "2 must not force false")
        XCTAssertFalse(optionalBool(args, "two", default: false), "2 must not be read as truthy")
        XCTAssertTrue(optionalBool(args, "neg", default: true), "-1 must not force false")
        XCTAssertFalse(optionalBool(args, "neg", default: false), "-1 must not be read as truthy")
    }

    /// Case folding and outer trimming are honored; an inner space is not a
    /// spelling of "true". Splitting these two claims apart matters: a refactor
    /// that reached for `contains("true")` instead of an exact match would keep
    /// the first three lines green and quietly accept "t rue" — and worse,
    /// "not true".
    func testOptionalBool_foldsCaseAndOuterSpace_butRejectsInnerSpace() {
        XCTAssertTrue(optionalBool(["flag": "TRUE"], "flag", default: false))
        XCTAssertTrue(optionalBool(["flag": "True"], "flag", default: false))
        XCTAssertTrue(optionalBool(["flag": " yes "], "flag", default: false))

        // Unparseable -> caller's default, checked in both directions so a
        // hardcoded return value cannot hide here.
        XCTAssertTrue(optionalBool(["flag": "t rue"], "flag", default: true), "inner space is not 'true'")
        XCTAssertFalse(optionalBool(["flag": "t rue"], "flag", default: false), "inner space must not become true")
        XCTAssertTrue(optionalBool(["flag": ""], "flag", default: true), "empty string keeps the default")
        XCTAssertFalse(optionalBool(["flag": ""], "flag", default: false), "empty string keeps the default")
    }

    // MARK: - String arrays

    /// A nested array is neither dropped nor deep-flattened: each inner array is
    /// stringified whole by `String(describing:)`, so the result has one entry per
    /// OUTER element and that entry is not the inner string.
    ///
    /// Asserted structurally rather than against the exact rendering — the
    /// `NSArray` description format is not something this code should promise.
    /// What it does promise: no silent flatten (which would fabricate a plausible
    /// but unrequested path list) and no silent drop.
    func testOptionalStringArray_nestedArrays_neitherFlattenedNorDropped() {
        let args = parseJSON(#"{"paths": [["a"], ["b"]]}"#)
        let result = optionalStringArray(args, "paths")

        XCTAssertNotNil(result, "a nested array must not read as an absent argument")
        XCTAssertEqual(result?.count, 2, "one entry per outer element — no deep flattening")
        XCTAssertNotEqual(result?.first, "a", "the inner array must not be unwrapped into its element")
    }

    /// Mixed element types: `NSNull` entries are dropped, numbers are stringified,
    /// and the surviving order is preserved.
    func testOptionalStringArray_mixedElements_dropsNullsAndStringifiesNumbers() {
        let args = parseJSON(#"{"ids": ["a", 1, null]}"#)
        XCTAssertEqual(
            optionalStringArray(args, "ids"), ["a", "1"],
            "nulls drop out, numbers stringify, order holds"
        )
    }

    /// An array whose every element is `NSNull` coerces to nothing at all — and
    /// "nothing" must be nil, not `[]`. The distinction is load-bearing: for
    /// `search paths`, `[]` is a legitimate caller-supplied value while nil means
    /// "no narrowing constraint given", and a `[]` here would be an empty
    /// constraint synthesized out of pure junk.
    func testOptionalStringArray_allNullElements_returnsNilNotEmptyArray() {
        let args = parseJSON(#"{"paths": [null, null]}"#)
        let result = optionalStringArray(args, "paths")

        XCTAssertNil(result, "an all-null array must read as absent, not as an empty list; got \(String(describing: result))")
    }

    /// Deliberate asymmetry between the two branches, pinned because it looks
    /// like an inconsistency and could easily be "fixed" into a behavior change:
    ///
    /// - a BARE empty string is nil (there is no element there to keep), but
    /// - an exact `[String]` is returned verbatim, empty elements included —
    ///   the caller explicitly built that list, so the coercer does not edit it.
    ///
    /// If the exact-match branch were ever routed through the `[Any]` mapper
    /// "for consistency", the empty entries would be silently filtered and
    /// `["a", ""]` would arrive as `["a"]`.
    func testOptionalStringArray_exactStringArray_preservesEmptyElementsUnlikeBareString() {
        XCTAssertEqual(
            optionalStringArray(["paths": ["a", ""]], "paths"), ["a", ""],
            "an exact [String] is passed through untouched, empty entries included"
        )
        XCTAssertEqual(
            optionalStringArray(["paths": ["", "  "]], "paths"), ["", "  "],
            "not even an all-empty [String] is filtered or collapsed to nil"
        )
        XCTAssertNil(
            optionalStringArray(["paths": ""], "paths"),
            "the bare-string branch, by contrast, has nothing to wrap"
        )
    }

    /// The all-null array is uncoercible but the key is present and is not itself
    /// `NSNull` — so `requiredStringArray` owes a type error, not "Missing".
    /// This is the array-side twin of the `requiredInt` boundary case and guards
    /// the same guard-ordering mistake.
    func testRequiredStringArray_arrayOfAllNulls_reportsTypeErrorNotMissing() {
        let args = parseJSON(#"{"participants": [null, null]}"#)
        XCTAssertThrowsError(try requiredStringArray(args, "participants")) { error in
            let message = (error as? ToolArgumentError)?.localizedDescription ?? ""
            XCTAssertFalse(message.contains("Missing"), "the key was present; got: \(message)")
            XCTAssertTrue(message.contains("participants"), "got: \(message)")
            XCTAssertTrue(message.contains("list of strings"), "got: \(message)")
        }
    }

    // A purity/idempotence test was written here and removed on review: `args` is a
    // `let [String: Any]` passed by value to non-inout parameters, so Swift's value
    // semantics make every "did not mutate" assertion unfailable, and the repeat-read
    // assertions only restate what the coercion tests above already pin.
}
