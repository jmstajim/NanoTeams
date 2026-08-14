import XCTest

@testable import NanoTeams

// Coverage for the parts of `AccessibilityInspector` that are pure but were previously reachable
// only from inside the live-AX walk, plus the frame-mapping edge cases that decide whether the
// coordinates the model is handed are usable at all.
//
// NOTHING here touches a real accessibility tree: no `collectElements` against a live pid, no
// `AXEnhancedUserInterface` write into another process, no synthesized input. The walk itself
// (`walk`, `runWalk`, `windowMatchingRegion`, `enableWebAccessibility`, `stringAttr`, `frame(of:)`,
// `children(of:)`) stays deliberately untested — it is synchronous AX IPC whose only observable
// behaviour requires a target application.

// MARK: - Post-walk finalization

/// `finalize` is the whole tail of `collectElements`: dedup → emission cap → warnings → wire
/// result. Its ORDER is load-bearing and had no test — capping before dedup would evict real click
/// targets to make room for copies dedup is about to delete, and the model would be told the list
/// was truncated when it wasn't.
final class AXInspectorFinalizationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private static let cap = AccessibilityWalkPolicy.maxEmittedElements

    private func make(
        role: String = "AXButton", label: String,
        x: Int, y: Int = 0, w: Int = 80, h: Int = 80, web: Bool = false
    ) -> AXElementInfo {
        let c = AccessibilityInspector.clampedCenter(
            x: x, y: y, w: w, h: h, pixelWidth: 1_000_000, pixelHeight: 1_000_000)
        return AXElementInfo(role: role, label: label, x: x, y: y, w: w, h: h,
                             cx: c.cx, cy: c.cy, web: web)
    }

    /// `n` distinct, disjoint, labelled elements — dedup is a no-op over them (it requires a
    /// matching label), so any change in the output size comes from the cap alone.
    private func distinct(_ n: Int, web: Bool = false, prefix: String = "el") -> [AXElementInfo] {
        (0..<n).map { make(label: "\(prefix)\($0)", x: $0 * 100, web: web) }
    }

    /// A same-role/same-label copy fully inside `original` — the shape `dedupNested` collapses.
    private func nestedCopy(of original: AXElementInfo) -> AXElementInfo {
        make(label: original.label, x: original.x + 5, y: original.y + 5, w: original.w - 10, h: original.h - 10)
    }

    // MARK: empty / clean

    func testFinalize_emptyWalk_producesTheEmptyResultAndSaysNothing() {
        let out = AccessibilityInspector.finalize(
            elements: [], sawWebArea: false, stoppedEarly: false, visitedNodes: 0)
        XCTAssertTrue(out.elements.isEmpty)
        XCTAssertEqual(out.totalAfterDedup, 0)
        XCTAssertTrue(out.warnings.isEmpty, "a clean empty walk has nothing to warn about")
    }

    func testFinalize_cleanUnderCapWalk_isSilentAndPassesElementsThrough() {
        let els = distinct(12)
        let out = AccessibilityInspector.finalize(
            elements: els, sawWebArea: false, stoppedEarly: false, visitedNodes: 400)
        XCTAssertEqual(out.elements, els, "order and content preserved verbatim")
        XCTAssertEqual(out.totalAfterDedup, 12)
        XCTAssertTrue(out.warnings.isEmpty)
    }

    // MARK: dedup happens BEFORE the cap

    /// The invariant the pipeline order exists for. Exactly `cap` real targets plus a handful of
    /// nested duplicates: dedup deletes the duplicates, so nothing is truncated and every real
    /// target survives. Capping first would keep `cap` entries INCLUDING the duplicates, delete
    /// them afterwards, and hand the model fewer targets than it could have had — plus a
    /// truncation warning about a list that fits.
    func testFinalize_dedupRunsBeforeTheCap_soDuplicatesNeverEvictRealTargets() {
        let targets = distinct(Self.cap)
        // Duplicates FIRST in document order, so a cap-first pipeline would spend its earliest
        // slots on them and push genuine targets off the end.
        let raw = targets.prefix(5).map(nestedCopy(of:)) + targets

        let out = AccessibilityInspector.finalize(
            elements: Array(raw), sawWebArea: false, stoppedEarly: false, visitedNodes: 900)

        XCTAssertEqual(out.elements, targets, "every real target survives, in document order")
        XCTAssertEqual(out.totalAfterDedup, Self.cap, "the post-dedup total is what gets reported")
        XCTAssertTrue(out.warnings.isEmpty, "nothing was actually dropped, so nothing may be claimed")
    }

    func testFinalize_totalAfterDedupCountsTheDedupedList_notTheRawWalk() {
        let big = make(label: "Id", x: 0, w: 100, h: 100)
        let out = AccessibilityInspector.finalize(
            elements: [big, nestedCopy(of: big), make(label: "Other", x: 400)],
            sawWebArea: false, stoppedEarly: false, visitedNodes: 30)
        XCTAssertEqual(out.elements.count, 2)
        XCTAssertEqual(out.totalAfterDedup, 2, "the raw walk saw 3; the model is offered 2")
    }

    // MARK: the emission cap at its production limit

    func testFinalize_exactlyAtCap_isNotTruncatedAndDoesNotWarn() {
        let els = distinct(Self.cap)
        let out = AccessibilityInspector.finalize(
            elements: els, sawWebArea: false, stoppedEarly: false, visitedNodes: 500)
        XCTAssertEqual(out.elements.count, Self.cap)
        XCTAssertEqual(out.elements, els)
        XCTAssertTrue(out.warnings.isEmpty)
    }

    func testFinalize_oneOverCap_dropsExactlyOneAndNamesBothCounts() {
        let els = distinct(Self.cap + 1)
        let out = AccessibilityInspector.finalize(
            elements: els, sawWebArea: false, stoppedEarly: false, visitedNodes: 500)
        XCTAssertEqual(out.elements.count, Self.cap)
        XCTAssertEqual(out.totalAfterDedup, Self.cap + 1)
        XCTAssertEqual(out.warnings.count, 1)
        XCTAssertTrue(out.warnings[0].contains("\(Self.cap) of \(Self.cap + 1)"),
                      "no silent caps — the drop must be countable from the warning")
        // Same tier throughout, so the survivors are the earliest in document order.
        XCTAssertEqual(out.elements, Array(els.prefix(Self.cap)))
    }

    /// Overflow at the production limit must evict browser chrome before page content — the
    /// incident shape (a favourites bar crowding out a LinkedIn feed). Existing coverage pins this
    /// against arbitrary small limits; this pins it through the pipeline at the real cap.
    func testFinalize_overflowAtProductionCap_keepsEveryLabelledWebElement() {
        let chrome = (0..<Self.cap).map { make(label: "", x: $0 * 100) }        // unlabeled chrome
        let page = distinct(10, web: true, prefix: "post")                       // labeled web
        let out = AccessibilityInspector.finalize(
            elements: chrome + page, sawWebArea: true, stoppedEarly: false, visitedNodes: 2000)

        XCTAssertEqual(out.elements.count, Self.cap)
        XCTAssertEqual(out.elements.filter(\.web), page, "page content is never the thing evicted")
        XCTAssertEqual(out.totalAfterDedup, Self.cap + 10)
        XCTAssertTrue(out.warnings.contains { $0.contains("truncated") })
    }

    // MARK: webAreaEmpty

    func testFinalize_webAreaSeenButNothingReadable_warnsThePageIsUnreadable() {
        let out = AccessibilityInspector.finalize(
            elements: distinct(3), sawWebArea: true, stoppedEarly: false, visitedNodes: 200)
        XCTAssertEqual(out.warnings.count, 1)
        XCTAssertTrue(out.warnings[0].contains("browser page"))
        XCTAssertTrue(out.warnings[0].contains("capture again"))
    }

    func testFinalize_webAreaSeenWithWebContent_staysSilent() {
        let out = AccessibilityInspector.finalize(
            elements: distinct(2) + distinct(1, web: true, prefix: "post"),
            sawWebArea: true, stoppedEarly: false, visitedNodes: 200)
        XCTAssertTrue(out.warnings.isEmpty)
    }

    func testFinalize_noWebAreaSeen_neverWarnsAboutABrowserPage() {
        // A native app must not be told its (nonexistent) page failed to load.
        let out = AccessibilityInspector.finalize(
            elements: [], sawWebArea: false, stoppedEarly: false, visitedNodes: 50)
        XCTAssertTrue(out.warnings.isEmpty)
    }

    /// `webAreaEmpty` is judged on the DEDUPED list, i.e. the list the model is actually given —
    /// which is what the warning's wording ("only browser chrome is listed") describes. A web
    /// element that dedup folded into a larger same-role/same-label chrome entry is genuinely
    /// absent from the emitted list, so the warning is accurate rather than over-eager.
    func testFinalize_webElementFoldedIntoChromeByDedup_stillCountsAsAnUnreadablePage() {
        let chromeTile = make(label: "Post", x: 0, w: 120, h: 120, web: false)
        let webLabel = make(label: "Post", x: 5, y: 5, w: 100, h: 100, web: true)
        let out = AccessibilityInspector.finalize(
            elements: [chromeTile, webLabel], sawWebArea: true, stoppedEarly: false, visitedNodes: 80)

        XCTAssertEqual(out.elements, [chromeTile])
        XCTAssertTrue(out.warnings.contains { $0.contains("browser page") },
                      "the emitted list carries no web element, and that is what is announced")
    }

    // MARK: stoppedEarly + composition

    func testFinalize_stoppedEarly_reportsTheNodeCountItGotThrough() {
        let out = AccessibilityInspector.finalize(
            elements: distinct(4), sawWebArea: false, stoppedEarly: true, visitedNodes: 3000)
        XCTAssertEqual(out.warnings.count, 1)
        XCTAssertTrue(out.warnings[0].contains("stopped early"))
        XCTAssertTrue(out.warnings[0].contains("3000 nodes"))
    }

    /// All three cuts at once. Order matters only in that the model reads them top-down; pinning it
    /// keeps the capture envelope byte-stable across runs (prompt-prefix stability).
    func testFinalize_everyCutAtOnce_composesAllThreeWarningsInOrder() {
        let els = distinct(Self.cap + 60) + distinct(1, prefix: "z")
        let out = AccessibilityInspector.finalize(
            elements: els, sawWebArea: true, stoppedEarly: true, visitedNodes: 3000)
        XCTAssertEqual(out.warnings.count, 3)
        XCTAssertTrue(out.warnings[0].contains("stopped early"))
        XCTAssertTrue(out.warnings[1].contains("truncated"))
        XCTAssertTrue(out.warnings[2].contains("browser page"))
    }
}

// MARK: - Label normalization

/// `normalizedLabel` is the only place the per-element label budget is enforced. Labels ship on
/// every capture, once per element, many times per step — an unenforced cap turns one pathological
/// `AXValue` (a text area's entire contents) into thousands of tokens.
final class AXInspectorLabelNormalizationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private static let cap = AccessibilityInspector.maxLabelChars

    func testNormalize_nilAttribute_becomesEmptyString() {
        // An element with no title/value/description is unlabeled, not absent — the emission cap's
        // lowest retention tier depends on `label.isEmpty` being reachable.
        XCTAssertEqual(AccessibilityInspector.normalizedLabel(nil), "")
    }

    func testNormalize_whitespaceOnlyLabel_becomesEmpty() {
        // A whitespace-only label must read as UNLABELED, or dedup would treat two such elements as
        // the same control ("   " == "   ") and silently drop one of them.
        XCTAssertEqual(AccessibilityInspector.normalizedLabel("   \n\t "), "")
    }

    func testNormalize_trimsSurroundingWhitespaceButKeepsInteriorSpacing() {
        XCTAssertEqual(AccessibilityInspector.normalizedLabel("  Sign in  "), "Sign in")
        XCTAssertEqual(AccessibilityInspector.normalizedLabel("\nPost\n"), "Post")
    }

    func testNormalize_exactlyAtCap_isLeftAlone() {
        let label = String(repeating: "a", count: Self.cap)
        let out = AccessibilityInspector.normalizedLabel(label)
        XCTAssertEqual(out, label)
        XCTAssertFalse(out.hasSuffix("…"), "a label that fits must not be marked as truncated")
    }

    func testNormalize_oneOverCap_truncatesToCapPlusAnEllipsis() {
        let out = AccessibilityInspector.normalizedLabel(String(repeating: "a", count: Self.cap + 1))
        XCTAssertEqual(out.count, Self.cap + 1)
        XCTAssertTrue(out.hasSuffix("…"), "truncation must be visible — a silent cut reads as the real label")
        XCTAssertEqual(String(out.dropLast()), String(repeating: "a", count: Self.cap))
    }

    /// Trim runs BEFORE the cap. Padding is not content, so it must not spend cap budget and push
    /// real characters out of a label that would otherwise fit whole.
    func testNormalize_trimHappensBeforeTheCap() {
        let padded = "   " + String(repeating: "b", count: Self.cap) + "   "
        let out = AccessibilityInspector.normalizedLabel(padded)
        XCTAssertEqual(out, String(repeating: "b", count: Self.cap))
        XCTAssertFalse(out.hasSuffix("…"))
    }

    /// Truncation is by `Character`, so a multi-scalar grapheme cluster is never split. Cutting
    /// mid-cluster would emit a lone ZWJ / orphan skin-tone modifier — still valid UTF-8, but a
    /// label the model cannot match against anything it sees on screen.
    func testNormalize_nonBMPGraphemeClusters_areNeverSplit() {
        let family = "👨‍👩‍👧‍👦"                       // one Character, several scalars
        let long = String(repeating: family, count: Self.cap + 10)
        let out = AccessibilityInspector.normalizedLabel(long)

        XCTAssertEqual(out.count, Self.cap + 1, "cap counts Characters, and the ellipsis is one more")
        XCTAssertEqual(String(out.dropLast()), String(repeating: family, count: Self.cap))
        XCTAssertTrue(out.dropLast().allSatisfy { String($0) == family },
                      "no partial cluster survived the cut")
    }

    func testNormalize_combiningMarks_countAsOneCharacter() {
        let e = "e\u{0301}"                              // e + combining acute = one Character
        let out = AccessibilityInspector.normalizedLabel(String(repeating: e, count: Self.cap))
        XCTAssertFalse(out.hasSuffix("…"), "\(Self.cap) combining pairs are \(Self.cap) Characters, not \(Self.cap * 2)")
        XCTAssertEqual(out.count, Self.cap)
    }

    /// The cap is a WIRE budget, so pin it where the bytes are produced: a pathological AX value
    /// must not be able to inflate one element's encoded label without bound.
    func testNormalize_boundsTheEncodedLabelOnTheWire() throws {
        let huge = AccessibilityInspector.normalizedLabel(String(repeating: "x", count: 50_000))
        let el = AXElementInfo(role: "AXTextArea", label: huge, x: 0, y: 0, w: 10, h: 10,
                               cx: 5, cy: 5, web: false)
        let data = try JSONCoderFactory.makeWireEncoder().encode(el)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["label"] as? String)?.count, Self.cap + 1)
    }
}

// MARK: - Frame mapping: delegation, edges, and untrusted geometry

/// `Geometry.mapFrame` is the single conversion from an AX frame (CoreGraphics global TOP-LEFT
/// points) into the screenshot's pixel space. Two failure modes matter: drifting from the click
/// map's inverse (every click then misses by a constant factor), and accepting geometry that the
/// integer rect cannot honestly represent.
final class AXInspectorFrameMappingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func geometry(
        originX: Double = 0, originY: Double = 0,
        regionW: Double = 1000, regionH: Double = 1000,
        pxW: Int = 500, pxH: Int = 500
    ) -> AccessibilityInspector.Geometry {
        AccessibilityInspector.Geometry(
            originX: originX, originY: originY,
            regionWidthPt: regionW, regionHeightPt: regionH,
            pixelWidth: pxW, pixelHeight: pxH)
    }

    // MARK: delegation to the shared inverse

    /// Differential pin: `mapFrame`'s corner must be exactly what
    /// `InputControlService.globalPointToImagePixel` returns (rounded), and its size must use the
    /// reciprocal of the SAME ratio. Hand-rolled math here — a `backing_scale`, an NSScreen-derived
    /// origin, a bottom-left flip — is invisible in a single-case test but shifts every advertised
    /// coordinate; this compares the two across a grid instead.
    private struct Setup {
        let name: String
        let originX: Double, originY: Double
        let regionW: Double, regionH: Double
        let pxW: Int, pxH: Int

        var geometry: AccessibilityInspector.Geometry {
            AccessibilityInspector.Geometry(
                originX: originX, originY: originY,
                regionWidthPt: regionW, regionHeightPt: regionH,
                pixelWidth: pxW, pixelHeight: pxH)
        }
    }

    func testMapFrame_cornerAndSizeDelegateToTheSharedClickInverse() {
        let setups: [Setup] = [
            Setup(name: "1:1", originX: 0, originY: 0, regionW: 1000, regionH: 1000, pxW: 1000, pxH: 1000),
            Setup(name: "downscale", originX: 0, originY: 0, regionW: 1000, regionH: 1000, pxW: 500, pxH: 500),
            Setup(name: "upscale", originX: 0, originY: 0, regionW: 500, regionH: 500, pxW: 1000, pxH: 1000),
            Setup(name: "secondary display", originX: -1440, originY: 200,
                  regionW: 1440, regionH: 900, pxW: 720, pxH: 450),
            Setup(name: "non-square", originX: 0, originY: 0, regionW: 2000, regionH: 500, pxW: 1000, pxH: 1000),
        ]
        var compared = 0
        for s in setups {
            let geom = s.geometry
            for dx in stride(from: 0.0, through: 400.0, by: 37.0) {
                for dy in stride(from: 0.0, through: 400.0, by: 53.0) {
                    let frame = CGRect(x: s.originX + dx, y: s.originY + dy, width: 41, height: 23)
                    guard let mapped = geom.mapFrame(frame) else { continue }
                    guard let shared = InputControlService.globalPointToImagePixel(
                        globalX: Double(frame.minX), globalY: Double(frame.minY),
                        originX: s.originX, originY: s.originY,
                        regionWidthPt: s.regionW, regionHeightPt: s.regionH,
                        pixelWidth: s.pxW, pixelHeight: s.pxH) else {
                        XCTFail("\(s.name): the shared inverse rejected an in-region point")
                        continue
                    }
                    let expectedW = Int((41.0 * Double(s.pxW) / s.regionW).rounded())
                    let expectedH = Int((23.0 * Double(s.pxH) / s.regionH).rounded())
                    XCTAssertEqual(mapped.x, Int(shared.x.rounded()), "\(s.name) x @\(frame)")
                    XCTAssertEqual(mapped.y, Int(shared.y.rounded()), "\(s.name) y @\(frame)")
                    XCTAssertEqual(mapped.w, expectedW, "\(s.name) w @\(frame)")
                    XCTAssertEqual(mapped.h, expectedH, "\(s.name) h @\(frame)")
                    compared += 1
                }
            }
        }
        XCTAssertGreaterThan(compared, 100, "the sweep must actually compare something")
    }

    // MARK: the advertised centre must be inside the advertised box

    /// The property a marginal element used to violate: `clampedCenter` clamps a centre back INTO
    /// the image, but the rounded `(x, w)` box shipped beside it could sit entirely outside. The
    /// model is told to click `cx`/`cy`; `elementContaining` then resolves that very point against
    /// the very same list and finds nothing, so `clickHitWarning` fires — telling the model its
    /// click missed everything at the coordinate the tool handed it.
    ///
    /// Swept across both far edges and both near edges at sub-pixel offsets, because the failure
    /// only appears when the corner rounds ACROSS an image boundary.
    func testMapFrame_advertisedCentreIsAlwaysInsideItsOwnAdvertisedBox() {
        let geom = geometry()   // 1000pt → 500px, ratio 0.5
        var advertised = 0
        // tenths of a point, sweeping the far edge (x ≈ 1000pt → 500px) and the near edge (x ≈ 0).
        let offsets = stride(from: -60, through: 20, by: 1).map { Double($0) / 10.0 }
            + stride(from: 9_940, through: 10_020, by: 1).map { Double($0) / 10.0 }
        for offset in offsets {
            for frame in [CGRect(x: offset, y: 100, width: 4, height: 40),
                          CGRect(x: 100, y: offset, width: 40, height: 4)] {
                guard let m = geom.mapFrame(frame) else { continue }
                advertised += 1
                let c = AccessibilityInspector.clampedCenter(
                    x: m.x, y: m.y, w: m.w, h: m.h, pixelWidth: 500, pixelHeight: 500)
                let el = AXElementInfo(role: "AXButton", label: "Edge",
                                       x: m.x, y: m.y, w: m.w, h: m.h, cx: c.cx, cy: c.cy, web: false)
                XCTAssertNotNil(
                    AccessibilityInspector.elementContaining(imageX: c.cx, imageY: c.cy, in: [el]),
                    "centre (\(c.cx), \(c.cy)) fell outside its own box \(m) for \(frame)")
                XCTAssertNotNil(
                    InputControlService.imagePixelToGlobalPoint(
                        imageX: Double(c.cx), imageY: Double(c.cy),
                        originX: 0, originY: 0, regionWidthPt: 1000, regionHeightPt: 1000,
                        pixelWidth: 500, pixelHeight: 500),
                    "the advertised centre must also be clickable")
            }
        }
        XCTAssertGreaterThan(advertised, 50, "the sweep must actually advertise something")
    }

    /// The concrete boundary behind the sweep: a corner half a pixel inside the far edge rounds to
    /// `pixelWidth`, which is one column past the last captured pixel. It is dropped for the same
    /// reason a sub-pixel element is — there is no pixel the model could see or click.
    func testMapFrame_cornerRoundingOntoTheFarEdge_isDropped() {
        let geom = geometry()   // ratio 0.5
        XCTAssertNil(geom.mapFrame(CGRect(x: 999.2, y: 100, width: 4, height: 40)),
                     "999.2pt → 499.6px → rounds to 500 == pixelWidth")
        XCTAssertNil(geom.mapFrame(CGRect(x: 100, y: 999.2, width: 40, height: 4)))
        // A tenth of a point further in still rounds to 499 and must survive.
        XCTAssertEqual(geom.mapFrame(CGRect(x: 998.8, y: 100, width: 4, height: 40))?.x, 499)
    }

    func testMapFrame_roundedRectEndingAtOrBeforeTheNearEdge_isDropped() {
        let geom = geometry()   // ratio 0.5
        // corner -1.6px, width 1.7px → overlaps pre-rounding (0.1px), but rounds to x=-2, w=2,
        // i.e. columns [-2, 0) — no visible column at all.
        XCTAssertNil(geom.mapFrame(CGRect(x: -3.2, y: 100, width: 3.4, height: 40)))
        XCTAssertNil(geom.mapFrame(CGRect(x: 100, y: -3.2, width: 40, height: 3.4)))
    }

    // MARK: untrusted geometry (another process supplies these numbers)

    /// AX frames come from the TARGET application. Before the guard, a bogus `AXSize` reached
    /// `Int(_: Double)`, which TRAPS rather than throwing — an uncatchable abort of the whole app
    /// from inside the detached walk, triggered by a third party. Dropping the element is the same
    /// outcome the sub-pixel rule already produces.
    func testMapFrame_unrepresentableGeometry_isDroppedRatherThanTrapping() {
        let geom = geometry()
        let hostile: [(String, CGRect)] = [
            ("astronomical width", CGRect(x: 0, y: 0, width: 1e300, height: 40)),
            ("astronomical height", CGRect(x: 0, y: 0, width: 40, height: 1e300)),
            ("astronomical negative origin", CGRect(x: -1e300, y: 0, width: 2e300, height: 40)),
            ("infinite width", CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 40)),
            ("NaN origin", CGRect(x: CGFloat.nan, y: 0, width: 40, height: 40)),
            ("NaN size", CGRect(x: 0, y: 0, width: CGFloat.nan, height: 40)),
        ]
        for (name, frame) in hostile {
            XCTAssertNil(geom.mapFrame(frame), name)
        }
    }

    /// Each side is representable on its own, but `w * h` is not — and that product is computed by
    /// both `dedupNested` and `elementContaining`, where an overflow traps just as hard.
    func testMapFrame_representableSidesWithOverflowingArea_areDropped() {
        let geom = geometry()   // ratio 0.5 → each side maps to 5e18, comfortably inside Int…
        XCTAssertNil(geom.mapFrame(CGRect(x: 0, y: 0, width: 1e19, height: 1e19)),
                     "…but 5e18 × 5e18 is not, and the area is taken downstream")
    }

    /// End-to-end: whatever survives `mapFrame` can be fed through the full post-processing
    /// pipeline without tripping an area computation.
    func testMapFrame_survivorsAreSafeToDedupAndFinalize() {
        let geom = geometry()
        let frames = [CGRect(x: 0, y: 0, width: 1e19, height: 1e19),
                      CGRect(x: -1e300, y: 0, width: 2e300, height: 40),
                      CGRect(x: 10, y: 10, width: 100, height: 40),
                      CGRect(x: 12, y: 12, width: 96, height: 36)]
        let elements: [AXElementInfo] = frames.compactMap { frame in
            guard let m = geom.mapFrame(frame) else { return nil }
            let c = AccessibilityInspector.clampedCenter(
                x: m.x, y: m.y, w: m.w, h: m.h, pixelWidth: 500, pixelHeight: 500)
            return AXElementInfo(role: "AXButton", label: "Same", x: m.x, y: m.y, w: m.w, h: m.h,
                                 cx: c.cx, cy: c.cy, web: false)
        }
        XCTAssertEqual(elements.count, 2, "the two hostile frames are dropped, the two real ones survive")
        let out = AccessibilityInspector.finalize(
            elements: elements, sawWebArea: false, stoppedEarly: false, visitedNodes: 4)
        XCTAssertEqual(out.elements.count, 1, "the nested same-label copy is deduped away")
    }

    // MARK: degenerate + edge frames

    func testMapFrame_zeroSizedFrame_isDropped() {
        let geom = geometry()
        XCTAssertNil(geom.mapFrame(CGRect(x: 100, y: 100, width: 0, height: 40)))
        XCTAssertNil(geom.mapFrame(CGRect(x: 100, y: 100, width: 40, height: 0)))
        XCTAssertNil(geom.mapFrame(.zero))
    }

    /// A negative-size AX frame is standardized by `CGRect` itself (`minX`/`width` already describe
    /// the normalized rect), so it maps to the same pixels as its positive twin rather than
    /// producing a negative `w` that would poison every area comparison downstream.
    func testMapFrame_negativeSizedFrame_mapsAsItsStandardizedRect() {
        let geom = geometry()
        let negative = geom.mapFrame(CGRect(x: 200, y: 200, width: -100, height: -40))
        let positive = geom.mapFrame(CGRect(x: 100, y: 160, width: 100, height: 40))
        XCTAssertNotNil(negative)
        XCTAssertEqual(negative?.x, positive?.x)
        XCTAssertEqual(negative?.y, positive?.y)
        XCTAssertEqual(negative?.w, positive?.w)
        XCTAssertGreaterThan(negative?.w ?? -1, 0)
    }

    func testMapFrame_elementFullyOutsideTheRegion_isDroppedOnAllFourSides() {
        let geom = geometry()   // captured region: global 0…1000 pt on both axes
        XCTAssertNil(geom.mapFrame(CGRect(x: -500, y: 100, width: 100, height: 100)), "left")
        XCTAssertNil(geom.mapFrame(CGRect(x: 1200, y: 100, width: 100, height: 100)), "right")
        XCTAssertNil(geom.mapFrame(CGRect(x: 100, y: -500, width: 100, height: 100)), "above")
        XCTAssertNil(geom.mapFrame(CGRect(x: 100, y: 1200, width: 100, height: 100)), "below")
    }

    func testMapFrame_straddlingEachEdge_survivesWithAClickableCentre() {
        let geom = geometry()
        let straddlers: [(String, CGRect)] = [
            ("left", CGRect(x: -80, y: 400, width: 200, height: 60)),
            ("right", CGRect(x: 920, y: 400, width: 200, height: 60)),
            ("top", CGRect(x: 400, y: -80, width: 60, height: 200)),
            ("bottom", CGRect(x: 400, y: 920, width: 60, height: 200)),
            ("whole region", CGRect(x: -200, y: -200, width: 1600, height: 1600)),
        ]
        for (name, frame) in straddlers {
            guard let m = geom.mapFrame(frame) else {
                XCTFail("\(name): a partially visible element must still be advertised")
                continue
            }
            let c = AccessibilityInspector.clampedCenter(
                x: m.x, y: m.y, w: m.w, h: m.h, pixelWidth: 500, pixelHeight: 500)
            XCTAssertTrue((0..<500).contains(c.cx), "\(name) cx")
            XCTAssertTrue((0..<500).contains(c.cy), "\(name) cy")
        }
    }

    func testMapFrame_degenerateGeometry_dropsEverything() {
        // `collectElements` rejects these up front, but `Geometry` is constructible directly and a
        // zero region would otherwise divide by zero and produce infinite pixel sizes.
        XCTAssertNil(geometry(regionW: 0).mapFrame(CGRect(x: 0, y: 0, width: 40, height: 40)))
        XCTAssertNil(geometry(regionH: 0).mapFrame(CGRect(x: 0, y: 0, width: 40, height: 40)))
        XCTAssertNil(geometry(pxW: 0).mapFrame(CGRect(x: 0, y: 0, width: 40, height: 40)))
        XCTAssertNil(geometry(pxH: 0).mapFrame(CGRect(x: 0, y: 0, width: 40, height: 40)))
    }
}
