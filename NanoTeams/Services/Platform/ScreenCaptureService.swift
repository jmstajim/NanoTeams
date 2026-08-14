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
        // These descriptions have no human sink: their only route out is
        // `errorText(_:)` → `makeErrorEnvelope(code: .commandFailed)` in `+ComputerUse`,
        // i.e. the MODEL. So they name the missing capability plus a recourse the model
        // can act on, never a Settings pane it cannot open. The two states stay DISTINCT —
        // "grant it" and "relaunch after granting" need different follow-ups.
        case .permissionDenied:
            "NanoTeams does not have macOS Screen Recording permission, so no screenshot can be taken. Only the supervisor can grant it — do not retry screen_capture in this step."
        case .permissionNeedsRelaunch:
            "Screen Recording permission was just granted, but it does not take effect until NanoTeams is relaunched. Capture is unavailable for the rest of this run — do not retry."
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

// MARK: - Backend seam

/// A PNG the compositor actually produced. `pixelWidth`/`pixelHeight` are the DELIVERED
/// dimensions, not the requested ones — the click inverse divides by these, so a compositor that
/// rounds or clamps must be believed rather than assumed.
nonisolated struct CapturedImage: Sendable, Equatable {
    let pngBase64: String
    let pixelWidth: Int
    let pixelHeight: Int
}

/// A display, as the three values the capture path reads off it. `SCDisplay` cannot be constructed
/// in a fixture, and `scale` folds the `CGDisplayCopyDisplayMode` round-trip that would otherwise
/// make the caller impure.
nonisolated struct DisplaySnapshot: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    /// Global TOP-LEFT points — `CGDisplayBounds`, never `SCDisplay.width/.height` (those can be
    /// backing pixels, and mixing the two spaces scales every click by the Retina factor).
    let boundsPt: CGRect
    let scale: Double
}

/// A window, as values: the ranking projection plus the geometry and identity the envelope needs.
nonisolated struct WindowSnapshot: Sendable, Equatable {
    let candidate: ScreenCaptureService.WindowCandidate
    /// Global top-left points (`SCWindow.frame`).
    let framePt: CGRect
    /// Backing scale of whichever display contains the frame's origin.
    let scale: Double
    let appName: String?
    let bundleID: String?
    let title: String?
    let pid: pid_t?
}

/// Everything `capture` touches outside its own arithmetic: the permission state, the shareable
/// content, and the two compositor calls.
///
/// `associatedtype Content` is the same device `AXNodeReading` uses — the opaque
/// `SCShareableContent` never crosses the seam, but the displays and windows it contains do, as
/// values, and a capture addresses them by INDEX into those arrays. That keeps the whole
/// resolve-rank-geometry chain (which is where every wrong-window and wrong-coordinate bug has
/// lived) on this side of the boundary and testable, while the two genuinely untestable acts —
/// asking the window server for content, and asking the compositor for pixels — stay behind it.
nonisolated protocol ScreenCaptureBackend: Sendable {
    associatedtype Content

    func hasPermission() -> Bool
    @discardableResult func requestPermission() -> Bool
    func shareableContent() async throws -> Content
    func displays(in content: Content) -> [DisplaySnapshot]
    func windows(in content: Content) -> [WindowSnapshot]
    func captureDisplay(
        _ content: Content, index: Int, excludingWindowIndices: [Int],
        pixelWidth: Int, pixelHeight: Int
    ) async throws -> CapturedImage
    func captureWindow(
        _ content: Content, index: Int, pixelWidth: Int, pixelHeight: Int
    ) async throws -> CapturedImage
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
    ///
    /// The production entry point: the ONE place `SystemScreenCaptureBackend` is named.
    static func capture(
        targetSpec: String,
        windowTitle: String?,
        ownBundleID: String
    ) async throws -> CapturedScreen {
        try await capture(
            targetSpec: targetSpec, windowTitle: windowTitle, ownBundleID: ownBundleID,
            backend: SystemScreenCaptureBackend())
    }

    /// The whole capture decision chain, over a backend. There is no default argument on purpose —
    /// the only honest default is the live one, and a test that reached it would ask the window
    /// server for content and the compositor for pixels. Omitting the backend is a compile error;
    /// the production entry point above supplies it.
    static func capture<B: ScreenCaptureBackend>(
        targetSpec: String,
        windowTitle: String?,
        ownBundleID: String,
        backend: B
    ) async throws -> CapturedScreen {
        guard backend.hasPermission() else {
            // Prompt once; the grant won't take effect until relaunch, so surface that.
            _ = backend.requestPermission()
            throw permissionFailure(grantedAfterPrompt: backend.hasPermission())
        }

        let content: B.Content
        do {
            content = try await backend.shareableContent()
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }

        switch resolveTarget(targetSpec) {
        case .display:
            return try await captureDisplay(content: content, backend: backend, ownBundleID: ownBundleID)
        case .window(let spec):
            return try await captureWindow(
                content: content, backend: backend, spec: spec,
                windowTitle: windowTitle, ownBundleID: ownBundleID)
        }
    }

    // MARK: - Target routing (pure)

    /// What a `targetSpec` asks for. `"screen"` / `"display"` / a blank spec mean the main
    /// display; anything else names an app (which `windowRank`'s title tier may in turn resolve
    /// to a page shown inside one).
    nonisolated enum CaptureTarget: Equatable, Sendable {
        case display
        case window(spec: String)
    }

    /// Routes `targetSpec` to a capture path. Trimmed and case-insensitive, because the spec is
    /// model-authored free text. Extracted from `capture` so the routing is testable without
    /// ScreenCaptureKit — a spec that silently routed to the wrong path would hand the model a
    /// whole-screen shot when it asked for one window (or vice versa).
    static func resolveTarget(_ targetSpec: String) -> CaptureTarget {
        let trimmed = targetSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty
            || trimmed.caseInsensitiveCompare("screen") == .orderedSame
            || trimmed.caseInsensitiveCompare("display") == .orderedSame {
            return .display
        }
        return .window(spec: trimmed)
    }

    /// Which permission error to raise after the preflight failed and the prompt was shown.
    /// A grant that lands DURING the prompt still can't capture until the app relaunches, so the
    /// two states must stay distinguishable — telling a just-granted user "permission is
    /// required" sends them back to a switch that is already on.
    static func permissionFailure(grantedAfterPrompt: Bool) -> ScreenCaptureError {
        grantedAfterPrompt ? .permissionNeedsRelaunch : .permissionDenied
    }

    // MARK: - Display

    private static func captureDisplay<B: ScreenCaptureBackend>(
        content: B.Content,
        backend: B,
        ownBundleID: String
    ) async throws -> CapturedScreen {
        // Prefer the MAIN display for "screen" — the shareable content's display order is not
        // documented as main-first, so `.first` can be a secondary monitor, which reads to the user
        // as the model clicking the "wrong place".
        let displays = backend.displays(in: content)
        guard let displayIdx = mainDisplayIndex(
            displayIDs: displays.map(\.displayID), mainID: CGMainDisplayID())
        else { throw ScreenCaptureError.noDisplay }
        let display = displays[displayIdx]

        // Both the origin AND the size come from the display's `CGDisplayBounds` (see
        // `DisplaySnapshot.boundsPt`) so the click-inverse lands in the space `CGEvent` uses.
        let region = captureRegion(display.boundsPt, scale: display.scale)

        // Exclude NanoTeams' own windows so a whole-screen shot never feeds the app its own UI back.
        let ownIdx = ownWindowIndices(
            backend.windows(in: content).map(\.candidate), ownBundleID: ownBundleID)

        let image = try await backend.captureDisplay(
            content, index: displayIdx, excludingWindowIndices: ownIdx,
            pixelWidth: region.pixelWidth, pixelHeight: region.pixelHeight)

        return makeDisplayCapture(
            pngBase64: image.pngBase64, imageWidth: image.pixelWidth, imageHeight: image.pixelHeight,
            region: region, displayID: display.displayID)
    }

    /// Index of the display to capture for `"screen"`: the MAIN display when the shareable set
    /// contains it, else the first available one, else nil (→ `.noDisplay`). `SCShareableContent`
    /// does not document `displays` as main-first, so picking `.first` blindly can capture a
    /// secondary monitor — which reads to the user as the model clicking the wrong place.
    static func mainDisplayIndex(displayIDs: [CGDirectDisplayID], mainID: CGDirectDisplayID) -> Int? {
        if let exact = displayIDs.firstIndex(of: mainID) { return exact }
        return displayIDs.isEmpty ? nil : 0
    }

    /// Indices of the candidates owned by THIS app, for exclusion from a whole-display capture —
    /// otherwise the screenshot feeds NanoTeams its own UI back to the model.
    ///
    /// Matching mirrors `windowRank`'s self-guard exactly, and both halves of that are
    /// load-bearing: case-INSENSITIVE (bundle ids compare case-insensitively everywhere else in
    /// this file, and a caller that hands us a differently-cased id must not silently stop
    /// excluding our own windows), and an EMPTY candidate bundle id is never "self" — the caller
    /// passes `Bundle.main.bundleIdentifier ?? ""`, so a blank own-id would otherwise match every
    /// window whose owning application has no bundle id and exclude half the screen.
    static func ownWindowIndices(_ candidates: [WindowCandidate], ownBundleID: String) -> [Int] {
        guard !ownBundleID.isEmpty else { return [] }
        return candidates.indices.filter { i in
            let bundleID = candidates[i].bundleID
            return !bundleID.isEmpty && bundleID.caseInsensitiveCompare(ownBundleID) == .orderedSame
        }
    }

    // MARK: - Window

    private static func captureWindow<B: ScreenCaptureBackend>(
        content: B.Content,
        backend: B,
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
        let windows = backend.windows(in: content)
        let candidates = windows.map(\.candidate)
        guard let idx = bestWindowIndex(
            candidates, specLower: specLower, windowTitle: windowTitle, ownBundleID: ownBundleID) else {
            throw ScreenCaptureError.windowNotFound(
                spec, visibleApps: visibleAppNames(candidates, ownBundleID: ownBundleID))
        }
        let window = windows[idx]
        let region = captureRegion(window.framePt, scale: window.scale)

        let image = try await backend.captureWindow(
            content, index: idx, pixelWidth: region.pixelWidth, pixelHeight: region.pixelHeight)

        return makeWindowCapture(
            pngBase64: image.pngBase64, imageWidth: image.pixelWidth, imageHeight: image.pixelHeight,
            region: region,
            appName: window.appName, bundleID: window.bundleID,
            windowTitle: window.title, pid: window.pid)
    }

    // MARK: - Region geometry + envelope assembly (pure)

    /// The capture region in the ONE coordinate space this whole stack agrees on — CoreGraphics
    /// global **top-left points** — plus the pixel size to ask the compositor for.
    /// `pixelWidth`/`pixelHeight` here are what we REQUEST; `CapturedScreen` carries what the
    /// compositor actually produced (`CGImage.width/.height`), and the click inverse divides by
    /// the latter, so the two must stay separate values.
    nonisolated struct CaptureRegion: Equatable, Sendable {
        let originX: Double
        let originY: Double
        let widthPt: Double
        let heightPt: Double
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// Region geometry for a rect already expressed in global top-left points (`CGDisplayBounds`
    /// for a display, `SCWindow.frame` for a window). Both capture paths go through here so the
    /// origin and the size can never come from different coordinate spaces — mixing a point-space
    /// origin with a pixel-space size is what scaled every click off by the backing factor.
    static func captureRegion(_ rect: CGRect, scale: Double) -> CaptureRegion {
        let widthPt = Double(rect.width)
        let heightPt = Double(rect.height)
        let (pxW, pxH) = targetPixelSize(regionW: widthPt, regionH: heightPt, scale: scale)
        return CaptureRegion(
            originX: Double(rect.origin.x), originY: Double(rect.origin.y),
            widthPt: widthPt, heightPt: heightPt, pixelWidth: pxW, pixelHeight: pxH)
    }

    /// Assembles the whole-display envelope. Extracted so the field mapping — which is what the
    /// click inverse reads back — is pinnable without Screen Recording permission.
    static func makeDisplayCapture(
        pngBase64: String, imageWidth: Int, imageHeight: Int,
        region: CaptureRegion, displayID: CGDirectDisplayID
    ) -> CapturedScreen {
        CapturedScreen(
            pngBase64: pngBase64,
            pixelWidth: imageWidth, pixelHeight: imageHeight,
            regionWidthPt: region.widthPt, regionHeightPt: region.heightPt,
            originX: region.originX, originY: region.originY,
            targetKind: "display", appName: nil, bundleID: nil, windowTitle: nil,
            displayID: displayID, pid: nil)
    }

    /// Assembles the single-window envelope. `pid` is carried for the AX enumeration of that
    /// window's app; `displayID` is deliberately nil — a window is not pinned to one display.
    static func makeWindowCapture(
        pngBase64: String, imageWidth: Int, imageHeight: Int,
        region: CaptureRegion, appName: String?, bundleID: String?,
        windowTitle: String?, pid: pid_t?
    ) -> CapturedScreen {
        CapturedScreen(
            pngBase64: pngBase64,
            pixelWidth: imageWidth, pixelHeight: imageHeight,
            regionWidthPt: region.widthPt, regionHeightPt: region.heightPt,
            originX: region.originX, originY: region.originY,
            targetKind: "window", appName: appName, bundleID: bundleID,
            windowTitle: windowTitle, displayID: nil, pid: pid)
    }

    // MARK: - Capture primitive

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

    /// The rank of `c` against `spec`, or nil if it doesn't match. Excludes our own windows and
    /// degenerate (≤1pt) windows, and honors an optional window-title substring constraint.
    /// Matching tiers: app bundle id (EXACT only) or app name (exact, then substring), then the
    /// window TITLE — so a model that targets a website by name ("LinkedIn") still finds the
    /// browser window showing it ("Feed | LinkedIn") instead of erroring out as if nothing were
    /// open.
    ///
    /// The bundle id is deliberately exact-only, and the asymmetry is load-bearing: bundle ids
    /// are dotted namespaces, so a substring test would make `target: "com.apple"` match every
    /// Apple app at once and hand the model an arbitrary one — reintroducing the wrong-window
    /// class of bug this ranking exists to prevent. App NAMES have no such shared prefix.
    /// (The doc used to read "app bundle/name (exact, then substring)", which invited exactly
    /// that "fix".)
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
    ///
    /// Both dimensions are sanitized to a finite native extent FIRST, because a region dimension
    /// arrives from another process (`SCWindow.frame`) or from the window server and is not
    /// guaranteed finite — `CGRect.infinite` is a real value a window can report, and a merely
    /// enormous frame overflows `regionW * scale` to `.infinity` all the same. The old code then
    /// computed `factor = 1568 / .infinity == 0` and `Int((.infinity * 0).rounded())`, i.e.
    /// `Int(Double.nan)` — an UNCATCHABLE trap that takes the whole app down from a value no
    /// caller controls. (Same defect class as `AccessibilityInspector.Geometry.mapFrame`'s
    /// `Int(exactly:)` guard, from the same untrusted-geometry source.)
    static func targetPixelSize(regionW: Double, regionH: Double, scale: Double) -> (Int, Int) {
        let nativeW = nativeExtent(regionW, scale: scale)
        let nativeH = nativeExtent(regionH, scale: scale)
        let longest = max(nativeW, nativeH)
        guard longest > Double(maxImageSide) else {
            return (pixelCount(nativeW), pixelCount(nativeH))
        }
        let factor = Double(maxImageSide) / longest
        return (pixelCount(nativeW * factor), pixelCount(nativeH * factor))
    }

    /// One region dimension in native pixels, guaranteed finite and ≥ 1. Deliberately sanitizes
    /// only the PRODUCT, so every input the old code already handled keeps its exact result: a
    /// NaN or negative product still collapses to the 1pt floor, as `max(1.0, …)` did. `+∞` — the
    /// one input that used to trap — means "unboundedly large" and so takes the cap.
    private static func nativeExtent(_ pointExtent: Double, scale: Double) -> Double {
        let native = pointExtent * scale
        guard native.isFinite else { return native > 0 ? Double(maxImageSide) : 1.0 }
        return max(1.0, native)
    }

    /// Non-trapping `Double` → pixel-count conversion. Both call sites above already feed values
    /// in `[1, maxImageSide]`, so this is a belt on a fixed brace: it exists so a future edit to
    /// the bounds cannot silently reintroduce the trap.
    private static func pixelCount(_ value: Double) -> Int {
        guard value.isFinite, let count = Int(exactly: value.rounded()) else { return 1 }
        return max(1, count)
    }

    /// Backing scale of a display, via CoreGraphics (no NSScreen — nonisolated-safe). Defaults to 2.0.
    static func displayScale(_ displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 2.0 }
        let points = mode.width
        guard points > 0 else { return 2.0 }
        return Double(mode.pixelWidth) / Double(points)
    }

    /// Scale of whichever active display contains `point` (global top-left points).
    static func displayScale(displayContaining point: CGPoint) -> Double {
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

// MARK: - Live backend

/// The ScreenCaptureKit adapter. Every method is one framework round-trip plus the projection into
/// values; the only judgement it makes is `?? ""` / `?? 2.0` defaults that the pure side already
/// treats as "unknown". Constructed in exactly one place — `ScreenCaptureService.capture`'s
/// three-argument entry point.
nonisolated struct SystemScreenCaptureBackend: ScreenCaptureBackend {

    func hasPermission() -> Bool { ScreenCaptureService.hasPermission() }

    @discardableResult
    func requestPermission() -> Bool { ScreenCaptureService.requestPermission() }

    func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.current
    }

    func displays(in content: SCShareableContent) -> [DisplaySnapshot] {
        content.displays.map {
            DisplaySnapshot(
                displayID: $0.displayID,
                boundsPt: CGDisplayBounds($0.displayID),
                scale: ScreenCaptureService.displayScale($0.displayID))
        }
    }

    func windows(in content: SCShareableContent) -> [WindowSnapshot] {
        content.windows.map { win in
            let app = win.owningApplication
            return WindowSnapshot(
                candidate: ScreenCaptureService.WindowCandidate(
                    bundleID: app?.bundleIdentifier ?? "",
                    appName: app?.applicationName ?? "",
                    title: win.title,
                    width: Double(win.frame.width),
                    height: Double(win.frame.height),
                    isOnScreen: win.isOnScreen,
                    layer: win.windowLayer),
                framePt: win.frame,
                scale: ScreenCaptureService.displayScale(displayContaining: win.frame.origin),
                appName: app?.applicationName,
                bundleID: app?.bundleIdentifier,
                title: win.title,
                pid: app.map { pid_t($0.processID) })
        }
    }

    func captureDisplay(
        _ content: SCShareableContent, index: Int, excludingWindowIndices: [Int],
        pixelWidth: Int, pixelHeight: Int
    ) async throws -> CapturedImage {
        let excluded = Set(excludingWindowIndices)
        let ownWindows = content.windows.enumerated()
            .compactMap { excluded.contains($0.offset) ? $0.element : nil }
        return try await capture(
            filter: SCContentFilter(display: content.displays[index], excludingWindows: ownWindows),
            pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    func captureWindow(
        _ content: SCShareableContent, index: Int, pixelWidth: Int, pixelHeight: Int
    ) async throws -> CapturedImage {
        try await capture(
            filter: SCContentFilter(desktopIndependentWindow: content.windows[index]),
            pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private func capture(
        filter: SCContentFilter, pixelWidth: Int, pixelHeight: Int
    ) async throws -> CapturedImage {
        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: ScreenCaptureService.makeConfiguration(pxW: pixelWidth, pxH: pixelHeight))
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
        return CapturedImage(
            pngBase64: try ScreenCaptureService.pngBase64(from: cgImage),
            pixelWidth: cgImage.width, pixelHeight: cgImage.height)
    }
}

// MARK: - Computer-use facade seam

/// What the computer-use finalizer needs from this file: one call. Separate from
/// `ScreenCaptureBackend` on purpose — that seam exists so *this file's* resolve-rank-geometry
/// chain is testable, while this one exists so the finalizer can be driven without a screenshot
/// at all. A test of the dispatcher has no business assembling shareable content.
nonisolated protocol ScreenCapturing: Sendable {
    func capture(targetSpec: String, windowTitle: String?, ownBundleID: String) async throws -> CapturedScreen
}

nonisolated struct SystemScreenCapture: ScreenCapturing {
    func capture(targetSpec: String, windowTitle: String?, ownBundleID: String) async throws -> CapturedScreen {
        try await ScreenCaptureService.capture(
            targetSpec: targetSpec, windowTitle: windowTitle, ownBundleID: ownBundleID)
    }
}

/// Refuses, exactly as an ungranted process does. The inert default for `ComputerUseEnvironment`.
nonisolated struct InertScreenCapture: ScreenCapturing {
    func capture(targetSpec: String, windowTitle: String?, ownBundleID: String) async throws -> CapturedScreen {
        throw ScreenCaptureError.permissionDenied
    }
}
