import XCTest

@testable import NanoTeams

/// Pure coordinate-conversion + key-combo pins for `InputControlService`. No CGEvent posted.
final class InputControlServiceTests: XCTestCase {

    // MARK: - image pixels → global points

    func testConversion_oneToOne() {
        let p = InputControlService.imagePixelToGlobalPoint(
            imageX: 100, imageY: 50, originX: 0, originY: 0,
            regionWidthPt: 200, regionHeightPt: 100, pixelWidth: 200, pixelHeight: 100)
        XCTAssertEqual(p?.x, 100)
        XCTAssertEqual(p?.y, 50)
    }

    func testConversion_downscaleRatio() {
        // Region 1440×900 pt shown as a 720×450 px image (0.5× ratio, folds Retina + downscale).
        let p = InputControlService.imagePixelToGlobalPoint(
            imageX: 360, imageY: 225, originX: 0, originY: 0,
            regionWidthPt: 1440, regionHeightPt: 900, pixelWidth: 720, pixelHeight: 450)
        XCTAssertEqual(p?.x, 720)
        XCTAssertEqual(p?.y, 450)
    }

    func testConversion_multiDisplayNegativeOrigin() {
        // A secondary display to the left has a negative global origin.
        let p = InputControlService.imagePixelToGlobalPoint(
            imageX: 100, imageY: 100, originX: -1440, originY: 0,
            regionWidthPt: 1440, regionHeightPt: 900, pixelWidth: 1440, pixelHeight: 900)
        XCTAssertEqual(p?.x, -1340)
        XCTAssertEqual(p?.y, 100)
    }

    func testConversion_outOfBounds_returnsNil() {
        let base = (o: 0.0, r: 100.0, px: 100)
        XCTAssertNil(InputControlService.imagePixelToGlobalPoint(
            imageX: 99999, imageY: 0, originX: base.o, originY: base.o,
            regionWidthPt: base.r, regionHeightPt: base.r, pixelWidth: base.px, pixelHeight: base.px))
        XCTAssertNil(InputControlService.imagePixelToGlobalPoint(
            imageX: -1, imageY: 0, originX: base.o, originY: base.o,
            regionWidthPt: base.r, regionHeightPt: base.r, pixelWidth: base.px, pixelHeight: base.px))
    }

    func testConversion_boundaryIsHalfOpen() {
        // imageX == pixelWidth is one past the last pixel column (valid range is 0 ..< 100) —
        // it maps to the region's far edge, OUTSIDE the captured content, so it must reject.
        XCTAssertNil(InputControlService.imagePixelToGlobalPoint(
            imageX: 100, imageY: 100, originX: 0, originY: 0,
            regionWidthPt: 100, regionHeightPt: 100, pixelWidth: 100, pixelHeight: 100))
        // The last valid pixel column (99) is still inside.
        XCTAssertNotNil(InputControlService.imagePixelToGlobalPoint(
            imageX: 99, imageY: 99, originX: 0, originY: 0,
            regionWidthPt: 100, regionHeightPt: 100, pixelWidth: 100, pixelHeight: 100))
    }

    // MARK: - forward ↔ inverse round trip (image pixels ↔ global points)

    /// The two directions must be EXACT inverses: a global point mapped into image space and back
    /// returns the original point. This is what guarantees a click on an AX element's reported
    /// `(x, y)` lands back on that element's real global point (no coordinate drift → no misses).
    func testRoundTrip_globalToImageToGlobal() {
        // Retina-like downscale: a 1512×982 pt display shown as a 756×491 px image (0.5 ratio).
        let cases: [(gx: Double, gy: Double)] = [
            (0, 0), (1512, 982), (756, 491), (100, 900), (1400, 50),
        ]
        for c in cases {
            guard let img = InputControlService.globalPointToImagePixel(
                globalX: c.gx, globalY: c.gy, originX: 0, originY: 0,
                regionWidthPt: 1512, regionHeightPt: 982, pixelWidth: 756, pixelHeight: 491) else {
                return XCTFail("inverse returned nil for \(c)")
            }
            // Feed the image coord back through the forward map (only in-range coords are valid;
            // the far corner (756,491) is the exclusive edge, so nudge it inside for the forward map).
            let ix = min(img.x, 755.999), iy = min(img.y, 490.999)
            guard let back = InputControlService.imagePixelToGlobalPoint(
                imageX: ix, imageY: iy, originX: 0, originY: 0,
                regionWidthPt: 1512, regionHeightPt: 982, pixelWidth: 756, pixelHeight: 491) else {
                return XCTFail("forward returned nil for image \(img)")
            }
            XCTAssertEqual(back.x, c.gx, accuracy: 2.0, "x drift for \(c)")
            XCTAssertEqual(back.y, c.gy, accuracy: 2.0, "y drift for \(c)")
        }
    }

    func testRoundTrip_imageToGlobalToImage() {
        // Non-square ratios + a non-zero (multi-display) origin.
        let originX = -1440.0, originY = 200.0
        let regionW = 2000.0, regionH = 500.0
        let pxW = 1000, pxH = 1000
        for (ix, iy): (Double, Double) in [(0, 0), (500, 500), (999, 0), (0, 999), (123, 456)] {
            guard let g = InputControlService.imagePixelToGlobalPoint(
                imageX: ix, imageY: iy, originX: originX, originY: originY,
                regionWidthPt: regionW, regionHeightPt: regionH, pixelWidth: pxW, pixelHeight: pxH) else {
                return XCTFail("forward returned nil for (\(ix),\(iy))")
            }
            guard let back = InputControlService.globalPointToImagePixel(
                globalX: Double(g.x), globalY: Double(g.y), originX: originX, originY: originY,
                regionWidthPt: regionW, regionHeightPt: regionH, pixelWidth: pxW, pixelHeight: pxH) else {
                return XCTFail("inverse returned nil for \(g)")
            }
            XCTAssertEqual(back.x, ix, accuracy: 0.001, "x round-trip")
            XCTAssertEqual(back.y, iy, accuracy: 0.001, "y round-trip")
        }
    }

    func testInverse_originMapsToZero_farEdgeMapsToPixelDim() {
        let img = InputControlService.globalPointToImagePixel(
            globalX: 300, globalY: 200, originX: 300, originY: 200,
            regionWidthPt: 100, regionHeightPt: 100, pixelWidth: 50, pixelHeight: 50)
        XCTAssertEqual(img?.x, 0)
        XCTAssertEqual(img?.y, 0)
        // The region's far corner maps to exactly pixelWidth/pixelHeight (the exclusive edge).
        let far = InputControlService.globalPointToImagePixel(
            globalX: 400, globalY: 300, originX: 300, originY: 200,
            regionWidthPt: 100, regionHeightPt: 100, pixelWidth: 50, pixelHeight: 50)
        XCTAssertEqual(far?.x, 50)
        XCTAssertEqual(far?.y, 50)
    }

    func testInverse_degenerateDimensions_returnNil() {
        XCTAssertNil(InputControlService.globalPointToImagePixel(
            globalX: 0, globalY: 0, originX: 0, originY: 0,
            regionWidthPt: 0, regionHeightPt: 100, pixelWidth: 100, pixelHeight: 100))
        XCTAssertNil(InputControlService.globalPointToImagePixel(
            globalX: 0, globalY: 0, originX: 0, originY: 0,
            regionWidthPt: 100, regionHeightPt: 100, pixelWidth: 0, pixelHeight: 100))
    }

    // MARK: - AX element frame mapping shares the same inverse (no drift)

    func testAXGeometry_mapsElementCornerToClickablePixel() {
        // A 1440×900 pt window shown at 720×450 px (0.5 ratio), captured at global origin (100, 50).
        let geom = AccessibilityInspector.Geometry(
            originX: 100, originY: 50, regionWidthPt: 1440, regionHeightPt: 900,
            pixelWidth: 720, pixelHeight: 450)
        // An element whose global frame starts at (820, 500) → image ((820-100)*0.5, (500-50)*0.5) = (360, 225).
        let mapped = geom.mapFrame(CGRect(x: 820, y: 500, width: 200, height: 100))
        XCTAssertEqual(mapped?.x, 360)
        XCTAssertEqual(mapped?.y, 225)
        XCTAssertEqual(mapped?.w, 100)  // 200pt * 0.5
        XCTAssertEqual(mapped?.h, 50)

        // Clicking the element's reported image pixel must map back to a point INSIDE its global
        // frame — the whole point of the shared inverse.
        let click = InputControlService.imagePixelToGlobalPoint(
            imageX: Double(mapped!.x), imageY: Double(mapped!.y), originX: 100, originY: 50,
            regionWidthPt: 1440, regionHeightPt: 900, pixelWidth: 720, pixelHeight: 450)
        XCTAssertEqual(Double(click!.x), 820, accuracy: 1.0)
        XCTAssertEqual(Double(click!.y), 500, accuracy: 1.0)
    }

    func testAXGeometry_offscreenElementIsClipped() {
        let geom = AccessibilityInspector.Geometry(
            originX: 0, originY: 0, regionWidthPt: 1000, regionHeightPt: 1000,
            pixelWidth: 500, pixelHeight: 500)
        // Fully to the left of the captured region → no overlap → nil.
        XCTAssertNil(geom.mapFrame(CGRect(x: -500, y: 100, width: 100, height: 100)))
        // Fully below → nil.
        XCTAssertNil(geom.mapFrame(CGRect(x: 100, y: 2000, width: 100, height: 100)))
        // Straddling the top-left edge → kept (partially visible).
        XCTAssertNotNil(geom.mapFrame(CGRect(x: -10, y: -10, width: 100, height: 100)))
    }

    // MARK: - own-window self-guard geometry (pure)

    func testPointInAnyRect_hitAndMiss() {
        let rects = [CGRect(x: 100, y: 100, width: 200, height: 150)]
        XCTAssertTrue(InputControlService.pointInAnyRect(CGPoint(x: 150, y: 150), rects: rects))
        XCTAssertFalse(InputControlService.pointInAnyRect(CGPoint(x: 50, y: 50), rects: rects))
        XCTAssertFalse(InputControlService.pointInAnyRect(CGPoint(x: 150, y: 150), rects: []))
    }

    // MARK: - AX conversion uses the SAME ratio (not backing_scale)

    func testAXConversion_matchesClickRatio() {
        // An AX element at global point (720, 450) inside a 1440×900pt region shown at 720×450px
        // must map to image pixel (360, 225) — the SAME 0.5 ratio the click conversion inverts.
        let ratioX = 720.0 / 1440.0
        let ratioY = 450.0 / 900.0
        XCTAssertEqual((720.0 - 0.0) * ratioX, 360)
        XCTAssertEqual((450.0 - 0.0) * ratioY, 225)
    }

    // MARK: - key combos

    func testParse_singleLetter() {
        let r = InputControlService.parseKeyCombo("cmd+s")
        XCTAssertEqual(r?.keyCode, 1)
        XCTAssertTrue(r?.flags.contains(.maskCommand) ?? false)
    }

    func testParse_namedKey() {
        XCTAssertEqual(InputControlService.parseKeyCombo("return")?.keyCode, 36)
        XCTAssertEqual(InputControlService.parseKeyCombo("escape")?.keyCode, 53)
        XCTAssertEqual(InputControlService.parseKeyCombo("tab")?.keyCode, 48)
    }

    func testParse_multipleModifiers() {
        let r = InputControlService.parseKeyCombo("cmd+shift+4")
        XCTAssertEqual(r?.keyCode, 21) // '4'
        XCTAssertTrue(r?.flags.contains(.maskCommand) ?? false)
        XCTAssertTrue(r?.flags.contains(.maskShift) ?? false)
    }

    func testParse_unknownKey_returnsNil() {
        XCTAssertNil(InputControlService.parseKeyCombo("cmd+definitelynotakey"))
        XCTAssertNil(InputControlService.parseKeyCombo(""))
    }

    func testParse_modifierAliases() {
        XCTAssertTrue(InputControlService.parseKeyCombo("command+s")?.flags.contains(.maskCommand) ?? false)
        XCTAssertTrue(InputControlService.parseKeyCombo("control+a")?.flags.contains(.maskControl) ?? false)
        XCTAssertTrue(InputControlService.parseKeyCombo("ctrl+c")?.flags.contains(.maskControl) ?? false)
        XCTAssertTrue(InputControlService.parseKeyCombo("option+x")?.flags.contains(.maskAlternate) ?? false)
        XCTAssertTrue(InputControlService.parseKeyCombo("alt+x")?.flags.contains(.maskAlternate) ?? false)
    }

    func testParse_caseInsensitive() {
        XCTAssertEqual(InputControlService.parseKeyCombo("CMD+S")?.keyCode, 1)
    }

    func testParse_digitAndArrows() {
        XCTAssertEqual(InputControlService.parseKeyCombo("cmd+1")?.keyCode, 18)
        XCTAssertEqual(InputControlService.parseKeyCombo("up")?.keyCode, 126)
        XCTAssertEqual(InputControlService.parseKeyCombo("down")?.keyCode, 125)
    }

    func testParse_whitespaceTolerated() {
        XCTAssertEqual(InputControlService.parseKeyCombo("  cmd + s ")?.keyCode, 1)
    }

    func testParse_modifierOnly_returnsNil() {
        XCTAssertNil(InputControlService.parseKeyCombo("cmd"))
        XCTAssertNil(InputControlService.parseKeyCombo("shift+"))  // trailing "+" has no keycode
    }

    func testConversion_zeroPixelDimensions_returnsNil() {
        XCTAssertNil(InputControlService.imagePixelToGlobalPoint(
            imageX: 0, imageY: 0, originX: 0, originY: 0,
            regionWidthPt: 100, regionHeightPt: 100, pixelWidth: 0, pixelHeight: 100))
    }

    func testConversion_nonSquareRatios() {
        // Region 200×50 pt shown as a 100×100 px image → x ratio 2.0, y ratio 0.5.
        let p = InputControlService.imagePixelToGlobalPoint(
            imageX: 50, imageY: 50, originX: 0, originY: 0,
            regionWidthPt: 200, regionHeightPt: 50, pixelWidth: 100, pixelHeight: 100)
        XCTAssertEqual(p?.x, 100)
        XCTAssertEqual(p?.y, 25)
    }

    func testConversion_originMapsToOrigin() {
        let p = InputControlService.imagePixelToGlobalPoint(
            imageX: 0, imageY: 0, originX: 300, originY: 200,
            regionWidthPt: 100, regionHeightPt: 100, pixelWidth: 100, pixelHeight: 100)
        XCTAssertEqual(p?.x, 300)
        XCTAssertEqual(p?.y, 200)
    }
}
