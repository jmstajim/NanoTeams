import CoreGraphics
import XCTest
@testable import NanoTeams

// MARK: - Target routing

/// `capture` used to decide "whole display vs one window" inline, welded between a permission
/// preflight and a `SCShareableContent` fetch, so the routing could only be exercised by taking a
/// real screenshot. It is now `resolveTarget`, and these pin it: routing a window request to the
/// display path hands the model the whole screen (and a coordinate space for the wrong region),
/// which reads as "the model clicked somewhere random".
final class ScreenCaptureTargetRoutingTests: XCTestCase {

    private func target(_ spec: String) -> ScreenCaptureService.CaptureTarget {
        ScreenCaptureService.resolveTarget(spec)
    }

    func testScreenAndDisplayKeywords_routeToTheDisplayPath() {
        XCTAssertEqual(target("screen"), .display)
        XCTAssertEqual(target("display"), .display)
    }

    /// The spec is model-authored free text; a capitalized "Screen" must not be read as an app
    /// name and sent looking for a window nothing owns.
    func testKeywords_areCaseInsensitiveAndWhitespaceTolerant() {
        XCTAssertEqual(target("Screen"), .display)
        XCTAssertEqual(target("SCREEN"), .display)
        XCTAssertEqual(target("  display  "), .display)
        XCTAssertEqual(target("\n Screen \t"), .display)
    }

    /// An omitted / blank target means "just show me the screen" — the alternative is a window
    /// search for the empty string, which `windowRank`'s `contains("")` would match against
    /// EVERY window and resolve to an arbitrary one.
    func testBlankSpec_routesToTheDisplayPath() {
        XCTAssertEqual(target(""), .display)
        XCTAssertEqual(target("   "), .display)
        XCTAssertEqual(target("\n\t "), .display)
    }

    func testAppName_routesToTheWindowPath_trimmed() {
        XCTAssertEqual(target("Safari"), .window(spec: "Safari"))
        XCTAssertEqual(target("  Safari  "), .window(spec: "Safari"))
        XCTAssertEqual(target("com.apple.Safari"), .window(spec: "com.apple.Safari"))
    }

    /// Case is preserved on the way out — `windowRank` lowercases the spec itself, and the
    /// ORIGINAL casing is what `titleOnlyMatchNote` and the `windowNotFound` message echo back to
    /// the model. Lowercasing here would make both quote a target the model never typed.
    func testWindowSpec_preservesTheCallersCasing() {
        XCTAssertEqual(target("LinkedIn"), .window(spec: "LinkedIn"))
    }

    /// A word that merely CONTAINS a keyword is an app name, not a keyword.
    func testKeywordSubstrings_areStillAppNames() {
        XCTAssertEqual(target("Screenflow"), .window(spec: "Screenflow"))
        XCTAssertEqual(target("Display Menu"), .window(spec: "Display Menu"))
    }
}

// MARK: - Permission failure selection

/// Which of the two Screen Recording errors gets raised. Both mean "no capture", but only one of
/// them tells a user who JUST granted the permission why it still doesn't work — sending them
/// back to a switch that is already on is a dead end they can't reason their way out of.
final class ScreenCapturePermissionFailureTests: XCTestCase {

    func testGrantLandedDuringThePrompt_asksForARelaunch() {
        XCTAssertEqual(
            ScreenCaptureService.permissionFailure(grantedAfterPrompt: true).errorDescription,
            ScreenCaptureError.permissionNeedsRelaunch.errorDescription)
    }

    func testStillDenied_asksForThePermission() {
        XCTAssertEqual(
            ScreenCaptureService.permissionFailure(grantedAfterPrompt: false).errorDescription,
            ScreenCaptureError.permissionDenied.errorDescription)
    }

    /// Anti-vacuity for the pair above: the two messages must not be the same string, or the
    /// branch is decorative.
    func testTheTwoMessages_areDistinguishable() throws {
        let relaunch = try XCTUnwrap(ScreenCaptureService.permissionFailure(grantedAfterPrompt: true).errorDescription)
        let denied = try XCTUnwrap(ScreenCaptureService.permissionFailure(grantedAfterPrompt: false).errorDescription)
        XCTAssertNotEqual(relaunch, denied)
        XCTAssertTrue(relaunch.lowercased().contains("relaunch"))
    }

    /// `hasPermission` is the NON-prompting half of the permission pair (`CGPreflightScreenCaptureAccess`),
    /// so it is safe to call — unlike `requestPermission`, which opens System Settings and must
    /// never run from a test. Pinned as a pure query: two calls in a row agree, and neither
    /// changes anything.
    func testHasPermission_isANonPromptingIdempotentQuery() {
        XCTAssertEqual(ScreenCaptureService.hasPermission(), ScreenCaptureService.hasPermission())
    }
}

// MARK: - Display selection

/// `SCShareableContent.displays` is not documented as main-display-first, so `.first` can be a
/// secondary monitor. Capturing the wrong monitor hands the model a coordinate space for a region
/// it isn't looking at — every click then lands on the other screen.
final class ScreenCaptureDisplaySelectionTests: XCTestCase {

    func testMainDisplay_isPreferredOverListOrder() {
        XCTAssertEqual(
            ScreenCaptureService.mainDisplayIndex(displayIDs: [77, 42, 91], mainID: 42), 1)
    }

    func testMainDisplayFirstInList_isStillChosen() {
        XCTAssertEqual(
            ScreenCaptureService.mainDisplayIndex(displayIDs: [42, 77], mainID: 42), 0)
    }

    /// A main display that isn't in the shareable set (screen-recording scope can exclude it)
    /// still has to produce SOME capture rather than an error — falling back to the first
    /// available display is strictly better than `.noDisplay`.
    func testMainDisplayAbsent_fallsBackToTheFirstAvailable() {
        XCTAssertEqual(
            ScreenCaptureService.mainDisplayIndex(displayIDs: [77, 91], mainID: 42), 0)
    }

    func testNoDisplays_returnsNil_soTheCallerCanRaiseNoDisplay() {
        XCTAssertNil(ScreenCaptureService.mainDisplayIndex(displayIDs: [], mainID: 42))
    }

    /// Single-display Macs are the common case and must not depend on the fallback.
    func testSingleDisplayThatIsMain_resolvesToIt() {
        XCTAssertEqual(ScreenCaptureService.mainDisplayIndex(displayIDs: [42], mainID: 42), 0)
    }

    /// Duplicate ids can't happen from CoreGraphics, but the resolver must still be total.
    func testDuplicateIDs_resolveToTheFirstOccurrence() {
        XCTAssertEqual(
            ScreenCaptureService.mainDisplayIndex(displayIDs: [42, 42], mainID: 42), 0)
    }
}

// MARK: - Own-window exclusion (whole-display capture)

/// A whole-display capture excludes NanoTeams' own windows so the screenshot never feeds the app
/// its own UI back to the model. The filter used to be a bare `==` on the bundle id — one of two
/// self-guards in this file, and the other (`windowRank`) compares case-insensitively and
/// explicitly refuses to treat an EMPTY candidate bundle id as self. These pin the two halves.
final class ScreenCaptureOwnWindowExclusionTests: XCTestCase {

    private func candidate(bundleID: String, appName: String = "App") -> ScreenCaptureService.WindowCandidate {
        .init(bundleID: bundleID, appName: appName, title: nil,
              width: 800, height: 600, isOnScreen: true, layer: 0)
    }

    private let own = "com.nanoteams.app"

    func testOwnWindows_areExcluded() {
        let candidates = [candidate(bundleID: "com.apple.Safari"), candidate(bundleID: own)]
        XCTAssertEqual(ScreenCaptureService.ownWindowIndices(candidates, ownBundleID: own), [1])
    }

    /// Matches `windowRank`'s self-guard, which compares case-insensitively. If only one of the
    /// two guards folded case, a differently-cased own-id would keep our windows OUT of the
    /// window-target search while leaving them IN the whole-screen shot.
    func testSelfMatch_isCaseInsensitive() {
        let candidates = [candidate(bundleID: "COM.NanoTeams.App")]
        XCTAssertEqual(ScreenCaptureService.ownWindowIndices(candidates, ownBundleID: own), [0])
    }

    /// The caller passes `Bundle.main.bundleIdentifier ?? ""`. A blank own-id must exclude
    /// NOTHING — matching it against every bundle-id-less window would blank out most of the
    /// screen and hand the model a picture of the desktop.
    func testBlankOwnBundleID_excludesNothing() {
        let candidates = [candidate(bundleID: ""), candidate(bundleID: "com.apple.Safari")]
        XCTAssertEqual(ScreenCaptureService.ownWindowIndices(candidates, ownBundleID: ""), [])
    }

    /// Symmetric to the above: a window with no bundle id is never "self", whatever our id is.
    func testEmptyCandidateBundleID_isNeverSelf() {
        let candidates = [candidate(bundleID: "")]
        XCTAssertEqual(ScreenCaptureService.ownWindowIndices(candidates, ownBundleID: own), [])
    }

    /// Indices, not values — the caller maps them back onto the live `SCWindow` array.
    func testEveryOwnWindow_isReported_withIndicesIntoTheInput() {
        let candidates = [
            candidate(bundleID: own), candidate(bundleID: "com.apple.Safari"),
            candidate(bundleID: own), candidate(bundleID: "com.apple.Finder"),
        ]
        XCTAssertEqual(ScreenCaptureService.ownWindowIndices(candidates, ownBundleID: own), [0, 2])
    }

    func testNoCandidates_returnsEmpty() {
        XCTAssertEqual(ScreenCaptureService.ownWindowIndices([], ownBundleID: own), [])
    }

    /// A bundle id that merely CONTAINS ours is a different app (the exact-only rule `windowRank`
    /// documents for bundle ids, applied to the self-guard too).
    func testBundleIDPrefix_isNotSelf() {
        let candidates = [candidate(bundleID: "com.nanoteams.app.helper")]
        XCTAssertEqual(ScreenCaptureService.ownWindowIndices(candidates, ownBundleID: own), [])
    }
}

// MARK: - Region geometry + envelope assembly

/// The capture region and the envelope built from it are the ONLY thing standing between the
/// model's pixel coordinates and a `CGEvent` at a global point. Both capture paths now go through
/// `captureRegion` + `make*Capture`, so a coordinate-space mistake is pinnable here instead of
/// requiring a real screenshot.
final class ScreenCaptureRegionAssemblyTests: XCTestCase {

    func testRegion_carriesTheRectVerbatimInPoints() {
        let region = ScreenCaptureService.captureRegion(
            CGRect(x: 100, y: -50, width: 800, height: 600), scale: 1.0)
        XCTAssertEqual(region.originX, 100)
        XCTAssertEqual(region.originY, -50)
        XCTAssertEqual(region.widthPt, 800)
        XCTAssertEqual(region.heightPt, 600)
    }

    /// The point size and the PIXEL size are different numbers on Retina, and the whole
    /// coordinate bug this file guards against was mixing them. A 2× 800×600pt window is
    /// 1600×1200 native, downscaled to fit 1568 — but `widthPt` stays 800.
    func testRegion_pixelSizeIsScaledAndCapped_whilePointSizeStaysInPoints() {
        let region = ScreenCaptureService.captureRegion(
            CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2.0)
        XCTAssertEqual(region.widthPt, 800)
        XCTAssertEqual(region.heightPt, 600)
        XCTAssertEqual(max(region.pixelWidth, region.pixelHeight), ScreenCaptureService.maxImageSide)
        XCTAssertEqual(region.pixelWidth, 1568)
        XCTAssertEqual(region.pixelHeight, 1176)
    }

    func testRegion_smallWindowAtOneX_isNotUpscaled() {
        let region = ScreenCaptureService.captureRegion(
            CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1.0)
        XCTAssertEqual(region.pixelWidth, 400)
        XCTAssertEqual(region.pixelHeight, 300)
    }

    /// A window on a secondary monitor to the LEFT of the main one has a negative origin. It must
    /// survive into the envelope unchanged — clamping it to zero would send every click on that
    /// window to the main display.
    func testRegion_negativeOrigin_survives() {
        let region = ScreenCaptureService.captureRegion(
            CGRect(x: -1920, y: -300, width: 600, height: 400), scale: 2.0)
        XCTAssertEqual(region.originX, -1920)
        XCTAssertEqual(region.originY, -300)
    }

    // MARK: Envelope identity fields

    private func sampleRegion() -> ScreenCaptureService.CaptureRegion {
        ScreenCaptureService.captureRegion(CGRect(x: 10, y: 20, width: 400, height: 300), scale: 1.0)
    }

    /// `targetKind` is a wire string the model reads, and `titleOnlyMatchNote` gates on it
    /// verbatim. A display capture emitting `"window"` would make that note fire on whole-screen
    /// shots, telling the model it captured the wrong app when it captured the screen.
    func testDisplayEnvelope_isTaggedDisplay_andCarriesNoWindowIdentity() {
        let captured = ScreenCaptureService.makeDisplayCapture(
            pngBase64: "PNG", imageWidth: 400, imageHeight: 300, region: sampleRegion(), displayID: 42)
        XCTAssertEqual(captured.targetKind, "display")
        XCTAssertEqual(captured.displayID, 42)
        XCTAssertNil(captured.appName)
        XCTAssertNil(captured.bundleID)
        XCTAssertNil(captured.windowTitle)
        XCTAssertNil(captured.pid)
    }

    /// The consumer-side half of the assertion above: a display capture must never be flagged as
    /// a title-only window match.
    func testDisplayEnvelope_neverTriggersTheTitleOnlyMatchWarning() {
        let captured = ScreenCaptureService.makeDisplayCapture(
            pngBase64: "PNG", imageWidth: 400, imageHeight: 300, region: sampleRegion(), displayID: 42)
        XCTAssertNil(ScreenCaptureService.titleOnlyMatchNote(requestedTarget: "screen", captured: captured))
    }

    /// `pid` is what the AX walk enumerates the window's app with; `displayID` is deliberately nil
    /// because a window is not pinned to one display.
    func testWindowEnvelope_isTaggedWindow_andCarriesTheAppIdentityAndPID() {
        let captured = ScreenCaptureService.makeWindowCapture(
            pngBase64: "PNG", imageWidth: 400, imageHeight: 300, region: sampleRegion(),
            appName: "Safari", bundleID: "com.apple.Safari",
            windowTitle: "Feed | LinkedIn", pid: 4242)
        XCTAssertEqual(captured.targetKind, "window")
        XCTAssertEqual(captured.appName, "Safari")
        XCTAssertEqual(captured.bundleID, "com.apple.Safari")
        XCTAssertEqual(captured.windowTitle, "Feed | LinkedIn")
        XCTAssertEqual(captured.pid, 4242)
        XCTAssertNil(captured.displayID)
    }

    /// The envelope reports what the COMPOSITOR produced, not what we asked for. SCK is free to
    /// return a different size, and the click inverse divides by these numbers — carrying the
    /// requested size instead would scale every click by the discrepancy.
    func testEnvelope_reportsTheProducedImageSize_notTheRequestedOne() {
        let region = ScreenCaptureService.captureRegion(
            CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2.0)
        let captured = ScreenCaptureService.makeWindowCapture(
            pngBase64: "PNG", imageWidth: 999, imageHeight: 777, region: region,
            appName: nil, bundleID: nil, windowTitle: nil, pid: nil)
        XCTAssertEqual(captured.pixelWidth, 999)
        XCTAssertEqual(captured.pixelHeight, 777)
        XCTAssertNotEqual(captured.pixelWidth, region.pixelWidth)
    }

    // MARK: Cross-service: the envelope actually feeds the click inverse

    /// End-to-end over the two services: a window frame goes in, and the top-left image pixel of
    /// the resulting envelope maps back to that window's own global origin. This is the assertion
    /// that would have caught a point/pixel mix-up in the assembly.
    func testWindowEnvelope_imageOriginMapsBackToTheWindowOrigin() throws {
        let frame = CGRect(x: 1440, y: -200, width: 900, height: 700)
        let region = ScreenCaptureService.captureRegion(frame, scale: 2.0)
        let captured = ScreenCaptureService.makeWindowCapture(
            pngBase64: "PNG", imageWidth: region.pixelWidth, imageHeight: region.pixelHeight,
            region: region, appName: "Safari", bundleID: "com.apple.Safari",
            windowTitle: "t", pid: 1)

        let point = try XCTUnwrap(InputControlService.imagePixelToGlobalPoint(
            imageX: 0, imageY: 0,
            originX: captured.originX, originY: captured.originY,
            regionWidthPt: captured.regionWidthPt, regionHeightPt: captured.regionHeightPt,
            pixelWidth: captured.pixelWidth, pixelHeight: captured.pixelHeight))
        XCTAssertEqual(point.x, frame.origin.x, accuracy: 0.0001)
        XCTAssertEqual(point.y, frame.origin.y, accuracy: 0.0001)
    }

    /// …and the LAST image pixel stays strictly inside the region (bounds are half-open), so no
    /// click aimed at a real pixel can land on the neighbouring display. Uses the DISPLAY
    /// assembler: both envelope builders feed the same inverse, so both have to agree.
    func testDisplayEnvelope_lastImagePixelStaysInsideTheRegion() throws {
        let frame = CGRect(x: 1440, y: -200, width: 900, height: 700)
        let region = ScreenCaptureService.captureRegion(frame, scale: 2.0)
        let captured = ScreenCaptureService.makeDisplayCapture(
            pngBase64: "PNG", imageWidth: region.pixelWidth, imageHeight: region.pixelHeight,
            region: region, displayID: 1)

        let point = try XCTUnwrap(InputControlService.imagePixelToGlobalPoint(
            imageX: Double(captured.pixelWidth - 1), imageY: Double(captured.pixelHeight - 1),
            originX: captured.originX, originY: captured.originY,
            regionWidthPt: captured.regionWidthPt, regionHeightPt: captured.regionHeightPt,
            pixelWidth: captured.pixelWidth, pixelHeight: captured.pixelHeight))
        XCTAssertLessThan(point.x, frame.maxX)
        XCTAssertLessThan(point.y, frame.maxY)
        XCTAssertGreaterThanOrEqual(point.x, frame.minX)
        XCTAssertGreaterThanOrEqual(point.y, frame.minY)
    }
}

// MARK: - Downscale arithmetic: the non-finite trap

/// **Regression.** `targetPixelSize` computed `Int((native * factor).rounded())`. Region
/// dimensions arrive from ANOTHER process (`SCWindow.frame` via ScreenCaptureKit) or from the
/// window server, and are not guaranteed finite — `CGRect.infinite` is a real value a window can
/// report, and a merely enormous frame overflows `regionW * scale` to `.infinity` all the same.
/// Then `factor = 1568 / .infinity == 0`, `.infinity * 0 == .nan`, and `Int(Double.nan)` is an
/// UNCATCHABLE trap: `Fatal error: Double value cannot be converted to Int because it is either
/// infinite or NaN`. A single misreported window frame took the whole app down, from a value no
/// caller controls. (Same defect class as `AccessibilityInspector.Geometry.mapFrame`'s
/// `Int(exactly:)` guard, from the same untrusted-geometry source.)
///
/// These tests cannot "catch" the trap — a trap kills the worker process. Reaching the assertion
/// at all IS the assertion.
final class ScreenCaptureDownscaleSafetyTests: XCTestCase {

    private func assertUsable(
        _ size: (Int, Int), file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(size.0, 1, "width must be a capturable pixel count", file: file, line: line)
        XCTAssertGreaterThanOrEqual(size.1, 1, "height must be a capturable pixel count", file: file, line: line)
        XCTAssertLessThanOrEqual(
            max(size.0, size.1), ScreenCaptureService.maxImageSide,
            "long side must respect the cap", file: file, line: line)
    }

    // MARK: The regression

    func testInfiniteWidth_doesNotTrap() {
        assertUsable(ScreenCaptureService.targetPixelSize(regionW: .infinity, regionH: 1000, scale: 2.0))
    }

    func testInfiniteHeight_doesNotTrap() {
        assertUsable(ScreenCaptureService.targetPixelSize(regionW: 1000, regionH: .infinity, scale: 2.0))
    }

    /// `CGRect.infinite` in both axes — the literal value AppKit/CoreGraphics use for "unbounded".
    func testFullyInfiniteRect_doesNotTrap() {
        assertUsable(ScreenCaptureService.targetPixelSize(
            regionW: .infinity, regionH: .infinity, scale: 2.0))
    }

    /// The subtler reachability: a FINITE but enormous frame whose product with the backing scale
    /// overflows. No infinity is ever reported by the window server here — the overflow is ours.
    func testFiniteButOverflowingProduct_doesNotTrap() {
        assertUsable(ScreenCaptureService.targetPixelSize(
            regionW: .greatestFiniteMagnitude, regionH: 800, scale: 2.0))
    }

    /// A non-finite backing scale can only come from a malformed display mode, but it flows into
    /// the same multiplication.
    func testInfiniteScale_doesNotTrap() {
        assertUsable(ScreenCaptureService.targetPixelSize(regionW: 800, regionH: 600, scale: .infinity))
    }

    func testNaNScale_doesNotTrap() {
        assertUsable(ScreenCaptureService.targetPixelSize(regionW: 800, regionH: 600, scale: .nan))
    }

    // MARK: Characterization — inputs the old code already handled keep their exact answers

    /// NaN previously collapsed to the 1pt floor via `max(1.0, .nan)` (Swift's `max` returns `x`
    /// when `y >= x` is false, and every comparison with NaN is false). The fix must not change
    /// that: only `+∞` behaved differently before, because only `+∞` trapped.
    func testNaNDimensions_stillCollapseToTheOnePixelFloor() {
        let (w, h) = ScreenCaptureService.targetPixelSize(regionW: .nan, regionH: .nan, scale: 2.0)
        XCTAssertEqual(w, 1)
        XCTAssertEqual(h, 1)
    }

    /// A negative width (an inverted rect) also collapsed to the floor before, and still does.
    func testNegativeDimensions_stillCollapseToTheOnePixelFloor() {
        let (w, h) = ScreenCaptureService.targetPixelSize(regionW: -800, regionH: -600, scale: 2.0)
        XCTAssertEqual(w, 1)
        XCTAssertEqual(h, 1)
    }

    func testNegativeInfinity_collapsesToTheFloor_ratherThanTheCap() {
        let (w, _) = ScreenCaptureService.targetPixelSize(regionW: -.infinity, regionH: 600, scale: 2.0)
        XCTAssertEqual(w, 1)
    }

    /// Anti-vacuity for the whole suite: ordinary geometry is untouched by the sanitizer.
    /// (These duplicate `ScreenCaptureServiceGeometryTests` on purpose — if the fix had shifted
    /// the normal path, that would show up here rather than only in a sibling file.)
    func testOrdinaryRetinaDisplay_isUnchangedByTheSanitizer() {
        let (w, h) = ScreenCaptureService.targetPixelSize(regionW: 1512, regionH: 982, scale: 2.0)
        XCTAssertEqual(w, 1568)
        XCTAssertEqual(h, 1018)
    }

    func testSmallRegion_isStillNotUpscaled() {
        let (w, h) = ScreenCaptureService.targetPixelSize(regionW: 300, regionH: 200, scale: 1.0)
        XCTAssertEqual(w, 300)
        XCTAssertEqual(h, 200)
    }

    /// The one axis a mixed infinite/finite pair must still get right: the finite side is scaled
    /// by the real factor, not silently zeroed.
    func testInfiniteWidthWithFiniteHeight_stillScalesTheFiniteAxisProportionally() {
        let (_, h) = ScreenCaptureService.targetPixelSize(regionW: .infinity, regionH: 1000, scale: 2.0)
        XCTAssertEqual(h, ScreenCaptureService.maxImageSide)
    }
}
