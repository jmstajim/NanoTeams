import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization

// MARK: - AX Element Info

/// One actionable UI element, with its frame already converted to **image-pixel** space
/// (the coordinate space of the returned screenshot) so the model can cross-reference it
/// against the pixels it sees. `cx`/`cy` is the pre-computed clickable CENTER (clamped to
/// the visible part of the image) — models should click that, never the `(x, y)` top-left
/// corner: corner clicks on small controls land on boundary pixels / the dead gap next to
/// the control (observed in the wild: a click at the exact top-left of a 23-px-high button
/// did nothing).
nonisolated struct AXElementInfo: Sendable, Codable, Hashable {
    let role: String
    let label: String
    let x: Int
    let y: Int
    let w: Int
    let h: Int
    let cx: Int
    let cy: Int
    /// The element lives inside an `AXWebArea` subtree — page content rendered by a browser,
    /// as opposed to the browser's own chrome (toolbar, favorites bar). Lets the model prefer
    /// page targets over look-alike chrome controls, and drives cap-overflow retention.
    let web: Bool

    /// Wire shape is intentionally narrower than the stored struct: the model is told to
    /// click `cx`/`cy` and judge size by `w`/`h` — also shipping the `x`/`y` top-left corner
    /// doubles the coordinate tokens per element (captures recur many times per step) and is
    /// exactly the corner the incident model wrongly clicked. `x`/`y` stay stored for the
    /// dedup / containment math. `web` is encoded only when true so native-app captures pay
    /// zero extra tokens.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(label, forKey: .label)
        try c.encode(w, forKey: .w)
        try c.encode(h, forKey: .h)
        try c.encode(cx, forKey: .cx)
        try c.encode(cy, forKey: .cy)
        if web { try c.encode(true, forKey: .web) }
    }
}

// MARK: - Cancellation flag

/// Reference wrapper around an atomic Bool so the detached walk and the `onCancel` handler can
/// share ONE flag (a bare `Atomic` is noncopyable and can't be captured by two closures). Lets
/// a Pause landing mid-walk stop it — `Task.detached` doesn't inherit the caller's cancellation.
nonisolated final class WalkCancellationFlag: @unchecked Sendable {
    private let value = Atomic<Bool>(false)
    var isCancelled: Bool { value.load(ordering: .relaxed) }
    func cancel() { value.store(true, ordering: .relaxed) }
}

// MARK: - Collection request / result

/// Sendable input for `AccessibilityInspector.collectElements` — plain values only, so the
/// whole walk (synchronous AX IPC) can run inside a detached task off the main actor.
nonisolated struct AXCollectionRequest: Sendable {
    let pid: pid_t
    let regionOriginX: Double
    let regionOriginY: Double
    let regionWidthPt: Double
    let regionHeightPt: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let matchWindowToRegion: Bool
}

/// Wire-ready outcome of one collection: deduped + capped elements, the pre-cap total (drives
/// the `meta.truncated` flag), and no-silent-caps warnings for the capture envelope.
nonisolated struct AXCollectionResult: Sendable {
    let elements: [AXElementInfo]
    let totalAfterDedup: Int
    let warnings: [String]

    static let empty = AXCollectionResult(elements: [], totalAfterDedup: 0, warnings: [])
}

// MARK: - Accessibility Inspector

/// Enumerates the Accessibility tree of a target application and returns actionable elements
/// with frames mapped into image-pixel space. Bounded by depth/node caps so pathological trees
/// (browsers, Xcode) can't hang. Uses the SAME `pixel/point` ratio as the screenshot — never
/// `backing_scale` — so the element list and the visible pixels stay in sync.
nonisolated enum AccessibilityInspector {

    /// Roles worth surfacing to the model as click targets. Container/decorative roles are skipped.
    static let actionableRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuItem", "AXMenuButton", "AXLink", "AXComboBox",
        "AXSlider", "AXTabButton", "AXDisclosureTriangle", "AXIncrementor",
        "AXSegmentedControl", "AXSearchField", "AXStepper", "AXColorWell",
    ]

    static let maxLabelChars = 80

    /// A warning to attach to a screenshot whose element list came back EMPTY because
    /// Accessibility isn't granted — otherwise the model gets a silently blank `ax_elements`, has
    /// no clickable coordinates, and resorts to blind typing / looping (observed in the wild).
    /// nil when there's nothing to say (elements present, or AX granted so empty is genuine).
    static func emptyElementsNote(hasAccessibility: Bool, elementCount: Int) -> String? {
        guard elementCount == 0, !hasAccessibility else { return nil }
        return "No UI element coordinates are available because NanoTeams lacks Accessibility "
            + "permission. Grant it in System Settings → Privacy & Security → Accessibility to get "
            + "clickable element positions; until then, act from the screenshot pixels directly."
    }

    /// Enumerate actionable elements of the request's `pid`, returning frames in image-pixel
    /// space, deduped + capped + wire-ready. `matchWindowToRegion: true` (window captures)
    /// roots the walk at the AXWindow whose frame mutually covers the captured region —
    /// without it the walk starts at the APP root, and elements of the app's OTHER windows
    /// whose global frames overlap the region get advertised with valid-looking coordinates
    /// even though the image shows a different window at those pixels.
    ///
    /// Runs the entire pipeline (web-AX enable → walk → one-shot settle+retry → dedup →
    /// emission cap → warnings) inside a detached task: the walk is synchronous AX IPC that can
    /// take seconds against a busy browser, and must not block the main actor. `AXUIElement`
    /// references live and die inside the closure — only Sendable values cross.
    ///
    /// Cancellation-responsive: `Task.detached` does NOT inherit the caller's cancellation, so a
    /// shared atomic flag (flipped by `withTaskCancellationHandler`) is what the walk polls —
    /// otherwise a Pause landing mid-walk would block the caller past the bounded-wait budget.
    static func collectElements(_ request: AXCollectionRequest) async -> AXCollectionResult {
        guard request.pixelWidth > 0, request.pixelHeight > 0,
              request.regionWidthPt > 0, request.regionHeightPt > 0 else { return .empty }
        let cancelled = WalkCancellationFlag()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> AXCollectionResult in
                let geom = Geometry(
                    originX: request.regionOriginX, originY: request.regionOriginY,
                    regionWidthPt: request.regionWidthPt, regionHeightPt: request.regionHeightPt,
                    pixelWidth: request.pixelWidth, pixelHeight: request.pixelHeight)

                let appElement = AXUIElementCreateApplication(request.pid)
                // Bound each AX IPC round-trip so a beachballing target can't stall the walk past
                // its wall-clock deadline (the deadline is only checked BETWEEN nodes; a single
                // hung `AXUIElementCopyAttributeValue` would otherwise block ~6 s at the default).
                AXUIElementSetMessagingTimeout(appElement, Float(AccessibilityWalkPolicy.axMessagingTimeoutSeconds))
                let region = CGRect(x: request.regionOriginX, y: request.regionOriginY,
                                    width: request.regionWidthPt, height: request.regionHeightPt)
                let root = request.matchWindowToRegion
                    ? (windowMatchingRegion(appElement: appElement, region: region) ?? appElement)
                    : appElement

                // Enable idempotently and DON'T restore: read-before-set means a second capture
                // of the same app sees the attribute already true, skips the write, and finds the
                // web tree already populated (no empty-area retry). Restoring instead (a) tore the
                // web AX tree down under a concurrent capture of the same app — resurrecting the
                // chrome-only incident — and (b) made every subsequent capture re-pay the
                // settle+retry. Leaving it enabled matches what VoiceOver does; it resets on app
                // quit. The click path never needs live AX (it uses the saved element list).
                enableWebAccessibility(on: appElement)
                let first = runWalk(root: root, geom: geom, cancelled: cancelled)
                var outcome = first
                if AccessibilityWalkPolicy.shouldRetryForWebContent(
                    sawWebArea: first.sawWebArea,
                    webElementCount: first.elements.count(where: \.web)) {
                    // The web area exists but hadn't populated when we walked — WebKit/Chromium
                    // build it lazily after `enableWebAccessibility` announced us. Settle, retry
                    // once, and keep whichever attempt yielded MORE elements: a retry that hits
                    // its deadline deep in a now-huge web subtree can return fewer than attempt 1,
                    // and the model must not end up with neither the chrome nor the page content.
                    try? await Task.sleep(for: .milliseconds(AccessibilityWalkPolicy.webSettleMilliseconds))
                    let second = runWalk(root: root, geom: geom, cancelled: cancelled)
                    outcome = second.elements.count >= first.elements.count ? second : first
                }

                // Dedup BEFORE the cap so nested duplicates don't consume emission slots.
                let deduped = dedupNested(outcome.elements)
                let capped = AccessibilityWalkPolicy.capEmission(
                    deduped, limit: AccessibilityWalkPolicy.maxEmittedElements)
                let webAreaEmpty = outcome.sawWebArea && !deduped.contains(where: \.web)
                let warnings = AccessibilityWalkPolicy.collectionWarnings(
                    stoppedEarly: outcome.stoppedEarly, webAreaEmpty: webAreaEmpty,
                    visited: outcome.visitedNodes,
                    kept: capped.kept.count, totalAfterDedup: deduped.count)
                return AXCollectionResult(
                    elements: capped.kept, totalAfterDedup: deduped.count, warnings: warnings)
            }.value
        } onCancel: {
            cancelled.cancel()
        }
    }

    private static func runWalk(root: AXUIElement, geom: Geometry, cancelled: WalkCancellationFlag) -> AXWalkOutcome {
        var outcome = AXWalkOutcome()
        let deadline = ContinuousClock.now
            + .milliseconds(AccessibilityWalkPolicy.walkDeadlineMilliseconds)
        walk(root, depth: 0, insideWebArea: false, deadline: deadline,
             cancelled: cancelled, outcome: &outcome, geom: geom)
        return outcome
    }

    // MARK: - Web-content accessibility (lazy AX trees)

    /// Attributes that announce an assistive client: WebKit keys off `AXEnhancedUserInterface`,
    /// Chromium/Electron off `AXManualAccessibility`. Without one of them set on the app
    /// element, a browser's `AXWebArea` reports NO children — the incident capture advertised
    /// only Safari chrome for a full LinkedIn page.
    private static let webAXAttributes = ["AXEnhancedUserInterface", "AXManualAccessibility"]

    /// Idempotently sets both attributes to true (read-before-set skips the write when already
    /// on — including when another assistive client set it). Never restored (see the call-site
    /// rationale). All AX errors are advisory: an app that rejects the set degrades to its
    /// native tree.
    private static func enableWebAccessibility(on appElement: AXUIElement) {
        for attribute in webAXAttributes {
            var current: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, attribute as CFString, &current) == .success,
               (current as? Bool) == true {
                continue
            }
            _ = AXUIElementSetAttributeValue(appElement, attribute as CFString, kCFBooleanTrue)
        }
    }

    /// The app's AXWindow whose frame (global top-left points) mutually covers the captured
    /// region — i.e. the window the screenshot actually shows. nil when none matches
    /// (screen captures, moved/ambiguous frames); the caller falls back to the app root.
    private static func windowMatchingRegion(appElement: AXUIElement, region: CGRect) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return nil }
        let frames = windows.map { frame(of: $0) ?? .null }
        guard let index = bestWindowMatchIndex(windowFrames: frames, region: region) else { return nil }
        return windows[index]
    }

    /// Coverage (of BOTH areas) above which a window frame is "the captured window".
    private static let windowMatchCoverageThreshold = 0.8

    /// Pure frame-match: index of the window frame that MUTUALLY overlaps the region ≥ 80%
    /// of both areas. Mutual coverage identifies identity while rejecting both small child
    /// windows inside the region and huge windows that merely contain it. Best coverage
    /// wins; ties keep the earlier (frontmost in AX order) window.
    static func bestWindowMatchIndex(windowFrames: [CGRect], region: CGRect) -> Int? {
        let regionArea = region.width * region.height
        guard regionArea > 0 else { return nil }
        var best: (index: Int, coverage: Double)?
        for (i, f) in windowFrames.enumerated() {
            let inter = f.intersection(region)
            let frameArea = f.width * f.height
            guard !inter.isNull, frameArea > 0 else { continue }
            let interArea = inter.width * inter.height
            let coverage = Double(min(interArea / regionArea, interArea / frameArea))
            guard coverage >= windowMatchCoverageThreshold, coverage > (best?.coverage ?? 0) else { continue }
            best = (i, coverage)
        }
        return best?.index
    }

    /// Center of the element's VISIBLE part, clamped into `0 ..< pixelWidth/Height` so the
    /// returned point is always a clickable pixel of the image. An element straddling the
    /// capture edge can have a negative `x` (or overflow the far edge) — its geometric center
    /// may lie outside the image, where `imagePixelToGlobalPoint` would reject the click.
    static func clampedCenter(
        x: Int, y: Int, w: Int, h: Int,
        pixelWidth: Int, pixelHeight: Int
    ) -> (cx: Int, cy: Int) {
        func axis(_ lo: Int, _ len: Int, _ bound: Int) -> Int {
            let visLo = max(lo, 0)
            let visHi = min(lo + len, bound)
            // Non-empty overlap is guaranteed by mapFrame's clip; the max() guards rounding.
            // center ≥ visLo ≥ 0 always; only the UPPER edge is reachable (mapFrame bounds-
            // checks pre-rounding, so a rounded corner can equal `bound`).
            let center = visLo + max(visHi - visLo, 1) / 2
            return min(center, bound - 1)
        }
        return (axis(x, w, pixelWidth), axis(y, h, pixelHeight))
    }

    // MARK: - Nested-duplicate dedup

    /// Coverage fraction (of the SMALLER element) above which a same-role/same-label pair is
    /// treated as one control reported twice. Not 1.0: real trees are sloppy — Safari's start
    /// page reports a favorite as a tile button AND a label button whose frames disagree by
    /// ~1 pt, so strict containment never fires.
    private static let dedupCoverageThreshold = 0.85

    /// Drops redundant nested entries: when two elements share `role` + a NON-EMPTY `label`
    /// and the smaller is (almost) fully covered by the larger, only the larger survives — it
    /// is the same control reported at two granularities, and the duplicate doubles the list
    /// the model must scan (observed confusion: near-identical two-char labels picked from
    /// the wrong row). Unlabeled pairs never dedup — icon-only controls legitimately nest
    /// (a play button covering most of its card) and `"" == ""` would silently drop the real
    /// target. Disjoint same-label elements are both kept.
    ///
    /// Processing is largest-first so a chain (tile ⊃ label ⊃ glyph) collapses onto the
    /// largest regardless of input order; output preserves input order; equal-area ties keep
    /// the first-seen entry (area-sort is stable by original index).
    static func dedupNested(_ elements: [AXElementInfo]) -> [AXElementInfo] {
        guard elements.count > 1 else { return elements }
        let byAreaDesc = elements.indices.sorted {
            let a = elements[$0].w * elements[$0].h
            let b = elements[$1].w * elements[$1].h
            return a != b ? a > b : $0 < $1
        }
        var dropped = Set<Int>()
        for (rank, i) in byAreaDesc.enumerated() where !dropped.contains(i) {
            let a = elements[i]
            for j in byAreaDesc.dropFirst(rank + 1) where !dropped.contains(j) {
                let b = elements[j]   // b.area ≤ a.area by construction
                guard a.role == b.role, a.label == b.label, !a.label.isEmpty, b.w * b.h > 0 else { continue }
                let overlapW = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
                let overlapH = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
                guard overlapW > 0, overlapH > 0,
                      Double(overlapW * overlapH) >= dedupCoverageThreshold * Double(b.w * b.h)
                else { continue }
                dropped.insert(j)
            }
        }
        return elements.indices.filter { !dropped.contains($0) }.map { elements[$0] }
    }

    // MARK: - Click-point containment echo

    /// The most specific (smallest-area) element whose frame contains the image-pixel point.
    /// Pure lookup against the elements ADVERTISED with the same capture the click
    /// coordinates reference — deliberately not a live AX hit-test: a hit-test IPC on the
    /// click path can block the main actor for seconds against a busy target app, resolves
    /// to roles outside `actionableRoles` for legitimate targets (table rows, web widgets,
    /// context-menu backgrounds), and returns nothing at all in apps with sparse AX trees —
    /// each of which would turn successful clicks into false "you missed" signals.
    static func elementContaining(imageX: Int, imageY: Int, in elements: [AXElementInfo]) -> AXElementInfo? {
        elements
            .filter { imageX >= $0.x && imageX < $0.x + $0.w && imageY >= $0.y && imageY < $0.y + $0.h }
            .min { $0.w * $0.h < $1.w * $1.h }
    }

    /// Pure warning decision for the click echo: fires only when the advertised element list
    /// is non-empty AND the point is inside none of its entries — positive evidence of a
    /// likely miss (the incident click sat 1 px inside a neighboring element's corner; under
    /// centers-only aiming a dead-space click means a wrong pick). Phrased as a nudge, not a
    /// verdict: dead-space clicks are sometimes intentional, and the list is capped and
    /// role-filtered so legitimate targets can be absent from it.
    static func clickHitWarning(hit: AXElementInfo?, x: Int, y: Int, hasElements: Bool) -> String? {
        guard hasElements, hit == nil else { return nil }
        return "The click at (\(x), \(y)) is not inside any element from the latest screenshot's "
            + "ax_elements. If it had no effect, re-check the screenshot and click an element's cx/cy."
    }

    /// Pure staleness nudge for pointer actions: fires when UI-changing actions (clicks, keys,
    /// typing) ran AFTER the capture the coordinates reference. The advertised element list —
    /// and the `element_at_point` echo resolved against it — describe a UI that may no longer
    /// exist (the incident model clicked Safari's Page Menu, which opened a dropdown, then kept
    /// aiming with pre-dropdown coordinates while the echo "confirmed" stale elements). Distinct
    /// from `clickHitWarning`, which is about a miss within a FRESH capture.
    static func staleCaptureWarning(actionsSinceCapture: Int) -> String? {
        guard actionsSinceCapture > 0 else { return nil }
        let counted = actionsSinceCapture == 1
            ? "1 action has" : "\(actionsSinceCapture) actions have"
        return "\(counted) run since the last screen_capture — the screenshot, its ax_elements, "
            + "and element_at_point may be stale. If the UI changed (a menu or dialog opened, the "
            + "page navigated), take a new screen_capture before further clicks."
    }

    /// The screenshot region geometry an element frame is mapped against. `mapFrame` is the
    /// single source of the global-point → image-pixel conversion, delegating the corner to
    /// `InputControlService.globalPointToImagePixel` (the exact inverse of the click map) so the
    /// element list and the click resolution can never drift. Internal (not private) so tests can
    /// pin the mapping + overlap clip directly.
    struct Geometry {
        let originX: Double, originY: Double
        let regionWidthPt: Double, regionHeightPt: Double
        let pixelWidth: Int, pixelHeight: Int

        /// Global (top-left points) frame → integer image-pixel rect, or nil if it doesn't
        /// overlap the captured region.
        func mapFrame(_ frame: CGRect) -> (x: Int, y: Int, w: Int, h: Int)? {
            guard let corner = InputControlService.globalPointToImagePixel(
                globalX: Double(frame.minX), globalY: Double(frame.minY),
                originX: originX, originY: originY,
                regionWidthPt: regionWidthPt, regionHeightPt: regionHeightPt,
                pixelWidth: pixelWidth, pixelHeight: pixelHeight) else { return nil }
            let iw = Double(frame.width) * (Double(pixelWidth) / regionWidthPt)
            let ih = Double(frame.height) * (Double(pixelHeight) / regionHeightPt)
            let overlaps = corner.x + iw > 0 && corner.y + ih > 0
                && corner.x < Double(pixelWidth) && corner.y < Double(pixelHeight) && iw >= 1 && ih >= 1
            guard overlaps else { return nil }
            return (Int(corner.x.rounded()), Int(corner.y.rounded()), Int(iw.rounded()), Int(ih.rounded()))
        }
    }

    // MARK: - Traversal

    /// Raw stats of one walk attempt — feeds the retry decision and the no-silent-caps
    /// warnings. Each `hit*` flag marks a place the walk abandoned a subtree; `stoppedEarly`
    /// folds them for the warning so no budget cut is silent (the incident's failure mode was a
    /// truncated list read as complete). Not `Task.isCancelled` — a cancelled result is discarded.
    private struct AXWalkOutcome {
        var elements: [AXElementInfo] = []
        var sawWebArea = false
        var visitedNodes = 0
        var hitNodeCap = false
        var hitDeadline = false
        var hitDepthCap = false

        var stoppedEarly: Bool { hitNodeCap || hitDeadline || hitDepthCap }
    }

    private static func walk(
        _ element: AXUIElement, depth: Int, insideWebArea: Bool,
        deadline: ContinuousClock.Instant, cancelled: WalkCancellationFlag,
        outcome: inout AXWalkOutcome, geom: Geometry
    ) {
        // Cancellation (Pause / teardown) → bail without a warning; the result is thrown away.
        if cancelled.isCancelled { return }
        // Depth cut drops a subtree — must surface, or a &gt;maxDepth-nested page control reads as
        // "not on screen" (the exact no-silent-caps failure the warnings exist to prevent).
        guard depth <= AccessibilityWalkPolicy.maxDepth else {
            outcome.hitDepthCap = true
            return
        }
        guard outcome.visitedNodes < AccessibilityWalkPolicy.maxVisitedNodes else {
            outcome.hitNodeCap = true
            return
        }
        guard ContinuousClock.now < deadline else {
            outcome.hitDeadline = true
            return
        }
        outcome.visitedNodes += 1

        let role = stringAttr(element, kAXRoleAttribute as String)
        let inWebArea = insideWebArea || role == "AXWebArea"
        if role == "AXWebArea" { outcome.sawWebArea = true }

        if let role,
           actionableRoles.contains(role),
           let frame = frame(of: element),
           let mapped = geom.mapFrame(frame) {
            let center = clampedCenter(
                x: mapped.x, y: mapped.y, w: mapped.w, h: mapped.h,
                pixelWidth: geom.pixelWidth, pixelHeight: geom.pixelHeight)
            outcome.elements.append(AXElementInfo(
                role: role,
                label: label(of: element),
                x: mapped.x, y: mapped.y, w: mapped.w, h: mapped.h,
                cx: center.cx, cy: center.cy,
                web: inWebArea
            ))
        }

        for child in children(of: element) {
            // Set the flag on the way out so the cap/deadline cut isn't silent — the child's own
            // entry guard would set it, but breaking here avoids O(children) no-op recursions.
            if outcome.hitDeadline || cancelled.isCancelled { break }
            if outcome.visitedNodes >= AccessibilityWalkPolicy.maxVisitedNodes {
                outcome.hitNodeCap = true
                break
            }
            walk(child, depth: depth + 1, insideWebArea: inWebArea,
                 deadline: deadline, cancelled: cancelled, outcome: &outcome, geom: geom)
        }
    }

    // MARK: - AX attribute helpers

    private static func stringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func label(of element: AXUIElement) -> String {
        let raw = stringAttr(element, kAXTitleAttribute as String)
            ?? stringAttr(element, kAXValueAttribute as String)
            ?? stringAttr(element, kAXDescriptionAttribute as String)
            ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maxLabelChars ? String(trimmed.prefix(maxLabelChars)) + "…" : trimmed
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posVal: AnyObject?
        var sizeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let posRef = posVal, let sizeRef = sizeVal else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        // CF bridge guaranteed after .success.
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }
}
