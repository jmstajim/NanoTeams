import XCTest

@testable import NanoTeams

/// Behavior-level proof that the widened argument coercion (`coerceInt` /
/// `coerceBool` / `coerceStringArray` in `ToolArgumentHelpers`) does not turn
/// legitimate work into a false loop accusation — and that a real loop still fires.
///
/// Why this layer: `ToolCallLoopDetector` keys repetition on
/// `TrackedCall.argumentsIdentity` (hash of the spelling-normalized canonical
/// arguments JSON — `"501"` folds with `501`), and fires only on a trailing run of
/// consecutive identical calls. These tests pin the resulting VERDICT through a real
/// tracker, which is the only place a collapsed identity becomes a user-visible
/// misfire. Fixtures place their runs at the TAIL of the window — the state
/// production actually fires on, since the check runs every iteration.
///
/// The regression these guard: widening the handler's coercion made string-argument
/// calls SUCCEED (previously they failed with "Missing required argument" and were
/// invisible to the repetition arm as failures). An identity that ignored the
/// spelling-normalized arguments would collapse distinct paginated reads onto one
/// run and accuse the model of looping on correct pagination.
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

    /// Records one `update_scratchpad` call — window filler the repetition arm ignores:
    /// it is explicitly excluded from repetition counting, so it cannot itself become
    /// the max identity group. Content is unique per call (`tag` distinguishes them)
    /// because `record` drops repeated identical scratchpad content.
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
    /// would pass vacuously. Re-reading the SAME string-bounded page three times in a
    /// row is a genuine loop and must still be reported.
    func testIdenticalStringBoundedPage_repeated_isDetected() {
        recordFiller()
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")

        let result = detect()
        guard case .repetitiveTool(let tool, let count)? = result else {
            return XCTFail("re-reading one page 3× is a real loop; got \(String(describing: result))")
        }
        XCTAssertEqual(tool, TN.readLines)
        XCTAssertEqual(count, 3, "all three identical string-bounded reads must land in one identity group")
    }

    /// Threshold boundary: two identical calls in a row are not yet a loop. Catches an
    /// off-by-one (`>= 2`) that would flag a single legitimate retry. The 2-run sits at
    /// the TAIL so this guards the threshold, not merely a broken run.
    func testTwoIdenticalStringBoundedPages_belowThreshold_notFlagged() {
        recordFiller()
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")
        record(TN.readFile, "{\"path\": \"c.swift\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")

        XCTAssertNil(detect(), "2 identical calls is under the 3-call repetition threshold")
    }

    /// A model that alternates spellings of the SAME logical call must not escape
    /// detection by re-typing its arguments. `{"start_line": 1}` and
    /// `{"start_line": "1"}` read the identical range, so they share an identity —
    /// and, sharing it, the alternation is one UNBROKEN run of 3, not runs of 1.
    func testMixedNumericAndStringSpelling_shareOneIdentity() {
        recordFiller()
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": 1, \"end_line\": 500}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}")
        record(TN.readLines, "{\"path\": \"big.txt\", \"start_line\": 1, \"end_line\": 500}")

        guard case .repetitiveTool(let tool, let count)? = detect() else {
            return XCTFail("alternating numeric/string spelling of one call must not dodge loop detection")
        }
        XCTAssertEqual(tool, TN.readLines)
        XCTAssertEqual(count, 3, "3 spellings of the same range are 3 calls to one identity, not 2+1")
    }

    /// Calls that FAILED remain INVISIBLE to the REPETITION arm — they neither count
    /// toward a `.repetitiveTool` run nor break one (see the detector's invisibility
    /// rule). (Counterpart: `ToolCallLoopDetectorTests.
    /// testDetectLoopPattern_failedCallInsideIdenticalRun_doesNotBreakTheRun` pins the
    /// non-breaking direction.)
    ///
    /// What changed on 2026-08-13: this test used to assert that three identical
    /// failures produce NO detection at all, on the argument that "each failure already
    /// got its own error guidance, and a loop warning on top would double-nudge". The
    /// gemma-4-26b-a4b-qat MeditationApp run refuted it empirically — four byte-identical
    /// failing `edit_file` calls, per-call `INVALID_ARGS` guidance every time, and the
    /// model re-emitted the same broken shape until a human hit Pause. Per-call guidance
    /// cannot say the one thing that breaks the loop ("you have now done this three times;
    /// repeating it cannot succeed"), because it has no memory of the previous calls.
    ///
    /// So the contract is now two-armed and this test pins both halves: the failure run
    /// is reported, and it is reported as `.repetitiveFailure` — never as
    /// `.repetitiveTool`, whose "the state isn't changing" diagnosis would be false here.
    func testFailedIdenticalCalls_feedTheFailureArmNotTheRepetitionArm() {
        recordFiller()
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")
        record(TN.readLines, "{\"path\": \"gone.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}", isError: true)
        record(TN.readLines, "{\"path\": \"gone.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}", isError: true)
        record(TN.readLines, "{\"path\": \"gone.txt\", \"start_line\": \"1\", \"end_line\": \"500\"}", isError: true)

        guard case .repetitiveFailure(let tool, let count, _)? = detect() else {
            return XCTFail("three identical failures must be reported by the failure arm")
        }
        XCTAssertEqual(tool, TN.readLines)
        XCTAssertEqual(count, 3)
    }

    // MARK: - ui_click: string-encoded `double` (coerceBool)

    /// A single click and a double click at the same point are different actions.
    /// The model spells the flag as `"true"`; an identity that dropped the flag would
    /// merge the alternation at the TAIL into one unbroken run of 4 — over the
    /// threshold. Kept distinct, every run is length 1 and nothing fires. The same-
    /// point alternation sits at the tail so a collapsed identity is still VISIBLE to
    /// the tail-anchored detector (at the head it would be a moved-past run either way).
    func testUIClick_stringEncodedDouble_doesNotCollapseWithSingleClick() {
        record(TN.uiClick, "{\"x\": 300, \"y\": 400}")
        record(TN.uiClick, "{\"x\": 300, \"y\": 400, \"double\": \"1\"}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200, \"double\": \"true\"}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200, \"double\": \"true\"}")

        XCTAssertNil(
            detect(),
            "single and double clicks at one point are distinct identities; every run is length 1"
        )
    }

    /// The genuine GUI loop still fires — and for computer-use tools the advice must
    /// be "re-capture", not "try different arguments" (the model is probing a UI it
    /// can no longer see, so changing coordinates blindly is the wrong cure).
    func testUIClick_identicalStringEncodedDouble_repeated_isDetected() {
        record(TN.uiKey, "{\"keys\": \"return\"}")
        record(TN.uiType, "{\"text\": \"hello\"}")
        record(TN.uiScroll, "{\"x\": 5, \"y\": 5, \"dy\": -3}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200, \"double\": \"true\"}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200, \"double\": \"true\"}")
        record(TN.uiClick, "{\"x\": 100, \"y\": 200, \"double\": \"true\"}")

        guard case .repetitiveTool(let tool, let count)? = detect() else {
            return XCTFail("3 identical double-clicks are a real loop")
        }
        XCTAssertEqual(tool, TN.uiClick)
        XCTAssertEqual(count, 3)
        let message = LLMExecutionService.loopWarningMessage(
            loopDetection: .repetitiveTool(tool: tool, count: count),
            allowedToolNames: [TN.uiClick, TN.screenCapture])
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

    /// Was pinned as a "KNOWN LIMITATION": the `search` DISPLAY summary encodes only the
    /// path COUNT (`"TODO" in 1 paths`), so three searches for one query scoped to three
    /// DIFFERENT directories collapsed onto a single identity and were reported as a loop.
    /// The pin recorded that as behaviour to preserve — but there is no caller for whom
    /// "you have called search with identical arguments 3 times" is a correct thing to say
    /// about three different directories, which makes it a defect wearing a
    /// characterization's clothes.
    ///
    /// It is gone because identity no longer comes from the display summarizer at all.
    ///
    /// RED: revert `TrackedCall.argumentsIdentity` to `argumentsSummary` → this fires, and
    /// so does the Autovisor's `task_status(1/2/3)` case, which is the same collapse on a
    /// tool the summarizer has no entry for at all.
    func testSearch_differentSingleBareStringPaths_areNotALoop() {
        recordFiller()
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": \"src\"}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": \"lib\"}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": \"tests\"}")

        XCTAssertNil(
            detect(),
            "three different search scopes are three different calls, not one repeated three times")
    }

    /// The other half of the `search` picture: differing path COUNTS do stay
    /// distinct, which is what keeps a widening/narrowing sweep from being flagged.
    func testSearch_differingPathCounts_stayDistinct() {
        recordFiller()
        record(TN.readFile, "{\"path\": \"a.swift\"}")
        record(TN.readFile, "{\"path\": \"b.swift\"}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": \"src\"}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": [\"src\", \"lib\"]}")
        record(TN.search, "{\"query\": \"TODO\", \"paths\": [\"src\", \"lib\", \"tests\"]}")

        XCTAssertNil(detect(), "searches over 1, 2 and 3 paths are distinct identities")
    }
}
