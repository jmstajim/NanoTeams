import XCTest

@testable import NanoTeams

/// Wave 11 — the extraction arms of `TeamConfigParser` that no payload had taken.
///
/// `extractJSONObject` is the third and last fallback of `TeamGenerationService`'s cascade: it runs
/// when a model answered `create_team` as PROSE instead of a tool call, which is the common failure
/// for small local models. Its two fenced-block branches sit ahead of the raw scan precisely because
/// "the model wrapped its JSON in an explanation" is the dominant shape — and neither branch had
/// ever returned an object under test. The raw scan reaches the same answer for a fence-free
/// payload, so the gap was invisible: every existing suite fed unfenced JSON.
///
/// The distinction the fences buy is not decoration. `scanBalancedObject` takes the FIRST balanced
/// object it sees, so on prose that contains an illustrative object before the real one, the raw
/// scan returns the wrong object and the fence returns the right one. That is what these tests pin.
///
/// `extractInnerTeamConfig` is the unwrapper for the two observed wrapper shapes. Its
/// ordering clause — prefer whichever of `"team_config":"` / `"team_config":{` appears FIRST — had
/// never been evaluated with both present, and its no-brace bail had never fired.
final class TeamConfigExtractionCoverageTests: XCTestCase {

    // MARK: - extractJSONObject

    /// A ```json fence wins over an earlier balanced object in the surrounding prose.
    ///
    /// RED: delete the ```json branch (lines 24-28) → the raw scan runs instead and returns the
    /// decoy `{"note":"example"}`, failing both assertions.
    func testExtractJSONObject_jsonFence_beatsAnEarlierBalancedObjectInTheProse() {
        let text = """
        Here is the shape I will use: {"note":"example"}

        ```json
        {"name":"Payments Team","roles":[{"name":"Engineer"}]}
        ```
        """

        let extracted = TeamConfigParser.extractJSONObject(from: text)

        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.contains("Payments Team") == true,
                      "the fenced object is the model's answer; got: \(extracted ?? "nil")")
        XCTAssertFalse(extracted?.contains("example") == true,
                       "the prose decoy must not win")
    }

    /// A bare ``` fence — no language tag — takes the second branch. Same precedence over prose.
    ///
    /// RED: delete the generic-fence branch (lines 30-35) → the raw scan returns the decoy
    /// `{"note":"example"}` and the assertions fail.
    func testExtractJSONObject_untaggedFence_stillBeatsTheProse() {
        let text = """
        Draft, ignore this: {"note":"example"}

        ```
        {"name":"Payments Team","roles":[{"name":"Engineer"}]}
        ```
        """

        let extracted = TeamConfigParser.extractJSONObject(from: text)

        XCTAssertTrue(extracted?.contains("Payments Team") == true,
                      "got: \(extracted ?? "nil")")
        XCTAssertFalse(extracted?.contains("example") == true)
    }

    /// A fence whose body holds no balanced object falls THROUGH to the raw scan rather than
    /// failing — the branch returns only on success, which is why it is written as an `if let`
    /// inside the block rather than as the block's result.
    ///
    /// RED: change `if let obj = scanBalancedObject(in: inner) { return obj }` to
    /// `return scanBalancedObject(in: inner)` in the ```json branch → the fence's nil is returned
    /// and the assertion that the outside object is found fails.
    func testExtractJSONObject_emptyFence_fallsThroughToTheRawScan() {
        let text = """
        ```json
        (the model wrote nothing parseable here)
        ```
        {"name":"Fallback Team"}
        """

        XCTAssertTrue(TeamConfigParser.extractJSONObject(from: text)?.contains("Fallback Team") == true,
                      "an unparseable fence must not veto the raw scan")
    }

    // MARK: - extractInnerTeamConfig

    /// Both wrapper shapes present, string-form FIRST. The ordering clause picks the earlier one,
    /// so the extracted inner object is the string-encoded one and its escapes are decoded.
    ///
    /// This is the operand that had never been evaluated: with only one shape present the clause
    /// short-circuits on `objectForm == nil`, and the comparison never runs.
    ///
    /// RED: drop the `r.lowerBound < objectForm!.lowerBound` operand (leave only
    /// `objectForm == nil`) → the string form loses to the object form and the assertion that the
    /// FIRST wrapper won fails.
    func testExtractInnerTeamConfig_bothWrapperShapes_theEarlierOneWins() {
        // A string-encoded wrapper, then an object-form wrapper later in the same blob.
        let s = #"{"a":{"team_config":"{\"name\":\"First\"}"},"b":{"team_config":{"name":"Second"}}}"#

        let inner = TeamConfigParser.extractInnerTeamConfig(from: s)

        XCTAssertNotNil(inner)
        XCTAssertTrue(inner?.contains("First") == true,
                      "the earlier (string-form) wrapper must win; got: \(inner ?? "nil")")
        XCTAssertFalse(inner?.contains("Second") == true)
        XCTAssertFalse(inner?.contains("\\\"") == true,
                       "the string form's escapes must be decoded; got: \(inner ?? "nil")")
    }

    /// A `"team_config":"` wrapper with no `{` anywhere after it. The brace scan walks to the end
    /// of the string and bails rather than reading past it.
    ///
    /// RED: change `guard pos < s.endIndex else { return nil }` to `guard true else { return nil }`
    /// → `s[innerStart]` indexes at `endIndex` and the test traps instead of returning nil.
    func testExtractInnerTeamConfig_wrapperWithNoOpeningBrace_returnsNil() {
        XCTAssertNil(TeamConfigParser.extractInnerTeamConfig(from: #"{"team_config":"truncated"#))
    }

    /// Neither wrapper shape present — the `else { return nil }` arm, kept beside the two above so
    /// the three-way decision is stated in one place.
    ///
    /// RED: make the no-wrapper `else` at `TeamConfigParser.swift` return the payload itself
    /// instead of nil → a bare `{...}` with no `team_config` key resolves as if it had been
    /// wrapped, and the caller's "is this the inner config?" question is answered yes for a
    /// payload that was never wrapped.
    func testExtractInnerTeamConfig_noWrapper_returnsNil() {
        XCTAssertNil(TeamConfigParser.extractInnerTeamConfig(from: #"{"name":"Plain"}"#))
    }
}
