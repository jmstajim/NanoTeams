import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Captured Screen

/// The result of a screen/window capture. All coordinates the model works in are
/// **image pixels** (post-downscale); `regionWidthPt`/`regionHeightPt` + `origin*`
/// let the finalizer convert image pixels back to global display points for CGEvent.
nonisolated struct CapturedScreen: Sendable {
    let pngBase64: String
    /// Post-downscale image dimensions — the space the model reasons in.
    let pixelWidth: Int
    let pixelHeight: Int
    /// Capture region size in global display points.
    let regionWidthPt: Double
    let regionHeightPt: Double
    /// Global TOP-LEFT point of the capture region (CoreGraphics coordinate space).
    let originX: Double
    let originY: Double
    let targetKind: String          // "display" | "window"
    let appName: String?
    let bundleID: String?
    let windowTitle: String?
    let displayID: UInt32?
    let pid: pid_t?                  // for AX enumeration of a window's app
}

// MARK: - Errors

nonisolated enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case permissionNeedsRelaunch
    case noDisplay
    case windowNotFound(String, visibleApps: [String])
    case captureFailed(String)
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording."
        case .permissionNeedsRelaunch:
            "Screen Recording permission was just granted — relaunch NanoTeams to enable capture."
        case .noDisplay:
            "No display available to capture."
        case .windowNotFound(let spec, let visibleApps):
            // A weak model that targets a website by name reads a bare "not found" as "the
            // site isn't open" and detours (Spotlight, ask_supervisor). Name the actual
            // options instead: sites live inside a browser, and here is what IS capturable.
            "No visible window found for target '\(spec)'. Target must be an application name "
                + "or bundle id — a website is a page inside a browser, so capture the browser "
                + "app (optionally with window_title), or \"screen\"."
                + (visibleApps.isEmpty ? "" : " Visible apps: \(visibleApps.joined(separator: ", ")).")
        case .captureFailed(let reason):
            "Screen capture failed: \(reason)"
        case .encodeFailed:
            "Could not encode the captured image as PNG."
        }
    }
}

// MARK: - Screen Capture Service

/// Captures the screen or a specific app window via ScreenCaptureKit, downscales to a
/// vision-model-friendly size, and returns a base64 PNG plus the geometry needed to map
/// image pixels back to global display points. NanoTeams' own windows are excluded from
/// whole-display captures (self-guard). Stateless.
nonisolated enum ScreenCaptureService {

    /// Longest side of the returned image, in pixels. Vision models degrade on very large
    /// images; this also bounds token cost. Native captures smaller than this are not upscaled.
    static let maxImageSide = 1568

    // MARK: - Permission

    /// True if Screen Recording is already granted for this process.
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts for Screen Recording permission (opens System Settings). Returns the
    /// immediate grant state — note macOS usually requires an app relaunch before capture
    /// actually works even after the user flips the toggle.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Capture

    /// Captures `targetSpec` — either `"screen"` (main display) or an app name / bundle id
    /// (its frontmost matching window, optionally narrowed by `windowTitle`).
    static func capture(
        targetSpec: String,
        windowTitle: String?,
        ownBundleID: String
    ) async throws -> CapturedScreen {
        guard hasPermission() else {
            // Prompt once; the grant won't take effect until relaunch, so surface that.
            _ = requestPermission()
            throw hasPermission() ? ScreenCaptureError.permissionNeedsRelaunch
                                  : ScreenCaptureError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }

        let trimmed = targetSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("screen") == .orderedSame
            || trimmed.caseInsensitiveCompare("display") == .orderedSame {
            return try await captureDisplay(content: content, ownBundleID: ownBundleID)
        }
        return try await captureWindow(
            content: content, spec: trimmed, windowTitle: windowTitle, ownBundleID: ownBundleID
        )
    }

    // MARK: - Display

    private static func captureDisplay(
        content: SCShareableContent,
        ownBundleID: String
    ) async throws -> CapturedScreen {
        // Prefer the MAIN display for "screen" — `content.displays` order is not documented as
        // main-first, so `.first` can be a secondary monitor, which reads to the user as the model
        // clicking the "wrong place".
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
            ?? content.displays.first else { throw ScreenCaptureError.noDisplay }

        // Take BOTH the origin AND the size from `CGDisplayBounds` — it is in the global display
        // coordinate space (top-left points) that `CGEvent` mouse positions use, so the
        // click-inverse lands in the right space. `SCDisplay.width/.height` are NOT guaranteed to
        // be in that same space (they can report backing pixels), and mixing a point-space origin
        // with a pixel-space size scales every click off by the backing factor (~2× on Retina).
        let bounds = CGDisplayBounds(display.displayID)       // global top-left points
        let regionW = Double(bounds.width)                    // points (CGEvent space)
        let regionH = Double(bounds.height)
        let scale = displayScale(display.displayID)
        let (pxW, pxH) = targetPixelSize(regionW: regionW, regionH: regionH, scale: scale)

        // Exclude NanoTeams' own windows so a whole-screen shot never feeds the app its own UI back.
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let cgImage = try await captureImage(filter: filter, pxW: pxW, pxH: pxH)
        let base64 = try pngBase64(from: cgImage)

        return CapturedScreen(
            pngBase64: base64,
            pixelWidth: cgImage.width, pixelHeight: cgImage.height,
            regionWidthPt: regionW, regionHeightPt: regionH,
            originX: Double(bounds.origin.x), originY: Double(bounds.origin.y),
            targetKind: "display", appName: nil, bundleID: nil, windowTitle: nil,
            displayID: display.displayID, pid: nil
        )
    }

    // MARK: - Window

    private static func captureWindow(
        content: SCShareableContent,
        spec: String,
        windowTitle: String?,
        ownBundleID: String
    ) async throws -> CapturedScreen {
        let specLower = spec.lowercased()
        // RANK all windows and pick the best match — a plain "largest area" pick let a helper
        // process win: `target:"safari"` matched "Open and Save Panel Service (Safari)" (its app
        // name CONTAINS "safari") and handed the model an empty, un-actionable window instead of
        // the real browser. The ranking makes an EXACT app match beat a substring-only helper
        // match, and an on-screen normal-layer window beat an off-screen / panel overlay, before
        // area is even considered.
        let candidates = content.windows.map(Self.windowCandidate(from:))
        guard let idx = bestWindowIndex(
            candidates, specLower: specLower, windowTitle: windowTitle, ownBundleID: ownBundleID) else {
            throw ScreenCaptureError.windowNotFound(
                spec, visibleApps: visibleAppNames(candidates, ownBundleID: ownBundleID))
        }
        let window = content.windows[idx]

        let region = window.frame                              // global top-left points
        let regionW = Double(region.width)
        let regionH = Double(region.height)
        let scale = displayScale(displayContaining: region.origin)
        let (pxW, pxH) = targetPixelSize(regionW: regionW, regionH: regionH, scale: scale)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cgImage = try await captureImage(filter: filter, pxW: pxW, pxH: pxH)
        let base64 = try pngBase64(from: cgImage)

        let app = window.owningApplication
        return CapturedScreen(
            pngBase64: base64,
            pixelWidth: cgImage.width, pixelHeight: cgImage.height,
            regionWidthPt: regionW, regionHeightPt: regionH,
            originX: Double(region.origin.x), originY: Double(region.origin.y),
            targetKind: "window",
            appName: app?.applicationName, bundleID: app?.bundleIdentifier,
            windowTitle: window.title,
            displayID: nil,
            pid: app.map { pid_t($0.processID) }
        )
    }

    // MARK: - Capture primitive

    private static func captureImage(filter: SCContentFilter, pxW: Int, pxH: Int) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: makeConfiguration(pxW: pxW, pxH: pxH))
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }

    /// Builds the capture configuration. **Coordinate correctness:** for a single-window capture
    /// SCK otherwise includes the window's DROP SHADOW (and global clip) in the output, so the
    /// captured content covers `window.frame + shadow` while the geometry we map against is
    /// `window.frame` — every window-target click then drifts toward the top-left by the shadow
    /// inset. `ignoreShadowsSingleWindow` + `ignoreGlobalClipSingleWindow` make the output match
    /// the window's frame exactly. Both are no-ops for a whole-display filter, so the shared
    /// builder is safe for both paths. Extracted so a test can pin the flags.
    static func makeConfiguration(pxW: Int, pxH: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = pxW
        config.height = pxH
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        return config
    }

    // MARK: - Window matching (pure, testable)

    /// Plain-value projection of an `SCWindow` — `SCWindow` can't be constructed in tests, so the
    /// matcher works on this instead.
    nonisolated struct WindowCandidate: Equatable, Sendable {
        let bundleID: String
        let appName: String
        let title: String?
        let width: Double
        let height: Double
        let isOnScreen: Bool
        let layer: Int
    }

    /// Rank of a matching candidate, compared lexicographically (higher is better): an EXACT app
    /// match outranks a substring app match, which outranks a TITLE-only match (a website name
    /// like "LinkedIn" resolving to the browser window that shows it); then on-screen; then a
    /// normal window layer (0, an ordinary app window — not a panel/overlay/menu); then larger
    /// area. App-name tiers stay above the title tier so `target:"Safari"` can never be stolen
    /// by some window merely titled "…Safari…".
    nonisolated struct WindowMatchRank: Comparable, Sendable {
        let exactApp: Bool
        let appMatch: Bool
        let onScreen: Bool
        let normalLayer: Bool
        let area: Double
        static func < (l: WindowMatchRank, r: WindowMatchRank) -> Bool {
            if l.exactApp != r.exactApp { return r.exactApp }
            if l.appMatch != r.appMatch { return r.appMatch }
            if l.onScreen != r.onScreen { return r.onScreen }
            if l.normalLayer != r.normalLayer { return r.normalLayer }
            return l.area < r.area
        }
    }

    private static func windowCandidate(from win: SCWindow) -> WindowCandidate {
        WindowCandidate(
            bundleID: win.owningApplication?.bundleIdentifier ?? "",
            appName: win.owningApplication?.applicationName ?? "",
            title: win.title,
            width: Double(win.frame.width),
            height: Double(win.frame.height),
            isOnScreen: win.isOnScreen,
            layer: win.windowLayer)
    }

    /// The rank of `c` against `spec`, or nil if it doesn't match. Excludes our own windows and
    /// degenerate (≤1pt) windows, and honors an optional window-title substring constraint.
    /// Matching tiers: app bundle/name (exact, then substring), then the window TITLE — so a
    /// model that targets a website by name ("LinkedIn") still finds the browser window showing
    /// it ("Feed | LinkedIn") instead of erroring out as if nothing were open.
    static func windowRank(
        _ c: WindowCandidate, specLower: String, windowTitle: String?, ownBundleID: String
    ) -> WindowMatchRank? {
        if !c.bundleID.isEmpty, c.bundleID.caseInsensitiveCompare(ownBundleID) == .orderedSame { return nil }
        if c.width <= 1 || c.height <= 1 { return nil }
        let bundleLower = c.bundleID.lowercased()
        let nameLower = c.appName.lowercased()
        let exact = bundleLower == specLower || nameLower == specLower
        let appMatch = exact || nameLower.contains(specLower)
        let titleMatch = (c.title ?? "").lowercased().contains(specLower)
        guard appMatch || titleMatch else { return nil }
        if let wt = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !wt.isEmpty {
            guard (c.title ?? "").lowercased().contains(wt.lowercased()) else { return nil }
        }
        return WindowMatchRank(
            exactApp: exact, appMatch: appMatch,
            onScreen: c.isOnScreen, normalLayer: c.layer == 0, area: c.width * c.height)
    }

    /// A warning when a window capture resolved by TITLE only — the captured app's name/bundle
    /// doesn't match the requested target, so the target likely named a website or a non-running
    /// app and we captured whatever window's title contained the spec (e.g. `target:"Notes"` with
    /// Notes closed matching a Safari tab "Release Notes"). nil for display captures and genuine
    /// app-name matches. Mirrors `windowRank`'s app-vs-title tiering; pure over value types.
    static func titleOnlyMatchNote(requestedTarget: String, captured: CapturedScreen) -> String? {
        guard captured.targetKind == "window", let app = captured.appName else { return nil }
        let spec = requestedTarget.lowercased()
        let appMatched = app.lowercased() == spec || app.lowercased().contains(spec)
            || (captured.bundleID?.lowercased() == spec)
        guard !appMatched else { return nil }
        return "Captured “\(app)” by matching the window title, not an app named “\(requestedTarget)”. "
            + "If you meant a different app, target it by its app name (open it first if it isn't running)."
    }

    /// Distinct app names with a real, ordinary on-screen window (excluding NanoTeams itself),
    /// sorted — the actionable-alternatives list for the `windowNotFound` error. The `layer == 0`
    /// filter (same notion `windowRank` uses for `normalLayer`) drops the always-on-screen system
    /// surfaces — Dock, Control Centre, Notification Center, Window Server — so the hint isn't
    /// flooded with non-capturable overlays a weak model would then try to target.
    static func visibleAppNames(_ candidates: [WindowCandidate], ownBundleID: String) -> [String] {
        Set(candidates.compactMap { c -> String? in
            guard c.isOnScreen, c.layer == 0, c.width > 1, c.height > 1, !c.appName.isEmpty,
                  c.bundleID.caseInsensitiveCompare(ownBundleID) != .orderedSame else { return nil }
            return c.appName
        }).sorted()
    }

    /// Index of the best-ranked matching window in `candidates`, or nil if none match.
    static func bestWindowIndex(
        _ candidates: [WindowCandidate], specLower: String, windowTitle: String?, ownBundleID: String
    ) -> Int? {
        var best: (idx: Int, rank: WindowMatchRank)?
        for (i, c) in candidates.enumerated() {
            guard let rank = windowRank(
                c, specLower: specLower, windowTitle: windowTitle, ownBundleID: ownBundleID) else { continue }
            if best == nil || best!.rank < rank { best = (i, rank) }
        }
        return best?.idx
    }

    // MARK: - Geometry helpers

    /// Downscaled target pixel size: never upscale beyond native, cap the long side at `maxImageSide`.
    static func targetPixelSize(regionW: Double, regionH: Double, scale: Double) -> (Int, Int) {
        let nativeW = max(1.0, regionW * scale)
        let nativeH = max(1.0, regionH * scale)
        let longest = max(nativeW, nativeH)
        guard longest > Double(maxImageSide) else {
            return (Int(nativeW.rounded()), Int(nativeH.rounded()))
        }
        let factor = Double(maxImageSide) / longest
        return (max(1, Int((nativeW * factor).rounded())), max(1, Int((nativeH * factor).rounded())))
    }

    /// Backing scale of a display, via CoreGraphics (no NSScreen — nonisolated-safe). Defaults to 2.0.
    private static func displayScale(_ displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 2.0 }
        let points = mode.width
        guard points > 0 else { return 2.0 }
        return Double(mode.pixelWidth) / Double(points)
    }

    /// Scale of whichever active display contains `point` (global top-left points).
    private static func displayScale(displayContaining point: CGPoint) -> Double {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return 2.0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        for id in ids where CGDisplayBounds(id).contains(point) {
            return displayScale(id)
        }
        return displayScale(CGMainDisplayID())
    }

    // MARK: - PNG

    static func pngBase64(from cgImage: CGImage) throws -> String {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.encodeFailed
        }
        return png.base64EncodedString()
    }
}
