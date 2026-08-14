import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest

@testable import NanoTeams

// MARK: - Test doubles

/// Records what `QuickCaptureController.setup` asks the hotkey layer to register, so the
/// registration contract can be pinned without touching Carbon or the process-wide
/// `GlobalHotkeyManager.shared` (whose `unregisterAll` would sabotage any sibling test in the
/// same worker that had registered a hotkey).
///
/// It also RETAINS the handler closures, exactly as the production singleton does — that
/// retention is what makes the leak test below meaningful.
@MainActor
private final class ScreenInputHotkeyRecordingHotkeyManager: HotkeyManager {
    struct Registration {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private(set) var registrations: [Registration] = []
    private(set) var handlers: [UInt32: () -> Void] = [:]

    /// Key codes the fake refuses, standing in for a combo another app already owns — the case
    /// Carbon reports through `RegisterEventHotKey`'s status and that used to be dropped.
    var refusedKeyCodes: Set<UInt32> = []

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        guard !refusedKeyCodes.contains(keyCode) else { return false }
        registrations.append(Registration(id: id, keyCode: keyCode, modifiers: modifiers))
        handlers[id] = handler
        return true
    }

    func registration(forKeyCode keyCode: UInt32) -> Registration? {
        registrations.first { $0.keyCode == keyCode }
    }
}

// MARK: - Window ranking (tiers, bundle-id targeting, title constraint)

/// `ScreenCaptureServiceGeometryTests` pins `bestWindowIndex` against specific candidate SETS.
/// This suite pins the two things a candidate-set test structurally cannot: the `windowRank`
/// predicate on its own (bundle-id targeting, the self-guard's empty-bundle case, the
/// window-title constraint) and the `WindowMatchRank` comparator's TIER ORDER. Reordering the
/// `if` chain inside `<` can leave hand-picked candidate sets passing while a real desktop
/// resolves the wrong window — which is how the model ends up driving a helper process.
final class ScreenInputHotkeyCaptureRankTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func windowCandidate(
        bundleID: String = "", appName: String, title: String? = nil,
        width: Double = 800, height: Double = 600, onScreen: Bool = true, layer: Int = 0
    ) -> ScreenCaptureService.WindowCandidate {
        .init(bundleID: bundleID, appName: appName, title: title,
              width: width, height: height, isOnScreen: onScreen, layer: layer)
    }

    private func rank(
        exactApp: Bool, appMatch: Bool, onScreen: Bool, normalLayer: Bool, area: Double
    ) -> ScreenCaptureService.WindowMatchRank {
        .init(exactApp: exactApp, appMatch: appMatch,
              onScreen: onScreen, normalLayer: normalLayer, area: area)
    }

    // MARK: Targeting by bundle id

    /// `windowNotFound`'s own message tells the model "target must be an application name **or
    /// bundle id**", so an exact bundle id must resolve — and must land in the EXACT tier, or a
    /// same-named helper process could outrank the real app.
    func testWindowRank_exactBundleIDMatches_andLandsInTheExactTier() throws {
        let candidate = windowCandidate(bundleID: "com.apple.Safari", appName: "Safari")
        let matched = try XCTUnwrap(ScreenCaptureService.windowRank(
            candidate, specLower: "com.apple.safari", windowTitle: nil, ownBundleID: "com.nanoteams"))
        XCTAssertTrue(matched.exactApp, "a bundle-id target must rank as an exact app match")
        XCTAssertTrue(matched.appMatch)
    }

    /// A bundle-id PREFIX does not match through the app tier. This is deliberate and load-bearing
    /// even though `windowRank`'s doc comment reads "app bundle/name (exact, then substring)":
    /// substring is applied to the app NAME only, because `"com.apple"` as a substring would match
    /// every Apple app at once and hand the model an arbitrary one. Asserted as behaviour, not as
    /// an endorsement of either the code or the comment (see suspectedDefects).
    func testWindowRank_bundleIDPrefix_doesNotMatchThroughTheAppTier() {
        let candidate = windowCandidate(
            bundleID: "com.apple.Safari", appName: "Safari", title: "Start Page")
        XCTAssertNil(ScreenCaptureService.windowRank(
            candidate, specLower: "com.apple", windowTitle: nil, ownBundleID: "x"))
    }

    // MARK: Self-guard

    /// `windowCandidate(from:)` maps an SCWindow with no `owningApplication` to `bundleID: ""`.
    /// The self-guard skips empty bundle ids on purpose — otherwise, the moment `ownBundleID`
    /// resolved to `""` (an unbundled or misconfigured host), EVERY ownerless window would be
    /// discarded as "ours" and capture would report nothing is open.
    func testWindowRank_emptyBundleID_isNotTreatedAsSelfEvenWhenOwnBundleIDIsBlank() {
        let candidate = windowCandidate(bundleID: "", appName: "Safari")
        XCTAssertNotNil(ScreenCaptureService.windowRank(
            candidate, specLower: "safari", windowTitle: nil, ownBundleID: ""))
        XCTAssertNotNil(ScreenCaptureService.windowRank(
            candidate, specLower: "safari", windowTitle: nil, ownBundleID: "com.nanoteams"))
    }

    func testWindowRank_selfBundleID_isRejectedCaseInsensitively() {
        let candidate = windowCandidate(bundleID: "COM.NANOTEAMS", appName: "NanoTeams")
        XCTAssertNil(ScreenCaptureService.windowRank(
            candidate, specLower: "nanoteams", windowTitle: nil, ownBundleID: "com.nanoteams"))
    }

    // MARK: window_title constraint

    /// A blank `window_title` must read as "no constraint". A model that emits `window_title: "  "`
    /// (or an empty string it built by concatenation) would otherwise get `windowNotFound` for an
    /// app that is plainly open, and detour into Spotlight / ask_supervisor.
    func testWindowRank_whitespaceOnlyWindowTitle_isTreatedAsNoConstraint() {
        let candidate = windowCandidate(appName: "Safari", title: "Start Page")
        XCTAssertNotNil(ScreenCaptureService.windowRank(
            candidate, specLower: "safari", windowTitle: "   ", ownBundleID: "x"))
        XCTAssertNotNil(ScreenCaptureService.windowRank(
            candidate, specLower: "safari", windowTitle: "", ownBundleID: "x"))
    }

    /// A real constraint against a titleless window must reject rather than match vacuously —
    /// capturing "some window of that app" when the model asked for a specific one is worse than
    /// an error, because the model then acts on content it never asked to see.
    func testWindowRank_windowTitleConstraint_rejectsTitlelessWindow() {
        let candidate = windowCandidate(appName: "Safari", title: nil)
        XCTAssertNil(ScreenCaptureService.windowRank(
            candidate, specLower: "safari", windowTitle: "jobs", ownBundleID: "x"))
    }

    func testWindowRank_windowTitleConstraint_isCaseInsensitive() {
        let candidate = windowCandidate(appName: "Safari", title: "LinkedIn Jobs")
        XCTAssertNotNil(ScreenCaptureService.windowRank(
            candidate, specLower: "safari", windowTitle: "JOBS", ownBundleID: "x"))
    }

    // MARK: Comparator tier order

    /// Each tier must dominate everything below it regardless of area. The reported bug was a
    /// pure "largest area" pick handing `target:"safari"` to a 500×500 "Open and Save Panel
    /// Service (Safari)" helper; these four assertions pin the ordering that replaced it, so a
    /// future reordering of the `if` chain fails here even if every candidate-set test still passes.
    func testRankComparator_exactAppTier_dominatesAHugeSubstringMatch() {
        XCTAssertTrue(
            rank(exactApp: false, appMatch: true, onScreen: true, normalLayer: true, area: 9_000_000)
                < rank(exactApp: true, appMatch: true, onScreen: false, normalLayer: false, area: 1))
    }

    func testRankComparator_appMatchTier_dominatesAHugeTitleOnlyMatch() {
        XCTAssertTrue(
            rank(exactApp: false, appMatch: false, onScreen: true, normalLayer: true, area: 9_000_000)
                < rank(exactApp: false, appMatch: true, onScreen: false, normalLayer: false, area: 1))
    }

    func testRankComparator_onScreenTier_dominatesAHugeOffscreenWindow() {
        XCTAssertTrue(
            rank(exactApp: false, appMatch: true, onScreen: false, normalLayer: true, area: 9_000_000)
                < rank(exactApp: false, appMatch: true, onScreen: true, normalLayer: false, area: 1))
    }

    func testRankComparator_normalLayerTier_dominatesAHugePanelOverlay() {
        XCTAssertTrue(
            rank(exactApp: false, appMatch: true, onScreen: true, normalLayer: false, area: 9_000_000)
                < rank(exactApp: false, appMatch: true, onScreen: true, normalLayer: true, area: 1))
    }

    func testRankComparator_areaBreaksTiesInsideOneTier() {
        let small = rank(exactApp: true, appMatch: true, onScreen: true, normalLayer: true, area: 100)
        let large = rank(exactApp: true, appMatch: true, onScreen: true, normalLayer: true, area: 200)
        XCTAssertTrue(small < large)
        XCTAssertFalse(large < small)
    }

    /// Irreflexivity. `bestWindowIndex` keeps the FIRST candidate on a tie (`best!.rank < rank` is
    /// false for equals); a `<` that reported `true` for equal ranks would make window selection
    /// depend on `SCShareableContent`'s undocumented ordering — i.e. non-deterministic across runs.
    func testRankComparator_isIrreflexive_soTiesKeepTheFirstCandidate() {
        let r = rank(exactApp: true, appMatch: true, onScreen: true, normalLayer: true, area: 100)
        XCTAssertFalse(r < r)
    }
}

// MARK: - PNG encoding

/// `pngBase64` is the last step before the screenshot reaches the vision model, and it is the one
/// step in the capture path that needs no TCC grant — a `CGImage` built in memory exercises it
/// fully. If it ever stopped emitting PNG (e.g. a `.tiff` representation), the base64 would still
/// look plausible in the log while every model rejected the `image/png` data URL.
final class ScreenInputHotkeyPNGEncodingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    func testPNGBase64_emitsDecodablePNGPreservingDimensions() throws {
        let image = try XCTUnwrap(makeImage(width: 7, height: 5), "premise: in-memory CGImage")
        XCTAssertEqual(image.width, 7)
        XCTAssertEqual(image.height, 5)

        let base64 = try ScreenCaptureService.pngBase64(from: image)
        XCTAssertFalse(base64.isEmpty)

        let data = try XCTUnwrap(Data(base64Encoded: base64), "result must be valid base64")
        XCTAssertEqual(
            Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "must carry the PNG signature — the tool declares the payload as image/png")

        // Decoding it back is what the model's runtime does; dimensions must survive so the
        // image-pixel coordinates the model reports still index the picture it was shown.
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: data), "PNG must be re-parseable")
        XCTAssertEqual(decoded.pixelsWide, 7)
        XCTAssertEqual(decoded.pixelsHigh, 5)
    }

    /// `targetPixelSize` clamps to at least 1×1, so a 1-pixel capture is reachable for a sliver
    /// window; the encoder must not choke on it.
    func testPNGBase64_singlePixelImage_stillEncodes() throws {
        let image = try XCTUnwrap(makeImage(width: 1, height: 1))
        let data = try XCTUnwrap(Data(base64Encoded: ScreenCaptureService.pngBase64(from: image)))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    // NOTE: the `.encodeFailed` throw is not covered — it needs an NSBitmapImageRep that refuses
    // to produce a PNG representation, and every CGImage constructible from CGContext encodes.
}

// MARK: - Downscale ↔ click coordinate contract (cross-service)

/// `ScreenCaptureService.targetPixelSize` decides the image the model sees; `InputControlService`
/// maps the model's pixel back to a global point. Each half is pinned in isolation, but nothing
/// pins that they AGREE — and that agreement is exactly what broke before: mixing a point-space
/// region with a pixel-space size scaled every click by the backing factor (~2× on Retina), and
/// a single-window capture that included the drop shadow drifted every click by the inset.
///
/// These tests compose the two halves over realistic display geometries.
final class ScreenInputHotkeyCoordinateContractTests: XCTestCase {

    /// (regionW pt, regionH pt, backing scale) — Retina laptop, Retina external, 4K at 1×,
    /// and a small window that is never downscaled.
    private let geometries: [(w: Double, h: Double, scale: Double)] = [
        (1512, 982, 2.0), (1440, 900, 2.0), (3840, 2160, 1.0), (800, 600, 1.0),
    ]

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// The single most valuable composed assertion: the CENTRE of the downscaled image must map to
    /// the CENTRE of the captured region. Any conversion that reintroduces the backing `scale`
    /// instead of the folded `regionPt / pixel` ratio lands ~2× away on Retina — the exact class
    /// of failure that read to the user as "the model clicks the wrong place".
    func testImageCentre_mapsToRegionCentre_acrossRealisticGeometries() throws {
        for geometry in geometries {
            let (pxW, pxH) = ScreenCaptureService.targetPixelSize(
                regionW: geometry.w, regionH: geometry.h, scale: geometry.scale)
            XCTAssertGreaterThan(pxW, 0)
            XCTAssertGreaterThan(pxH, 0)

            let point = try XCTUnwrap(InputControlService.imagePixelToGlobalPoint(
                imageX: Double(pxW) / 2, imageY: Double(pxH) / 2,
                originX: 0, originY: 0,
                regionWidthPt: geometry.w, regionHeightPt: geometry.h,
                pixelWidth: pxW, pixelHeight: pxH), "centre pixel must be in bounds for \(geometry)")

            XCTAssertEqual(Double(point.x), geometry.w / 2, accuracy: 1.0, "x centre for \(geometry)")
            XCTAssertEqual(Double(point.y), geometry.h / 2, accuracy: 1.0, "y centre for \(geometry)")
        }
    }

    /// Anti-vacuity for the test above: at least one geometry must actually be DOWNSCALED, or the
    /// centre check would only ever exercise the 1:1 path and a broken ratio would slip through.
    func testLargeGeometries_areActuallyDownscaled() {
        let cap = Double(ScreenCaptureService.maxImageSide)
        var downscaledCount = 0
        for geometry in geometries {
            let nativeLongSide = max(geometry.w, geometry.h) * geometry.scale
            guard nativeLongSide > cap else { continue }
            downscaledCount += 1
            let (pxW, pxH) = ScreenCaptureService.targetPixelSize(
                regionW: geometry.w, regionH: geometry.h, scale: geometry.scale)
            XCTAssertEqual(max(pxW, pxH), ScreenCaptureService.maxImageSide,
                           "long side must be capped for \(geometry)")
        }
        XCTAssertGreaterThan(downscaledCount, 0,
            "the geometry table must include a downscaled case or the centre test is vacuous")
    }

    /// The LAST valid image pixel must land strictly inside the region, exactly one pixel-step
    /// short of the far edge. Bounded from BOTH sides on purpose: a ratio computed against
    /// `pixelWidth - 1` would push it onto the region boundary (a point on the neighbouring
    /// display), and a ratio that is too small would leave the right-hand strip of the screen
    /// unreachable — the model could see a button it can never click.
    func testLastImagePixel_landsExactlyOnePixelStepInsideTheRegion() throws {
        for geometry in geometries {
            let (pxW, pxH) = ScreenCaptureService.targetPixelSize(
                regionW: geometry.w, regionH: geometry.h, scale: geometry.scale)

            let point = try XCTUnwrap(InputControlService.imagePixelToGlobalPoint(
                imageX: Double(pxW - 1), imageY: Double(pxH - 1),
                originX: 0, originY: 0,
                regionWidthPt: geometry.w, regionHeightPt: geometry.h,
                pixelWidth: pxW, pixelHeight: pxH))

            XCTAssertLessThan(Double(point.x), geometry.w, "last pixel must stay inside \(geometry)")
            XCTAssertLessThan(Double(point.y), geometry.h)
            XCTAssertEqual(geometry.w - Double(point.x), geometry.w / Double(pxW),
                           accuracy: 0.001, "x step for \(geometry)")
            XCTAssertEqual(geometry.h - Double(point.y), geometry.h / Double(pxH),
                           accuracy: 0.001, "y step for \(geometry)")
        }
    }

    /// Round trip on a non-zero origin, using dimensions the downscaler actually produces. A
    /// secondary display sits at a negative global origin, so an origin term dropped anywhere in
    /// the pair sends every click to the primary monitor.
    func testRoundTrip_onDownscaledDimensionsWithNegativeOrigin() throws {
        let (pxW, pxH) = ScreenCaptureService.targetPixelSize(regionW: 1512, regionH: 982, scale: 2)
        let originX = -1512.0, originY = -300.0

        for (ix, iy) in [(0.0, 0.0), (1.0, 1.0), (Double(pxW - 1), Double(pxH - 1)),
                         (Double(pxW) / 3, Double(pxH) / 7)] {
            let global = try XCTUnwrap(InputControlService.imagePixelToGlobalPoint(
                imageX: ix, imageY: iy, originX: originX, originY: originY,
                regionWidthPt: 1512, regionHeightPt: 982, pixelWidth: pxW, pixelHeight: pxH))
            XCTAssertLessThan(Double(global.x), originX + 1512)
            XCTAssertGreaterThanOrEqual(Double(global.x), originX)

            let back = try XCTUnwrap(InputControlService.globalPointToImagePixel(
                globalX: Double(global.x), globalY: Double(global.y),
                originX: originX, originY: originY,
                regionWidthPt: 1512, regionHeightPt: 982, pixelWidth: pxW, pixelHeight: pxH))
            XCTAssertEqual(back.x, ix, accuracy: 0.001)
            XCTAssertEqual(back.y, iy, accuracy: 0.001)
        }
    }
}

// MARK: - Own-window self-guard geometry

/// The self-guard denies a click that lands on a NanoTeams window which a whole-display capture
/// filtered OUT of the image but which is still physically on screen. Its edge semantics decide
/// whether a click on our own title bar leaks through, so they are worth stating explicitly.
final class ScreenInputHotkeySelfGuardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// `CGRect.contains` is half-open: the min edges belong to the rect, the max edges do not.
    /// So a click on our window's top-left pixel IS blocked and a click on the pixel just past its
    /// bottom-right is NOT — which is correct, because that pixel belongs to whatever is behind us.
    func testPointInAnyRect_minEdgeIsInside_maxEdgeIsOutside() {
        let rects = [CGRect(x: 100, y: 100, width: 200, height: 150)]
        XCTAssertTrue(InputControlService.pointInAnyRect(CGPoint(x: 100, y: 100), rects: rects))
        XCTAssertTrue(InputControlService.pointInAnyRect(CGPoint(x: 299.9, y: 249.9), rects: rects))
        XCTAssertFalse(InputControlService.pointInAnyRect(CGPoint(x: 300, y: 250), rects: rects))
        XCTAssertFalse(InputControlService.pointInAnyRect(CGPoint(x: 100, y: 99.9), rects: rects))
    }

    /// Every window must be consulted, not just the first — NanoTeams routinely has the main
    /// window plus the Quick Capture panel plus a Settings window on screen at once.
    func testPointInAnyRect_consultsEveryRect() {
        let rects = [
            CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: 500, y: 500, width: 100, height: 100),
            CGRect(x: 900, y: 20, width: 50, height: 50),
        ]
        XCTAssertTrue(InputControlService.pointInAnyRect(CGPoint(x: 920, y: 40), rects: rects),
                      "the third window must still block a click")
        XCTAssertFalse(InputControlService.pointInAnyRect(CGPoint(x: 300, y: 300), rects: rects))
    }

    /// A degenerate frame contains nothing. `ownWindowFrames()` already filters ≤1pt windows, so
    /// this is defence in depth: a zero-size rect must never swallow the whole screen.
    func testPointInAnyRect_emptyRectBlocksNothing() {
        XCTAssertFalse(InputControlService.pointInAnyRect(
            CGPoint(x: 0, y: 0), rects: [CGRect(x: 0, y: 0, width: 0, height: 0)]))
        XCTAssertFalse(InputControlService.pointInAnyRect(CGPoint(x: 5, y: 5), rects: []))
    }

    /// Negative-origin rects are real (a secondary display left of the primary), and the guard
    /// works in the same CG top-left global space as `imagePixelToGlobalPoint`'s output.
    func testPointInAnyRect_handlesNegativeOriginWindows() {
        let rects = [CGRect(x: -1440, y: -200, width: 400, height: 300)]
        XCTAssertTrue(InputControlService.pointInAnyRect(CGPoint(x: -1200, y: -100), rects: rects))
        XCTAssertFalse(InputControlService.pointInAnyRect(CGPoint(x: -1500, y: -100), rects: rects))
    }
}

// MARK: - Key combo parsing

/// `parseKeyCombo` is the whole of `ui_key`'s contract with the model. A missing table entry is a
/// hard failure the model sees as `unknownKeyCombo`; a WRONG entry silently presses a different
/// key, which is worse — it can destroy work.
final class ScreenInputHotkeyKeyComboTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// Completeness + injectivity over the alphanumerics, asserted as a property rather than by
    /// freezing 36 magic numbers. A dropped entry makes `cmd+<letter>` unreachable; a duplicated
    /// keycode (the classic copy-paste slip in a hand-written virtual-keycode table) means one of
    /// the two letters presses the other.
    func testEveryAsciiLetterAndDigit_parsesToADistinctKeyCode() {
        var seen: [CGKeyCode: String] = [:]
        for token in "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init) {
            guard let parsed = InputControlService.parseKeyCombo(token) else {
                XCTFail("'\(token)' has no keycode — the model cannot press cmd+\(token)")
                continue
            }
            XCTAssertTrue(parsed.flags.isEmpty, "bare '\(token)' must carry no modifiers")
            if let clash = seen[parsed.keyCode] {
                XCTFail("'\(token)' and '\(clash)' share keycode \(parsed.keyCode) — one presses the wrong key")
            }
            seen[parsed.keyCode] = token
        }
        XCTAssertEqual(seen.count, 36, "26 letters + 10 digits must all resolve")
    }

    /// Punctuation shortcuts are not exotic: `cmd+,` opens Preferences on every Mac app and
    /// `cmd+/` toggles comments in every editor. Same distinctness argument.
    func testPunctuationKeys_parseToDistinctKeyCodes() {
        var seen: [CGKeyCode: String] = [:]
        for token in ["-", "=", "[", "]", ";", "'", "\\", ",", ".", "/", "`"] {
            guard let parsed = InputControlService.parseKeyCombo(token) else {
                XCTFail("punctuation '\(token)' has no keycode")
                continue
            }
            if let clash = seen[parsed.keyCode] {
                XCTFail("'\(token)' and '\(clash)' share keycode \(parsed.keyCode)")
            }
            seen[parsed.keyCode] = token
        }
        XCTAssertEqual(seen.count, 11)
    }

    /// The F-key codes are non-monotonic (F3=99 sits below F1=122), which is precisely why a
    /// hand-written table drifts silently. Distinctness catches a transposition; a duplicate would
    /// mean `ui_key f3` triggers Mission Control instead.
    func testFunctionKeys_allParseToDistinctKeyCodes() {
        var seen: [CGKeyCode: String] = [:]
        for n in 1...12 {
            let token = "f\(n)"
            guard let parsed = InputControlService.parseKeyCombo(token) else {
                XCTFail("'\(token)' has no keycode")
                continue
            }
            if let clash = seen[parsed.keyCode] {
                XCTFail("'\(token)' and '\(clash)' share keycode \(parsed.keyCode)")
            }
            seen[parsed.keyCode] = token
        }
        XCTAssertEqual(seen.count, 12)
    }

    /// Navigation/editing keys the model reaches for constantly. `forwarddelete` must NOT collapse
    /// onto `delete` — one deletes backwards, one forwards, and the model cannot tell from a
    /// success envelope which one happened.
    func testNavigationKeys_parse_andForwardDeleteIsDistinctFromDelete() throws {
        for token in ["home", "end", "pageup", "pagedown", "help",
                      "left", "right", "up", "down", "tab", "space", "escape", "return"] {
            XCTAssertNotNil(InputControlService.parseKeyCombo(token), "'\(token)' must parse")
        }
        let del = try XCTUnwrap(InputControlService.parseKeyCombo("delete")).keyCode
        let fwd = try XCTUnwrap(InputControlService.parseKeyCombo("forwarddelete")).keyCode
        XCTAssertNotEqual(del, fwd, "backward and forward delete must be different keys")
    }

    /// Aliases exist so the model's phrasing doesn't matter. If one drifted, `esc` would press
    /// something other than Escape while `escape` kept working — a maddening, intermittent bug.
    func testAliases_resolveToTheSameKeyCode() throws {
        let pairs = [("return", "enter"), ("escape", "esc"), ("delete", "backspace"),
                     ("space", "spacebar"), ("left", "leftarrow"), ("right", "rightarrow"),
                     ("up", "uparrow"), ("down", "downarrow")]
        for (canonical, alias) in pairs {
            let a = try XCTUnwrap(InputControlService.parseKeyCombo(canonical), canonical).keyCode
            let b = try XCTUnwrap(InputControlService.parseKeyCombo(alias), alias).keyCode
            XCTAssertEqual(a, b, "'\(alias)' must be an alias of '\(canonical)'")
        }
    }

    /// Models emit modifier GLYPHS as readily as words (they appear in every macOS menu).
    func testUnicodeModifierGlyphs_areAccepted() throws {
        let parsed = try XCTUnwrap(InputControlService.parseKeyCombo("⌃+⌥+⇧+⌘+s"))
        let bareS = try XCTUnwrap(InputControlService.parseKeyCombo("s")).keyCode
        XCTAssertEqual(parsed.keyCode, bareS)
        XCTAssertTrue(parsed.flags.contains(.maskControl))
        XCTAssertTrue(parsed.flags.contains(.maskAlternate))
        XCTAssertTrue(parsed.flags.contains(.maskShift))
        XCTAssertTrue(parsed.flags.contains(.maskCommand))
    }

    /// An unrecognized modifier must reject the WHOLE combo. Silently dropping it and pressing the
    /// bare key is the dangerous failure: `fn+delete` would become plain `delete` (deleting the
    /// character behind the caret instead of ahead of it) while still reporting success.
    func testUnknownModifier_rejectsTheWholeCombo_ratherThanPressingTheBareKey() {
        XCTAssertNil(InputControlService.parseKeyCombo("fn+delete"))
        XCTAssertNil(InputControlService.parseKeyCombo("hyper+x"))
        XCTAssertNil(InputControlService.parseKeyCombo("meta+cmd+s"))
    }

    /// A modifier in the KEY position is not a keystroke. Falling through to some arbitrary code
    /// would fire a real shortcut the model never asked for.
    func testModifierInKeyPosition_returnsNil() {
        XCTAssertNil(InputControlService.parseKeyCombo("cmd+shift"))
        XCTAssertNil(InputControlService.parseKeyCombo("cmd+cmd"))
        XCTAssertNil(InputControlService.parseKeyCombo("shift"))
    }

    /// Only the modifiers named are set — an extra flag turns `cmd+w` (close tab) into
    /// `cmd+shift+w` (close window).
    func testOnlyTheNamedModifiersAreSet() throws {
        let parsed = try XCTUnwrap(InputControlService.parseKeyCombo("cmd+w"))
        XCTAssertTrue(parsed.flags.contains(.maskCommand))
        XCTAssertFalse(parsed.flags.contains(.maskShift))
        XCTAssertFalse(parsed.flags.contains(.maskControl))
        XCTAssertFalse(parsed.flags.contains(.maskAlternate))
    }

    func testRepeatedModifier_isIdempotent() throws {
        let once = try XCTUnwrap(InputControlService.parseKeyCombo("cmd+s"))
        let twice = try XCTUnwrap(InputControlService.parseKeyCombo("cmd+command+s"))
        XCTAssertEqual(once.flags, twice.flags)
        XCTAssertEqual(once.keyCode, twice.keyCode)
    }

    /// Blank input must reject rather than resolve to an arbitrary key.
    func testBlankInput_returnsNil() {
        XCTAssertNil(InputControlService.parseKeyCombo("   "))
        XCTAssertNil(InputControlService.parseKeyCombo("\n"))
    }

    /// "+" IS a key. It was reported here as a dead branch — the parser normalized a trailing
    /// "+" into a "+" key token that no keycode table had an entry for, so `ui_key("cmd++")`
    /// (zoom in) could only ever return `unknownKeyCombo` while the code read as though it were
    /// supported. It now resolves to shift+"=", its real US-ANSI position. Full coverage of the
    /// separator-vs-key split lives in `ParseKeyComboPlusTests`.
    func testPlusAsAKeyToken_resolvesToShiftEquals() {
        XCTAssertEqual(InputControlService.parseKeyCombo("cmd++")?.keyCode, 24)
        XCTAssertEqual(InputControlService.parseKeyCombo("+")?.keyCode, 24)
    }
}

// MARK: - Running-app resolution

/// `runningApp(matching:)` picks the app that `ui_click` / `ui_type` will ACTIVATE before
/// synthesizing input. A wrong or over-eager match types into the wrong window.
final class ScreenInputHotkeyAppResolutionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// The safety-critical branch: a blank `target` must resolve to NOTHING. Without the guard,
    /// an empty spec would fall through to `contains("")` — true for every app — and activate an
    /// arbitrary one, then type into it.
    func testBlankSpec_resolvesToNil_ratherThanAnArbitraryApp() {
        XCTAssertNil(InputControlService.runningApp(matching: ""))
        XCTAssertNil(InputControlService.runningApp(matching: "   "))
        XCTAssertNil(InputControlService.runningApp(matching: "\n\t "))
    }

    func testUnknownSpec_resolvesToNil() {
        XCTAssertNil(InputControlService.runningApp(matching: "nanoteams-no-such-app-\(UUID().uuidString)"))
    }

    /// Exact bundle-id lookup, self-referentially (the test host is itself a running application),
    /// and case-insensitively — a model that echoes a bundle id in a different case must still hit.
    ///
    /// Asserts on the resolved BUNDLE ID, not the pid: the developer usually has the real
    /// NanoTeams.app open while the suite runs, so two processes share this bundle id and
    /// `runningApp` may legitimately return either. Pinning the pid made the test pass or fail
    /// on whether the app happened to be running.
    func testExactBundleID_resolves_caseInsensitively() throws {
        let current = NSRunningApplication.current
        guard let bundleID = current.bundleIdentifier, !bundleID.isEmpty else {
            throw XCTSkip("Test host has no bundle identifier; the exact-bundle-id premise is unavailable.")
        }
        XCTAssertEqual(
            InputControlService.runningApp(matching: bundleID)?.bundleIdentifier?.lowercased(),
            bundleID.lowercased())
        XCTAssertEqual(
            InputControlService.runningApp(matching: bundleID.uppercased())?.bundleIdentifier?.lowercased(),
            bundleID.lowercased(),
            "bundle-id matching lowercases both sides")
    }

    // NOTE: `activate(_:)` and the `contains`-name fallback are not covered — both depend on which
    // applications happen to be running on the machine, so any assertion would be environment-
    // dependent. `hasAccessibility()` / `requestAccessibilityIfNeeded()` are likewise untestable:
    // the first reads a TCC grant that cannot be faked, and the second OPENS a System Settings
    // prompt, so calling it from a test is not acceptable. The guard that consumes them
    // (`requiresAccessibility` in LLMExecutionService+ComputerUse) is `private`.
}

// MARK: - Error messages

/// These strings are the model's and the user's only signal when an OS gate blocks the feature.
/// They have to stay distinguishable and actionable, otherwise the model retries forever against
/// a permission the user never learns to grant.
final class ScreenInputHotkeyErrorMessageTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// The two Screen Recording states demand DIFFERENT follow-ups: grant it, versus relaunch
    /// after already granting it. macOS does not activate a fresh grant for a running process,
    /// so collapsing them strands the run waiting on a switch that is already on.
    ///
    /// These descriptions have no human sink — their only route out is `errorText(_:)` into a
    /// `commandFailed` envelope, i.e. the MODEL — so each must name a recourse the model can
    /// act on rather than a Settings pane it cannot open.
    func testScreenRecordingErrors_denyAndRelaunch_areDistinctAndActionable() throws {
        let denied = try XCTUnwrap(ScreenCaptureError.permissionDenied.errorDescription)
        let relaunch = try XCTUnwrap(ScreenCaptureError.permissionNeedsRelaunch.errorDescription)
        XCTAssertNotEqual(denied, relaunch)
        XCTAssertTrue(denied.contains("Screen Recording"))
        XCTAssertTrue(denied.contains("supervisor"), "must name a model-reachable recourse")
        XCTAssertFalse(denied.contains("System Settings"), "the model cannot open a Settings pane")
        XCTAssertTrue(relaunch.lowercased().contains("relaunch"), "must name the required action")
        XCTAssertFalse(relaunch.contains("System Settings"), "the model cannot open a Settings pane")
    }

    /// The underlying reason must survive into the envelope — a bare "capture failed" gives the
    /// model nothing to route on and it re-issues the identical call.
    func testCaptureFailed_echoesTheUnderlyingReason() throws {
        let message = try XCTUnwrap(
            ScreenCaptureError.captureFailed("SCStream timed out").errorDescription)
        XCTAssertTrue(message.contains("SCStream timed out"))
    }

    func testNoDisplayAndEncodeFailed_haveNonEmptyDescriptions() {
        XCTAssertFalse(ScreenCaptureError.noDisplay.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(ScreenCaptureError.encodeFailed.errorDescription?.isEmpty ?? true)
    }

    /// Accessibility is a DIFFERENT grant from Screen Recording; the message must send the user to
    /// the Accessibility pane, or they grant Screen Recording again and nothing changes.
    /// Pins the LIVE surface — the `.computerUseDenied` envelope text in
    /// `LLMExecutionService+ComputerUse` (wave 32 deleted the dead duplicate that used to
    /// live on `InputControlError.accessibilityDenied`, which no code path could throw).
    /// The message's only consumer is a `.computerUseDenied` envelope, i.e. the MODEL — which
    /// cannot open a Settings pane (the human is served by the OS prompt the call site raises).
    /// So it must name the missing capability and a model-reachable recourse, and it must not
    /// name the OTHER permission, which would send the model down the wrong path.
    func testAccessibilityDenied_namesTheCapabilityAndAModelReachableRecourse() {
        let message = LLMExecutionService.accessibilityDeniedMessage
        XCTAssertTrue(message.contains("Accessibility"))
        XCTAssertTrue(message.contains("supervisor"), "must name a recourse the model can act on")
        XCTAssertFalse(message.contains("System Settings"), "the model cannot open a Settings pane")
        XCTAssertFalse(message.contains("Screen Recording"), "must not point at the wrong permission")
    }

    /// The rejected combo has to appear verbatim so the model can see WHAT it got wrong and try a
    /// different spelling instead of resending the same token.
    func testUnknownKeyCombo_echoesTheRejectedCombo() throws {
        let message = try XCTUnwrap(InputControlError.unknownKeyCombo("cmd+frobnicate").errorDescription)
        XCTAssertTrue(message.contains("cmd+frobnicate"))
    }
}

// MARK: - Hotkey registration seam

/// `GlobalHotkeyManager` itself cannot be exercised here: it is a `private init` singleton whose
/// every mutating path calls Carbon's `RegisterEventHotKey` / `InstallEventHandler`, and calling
/// `unregisterAll()` on `.shared` would tear down hotkeys any sibling test in the same worker had
/// registered. What IS reachable — and what actually decides whether the user's global shortcuts
/// work — is the `HotkeyManager` seam and `QuickCaptureController.setup`'s bookkeeping on it.
@MainActor
final class ScreenInputHotkeyRegistrationTests: XCTestCase {

    /// Key code 29 is `kVK_ANSI_0`, 40 is `kVK_ANSI_K` — the documented Ctrl+Opt+Cmd+0 / +K.
    private let openKeyCode = UInt32(kVK_ANSI_0)
    private let clipKeyCode = UInt32(kVK_ANSI_K)

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// Ctrl+Opt+Cmd+0 and Ctrl+Opt+Cmd+K are the app's two advertised system-wide shortcuts
    /// (documented in CLAUDE.md and in the Settings shortcut sheet). A drifted key code or an
    /// extra modifier bit means the shortcut the docs promise silently does nothing.
    func testSetup_registersTheTwoDocumentedShortcuts() async throws {
        let hotkeys = ScreenInputHotkeyRecordingHotkeyManager()
        let store = TestOrchestrator.make()
        let dictation = DictationService()
        let controller = QuickCaptureController(hotkeyManager: hotkeys)

        controller.setup(store: store, dictation: dictation)

        XCTAssertEqual(hotkeys.registrations.count, 2, "exactly the open + clip hotkeys")
        let expectedModifiers = UInt32(cmdKey | optionKey | controlKey)

        for keyCode in [openKeyCode, clipKeyCode] {
            let registration = try XCTUnwrap(
                hotkeys.registration(forKeyCode: keyCode), "no hotkey registered for key \(keyCode)")
            XCTAssertEqual(registration.modifiers, expectedModifiers,
                           "key \(keyCode) must be Ctrl+Opt+Cmd")
            XCTAssertEqual(registration.modifiers & UInt32(shiftKey), 0,
                           "Shift is not part of either documented shortcut")
        }
    }

    /// Cross-check against the app's OWN virtual-keycode table: the hotkeys must be the '0' and
    /// 'k' keys. `QuickCaptureController+Hotkeys` and `InputControlService` carry two independent
    /// hand-written copies of macOS's keycodes, so their agreement is real evidence — and it pins
    /// the intent ("the zero key") rather than only the literal.
    func testSetup_hotkeyKeyCodesAgreeWithTheInputServiceKeyTable() async throws {
        let hotkeys = ScreenInputHotkeyRecordingHotkeyManager()
        let store = TestOrchestrator.make()
        let dictation = DictationService()
        let controller = QuickCaptureController(hotkeyManager: hotkeys)

        controller.setup(store: store, dictation: dictation)

        let zeroKey = try XCTUnwrap(InputControlService.parseKeyCombo("0")).keyCode
        let kKey = try XCTUnwrap(InputControlService.parseKeyCombo("k")).keyCode
        XCTAssertNotNil(hotkeys.registration(forKeyCode: UInt32(zeroKey)),
                        "the overlay hotkey must be the '0' key")
        XCTAssertNotNil(hotkeys.registration(forKeyCode: UInt32(kKey)),
                        "the context-capture hotkey must be the 'k' key")
    }

    /// The two ids must differ. `GlobalHotkeyManager` keys everything by id and `register` starts
    /// by UNREGISTERING a duplicate id — so a collision would leave Ctrl+Opt+Cmd+0 silently dead
    /// while the second shortcut still worked, with no error anywhere.
    func testSetup_theTwoHotkeyIDsAreDistinct() async throws {
        let hotkeys = ScreenInputHotkeyRecordingHotkeyManager()
        let store = TestOrchestrator.make()
        let dictation = DictationService()
        let controller = QuickCaptureController(hotkeyManager: hotkeys)

        controller.setup(store: store, dictation: dictation)

        let ids = Set(hotkeys.registrations.map(\.id))
        XCTAssertEqual(ids.count, hotkeys.registrations.count,
                       "duplicate hotkey ids would make one shortcut evict the other")
    }

    /// `setup` is called from `NanoTeamsApp`'s `.onAppear`, which can fire more than once. The
    /// `didSetupHotkeys` latch must keep registration to one pass: re-registering against the
    /// process-wide Carbon manager unregisters the live hotkey first, and if the re-registration
    /// then fails (a conflicting app claimed the combo in the meantime) the shortcut is simply
    /// gone — silently, because `register` reports nothing.
    func testSetup_calledTwice_registersOnlyOnce() async {
        let hotkeys = ScreenInputHotkeyRecordingHotkeyManager()
        let store = TestOrchestrator.make()
        let dictation = DictationService()
        let controller = QuickCaptureController(hotkeyManager: hotkeys)

        controller.setup(store: store, dictation: dictation)
        XCTAssertEqual(hotkeys.registrations.count, 2, "premise: the first setup registered")
        XCTAssertTrue(controller.didSetupHotkeys)

        controller.setup(store: store, dictation: dictation)

        XCTAssertEqual(hotkeys.registrations.count, 2, "the second setup must not re-register")
    }

    /// …but a repeat `setup` must still REBIND the collaborators, because the store/dictation
    /// assignments deliberately sit above the latch. The hotkey handlers reach the orchestrator
    /// through `self.store`, so a stale binding would leave Quick Capture driving a dead one.
    func testSetup_calledTwiceWithANewStore_rebindsTheStore() async {
        let hotkeys = ScreenInputHotkeyRecordingHotkeyManager()
        let firstStore = TestOrchestrator.make()
        let secondStore = TestOrchestrator.make()
        let dictation = DictationService()
        let controller = QuickCaptureController(hotkeyManager: hotkeys)

        controller.setup(store: firstStore, dictation: dictation)
        XCTAssertTrue(controller.store === firstStore, "premise: first setup bound the first store")

        controller.setup(store: secondStore, dictation: dictation)

        XCTAssertTrue(controller.store === secondStore,
                      "the store binding must follow the latest setup even when registration is latched")
        XCTAssertEqual(hotkeys.registrations.count, 2)
    }

    /// The handler closures capture `[weak self]`, and that is load-bearing rather than stylistic:
    /// the production `GlobalHotkeyManager` is a process-lifetime singleton that keeps every
    /// handler in `handlers[id]` forever. A strong capture would pin the controller — and whatever
    /// it transitively holds — for the life of the process.
    func testSetup_handlersDoNotRetainTheController() async {
        let hotkeys = ScreenInputHotkeyRecordingHotkeyManager()
        let store = TestOrchestrator.make()
        let dictation = DictationService()

        weak var weakController: QuickCaptureController?
        do {
            let controller = QuickCaptureController(hotkeyManager: hotkeys)
            weakController = controller
            controller.setup(store: store, dictation: dictation)
            XCTAssertEqual(hotkeys.registrations.count, 2, "premise: handlers were handed over")
            XCTAssertNotNil(weakController)
        }

        XCTAssertEqual(hotkeys.handlers.count, 2,
                       "premise: the hotkey layer still holds the closures, as the singleton would")
        XCTAssertNil(weakController,
                     "a strong capture in a hotkey handler leaks the controller for the process lifetime")
    }
}
