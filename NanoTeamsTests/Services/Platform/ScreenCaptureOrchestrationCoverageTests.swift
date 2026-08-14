import CoreGraphics
import XCTest

@testable import NanoTeams

// MARK: - Fake backend

/// A shareable-content set as plain values. `SCShareableContent` is only ever addressed by index
/// from above the seam, so a fixture needs nothing but two arrays.
struct FakeShareableContent: Sendable {
    var displays: [DisplaySnapshot] = []
    var windows: [WindowSnapshot] = []
}

final class FakeScreenCaptureBackend: ScreenCaptureBackend, @unchecked Sendable {

    struct DisplayCaptureCall: Equatable {
        let index: Int
        let excludingWindowIndices: [Int]
        let pixelWidth: Int
        let pixelHeight: Int
    }

    struct WindowCaptureCall: Equatable {
        let index: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    var permissionGranted = true
    /// What a second `hasPermission()` answers after the prompt — the "granted during the prompt,
    /// but not until relaunch" state.
    var permissionAfterPrompt: Bool?
    var content: Result<FakeShareableContent, Error> = .success(FakeShareableContent())
    var image = CapturedImage(pngBase64: "cG5n", pixelWidth: 64, pixelHeight: 48)
    var captureError: Error?

    private(set) var permissionChecks = 0
    private(set) var permissionRequests = 0
    private(set) var displayCaptures: [DisplayCaptureCall] = []
    private(set) var windowCaptures: [WindowCaptureCall] = []

    func hasPermission() -> Bool {
        permissionChecks += 1
        if permissionChecks > 1, let permissionAfterPrompt { return permissionAfterPrompt }
        return permissionGranted
    }

    @discardableResult
    func requestPermission() -> Bool {
        permissionRequests += 1
        return permissionAfterPrompt ?? permissionGranted
    }

    func shareableContent() async throws -> FakeShareableContent { try content.get() }

    func displays(in content: FakeShareableContent) -> [DisplaySnapshot] { content.displays }
    func windows(in content: FakeShareableContent) -> [WindowSnapshot] { content.windows }

    func captureDisplay(
        _ content: FakeShareableContent, index: Int, excludingWindowIndices: [Int],
        pixelWidth: Int, pixelHeight: Int
    ) async throws -> CapturedImage {
        displayCaptures.append(DisplayCaptureCall(
            index: index, excludingWindowIndices: excludingWindowIndices,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight))
        if let captureError { throw captureError }
        return image
    }

    func captureWindow(
        _ content: FakeShareableContent, index: Int, pixelWidth: Int, pixelHeight: Int
    ) async throws -> CapturedImage {
        windowCaptures.append(WindowCaptureCall(
            index: index, pixelWidth: pixelWidth, pixelHeight: pixelHeight))
        if let captureError { throw captureError }
        return image
    }
}

// MARK: - Tests

/// `ScreenCaptureService.capture` — the chain that turns a model's free-text `target` into a
/// screenshot plus the geometry every subsequent click is aimed with.
///
/// Every *decision* in that chain already had tests (`resolveTarget`, `windowRank`,
/// `bestWindowIndex`, `mainDisplayIndex`, `ownWindowIndices`, `captureRegion`, `targetPixelSize`).
/// What had none was the **composition** — which is where the coordinate bugs actually happened:
/// the Retina-factor drift came from taking a region's origin and its size from two different
/// spaces, and the window-shadow drift from mapping against a frame the compositor had not
/// honoured. Neither is visible in any single pure function; both are visible here.
///
/// The seam is deliberately index-addressed. A backend that returned opaque handles would let this
/// suite assert only "a capture happened"; returning displays and windows as values means the test
/// can state which one was chosen and why, which is the whole question.
///
/// RED: swap `display.boundsPt` for a synthetic origin in `captureDisplay` → the origin assertions
/// in `testDisplayCapture_carriesTheDisplaysOwnGeometry` fail.
final class ScreenCaptureOrchestrationCoverageTests: XCTestCase {

    private var backend: FakeScreenCaptureBackend!

    override func setUp() {
        super.setUp()
        backend = FakeScreenCaptureBackend()
    }

    override func tearDown() {
        backend = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func display(
        id: CGDirectDisplayID, x: Double = 0, y: Double = 0,
        w: Double = 1440, h: Double = 900, scale: Double = 2
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: id, boundsPt: CGRect(x: x, y: y, width: w, height: h), scale: scale)
    }

    private func window(
        app: String, bundle: String, title: String? = nil,
        x: Double = 100, y: Double = 200, w: Double = 800, h: Double = 600,
        onScreen: Bool = true, layer: Int = 0, scale: Double = 2, pid: pid_t = 42
    ) -> WindowSnapshot {
        WindowSnapshot(
            candidate: ScreenCaptureService.WindowCandidate(
                bundleID: bundle, appName: app, title: title,
                width: w, height: h, isOnScreen: onScreen, layer: layer),
            framePt: CGRect(x: x, y: y, width: w, height: h),
            scale: scale, appName: app, bundleID: bundle, title: title, pid: pid)
    }

    private func capture(
        _ spec: String, windowTitle: String? = nil, ownBundleID: String = "com.nanoteams.app"
    ) async throws -> CapturedScreen {
        try await ScreenCaptureService.capture(
            targetSpec: spec, windowTitle: windowTitle, ownBundleID: ownBundleID, backend: backend)
    }

    // MARK: - Permission

    /// The preflight is the first thing that runs, and a denial prompts exactly once — the system
    /// pane is modal-ish and a capture loop that re-prompted per call would be unusable.
    func testWithoutPermission_promptsOnceAndThrows() async {
        backend.permissionGranted = false

        await XCTAssertThrowsErrorAsync(try await capture("screen")) { error in
            guard case .permissionDenied? = error as? ScreenCaptureError else {
                return XCTFail("expected .permissionDenied, got \(error)")
            }
        }
        XCTAssertEqual(backend.permissionRequests, 1)
    }

    /// A grant that lands DURING the prompt still cannot capture until the app relaunches, so the
    /// two denial states must stay distinguishable — telling a just-granted user "permission is
    /// required" sends them back to a switch that is already on.
    ///
    /// RED: return `.permissionDenied` unconditionally → this fails while the test above still
    /// passes, which is exactly the pair that makes the distinction meaningful.
    func testPermissionGrantedDuringThePrompt_asksForARelaunch() async {
        backend.permissionGranted = false
        backend.permissionAfterPrompt = true

        await XCTAssertThrowsErrorAsync(try await capture("screen")) { error in
            guard case .permissionNeedsRelaunch? = error as? ScreenCaptureError else {
                return XCTFail("expected .permissionNeedsRelaunch, got \(error)")
            }
        }
    }

    func testShareableContentFailure_surfacesAsCaptureFailed() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "window server said no" } }
        backend.content = .failure(Boom())

        await XCTAssertThrowsErrorAsync(try await capture("screen")) { error in
            guard case .captureFailed(let reason)? = error as? ScreenCaptureError else {
                return XCTFail("expected .captureFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("window server said no"))
        }
    }

    // MARK: - Display path

    /// `"screen"` must capture the MAIN display. The shareable set's order is not documented as
    /// main-first, so picking `.first` blindly reads to the user as the model clicking the wrong
    /// monitor.
    ///
    /// RED: replace `mainDisplayIndex(...)` with `0` → index 1 is captured instead.
    func testScreenTarget_capturesTheMainDisplay() async throws {
        let mainID = CGMainDisplayID()
        backend.content = .success(FakeShareableContent(displays: [
            display(id: mainID &+ 1, x: -1440),
            display(id: mainID),
        ]))

        let captured = try await capture("screen")

        XCTAssertEqual(backend.displayCaptures.first?.index, 1)
        XCTAssertEqual(captured.displayID, mainID)
        XCTAssertEqual(captured.targetKind, "display")
    }

    /// Nothing to capture is an error, not an empty screenshot.
    func testScreenTarget_withNoDisplays_throwsNoDisplay() async {
        backend.content = .success(FakeShareableContent(displays: []))

        await XCTAssertThrowsErrorAsync(try await capture("screen")) { error in
            guard case .noDisplay? = error as? ScreenCaptureError else {
                return XCTFail("expected .noDisplay, got \(error)")
            }
        }
    }

    /// The click inverse divides by the geometry recorded here, so origin and size must both come
    /// from the display's own point-space bounds, and the DELIVERED image size must be believed
    /// rather than the requested one.
    func testDisplayCapture_carriesTheDisplaysOwnGeometry() async throws {
        backend.content = .success(FakeShareableContent(displays: [
            display(id: CGMainDisplayID(), x: -1440, y: -200, w: 1440, h: 900, scale: 2)
        ]))
        backend.image = CapturedImage(pngBase64: "aW1n", pixelWidth: 1568, pixelHeight: 980)

        let captured = try await capture("screen")

        XCTAssertEqual(captured.originX, -1440)
        XCTAssertEqual(captured.originY, -200)
        XCTAssertEqual(captured.regionWidthPt, 1440)
        XCTAssertEqual(captured.regionHeightPt, 900)
        XCTAssertEqual(captured.pixelWidth, 1568, "the compositor's delivered width, not the request")
        XCTAssertEqual(captured.pixelHeight, 980)
        XCTAssertEqual(captured.pngBase64, "aW1n")
    }

    /// A whole-screen shot must never feed the app its own UI back to the model. The exclusion is
    /// computed here and handed to the compositor as indices.
    ///
    /// RED: pass `[]` for `excludingWindowIndices` → NanoTeams' own windows appear in the shot.
    func testDisplayCapture_excludesOurOwnWindows() async throws {
        backend.content = .success(FakeShareableContent(
            displays: [display(id: CGMainDisplayID())],
            windows: [
                window(app: "Safari", bundle: "com.apple.Safari"),
                window(app: "NanoTeams", bundle: "com.nanoteams.app"),
                window(app: "Notes", bundle: "com.apple.Notes"),
                window(app: "NanoTeams", bundle: "COM.NANOTEAMS.APP"),
            ]))

        _ = try await capture("screen")

        XCTAssertEqual(backend.displayCaptures.first?.excludingWindowIndices, [1, 3],
                       "bundle ids compare case-insensitively, so a differently-cased id is still us")
    }

    // MARK: - Window path

    /// An EXACT app match must beat a substring match against a helper process — `target:"safari"`
    /// once resolved to "Open and Save Panel Service (Safari)" and handed the model an empty,
    /// un-actionable window.
    ///
    /// RED: drop the `exactApp` tier from `WindowMatchRank` → the larger helper window wins.
    func testWindowTarget_prefersTheExactAppOverALargerHelper() async throws {
        backend.content = .success(FakeShareableContent(windows: [
            window(app: "Open and Save Panel Service (Safari)", bundle: "com.apple.appkit.xpc",
                   w: 1600, h: 1200),
            window(app: "Safari", bundle: "com.apple.Safari", title: "Feed | LinkedIn", w: 800, h: 600),
        ]))

        let captured = try await capture("safari")

        XCTAssertEqual(backend.windowCaptures.first?.index, 1)
        XCTAssertEqual(captured.appName, "Safari")
        XCTAssertEqual(captured.windowTitle, "Feed | LinkedIn")
        XCTAssertEqual(captured.targetKind, "window")
    }

    /// Window geometry comes from the window's own frame and the scale of the display it sits on —
    /// a window on a secondary, differently-scaled monitor must not be measured with the main
    /// display's factor.
    func testWindowCapture_usesTheWindowsFrameAndItsOwnDisplayScale() async throws {
        backend.content = .success(FakeShareableContent(windows: [
            window(app: "Notes", bundle: "com.apple.Notes", x: 300, y: 150, w: 400, h: 300, scale: 1)
        ]))

        let captured = try await capture("Notes")

        XCTAssertEqual(captured.originX, 300)
        XCTAssertEqual(captured.originY, 150)
        XCTAssertEqual(captured.regionWidthPt, 400)
        XCTAssertEqual(captured.regionHeightPt, 300)
        XCTAssertEqual(backend.windowCaptures.first?.pixelWidth, 400,
                       "at scale 1 the request is the point size, not double it")
        XCTAssertEqual(backend.windowCaptures.first?.pixelHeight, 300)
        XCTAssertNil(captured.displayID, "a window is not pinned to one display")
        XCTAssertEqual(captured.pid, 42, "the pid is what AX enumeration is aimed at")
    }

    /// A `window_title` narrows the match; nothing matching it is a miss, not a fallback to the
    /// app's other window.
    func testWindowTitleConstraint_isHonoured() async throws {
        backend.content = .success(FakeShareableContent(windows: [
            window(app: "Safari", bundle: "com.apple.Safari", title: "Inbox", w: 1000, h: 800),
            window(app: "Safari", bundle: "com.apple.Safari", title: "Feed | LinkedIn"),
        ]))

        let captured = try await capture("Safari", windowTitle: "LinkedIn")

        XCTAssertEqual(captured.windowTitle, "Feed | LinkedIn")
    }

    /// The miss names what IS capturable. A bare "not found" reads to a weak model as "the site
    /// isn't open" and sends it detouring through Spotlight; the alternatives are the actionable
    /// part. Our own windows and non-ordinary layers are filtered out of that list — offering the
    /// Dock as a target is worse than offering nothing.
    ///
    /// RED: drop the `layer == 0` filter in `visibleAppNames` → "Dock" appears in the hint.
    func testUnmatchedTarget_throwsNamingTheCapturableApps() async {
        backend.content = .success(FakeShareableContent(windows: [
            window(app: "Safari", bundle: "com.apple.Safari"),
            window(app: "Dock", bundle: "com.apple.dock", layer: 20),
            window(app: "NanoTeams", bundle: "com.nanoteams.app"),
        ]))

        await XCTAssertThrowsErrorAsync(try await capture("Notes")) { error in
            guard case .windowNotFound(let spec, let visible)? = error as? ScreenCaptureError else {
                return XCTFail("expected .windowNotFound, got \(error)")
            }
            XCTAssertEqual(spec, "Notes")
            XCTAssertEqual(visible, ["Safari"])
        }
        XCTAssertEqual(backend.windowCaptures, [], "nothing may be captured when nothing matched")
    }

    /// The compositor refusing is reported with its reason rather than as a generic failure.
    func testCompositorFailure_surfacesAsCaptureFailed() async {
        backend.content = .success(FakeShareableContent(displays: [display(id: CGMainDisplayID())]))
        backend.captureError = ScreenCaptureError.captureFailed("display disconnected")

        await XCTAssertThrowsErrorAsync(try await capture("screen")) { error in
            guard case .captureFailed(let reason)? = error as? ScreenCaptureError else {
                return XCTFail("expected .captureFailed, got \(error)")
            }
            XCTAssertEqual(reason, "display disconnected")
        }
    }

    // MARK: - Routing

    /// The spec is model-authored free text, so the display pseudo-targets are matched trimmed and
    /// case-insensitively — and a blank spec means the screen rather than a hunt for an app with no
    /// name.
    func testDisplayPseudoTargets_allRouteToTheDisplayPath() async throws {
        for spec in ["screen", "  Screen ", "DISPLAY", "", "   "] {
            backend = FakeScreenCaptureBackend()
            backend.content = .success(FakeShareableContent(
                displays: [display(id: CGMainDisplayID())],
                windows: [window(app: "Screen Sharing", bundle: "com.apple.ScreenSharing")]))

            _ = try await capture(spec)

            XCTAssertEqual(backend.displayCaptures.count, 1, "\"\(spec)\" must capture the display")
            XCTAssertEqual(backend.windowCaptures.count, 0,
                           "\"\(spec)\" must not be matched against a window merely named like it")
        }
    }

    // MARK: - Display scale

    /// The backing scale is the factor that converts a region's point size into the pixel size the
    /// compositor is asked for, so it is one half of every coordinate this stack produces. The
    /// assertions are invariants rather than a number, because the answer legitimately differs
    /// between a Retina laptop and an external 1× monitor — what must hold on both is that it is
    /// positive and finite, since a zero or NaN propagates into `targetPixelSize` and from there
    /// into every click.
    func testDisplayScale_ofTheMainDisplay_isPositiveAndFinite() {
        let scale = ScreenCaptureService.displayScale(CGMainDisplayID())

        XCTAssertTrue(scale.isFinite)
        XCTAssertGreaterThan(scale, 0)
    }

    /// An unknown display id has no mode to read, and the 2.0 default is the Retina assumption —
    /// the safe direction, since over-requesting pixels downscales cleanly while under-requesting
    /// hands the model a blurry image it must click into.
    func testDisplayScale_ofAnUnknownDisplay_fallsBackToRetina() {
        XCTAssertEqual(ScreenCaptureService.displayScale(CGDirectDisplayID(0xDEAD_BEEF)), 2.0)
    }

    /// A window is measured with the scale of the display it actually sits on — mixing a secondary
    /// monitor's window with the main display's factor is the same class of error as mixing point
    /// and pixel spaces.
    func testDisplayScale_forAPointOnTheMainDisplay_matchesThatDisplay() {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let inside = CGPoint(x: bounds.midX, y: bounds.midY)

        XCTAssertEqual(
            ScreenCaptureService.displayScale(displayContaining: inside),
            ScreenCaptureService.displayScale(CGMainDisplayID()))
    }

    /// A point on no display at all — a window the server reports off-screen — falls back to the
    /// main display rather than to a hardcoded guess.
    func testDisplayScale_forAPointOnNoDisplay_fallsBackToTheMainDisplay() {
        let nowhere = CGPoint(x: -1_000_000, y: -1_000_000)

        XCTAssertEqual(
            ScreenCaptureService.displayScale(displayContaining: nowhere),
            ScreenCaptureService.displayScale(CGMainDisplayID()))
    }

    // MARK: - Wiring

    /// The live adapter is named in exactly one place — the three-argument entry point. The generic
    /// overload has no default backend on purpose: a default resolving outward is how a test comes
    /// to ask the real window server for content and the real compositor for pixels.
    func testProductionEntryPoint_isTheOnlyPlaceTheLiveBackendIsNamed() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Platform
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // NanoTeamsTests
            .deletingLastPathComponent()   // repo root
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "NanoTeams/Services/Platform/ScreenCaptureService.swift"),
            encoding: .utf8)
        let constructions = source.components(separatedBy: "SystemScreenCaptureBackend()").count - 1

        XCTAssertEqual(constructions, 1,
                       "exactly one construction of the live backend — found \(constructions)")
    }
}

// MARK: - Async throwing assertion

/// `XCTAssertThrowsError` predates `async`, and its `@autoclosure` cannot carry an `await`.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
