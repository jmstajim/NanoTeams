import XCTest

@testable import NanoTeams

// Coverage for the two TCC-gated platform services, restricted to what a test process can
// legitimately reach.
//
// This header used to list `captureSelection`, `requestAccessibilityIfNeeded` and the whole
// `AccessibilityInspector` walk as permanently out of reach. That was true of the code as written,
// not of the behaviour: both are now driven through value seams —
// `ClipboardCaptureFlowCoverageTests` (via `ClipboardCaptureEnvironment`) and
// `AccessibilityWalkCoverageTests` (via `AXNodeReading`). Neither posts a keystroke, touches
// `NSPasteboard.general`, or mutates a target app's AX state.
//
// What remains genuinely unreachable is the live conformance layer — `SystemPasteboard`,
// `SystemCopyKeystroke`, `SystemAXNodeReader` and friends — each of which is a single framework
// round-trip with no decision in it. That is the residue the seam was drawn to isolate.
//
// What follows covers the pure decision logic those paths are built out of.

// MARK: - SourceContext sentinel

/// The `\u{200B}// Source: ` sentinel is what separates "this clip came from a project file"
/// from "the user copied a line of code that happens to start with `// Source:`". Every clip
/// reader (`ClipCellPresentation`, `AnswerTextBuilder.clipSections`, the activity feed) branches
/// on `SourceContext.parse`, so a regression here either drops the file/line attribution the LLM
/// needs to locate the snippet, or fabricates attribution for ordinary user code.
final class ClipboardSourceSentinelTests: XCTestCase {

    private static let sentinel = "\u{200B}"
    /// Everything after the sentinel. `testParse_theZeroWidthSpaceIsTheSoleGate` builds its two
    /// inputs from this by prepending (or not) the sentinel, so they differ ONLY by that scalar
    /// by construction — no string search, no reliance on grapheme-cluster counting.
    private static let unsentinelledHeader = "// Source: a/b.swift:42-51\n"
    private static let header = "\u{200B}// Source: a/b.swift:42-51\n"

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// The zero-width space alone is the gate: the SAME characters minus that one scalar must stop
    /// parsing. Pins the sentinel as load-bearing rather than decorative — without it, any file
    /// whose first line is `// Source: ...` (a real convention in generated code) would be
    /// re-attributed to a project path the snippet never came from.
    func testParse_theZeroWidthSpaceIsTheSoleGate() {
        let tail = Self.unsentinelledHeader + "let x = 1"
        XCTAssertNotNil(SourceContext.parse(Self.sentinel + tail))
        XCTAssertNil(SourceContext.parse(tail), "same text, sentinel removed — must not parse")
    }

    /// CLAUDE.md 2026-07-11: `CharacterSet.whitespacesAndNewlines` classification of U+200B is
    /// PLATFORM-DEPENDENT (macOS 26's swift-foundation includes it; older Foundation does not), so
    /// this asserts the consequence in both directions instead of the classification itself — a
    /// direct assertion would be green locally and red on the macOS-15 CI runner.
    ///
    /// Either way the rule for callers is the same: detect on the RAW string, trim only the BODY.
    /// A caller that trims first is, on at least one shipping OS, silently discarding attribution.
    func testParse_trimmingBeforeParse_isUnsafeOnAtLeastOnePlatform() {
        let enriched = Self.header + "let x = 1"
        XCTAssertNotNil(SourceContext.parse(enriched), "raw text always parses")

        let trimmed = enriched.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(Self.sentinel) {
            // This Foundation keeps U+200B → trimming is (here) harmless.
            XCTAssertNotNil(SourceContext.parse(trimmed))
        } else {
            // This Foundation eats U+200B → the header is unrecognisable. This is the branch the
            // Грабли entry documents, and the reason detection must precede any trim.
            XCTAssertNil(SourceContext.parse(trimmed))
        }
    }

    /// Clips are code. `parse` must hand back the body byte-for-byte — leading indentation carries
    /// meaning (Python blocks, diff context) and trailing newlines carry structure. A body-side
    /// trim would silently rewrite the snippet the LLM is asked to reason about.
    func testParse_bodyIsReturnedVerbatim_indentationAndTrailingNewlinePreserved() {
        let body = "        if x {\n            return\n        }\n"
        let result = SourceContext.parse(Self.header + body)
        XCTAssertEqual(result?.body, body)
    }

    /// The sentinel is only a header when it is the FIRST scalar. A clip whose body contains a
    /// stray U+200B (re-clipped text, pasted from another enriched clip) must not be re-split at
    /// that point — the source label would be nonsense and the body would lose its first lines.
    func testParse_sentinelNotAtStart_returnsNil() {
        XCTAssertNil(SourceContext.parse("prefix \(Self.sentinel)// Source: a.swift:1\nbody"))
        XCTAssertNil(SourceContext.parse("\n\(Self.sentinel)// Source: a.swift:1\nbody"))
    }

    /// The header shape is exact — sentinel, `// Source:`, ONE space. A near-miss must fall
    /// through to "plain clip" rather than being parsed with a mangled source label.
    func testParse_headerShapeIsExact_nearMissesReturnNil() {
        XCTAssertNil(SourceContext.parse("\(Self.sentinel)// Source:a.swift:1\nbody"),
                     "missing the space after the colon")
        XCTAssertNil(SourceContext.parse("\(Self.sentinel)// source: a.swift:1\nbody"),
                     "case matters — the writer emits exactly one spelling")
        XCTAssertNil(SourceContext.parse("\(Self.sentinel)//Source: a.swift:1\nbody"),
                     "missing the space after //")
    }

    /// The split happens at the first newline, and the writer never puts one in the label — so a
    /// body that itself starts with a blank line keeps that blank line. Guards against an
    /// off-by-one that would eat the snippet's first (empty) line.
    func testParse_bodyStartingWithBlankLine_keepsIt() {
        let result = SourceContext.parse(Self.header + "\nlet x = 1")
        XCTAssertEqual(result?.source, "a/b.swift:42-51")
        XCTAssertEqual(result?.body, "\nlet x = 1")
    }
}

// MARK: - AX geometry: element frame → advertised centre → click

/// End-to-end pin for the coordinate chain the model actually uses:
/// `Geometry.mapFrame` (AX global frame → image pixels) → `clampedCenter` (the `cx`/`cy` shipped
/// on the wire) → `InputControlService.imagePixelToGlobalPoint` (the click). Nothing else pins the
/// composition; the individual links are tested in isolation, and it is the COMPOSITION that
/// failed in the wild (2026-07-02: clicks landing beside the control because the screenshot region
/// and the element list were built from different units).
final class AXInspectorGeometryRoundTripTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private struct Setup {
        let name: String
        let originX: Double, originY: Double
        let regionW: Double, regionH: Double
        let pxW: Int, pxH: Int
        let frames: [CGRect]

        var geometry: AccessibilityInspector.Geometry {
            AccessibilityInspector.Geometry(
                originX: originX, originY: originY,
                regionWidthPt: regionW, regionHeightPt: regionH,
                pixelWidth: pxW, pixelHeight: pxH)
        }
    }

    /// Clicking an element's advertised `cx`/`cy` must land on a global point INSIDE that
    /// element's real frame. If it doesn't, every click is a near-miss the model cannot diagnose:
    /// the tool reports success, the UI does nothing, and it loops.
    ///
    /// Scope is deliberate: integral frame origins and sides ≥ 8 pt. Integer pixel quantisation is
    /// lossy, so at aggressive downscale a control narrower than ~2 image pixels can round its
    /// corner outside itself — that is information loss, not a defect, and asserting it here would
    /// pin an accident.
    func testClickingAdvertisedCentre_landsInsideTheElementFrame() {
        let setups: [Setup] = [
            Setup(name: "1:1", originX: 0, originY: 0, regionW: 1000, regionH: 1000,
                  pxW: 1000, pxH: 1000,
                  frames: [CGRect(x: 0, y: 0, width: 40, height: 20),
                           CGRect(x: 100, y: 100, width: 8, height: 8),
                           CGRect(x: 101, y: 103, width: 9, height: 11),
                           CGRect(x: 400, y: 400, width: 40, height: 40)]),
            Setup(name: "0.5x downscale (Retina folded in)", originX: 0, originY: 0,
                  regionW: 1000, regionH: 1000, pxW: 500, pxH: 500,
                  frames: [CGRect(x: 0, y: 0, width: 40, height: 20),
                           CGRect(x: 100, y: 100, width: 8, height: 8),
                           CGRect(x: 101, y: 103, width: 9, height: 11),
                           CGRect(x: 400, y: 400, width: 40, height: 40)]),
            Setup(name: "2x upscale", originX: 0, originY: 0, regionW: 500, regionH: 500,
                  pxW: 1000, pxH: 1000,
                  frames: [CGRect(x: 0, y: 0, width: 40, height: 20),
                           CGRect(x: 100, y: 100, width: 8, height: 8),
                           CGRect(x: 101, y: 103, width: 9, height: 11),
                           CGRect(x: 400, y: 400, width: 40, height: 40)]),
            Setup(name: "secondary display (negative origin)", originX: -1440, originY: 200,
                  regionW: 1000, regionH: 1000, pxW: 500, pxH: 500,
                  frames: [CGRect(x: -1440, y: 200, width: 40, height: 20),
                           CGRect(x: -1340, y: 300, width: 8, height: 8),
                           CGRect(x: -1339, y: 303, width: 9, height: 11),
                           CGRect(x: -1040, y: 600, width: 40, height: 40)]),
            Setup(name: "non-square ratios", originX: 0, originY: 0, regionW: 2000, regionH: 500,
                  pxW: 1000, pxH: 1000,
                  frames: [CGRect(x: 0, y: 0, width: 40, height: 20),
                           CGRect(x: 100, y: 100, width: 8, height: 8),
                           CGRect(x: 101, y: 103, width: 9, height: 11),
                           CGRect(x: 400, y: 400, width: 40, height: 40)]),
        ]

        for setup in setups {
            let geom = setup.geometry
            for frame in setup.frames {
                guard let mapped = geom.mapFrame(frame) else {
                    XCTFail("\(setup.name): mapFrame dropped an in-region frame \(frame)")
                    continue
                }
                let centre = AccessibilityInspector.clampedCenter(
                    x: mapped.x, y: mapped.y, w: mapped.w, h: mapped.h,
                    pixelWidth: setup.pxW, pixelHeight: setup.pxH)

                // The advertised centre must itself be a clickable pixel of the image, or the
                // click conversion rejects it outright.
                XCTAssertTrue((0..<setup.pxW).contains(centre.cx),
                              "\(setup.name): cx \(centre.cx) outside image for \(frame)")
                XCTAssertTrue((0..<setup.pxH).contains(centre.cy),
                              "\(setup.name): cy \(centre.cy) outside image for \(frame)")

                guard let click = InputControlService.imagePixelToGlobalPoint(
                    imageX: Double(centre.cx), imageY: Double(centre.cy),
                    originX: setup.originX, originY: setup.originY,
                    regionWidthPt: setup.regionW, regionHeightPt: setup.regionH,
                    pixelWidth: setup.pxW, pixelHeight: setup.pxH) else {
                    XCTFail("\(setup.name): click conversion rejected \(centre) for \(frame)")
                    continue
                }
                XCTAssertTrue(frame.contains(click),
                              "\(setup.name): click \(click) missed \(frame) (mapped \(mapped), centre \(centre))")
            }
        }
    }

    /// A control that occupies less than one image pixel is dropped rather than advertised. It has
    /// no pixel the model can see or verify against the screenshot, and shipping it would spend a
    /// slot of the 140-element emission cap on a coordinate that cannot be checked. Exact ratio
    /// (0.125) chosen so the boundary is not a floating-point accident.
    func testMapFrame_subPixelElementIsDropped_onePixelElementIsKept() {
        let geom = AccessibilityInspector.Geometry(
            originX: 0, originY: 0, regionWidthPt: 1000, regionHeightPt: 1000,
            pixelWidth: 125, pixelHeight: 125)   // 0.125 px per pt, exactly representable

        XCTAssertNil(geom.mapFrame(CGRect(x: 400, y: 400, width: 4, height: 4)),
                     "0.5 px wide — no clickable pixel")
        let kept = geom.mapFrame(CGRect(x: 400, y: 400, width: 8, height: 8))
        XCTAssertEqual(kept?.w, 1)
        XCTAssertEqual(kept?.h, 1)
    }

    /// The far edge is exclusive on BOTH sides of the chain: an element whose corner sits exactly
    /// at `pixelWidth` is one column past the last captured pixel, and `imagePixelToGlobalPoint`
    /// would reject a click there anyway. Advertising it would guarantee a rejected click.
    func testMapFrame_frameStartingExactlyAtTheFarEdge_isDropped() {
        let geom = AccessibilityInspector.Geometry(
            originX: 0, originY: 0, regionWidthPt: 1000, regionHeightPt: 1000,
            pixelWidth: 500, pixelHeight: 500)
        XCTAssertNil(geom.mapFrame(CGRect(x: 1000, y: 100, width: 100, height: 100)))
        XCTAssertNil(geom.mapFrame(CGRect(x: 100, y: 1000, width: 100, height: 100)))
        // One point back in, the element is partly visible and must survive.
        XCTAssertNotNil(geom.mapFrame(CGRect(x: 990, y: 990, width: 100, height: 100)))
    }

    /// An element straddling the right/bottom edge keeps a centre inside the image (existing
    /// coverage only exercises the top-left straddle, where clamping is trivially satisfied).
    func testStraddlingFarEdge_centreStaysClickable() {
        let geom = AccessibilityInspector.Geometry(
            originX: 0, originY: 0, regionWidthPt: 1000, regionHeightPt: 1000,
            pixelWidth: 500, pixelHeight: 500)
        guard let mapped = geom.mapFrame(CGRect(x: 960, y: 960, width: 200, height: 200)) else {
            return XCTFail("a partially visible element must be advertised")
        }
        let centre = AccessibilityInspector.clampedCenter(
            x: mapped.x, y: mapped.y, w: mapped.w, h: mapped.h,
            pixelWidth: 500, pixelHeight: 500)
        XCTAssertTrue((0..<500).contains(centre.cx))
        XCTAssertTrue((0..<500).contains(centre.cy))
        XCTAssertNotNil(InputControlService.imagePixelToGlobalPoint(
            imageX: Double(centre.cx), imageY: Double(centre.cy),
            originX: 0, originY: 0, regionWidthPt: 1000, regionHeightPt: 1000,
            pixelWidth: 500, pixelHeight: 500))
    }
}

// MARK: - Window matching: ambiguity + threshold edges

/// `bestWindowMatchIndex` decides which AXWindow the walk is rooted at. Picking the wrong one
/// advertises elements of a window the screenshot does NOT show, with valid-looking coordinates —
/// the exact failure mode `matchWindowToRegion` exists to prevent. Existing coverage pins the
/// accept/reject shapes; this pins the AMBIGUOUS ones (several plausible windows) and the
/// threshold boundary.
final class AXInspectorWindowMatchTieBreakTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// Two windows both clear the bar; the better-covering one wins even though it is later in AX
    /// order. Position must not beat evidence — a stale/offset frame listed first would otherwise
    /// capture the match.
    func testBestCoverageWins_evenWhenListedSecond() {
        let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let offset = region.offsetBy(dx: 50, dy: 0)     // 0.95 mutual coverage
        let exact = region                              // 1.0
        XCTAssertEqual(
            AccessibilityInspector.bestWindowMatchIndex(windowFrames: [offset, exact], region: region), 1)
        XCTAssertEqual(
            AccessibilityInspector.bestWindowMatchIndex(windowFrames: [exact, offset], region: region), 0)
    }

    /// Exact tie → the EARLIER window wins. AX lists windows front-to-back, so the earlier one is
    /// the frontmost — the one the screenshot actually shows when two windows are stacked at the
    /// same frame. Also keeps the choice deterministic across captures (prompt-prefix stability).
    func testExactTie_keepsTheFrontmostWindow() {
        let region = CGRect(x: 100, y: 100, width: 800, height: 600)
        let frames = [region, region, region]
        XCTAssertEqual(
            AccessibilityInspector.bestWindowMatchIndex(windowFrames: frames, region: region), 0)
    }

    /// The 0.8 coverage bar is INCLUSIVE, and one point below it rejects. Pinned from both sides
    /// with exactly representable areas so the boundary is a decision, not a rounding artefact:
    /// intersection 8 000 / region 10 000 == 0.8 exactly in IEEE double. A window sitting right at
    /// the bar is the common real case (title-bar/shadow slop), so which way it falls matters.
    func testCoverageThreshold_inclusiveLowerBound() {
        let region = CGRect(x: 0, y: 0, width: 100, height: 100)        // area 10 000
        let atThreshold = CGRect(x: 0, y: 0, width: 100, height: 80)    // inter 8 000 → 0.80
        let belowThreshold = CGRect(x: 0, y: 0, width: 100, height: 79) // inter 7 900 → 0.79

        XCTAssertEqual(
            AccessibilityInspector.bestWindowMatchIndex(windowFrames: [atThreshold], region: region), 0)
        XCTAssertNil(
            AccessibilityInspector.bestWindowMatchIndex(windowFrames: [belowThreshold], region: region))
    }

    /// Windows on a secondary display have negative global origins. Coverage is area-based so the
    /// sign must not matter — a regression here makes every capture on a left-hand display fall
    /// back to the app root and advertise the wrong window's elements.
    func testNegativeOriginRegion_matchesNormally() {
        let region = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        XCTAssertEqual(
            AccessibilityInspector.bestWindowMatchIndex(windowFrames: [region], region: region), 0)
        // A window on the primary display must not match a secondary-display capture.
        XCTAssertNil(AccessibilityInspector.bestWindowMatchIndex(
            windowFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)], region: region))
    }

    /// A zero-area frame (a minimised/off-screen window reports one) carries no identity evidence
    /// and is skipped — but it must not shadow a valid sibling later in the list. Existing coverage
    /// only exercises single-element lists, where "skipped" and "list exhausted" look the same.
    func testZeroAreaFrame_isSkippedWithoutShadowingAValidSibling() {
        let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let minimised = CGRect(x: 0, y: 0, width: 0, height: 1000)
        XCTAssertNil(AccessibilityInspector.bestWindowMatchIndex(
            windowFrames: [minimised], region: region))
        XCTAssertEqual(AccessibilityInspector.bestWindowMatchIndex(
            windowFrames: [minimised, region], region: region), 1)
    }
}

// MARK: - Walk cancellation flag

/// `Task.detached` does not inherit the caller's cancellation (CLAUDE.md 2026-07-02), so this
/// shared atomic flag is the ONLY thing that stops an in-flight AX walk. If it stopped working, a
/// Pause landing mid-walk would block the caller past the bounded-wait budget while the walk keeps
/// doing synchronous IPC against a busy browser.
final class AXInspectorWalkCancellationTests: XCTestCase {

    var sut: WalkCancellationFlag!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        sut = WalkCancellationFlag()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testFreshFlag_isNotCancelled() {
        XCTAssertFalse(sut.isCancelled)
    }

    /// One-way latch: once set it must never read false again. The walk polls it at every node and
    /// on every child loop, so a flag that could flip back would let a cancelled walk resume.
    func testCancel_latchesAndIsIdempotent() {
        sut.cancel()
        XCTAssertTrue(sut.isCancelled)
        sut.cancel()
        XCTAssertTrue(sut.isCancelled)
    }

    /// The whole point of the reference wrapper: the `onCancel` handler and the detached walk hold
    /// the SAME flag and touch it from different threads. Reading while others cancel must be
    /// well-defined (it is an `Atomic`, not a bare `Bool`).
    func testConcurrentCancelAndRead_isWellDefined() async {
        let flag = sut!
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<32 {
                group.addTask {
                    if i.isMultiple(of: 2) { flag.cancel() }
                    return flag.isCancelled
                }
            }
            for await _ in group {}
        }
        XCTAssertTrue(flag.isCancelled)
    }
}

// MARK: - collectElements input guard

/// The degenerate-request guard, driven through the PRODUCTION entry point — the one that names
/// `SystemAXNodeReader()`. `AccessibilityWalkCoverageTests` drives the same guard through the seam;
/// this suite is what proves the guard still fronts the live path, so a request that would spend up
/// to 1.2 s of AX IPC and permanently switch a target app into assistive mode is rejected before
/// any of it. pid -1 is not a live process, so a guard that stopped firing fails immediately rather
/// than walking a real application.
final class AXInspectorCollectionGuardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func request(
        pixelWidth: Int = 100, pixelHeight: Int = 100,
        regionWidthPt: Double = 100, regionHeightPt: Double = 100
    ) -> AXCollectionRequest {
        // pid -1 is not a live process: if the guard ever stopped firing, the AX calls below it
        // fail immediately instead of walking a real application.
        AXCollectionRequest(
            pid: -1, regionOriginX: 0, regionOriginY: 0,
            regionWidthPt: regionWidthPt, regionHeightPt: regionHeightPt,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, matchWindowToRegion: false)
    }

    /// A zero/negative-sized capture must be rejected up front. Past the guard, `Geometry` would
    /// divide by a zero region and drop every element anyway — but only AFTER spending up to
    /// 1.2 s of synchronous AX IPC and, worse, after `enableWebAccessibility` has permanently
    /// switched the target app into assistive mode for a capture that can never yield anything.
    func testDegenerateDimensions_returnEmptyWithoutWalking() async {
        let cases: [(String, AXCollectionRequest)] = [
            ("zero pixel width", request(pixelWidth: 0)),
            ("zero pixel height", request(pixelHeight: 0)),
            ("negative pixel width", request(pixelWidth: -10)),
            ("zero region width", request(regionWidthPt: 0)),
            ("zero region height", request(regionHeightPt: 0)),
            ("negative region height", request(regionHeightPt: -5)),
        ]
        for (name, req) in cases {
            let result = await AccessibilityInspector.collectElements(req)
            XCTAssertTrue(result.elements.isEmpty, name)
            XCTAssertEqual(result.totalAfterDedup, 0, name)
            XCTAssertTrue(result.warnings.isEmpty, "\(name): a rejected request has nothing to warn about")
        }
    }

    func testEmptyResult_hasNoElementsNoTotalNoWarnings() {
        XCTAssertTrue(AXCollectionResult.empty.elements.isEmpty)
        XCTAssertEqual(AXCollectionResult.empty.totalAfterDedup, 0)
        XCTAssertTrue(AXCollectionResult.empty.warnings.isEmpty)
    }
}

// MARK: - Actionable role filter

/// `actionableRoles` is the walk's only content filter, and it feeds a list capped at
/// `AccessibilityWalkPolicy.maxEmittedElements` (140). Admitting a container or text role does not
/// merely add noise: the cap then EVICTS real click targets to make room, which is the failure the
/// retention-priority machinery exists to prevent.
final class AXInspectorRoleFilterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// `AXWebArea` doubles as the marker that flips `web: true` for a subtree. If it were ALSO
    /// actionable, every browser capture would advertise one page-sized element whose centre is
    /// the middle of the page — a coordinate that clicks whatever happens to be there.
    func testWebAreaIsAMarkerNotATarget() {
        XCTAssertFalse(AccessibilityInspector.actionableRoles.contains("AXWebArea"))
    }

    /// Container roles wrap other elements, so their frames cover their children. Emitting them
    /// gives the model an element whose centre is arbitrary AND duplicates every child's region
    /// (dedup will not remove them — it requires matching role AND label).
    func testContainerAndDecorativeRoles_areExcluded() {
        let mustNotBeActionable = [
            "AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup",
            "AXToolbar", "AXList", "AXTable", "AXRow", "AXCell", "AXOutline",
            "AXStaticText", "AXImage", "AXUnknown",
        ]
        for role in mustNotBeActionable {
            XCTAssertFalse(AccessibilityInspector.actionableRoles.contains(role),
                           "\(role) would consume emission-cap slots and evict real targets")
        }
    }

    /// The minimum viable target set. Dropping `AXLink` alone makes every web page unclickable —
    /// the incident shape (a full LinkedIn page reported as chrome only).
    func testCoreClickTargets_arePresent() {
        for role in ["AXButton", "AXLink", "AXTextField", "AXMenuItem", "AXCheckBox", "AXPopUpButton"] {
            XCTAssertTrue(AccessibilityInspector.actionableRoles.contains(role), role)
        }
    }

    /// Labels ship on every capture, once per element, many times per step. The cap must stay
    /// small enough that a worst-case list cannot dominate the request: 140 elements at the label
    /// cap is the budget being bounded here.
    func testLabelCap_boundsWorstCasePayload() {
        XCTAssertGreaterThan(AccessibilityInspector.maxLabelChars, 0)
        XCTAssertLessThanOrEqual(
            AccessibilityInspector.maxLabelChars * AccessibilityWalkPolicy.maxEmittedElements, 20_000,
            "worst-case label payload per capture must stay well under a context window")
    }
}
