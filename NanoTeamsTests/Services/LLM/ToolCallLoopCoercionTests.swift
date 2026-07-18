import XCTest

@testable import NanoTeams

/// Behavior-level proof that the widened argument coercion (`coerceInt` /
/// `coerceBool` / `coerceStringArray` in `ToolArgumentHelpers`) does not turn
/// legitimate work into a false loop accusation — and that a real loop still fires.
///
/// Why this layer and not the summarizer: `ToolCallTracker.record` stores
/// `ToolCallSummarizer.summarizeArguments` as `argumentsSummary`, and
/// `ToolCallLoopDetector` groups successful calls by `toolName + argumentsSummary`.
/// So the summary string IS the loop-detector identity key. `ToolCallSummarizerTests`
/// pins the strings; these tests pin the resulting VERDICT through a real tracker,
/// which is the only place a collapsed identity becomes a user-visible misfire.
///
/// The regression these guard: widening the handler's coercion made string-argument
/// calls SUCCEED (previously they failed with "Missing required argument" and were
/// filtered out of the repetition arm by `wasSuccessful`). A summarizer left on a
/// strict cast would then collapse distinct paginated reads onto one identity and
/// accuse the model of looping on correct pagination.
final class ToolCallLoopCoercionTests: XCTestCase {

    private typealias TN = ToolNames

    var tracker: ToolCallTracker!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tracker = ToolCallTracker()
    }

    override func tearDown() {
        tracker = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func record(_ toolName: String, _ argumentsJSON: String, isError: Bool = false) {
        tracker.record(
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            resultJSON: isError ? "{\"ok\": false}" : "{\"ok\": true}",
            isError: isError
        )
    }

    /// Records one `update_scratchpad` call. Two jobs, both required by the
    /// detector's shape: it is NOT a read-only tool (so the read-only arm, which
    /// fires when all 6 calls are reads, cannot pre-empt the repetition arm we are
    /// actually testing), and it is explicitly excluded from repetition counting
    /// (so it cannot itself become the max identity group). Content is unique per
    /// call (`tag` distinguishes them) because `record` drops repeated identical
    /// scratchpad content.
    private func recordFiller(_ tag: Int = 1) {
        record(TN.updateScratchpad, "{\"content\": \"plan step \(tag)\"}")
    }

    private func detect() -> LoopDetection? {
        ToolCallLoopDetector.detectLoopPattern(in: tracker.recentCalls(limit: 6))
    }

    // MARK: - Paginated read_lines with string-encoded bounds (the regression)

    /// THE regression. A model paging through a large file with quoted bounds
    /// ({"start_line": "501"}) makes five distinct, correct calls. With a strict
    /// `as? Int` in the summarizer every page collapses to the bare path
    /// ("big.txt"), the identity group hits 5, and the model is told it is looping
    /// while it is doing exactly the right thing.
    func testPaginatedReadLines_stringBounds_notFlaggedAsRepetition() {
        recordFiller()
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"501\", \"end_line\": \"1000\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1001\", \"end_line\": \"1500\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1501\", \"end_line\": \"2000\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"2001\", \"end_line\": \"2500\"}")

        XCTAssertNil(
            detect(),
            "successive pages of one file are distinct calls; quoting the bounds must not make them one identity"
        )
    }

    /// Control for the above: the numeric spelling must stay unflagged too, so a
    /// failure here isolates a broken Int branch from a broken String branch.
    func testPaginatedReadLines_numericBounds_notFlaggedAsRepetition() {
        recordFiller()
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": 1, \"end_line\": 500}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": 501, \"end_line\": 1000}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": 1001, \"end_line\": 1500}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": 1501, \"end_line\": 2000}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": 2001, \"end_line\": 2500}")

        XCTAssertNil(detect(), "numeric pagination must not be flagged either")
    }

    /// Counterweight to the two tests above: if detection were simply broken, they
    /// would pass vacuously. Re-reading the SAME string-bounded page over and over
    /// is a genuine loop and must still be reported.
    func testIdenticalStringBoundedPage_repeated_isDetected() {
        recordFiller()
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")

        let result = detect()
        guard case .repetitiveTool(let tool, let count, _)? = result else {
            return XCTFail("re-reading one page 3× is a real loop; got \(String(describing: result))")
        }
        XCTAssertEqual(tool, TN.readLines)
        XCTAssertEqual(count, 3, "all three identical string-bounded reads must land in one identity group")
    }

    /// Threshold boundary: two identical calls are not yet a loop. Catches an
    /// off-by-one (`>= 2`) that would flag a single legitimate retry.
    func testTwoIdenticalStringBoundedPages_belowThreshold_notFlagged() {
        recordFiller()
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")
        record(TN.readFile, "{\"path\": \"c.swift\"}")

        XCTAssertNil(detect(), "2 identical calls is under the 3-call repetition threshold")
    }

    /// A model that alternates spellings of the SAME logical call must not escape
    /// detection by re-typing its arguments. `{"start_line": 1}` and
    /// `{"start_line": "1"}` read the identical range, so they share an identity
    /// and their counts add up. Verified against the implementation: `coerceInt`
    /// maps both to 1, so both summarize to "big.txt 1:500".
    func testMixedNumericAndStringSpelling_shareOneIdentity() {
        recordFiller()
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": 1, \"end_line\": 500}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": 1, \"end_line\": 500}")
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")

        guard case .repetitiveTool(let tool, let count, _)? = detect() else {
            return XCTFail("alternating numeric/string spelling of one call must not dodge loop detection")
        }
        XCTAssertEqual(tool, TN.readLines)
        XCTAssertEqual(count, 3, "3 spellings of the same range are 3 calls to one identity, not 2+1")
    }

    /// Calls that FAILED are excluded from the repetition arm. This filter became
    /// load-bearing in the opposite direction after the widening: before it,
    /// string-argument calls errored out and were invisible to the detector; now
    /// they succeed and are counted (see the test above). Dropping the
    /// `wasSuccessful` filter would flag a model retrying a genuinely failing call.
    func testFailedIdenticalCalls_areNotCounted() {
        recordFiller()
        record(TN.readLines, "{\"path\": \"gone.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}", isError: true)
        record(TN.readLines, "{\"path\": \"gone.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}", isError: true)
        record(TN.readLines, "{\"path\": \"gone.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}", isError: true)
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")

        XCTAssertNil(detect(), "failed calls must not feed the repetition arm")
    }

    // MARK: - ui_click: string-encoded `double` (coerceBool)

    /// A single click and a double click at the same point are different actions.
    /// The model spells the flag as `"true"`; with a strict `as? Bool` that resolves
    /// to the handler's `false` default, both summarize to "(100, 200)", and four
    /// distinct actions become one identity group of 4 — over the threshold.
    func testUIClick_stringEncodedDouble_doesNotCollapseWithSingleClick() {
        record(TN.uiClick, "{\"x\": 100, \"y\": 200}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200, \"double\": \"true\"}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200, \"double\": \"true\"}")
        record(TN.uiClick, "{\"x\": 300, \"y\": 400}")
        record(TN.uiClick, "{\"x\": 300, \"y\": 400, \"double\": \"1\"}")

        XCTAssertNil(
            detect(),
            "single and double clicks at one point are distinct identities; neither pair reaches 3"
        )
    }

    /// The genuine GUI loop still fires — and for computer-use tools the advice must
    /// be "re-capture", not "try different arguments" (the model is probing a UI it
    /// can no longer see, so changing coordinates blindly is the wrong cure).
    func testUIClick_identicalStringEncodedDouble_repeated_isDetected() {
        record(TN.uiClick, "{\"x\": 100, \"y\": 200, \"double\": \"true\"}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200, \"double\": \"true\"}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200, \"double\": \"true\"}")
        record(TN.uiKey, "{\"keys\": \"return\"}")
        record(TN.uiType, "{\"text\": \"hello\"}")
        record(TN.uiScroll, "{\"x\": 5, \"y\": 5, \"dy\": -3}")

        guard case .repetitiveTool(let tool, let count, let message)? = detect() else {
            return XCTFail("3 identical double-clicks are a real loop")
        }
        XCTAssertEqual(tool, TN.uiClick)
        XCTAssertEqual(count, 3)
        XCTAssertTrue(message.contains("screen_capture"), "GUI loop advice must be re-capture. Got: \(message)")
    }

    // MARK: - search: bare-string `paths` (coerceStringArray)

    /// A search scoped to a bare-string path and an unscoped search over the whole
    /// tree are different operations. Without `coerceStringArray`, `paths: "src"`
    /// fails the `as? [String]` cast, the summary drops the scope entirely, and the
    /// scoped calls become indistinguishable from the unscoped ones — four calls on
    /// one identity, over the threshold.
    func testSearch_scopedBareStringPath_doesNotShareIdentityWithUnscopedSearch() {
        recordFiller(1)
        recordFiller(2)
        record(TN.search, "{\"query\": \"TODO\", \"paths\": \"src\"}")
        record(TN.search, "{\"query\": \"TODO\"}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": \"src\"}")
        record(TN.search, "{\"query\": \"TODO\"}")

        XCTAssertNil(
            detect(),
            "a scoped search must not share the unscoped search's identity; neither pair reaches 3"
        )
    }

    /// KNOWN LIMITATION, pinned deliberately so a future change to it is a choice
    /// rather than an accident. The `search` summarizer encodes only the path COUNT
    /// (`"TODO" in 1 paths`), not the path values — so three searches for the same
    /// query scoped to three DIFFERENT single directories share one identity and are
    /// reported as a loop. Coercion is not at fault (it correctly yields `["src"]`,
    /// `["lib"]`, `["tests"]`); the summary format is. Contrast `git_add`, which
    /// names the file for a single path and only falls back to a count for many.
    func testSearch_differentSingleBareStringPaths_shareIdentity_knownLimitation() {
        recordFiller()
        record(TN.search, "{\"query\": \"TODO\", \"paths\": \"src\"}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": \"lib\"}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": \"tests\"}")
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")

        guard case .repetitiveTool(let tool, let count, _)? = detect() else {
            return XCTFail("documents current behavior: count-only path summary collapses distinct scopes")
        }
        XCTAssertEqual(tool, TN.search)
        XCTAssertEqual(
            count, 3,
            "same query + different single paths currently share one identity (summary encodes count, not values)"
        )
    }

    /// The other half of the `search` picture: differing path COUNTS do stay
    /// distinct, which is what keeps a widening/narrowing sweep from being flagged.
    func testSearch_differingPathCounts_stayDistinct() {
        recordFiller()
        record(TN.search, "{\"query\": \"TODO\", \"paths\": \"src\"}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": [\"src\", \"lib\"]}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": [\"src\", \"lib\", \"tests\"]}")
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")

        XCTAssertNil(detect(), "searches over 1, 2 and 3 paths are distinct identities")
    }
}
