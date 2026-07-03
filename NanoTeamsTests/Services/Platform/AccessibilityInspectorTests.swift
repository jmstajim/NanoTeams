import XCTest

@testable import NanoTeams

/// Pure pins for the AX element post-processing: clickable centers, nested-duplicate dedup,
/// click-point containment echo + warning truth table, window-frame matching, and the wire
/// shape. No live AX calls.
final class AccessibilityInspectorTests: XCTestCase {

    private func make(
        role: String = "AXButton", label: String = "Id",
        x: Int, y: Int, w: Int, h: Int, web: Bool = false
    ) -> AXElementInfo {
        let c = AccessibilityInspector.clampedCenter(x: x, y: y, w: w, h: h, pixelWidth: 10_000, pixelHeight: 10_000)
        return AXElementInfo(role: role, label: label, x: x, y: y, w: w, h: h, cx: c.cx, cy: c.cy, web: web)
    }

    // MARK: - clampedCenter

    func testClampedCenter_fullyInside_isGeometricCenter() {
        let c = AccessibilityInspector.clampedCenter(x: 10, y: 20, w: 100, h: 50, pixelWidth: 500, pixelHeight: 500)
        XCTAssertEqual(c.cx, 60)
        XCTAssertEqual(c.cy, 45)
    }

    func testClampedCenter_straddlingLeftEdge_centersVisiblePart() {
        // Element starts off-image (x = -40); its geometric center (10) differs from the
        // center of the VISIBLE strip [0, 60) — the visible center is the clickable one.
        let c = AccessibilityInspector.clampedCenter(x: -40, y: 10, w: 100, h: 20, pixelWidth: 500, pixelHeight: 500)
        XCTAssertEqual(c.cx, 30)
        XCTAssertEqual(c.cy, 20)
    }

    func testClampedCenter_straddlingRightEdge_staysInsideImage() {
        let c = AccessibilityInspector.clampedCenter(x: 450, y: 0, w: 100, h: 10, pixelWidth: 500, pixelHeight: 500)
        XCTAssertEqual(c.cx, 475)
        XCTAssertLessThan(c.cx, 500)
        XCTAssertEqual(c.cy, 5)
    }

    func testClampedCenter_onePixelElementAtFarCorner_clampsToLastPixel() {
        let c = AccessibilityInspector.clampedCenter(x: 499, y: 499, w: 1, h: 1, pixelWidth: 500, pixelHeight: 500)
        XCTAssertEqual(c.cx, 499)
        XCTAssertEqual(c.cy, 499)
    }

    func testClampedCenter_elementCoveringWholeImage_isImageCenter() {
        let c = AccessibilityInspector.clampedCenter(x: -100, y: -100, w: 700, h: 700, pixelWidth: 500, pixelHeight: 500)
        XCTAssertEqual(c.cx, 250)
        XCTAssertEqual(c.cy, 250)
    }

    // MARK: - dedupNested

    /// The verbatim production case (Safari start page): a favorite is reported twice — a tall
    /// tile button AND a small label button, same role, same label "Id", frames off by 1 pt.
    /// Strict containment never fires; the coverage threshold must.
    func testDedup_safariFavoriteTilePlusLabel_keepsTileOnly() {
        let tile = make(x: 372, y: 881, w: 104, h: 172)
        let label = make(x: 371, y: 994, w: 107, h: 23)
        let out = AccessibilityInspector.dedupNested([tile, label])
        XCTAssertEqual(out, [tile])
    }

    func testDedup_orderIndependent_smallerDroppedWhenListedFirst() {
        let tile = make(x: 372, y: 881, w: 104, h: 172)
        let label = make(x: 371, y: 994, w: 107, h: 23)
        let out = AccessibilityInspector.dedupNested([label, tile])
        XCTAssertEqual(out, [tile])
    }

    func testDedup_sameLabelDisjointColumns_bothKept() {
        // Two favorites that happen to share a label but sit in different columns —
        // genuinely distinct click targets, must both survive.
        let a = make(x: 371, y: 994, w: 107, h: 23)
        let b = make(x: 858, y: 994, w: 107, h: 23)
        XCTAssertEqual(AccessibilityInspector.dedupNested([a, b]).count, 2)
    }

    func testDedup_differentLabels_bothKept() {
        let a = make(label: "Id", x: 371, y: 994, w: 107, h: 23)
        let b = make(label: "in", x: 372, y: 994, w: 106, h: 23)
        XCTAssertEqual(AccessibilityInspector.dedupNested([a, b]).count, 2)
    }

    func testDedup_differentRoles_bothKept() {
        let a = make(role: "AXButton", x: 371, y: 994, w: 107, h: 23)
        let b = make(role: "AXLink", x: 371, y: 994, w: 107, h: 23)
        XCTAssertEqual(AccessibilityInspector.dedupNested([a, b]).count, 2)
    }

    func testDedup_emptyLabels_neverDeduped() {
        // Icon-only controls legitimately nest (play button covering most of its card);
        // "" == "" must not collapse two DIFFERENT unlabeled controls into one.
        let card = make(label: "", x: 0, y: 0, w: 200, h: 200)
        let play = make(label: "", x: 20, y: 20, w: 160, h: 160)
        XCTAssertEqual(AccessibilityInspector.dedupNested([card, play]).count, 2)
    }

    func testDedup_identicalFrames_keepsFirstOnly() {
        let a = make(x: 371, y: 994, w: 107, h: 23)
        let b = make(x: 371, y: 994, w: 107, h: 23)
        let out = AccessibilityInspector.dedupNested([a, b])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first, a)
    }

    func testDedup_overlapBelowThreshold_bothKept() {
        // ~50% mutual overlap — two adjacent same-label buttons, not a nested duplicate.
        let a = make(x: 0, y: 0, w: 100, h: 20)
        let b = make(x: 50, y: 0, w: 100, h: 20)
        XCTAssertEqual(AccessibilityInspector.dedupNested([a, b]).count, 2)
    }

    func testDedup_zeroAreaElement_neverMatches() {
        let a = make(x: 10, y: 10, w: 0, h: 23)
        let b = make(x: 10, y: 10, w: 100, h: 23)
        XCTAssertEqual(AccessibilityInspector.dedupNested([a, b]).count, 2)
    }

    func testDedup_emptyAndSingle_passThrough() {
        XCTAssertEqual(AccessibilityInspector.dedupNested([]), [])
        let a = make(x: 0, y: 0, w: 10, h: 10)
        XCTAssertEqual(AccessibilityInspector.dedupNested([a]), [a])
    }

    func testDedup_chainOfThree_keepsLargestOnly_anyOrder() {
        // Tile ⊃ label ⊃ inner glyph, all same role+label — only the largest survives,
        // regardless of AX traversal order (largest-first processing).
        let tile = make(x: 0, y: 0, w: 100, h: 170)
        let label = make(x: 0, y: 140, w: 100, h: 23)
        let glyph = make(x: 2, y: 142, w: 96, h: 19)
        XCTAssertEqual(AccessibilityInspector.dedupNested([glyph, label, tile]), [tile])
        XCTAssertEqual(AccessibilityInspector.dedupNested([label, glyph, tile]), [tile])
        XCTAssertEqual(AccessibilityInspector.dedupNested([tile, label, glyph]), [tile])
    }

    func testDedup_outputPreservesInputOrder() {
        let big = make(label: "A", x: 0, y: 0, w: 100, h: 100)
        let other = make(label: "B", x: 300, y: 0, w: 10, h: 10)
        let inner = make(label: "A", x: 5, y: 5, w: 90, h: 90)
        XCTAssertEqual(AccessibilityInspector.dedupNested([other, big, inner]), [other, big])
    }

    // MARK: - elementContaining

    func testElementContaining_pointInsideNested_returnsSmallest() {
        let outer = make(label: "card", x: 0, y: 0, w: 200, h: 200)
        let inner = make(label: "button", x: 50, y: 50, w: 40, h: 20)
        let hit = AccessibilityInspector.elementContaining(imageX: 60, imageY: 55, in: [outer, inner])
        XCTAssertEqual(hit, inner)
    }

    func testElementContaining_pointOutsideAll_returnsNil() {
        // The incident click: (858, 994) with only the two "Id" elements present.
        let tile = make(x: 372, y: 881, w: 104, h: 172)
        let label = make(x: 371, y: 994, w: 107, h: 23)
        XCTAssertNil(AccessibilityInspector.elementContaining(imageX: 858, imageY: 994, in: [tile, label]))
    }

    func testElementContaining_boundsAreHalfOpen() {
        let el = make(x: 10, y: 10, w: 20, h: 20)
        XCTAssertNotNil(AccessibilityInspector.elementContaining(imageX: 10, imageY: 10, in: [el]))
        XCTAssertNotNil(AccessibilityInspector.elementContaining(imageX: 29, imageY: 29, in: [el]))
        XCTAssertNil(AccessibilityInspector.elementContaining(imageX: 30, imageY: 10, in: [el]))
        XCTAssertNil(AccessibilityInspector.elementContaining(imageX: 10, imageY: 30, in: [el]))
    }

    func testElementContaining_emptyList_returnsNil() {
        XCTAssertNil(AccessibilityInspector.elementContaining(imageX: 5, imageY: 5, in: []))
    }

    // MARK: - clickHitWarning

    func testClickHitWarning_hitPresent_noWarning() {
        let el = make(x: 371, y: 994, w: 107, h: 23)
        XCTAssertNil(AccessibilityInspector.clickHitWarning(hit: el, x: 424, y: 1005, hasElements: true))
    }

    func testClickHitWarning_missWithElements_warnsWithCoordsAndAim() {
        let w = AccessibilityInspector.clickHitWarning(hit: nil, x: 858, y: 994, hasElements: true)
        XCTAssertNotNil(w)
        XCTAssertTrue(w?.contains("(858, 994)") ?? false)
        XCTAssertTrue(w?.contains("cx/cy") ?? false)
    }

    func testClickHitWarning_noElementList_staysSilent() {
        // AX-sparse apps (Electron, games) advertise no elements — a miss verdict would be
        // noise on every legitimate click there.
        XCTAssertNil(AccessibilityInspector.clickHitWarning(hit: nil, x: 5, y: 5, hasElements: false))
    }

    // MARK: - bestWindowMatchIndex

    func testWindowMatch_exactFrame_matches() {
        let region = CGRect(x: 890, y: 34, width: 838, height: 1083)
        let frames = [CGRect(x: 0, y: 0, width: 300, height: 200), region]
        XCTAssertEqual(AccessibilityInspector.bestWindowMatchIndex(windowFrames: frames, region: region), 1)
    }

    func testWindowMatch_smallChildWindowInsideRegion_rejected() {
        let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let sheet = CGRect(x: 300, y: 100, width: 400, height: 300)
        XCTAssertNil(AccessibilityInspector.bestWindowMatchIndex(windowFrames: [sheet], region: region))
    }

    func testWindowMatch_hugeWindowContainingRegion_rejected() {
        // Mutual coverage: a window 5× the region merely contains it — not identity.
        let region = CGRect(x: 100, y: 100, width: 400, height: 400)
        let huge = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        XCTAssertNil(AccessibilityInspector.bestWindowMatchIndex(windowFrames: [huge], region: region))
    }

    func testWindowMatch_slightlyShiftedFrame_stillMatches() {
        // Shadow/border slop of a few points must not break identity (80% mutual coverage).
        let region = CGRect(x: 890, y: 34, width: 838, height: 1083)
        let shifted = region.offsetBy(dx: 6, dy: 4)
        XCTAssertEqual(AccessibilityInspector.bestWindowMatchIndex(windowFrames: [shifted], region: region), 0)
    }

    func testWindowMatch_degenerateInputs_returnNil() {
        XCTAssertNil(AccessibilityInspector.bestWindowMatchIndex(windowFrames: [], region: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertNil(AccessibilityInspector.bestWindowMatchIndex(windowFrames: [.null], region: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertNil(AccessibilityInspector.bestWindowMatchIndex(windowFrames: [CGRect(x: 0, y: 0, width: 100, height: 100)], region: .zero))
    }

    // MARK: - wire shape

    func testAXElementInfo_wireCarriesCentersAndSize_notCorner() throws {
        let el = make(x: 371, y: 994, w: 107, h: 23)
        let data = try JSONCoderFactory.makeWireEncoder().encode(el)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["cx"] as? Int, 424)
        XCTAssertEqual(json["cy"] as? Int, 1005)
        XCTAssertEqual(json["w"] as? Int, 107)
        XCTAssertEqual(json["h"] as? Int, 23)
        XCTAssertEqual(json["role"] as? String, "AXButton")
        // Top-left corner intentionally stays off the wire — the incident model clicked it.
        XCTAssertNil(json["x"])
        XCTAssertNil(json["y"])
    }

    func testAXElementInfo_isEncodeOnly_decodingEncodedThrows() throws {
        // The wire shape is deliberately narrower than storage: `encode(to:)` omits x/y (and web
        // when false), but the synthesized `init(from:)` requires ALL stored keys. So an encoded
        // element is NOT round-trippable — decoding throws. No production path decodes AXElementInfo
        // (it's write-side/in-memory only); this pins the asymmetry so a future decode path fails
        // loudly in tests instead of silently at runtime. If this ever STOPS throwing, the shapes
        // have converged and it should become a round-trip pin.
        let encoded = try JSONCoderFactory.makeWireEncoder().encode(make(x: 0, y: 0, w: 10, h: 10))
        XCTAssertThrowsError(try JSONCoderFactory.makeWireDecoder().decode(AXElementInfo.self, from: encoded))
    }

    func testAXElementInfo_wireEncodesWebOnlyWhenTrue() throws {
        // Chrome/native elements must NOT pay the extra key — token cost only where it informs.
        let chrome = try JSONSerialization.jsonObject(
            with: JSONCoderFactory.makeWireEncoder().encode(make(x: 0, y: 0, w: 10, h: 10))) as? [String: Any]
        XCTAssertNil(chrome?["web"])
        let web = try JSONSerialization.jsonObject(
            with: JSONCoderFactory.makeWireEncoder().encode(make(x: 0, y: 0, w: 10, h: 10, web: true))) as? [String: Any]
        XCTAssertEqual(web?["web"] as? Bool, true)
    }

    func testDedup_webFlagDoesNotAffectDedup() {
        // Dedup keys on role + label + coverage — a web/chrome disagreement between two
        // reports of the same control must not resurrect the duplicate.
        let tile = make(x: 372, y: 881, w: 104, h: 172, web: true)
        let label = make(x: 371, y: 994, w: 107, h: 23, web: false)
        XCTAssertEqual(AccessibilityInspector.dedupNested([tile, label]), [tile])
    }

    // MARK: - staleCaptureWarning

    func testStaleCaptureWarning_zeroActions_silent() {
        XCTAssertNil(AccessibilityInspector.staleCaptureWarning(actionsSinceCapture: 0))
        XCTAssertNil(AccessibilityInspector.staleCaptureWarning(actionsSinceCapture: -1))
    }

    func testStaleCaptureWarning_countsAndAdvisesRecapture() {
        let one = AccessibilityInspector.staleCaptureWarning(actionsSinceCapture: 1)
        XCTAssertTrue(one?.contains("1 action has") ?? false)
        XCTAssertTrue(one?.contains("screen_capture") ?? false, "the cure must be named")
        let three = AccessibilityInspector.staleCaptureWarning(actionsSinceCapture: 3)
        XCTAssertTrue(three?.contains("3 actions have") ?? false)
        XCTAssertTrue(three?.contains("element_at_point") ?? false,
                      "must flag that the echo itself may be stale")
    }
}
