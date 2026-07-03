import ScreenCaptureKit
import XCTest

@testable import NanoTeams

/// Pure downscale-math pins for `ScreenCaptureService.targetPixelSize`.
final class ScreenCaptureServiceGeometryTests: XCTestCase {

    func testSmallRegion_isNotUpscaled() {
        // Native 800×600 ≤ maxImageSide → returned as-is.
        let (w, h) = ScreenCaptureService.targetPixelSize(regionW: 400, regionH: 300, scale: 2)
        XCTAssertEqual(w, 800)
        XCTAssertEqual(h, 600)
    }

    func testLargeRegion_downscaledToLongSide() {
        // Native 2880×1800; long side capped at 1568 (0.5444× → 980 tall).
        let (w, h) = ScreenCaptureService.targetPixelSize(regionW: 1440, regionH: 900, scale: 2)
        XCTAssertEqual(w, ScreenCaptureService.maxImageSide)
        XCTAssertEqual(h, 980)
    }

    func testPortraitRegion_capsHeight() {
        let (w, h) = ScreenCaptureService.targetPixelSize(regionW: 900, regionH: 1440, scale: 2)
        XCTAssertEqual(h, ScreenCaptureService.maxImageSide)
        XCTAssertEqual(w, 980)
    }

    func testScaleOne() {
        // Native 2000×1000; 0.784× → 1568×784.
        let (w, h) = ScreenCaptureService.targetPixelSize(regionW: 2000, regionH: 1000, scale: 1)
        XCTAssertEqual(w, ScreenCaptureService.maxImageSide)
        XCTAssertEqual(h, 784)
    }

    func testDegenerateTinyRegion_clampsToAtLeastOne() {
        let (w, h) = ScreenCaptureService.targetPixelSize(regionW: 0.3, regionH: 0.3, scale: 1)
        XCTAssertGreaterThanOrEqual(w, 1)
        XCTAssertGreaterThanOrEqual(h, 1)
    }

    func testAspectRatioIsPreserved() {
        let (w, h) = ScreenCaptureService.targetPixelSize(regionW: 1600, regionH: 900, scale: 2)
        // 16:9 native 3200×1800 → both scaled by the same factor.
        XCTAssertEqual(Double(w) / Double(h), 1600.0 / 900.0, accuracy: 0.01)
    }

    /// A single-window capture must exclude the window's drop shadow + global clip, otherwise the
    /// captured content covers `window.frame + shadow` while the click geometry is mapped against
    /// `window.frame` → every window-target click drifts by the shadow inset.
    func testConfiguration_ignoresShadowAndGlobalClip() {
        let config = ScreenCaptureService.makeConfiguration(pxW: 800, pxH: 600)
        XCTAssertEqual(config.width, 800)
        XCTAssertEqual(config.height, 600)
        XCTAssertFalse(config.showsCursor)
        XCTAssertTrue(config.ignoreShadowsSingleWindow, "window capture must not include the drop shadow")
        XCTAssertTrue(config.ignoreGlobalClipSingleWindow)
    }

    // MARK: - Window selection (pure ranking)

    private func candidate(
        bundleID: String = "", appName: String, title: String? = nil,
        width: Double = 800, height: Double = 600, onScreen: Bool = true, layer: Int = 0
    ) -> ScreenCaptureService.WindowCandidate {
        .init(bundleID: bundleID, appName: appName, title: title,
              width: width, height: height, isOnScreen: onScreen, layer: layer)
    }

    /// The exact reproduction of the reported bug: `target:"safari"` must pick real Safari, NOT
    /// the (larger) "Open and Save Panel Service (Safari)" helper window whose app name merely
    /// CONTAINS "safari".
    func testBestWindow_exactAppBeatsLargerHelperSubstring() {
        let candidates = [
            candidate(bundleID: "com.apple.appkit.xpc.openAndSavePanelService",
                      appName: "Open and Save Panel Service (Safari)", width: 500, height: 500),
            candidate(bundleID: "com.apple.Safari", appName: "Safari", width: 1440, height: 900),
        ]
        let idx = ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "safari", windowTitle: nil, ownBundleID: "com.nanoteams")
        XCTAssertEqual(idx, 1, "exact 'Safari' match must win over the helper's substring match")
    }

    func testBestWindow_exactBeatsHelperEvenWhenHelperIsLarger() {
        let candidates = [
            candidate(appName: "Open and Save Panel Service (Safari)", width: 3000, height: 2000),
            candidate(appName: "Safari", width: 100, height: 100),
        ]
        XCTAssertEqual(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "safari", windowTitle: nil, ownBundleID: "x"), 1)
    }

    func testBestWindow_prefersOnScreenNormalLayer() {
        // Two substring matches (no exact): the on-screen normal-layer one wins over a bigger
        // off-screen / panel-layer one.
        let candidates = [
            candidate(appName: "Google Chrome Helper", width: 2000, height: 2000, onScreen: false, layer: 25),
            candidate(appName: "Google Chrome", width: 1200, height: 800, onScreen: true, layer: 0),
        ]
        XCTAssertEqual(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "chrome", windowTitle: nil, ownBundleID: "x"), 1)
    }

    func testBestWindow_areaTiebreakWithinSameClass() {
        let candidates = [
            candidate(appName: "Safari", width: 800, height: 600),
            candidate(appName: "Safari", width: 1440, height: 900),
        ]
        XCTAssertEqual(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "safari", windowTitle: nil, ownBundleID: "x"), 1)
    }

    func testBestWindow_excludesSelfAndDegenerate() {
        let candidates = [
            candidate(bundleID: "com.nanoteams", appName: "NanoTeams"),   // self → excluded
            candidate(appName: "Safari", width: 1, height: 1),           // degenerate → excluded
        ]
        XCTAssertNil(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "nanoteams", windowTitle: nil, ownBundleID: "com.nanoteams"))
        XCTAssertNil(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "safari", windowTitle: nil, ownBundleID: "com.nanoteams"))
    }

    func testBestWindow_windowTitleConstraint() {
        let candidates = [
            candidate(appName: "Safari", title: "GitHub"),
            candidate(appName: "Safari", title: "LinkedIn"),
        ]
        XCTAssertEqual(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "safari", windowTitle: "linked", ownBundleID: "x"), 1)
        XCTAssertNil(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "safari", windowTitle: "reddit", ownBundleID: "x"))
    }

    func testBestWindow_noMatchReturnsNil() {
        XCTAssertNil(ScreenCaptureService.bestWindowIndex(
            [candidate(appName: "Mail")], specLower: "safari", windowTitle: nil, ownBundleID: "x"))
    }

    // MARK: - Title-only matching (websites targeted by name)

    /// The incident: `target:"LinkedIn"` errored "No visible window found" while Safari sat
    /// on linkedin.com — the model concluded the site wasn't open and detoured through
    /// Spotlight + ask_supervisor. A window TITLE match must resolve it to the browser window.
    func testBestWindow_titleOnlyMatch_findsBrowserWindowShowingSite() {
        let candidates = [
            candidate(appName: "Mail", title: "Inbox"),
            candidate(appName: "Safari", title: "Feed | LinkedIn"),
        ]
        XCTAssertEqual(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "linkedin", windowTitle: nil, ownBundleID: "x"), 1)
    }

    func testBestWindow_appMatchBeatsTitleOnlyMatch() {
        // `target:"Safari"` must never be stolen by a window merely TITLED "…Safari…",
        // even a much larger one — app-name tiers stay above the title tier.
        let candidates = [
            candidate(appName: "Notes", title: "My Safari bookmarks notes", width: 3000, height: 2000),
            candidate(appName: "Safari", title: "Start Page", width: 800, height: 600),
        ]
        XCTAssertEqual(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "safari", windowTitle: nil, ownBundleID: "x"), 1)
    }

    func testBestWindow_titleMatch_stillHonorsWindowTitleConstraint() {
        let candidates = [
            candidate(appName: "Safari", title: "Feed | LinkedIn"),
            candidate(appName: "Safari", title: "LinkedIn Jobs"),
        ]
        XCTAssertEqual(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "linkedin", windowTitle: "jobs", ownBundleID: "x"), 1)
    }

    func testBestWindow_titleMatchOnOwnWindow_excluded() {
        // Our own window whose title contains the spec must never be captured (self-guard runs
        // before the title tier).
        let candidates = [
            candidate(bundleID: "com.nanoteams", appName: "NanoTeams", title: "LinkedIn notes"),
        ]
        XCTAssertNil(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "linkedin", windowTitle: nil, ownBundleID: "com.nanoteams"))
    }

    func testBestWindow_titleMatchOnDegenerateWindow_excluded() {
        let candidates = [
            candidate(appName: "Safari", title: "LinkedIn", width: 1, height: 1),
        ]
        XCTAssertNil(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "linkedin", windowTitle: nil, ownBundleID: "x"))
    }

    func testBestWindow_neitherAppNorTitleMatch_returnsNil() {
        let candidates = [candidate(appName: "Mail", title: "Inbox")]
        XCTAssertNil(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "linkedin", windowTitle: nil, ownBundleID: "x"))
    }

    func testBestWindow_twoTitleOnlyMatches_prefersOnScreenNormalLayer() {
        // Both match by title only (app names don't contain the spec) — the on-screen, normal-layer
        // one wins over a bigger off-screen / panel-layer one.
        let candidates = [
            candidate(appName: "Chrome Helper", title: "LinkedIn", width: 3000, height: 2000,
                      onScreen: false, layer: 25),
            candidate(appName: "Safari", title: "LinkedIn", width: 800, height: 600,
                      onScreen: true, layer: 0),
        ]
        XCTAssertEqual(ScreenCaptureService.bestWindowIndex(
            candidates, specLower: "linkedin", windowTitle: nil, ownBundleID: "x"), 1)
    }

    // MARK: - windowNotFound error (actionable for weak models)

    // MARK: - titleOnlyMatchNote (wrong-app-by-title guard)

    private func captured(
        kind: String = "window", appName: String?, bundleID: String? = nil, title: String? = nil
    ) -> CapturedScreen {
        CapturedScreen(
            pngBase64: "", pixelWidth: 100, pixelHeight: 100,
            regionWidthPt: 100, regionHeightPt: 100, originX: 0, originY: 0,
            targetKind: kind, appName: appName, bundleID: bundleID, windowTitle: title,
            displayID: nil, pid: nil)
    }

    func testTitleOnlyMatchNote_warnsWhenCapturedAppDiffersFromTarget() {
        // target:"Notes" (closed) matched a Safari tab "Release Notes" → warn, don't silently
        // let the model operate Safari believing it's Notes.
        let note = ScreenCaptureService.titleOnlyMatchNote(
            requestedTarget: "Notes",
            captured: captured(appName: "Safari", bundleID: "com.apple.Safari", title: "Release Notes"))
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("“Safari”") ?? false)
        XCTAssertTrue(note?.contains("“Notes”") ?? false)
    }

    func testTitleOnlyMatchNote_silentOnGenuineAppMatch() {
        XCTAssertNil(ScreenCaptureService.titleOnlyMatchNote(
            requestedTarget: "Safari", captured: captured(appName: "Safari", bundleID: "com.apple.Safari")))
        // Substring app match (the existing behavior) also stays silent.
        XCTAssertNil(ScreenCaptureService.titleOnlyMatchNote(
            requestedTarget: "safari", captured: captured(appName: "Safari Technology Preview")))
        // Bundle-id match stays silent.
        XCTAssertNil(ScreenCaptureService.titleOnlyMatchNote(
            requestedTarget: "com.apple.Safari", captured: captured(appName: "Safari", bundleID: "com.apple.Safari")))
    }

    func testTitleOnlyMatchNote_silentOnDisplayCapture() {
        XCTAssertNil(ScreenCaptureService.titleOnlyMatchNote(
            requestedTarget: "screen", captured: captured(kind: "display", appName: nil)))
    }

    func testTitleOnlyMatchNote_caseInsensitiveAppMatch_staysSilent() {
        XCTAssertNil(ScreenCaptureService.titleOnlyMatchNote(
            requestedTarget: "SAFARI", captured: captured(appName: "Safari", bundleID: "com.apple.Safari")))
    }

    func testTitleOnlyMatchNote_windowKindButNilAppName_staysSilent() {
        // A window capture that somehow carries no app name can't be classified — no false warning.
        XCTAssertNil(ScreenCaptureService.titleOnlyMatchNote(
            requestedTarget: "Notes", captured: captured(appName: nil, title: "Release Notes")))
    }

    func testWindowNotFoundError_namesBrowserHintAndVisibleApps() {
        let message = ScreenCaptureError.windowNotFound(
            "LinkedIn", visibleApps: ["Finder", "Safari"]).errorDescription ?? ""
        XCTAssertTrue(message.contains("'LinkedIn'"))
        XCTAssertTrue(message.contains("website is a page inside a browser"),
                      "must teach site ≠ app")
        XCTAssertTrue(message.contains("Visible apps: Finder, Safari."))
    }

    func testWindowNotFoundError_noApps_omitsEmptyList() {
        let message = ScreenCaptureError.windowNotFound("X", visibleApps: []).errorDescription ?? ""
        XCTAssertFalse(message.contains("Visible apps"))
    }

    func testVisibleAppNames_filtersSelfOffscreenDegenerateSystemSurfaces_dedupsAndSorts() {
        let candidates = [
            candidate(bundleID: "com.nanoteams", appName: "NanoTeams"),                    // self
            candidate(appName: "Safari", title: "A"),
            candidate(appName: "Safari", title: "B"),                                      // dup name
            candidate(appName: "Ghost", onScreen: false),                                  // off-screen
            candidate(appName: "Sliver", width: 1, height: 1),                             // degenerate
            candidate(appName: ""),                                                        // unnamed
            candidate(appName: "Control Centre", layer: 25),                               // system overlay
            candidate(appName: "Dock", layer: 20),                                         // system surface
            candidate(appName: "Finder"),
        ]
        XCTAssertEqual(
            ScreenCaptureService.visibleAppNames(candidates, ownBundleID: "com.nanoteams"),
            ["Finder", "Safari"], "layer>0 system surfaces (Dock, Control Centre) must be excluded")
    }

    func testVisibleAppNames_empty_returnsEmpty() {
        XCTAssertEqual(ScreenCaptureService.visibleAppNames([], ownBundleID: "com.nanoteams"), [])
    }

    func testVisibleAppNames_allExcluded_returnsEmpty() {
        let candidates = [
            candidate(bundleID: "com.nanoteams", appName: "NanoTeams"),   // self
            candidate(appName: "Offscreen", onScreen: false),             // off-screen
            candidate(appName: "Overlay", layer: 25),                     // system surface
            candidate(appName: "Tiny", width: 1, height: 1),              // degenerate
        ]
        XCTAssertEqual(ScreenCaptureService.visibleAppNames(candidates, ownBundleID: "com.nanoteams"), [])
    }

    // MARK: - Accessibility-empty note

    func testEmptyElementsNote_onlyWhenEmptyAndUntrusted() {
        XCTAssertNotNil(AccessibilityInspector.emptyElementsNote(hasAccessibility: false, elementCount: 0))
        XCTAssertNil(AccessibilityInspector.emptyElementsNote(hasAccessibility: true, elementCount: 0),
                     "AX granted → an empty list is genuine, no note")
        XCTAssertNil(AccessibilityInspector.emptyElementsNote(hasAccessibility: false, elementCount: 5))
    }
}
