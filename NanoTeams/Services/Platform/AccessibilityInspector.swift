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

// MARK: - Accessibility tree seam

/// A UTF-16 text range as reported by Accessibility. `CFRange` carries `CFIndex` and is awkward to
/// construct in a fixture; this is the plain value the decisions above the seam work with.
nonisolated struct AXTextRange: Sendable, Equatable {
    let location: Int
    let length: Int
}

/// Read + announce access to ONE process's Accessibility tree, parameterised over the node type.
///
/// An AX tree belongs to another process and cannot be constructed, so while the traversal below
/// called `AXUIElementCopyAttributeValue` directly, none of it was reachable from a test — and what
/// it contains is a **budget state machine**: a depth cap, a node cap, a wall-clock deadline, a
/// cancellation poll, web-area propagation down the recursion, and a deliberate
/// set-the-flag-on-the-way-out so that no budget cut is silent. The no-silent-caps contract those
/// flags implement was stated in prose and enforced nowhere; the incident it exists to prevent is a
/// truncated element list read by the model as a complete one.
///
/// `HotkeyRegistry<Ref>` in this directory is the same shape: parameterise over the opaque OS
/// handle, keep the bookkeeping generic, and let the live conformance be the only part that talks
/// to the framework.
nonisolated protocol AXNodeReading: Sendable {
    associatedtype Node

    /// Root node for a process. Called INSIDE the detached walk so no node ever crosses a task
    /// boundary — only the `pid` and the reader itself do.
    func applicationNode(pid: pid_t) -> Node

    func string(_ attribute: String, of node: Node) -> String?
    func boolValue(_ attribute: String, of node: Node) -> Bool?
    func frame(of node: Node) -> CGRect?
    func children(of node: Node) -> [Node]
    func element(_ attribute: String, of node: Node) -> Node?
    func elements(_ attribute: String, of node: Node) -> [Node]
    func selectedRange(of node: Node) -> AXTextRange?

    /// Announce this process as an assistive client. Advisory: an app that rejects the write
    /// degrades to its native tree.
    func setTrue(_ attribute: String, on node: Node)

    /// Bound each AX IPC round-trip. The walk's deadline is only checked BETWEEN nodes, so a single
    /// hung `AXUIElementCopyAttributeValue` would otherwise block ~6 s at the framework default.
    func setMessagingTimeout(_ seconds: Double, on node: Node)
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
        // Model-read (rides the capture envelope's `warnings`), so the recourse is one the
        // model can act on — only the supervisor can grant the permission.
        return "No UI element coordinates are available because NanoTeams lacks macOS Accessibility "
            + "permission. Only the supervisor can grant it; until then, act from the screenshot "
            + "pixels directly."
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
    /// Production entry point, and the ONLY place the live reader is named. Deliberately not a
    /// defaulted parameter on the generic overload below: a default that resolves OUTWARD is the
    /// shape CLAUDE.md §49 records as a 93-site disaster, and one resolving INWARD (an inert reader)
    /// would make a forgotten injection in production look exactly like "this app has no
    /// accessibility tree" — the chrome-only capture incident, silently. A separate overload makes
    /// the reader mandatory for every other caller, so forgetting it is a compile error.
    static func collectElements(_ request: AXCollectionRequest) async -> AXCollectionResult {
        await collectElements(request, reader: SystemAXNodeReader())
    }

    static func collectElements<R: AXNodeReading>(
        _ request: AXCollectionRequest, reader: R
    ) async -> AXCollectionResult {
        guard request.pixelWidth > 0, request.pixelHeight > 0,
              request.regionWidthPt > 0, request.regionHeightPt > 0 else { return .empty }
        let cancelled = WalkCancellationFlag()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> AXCollectionResult in
                let geom = Geometry(
                    originX: request.regionOriginX, originY: request.regionOriginY,
                    regionWidthPt: request.regionWidthPt, regionHeightPt: request.regionHeightPt,
                    pixelWidth: request.pixelWidth, pixelHeight: request.pixelHeight)

                let appElement = reader.applicationNode(pid: request.pid)
                reader.setMessagingTimeout(
                    AccessibilityWalkPolicy.axMessagingTimeoutSeconds, on: appElement)
                let region = CGRect(x: request.regionOriginX, y: request.regionOriginY,
                                    width: request.regionWidthPt, height: request.regionHeightPt)
                let root = request.matchWindowToRegion
                    ? (windowMatchingRegion(appElement: appElement, reader: reader, region: region) ?? appElement)
                    : appElement

                // Enable idempotently and DON'T restore: read-before-set means a second capture
                // of the same app sees the attribute already true, skips the write, and finds the
                // web tree already populated (no empty-area retry). Restoring instead (a) tore the
                // web AX tree down under a concurrent capture of the same app — resurrecting the
                // chrome-only incident — and (b) made every subsequent capture re-pay the
                // settle+retry. Leaving it enabled matches what VoiceOver does; it resets on app
                // quit. The click path never needs live AX (it uses the saved element list).
                enableWebAccessibility(on: appElement, reader: reader)
                let first = runWalk(root: root, reader: reader, geom: geom, cancelled: cancelled)
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
                    let second = runWalk(root: root, reader: reader, geom: geom, cancelled: cancelled)
                    outcome = second.elements.count >= first.elements.count ? second : first
                }

                return finalize(
                    elements: outcome.elements, sawWebArea: outcome.sawWebArea,
                    stoppedEarly: outcome.stoppedEarly, visitedNodes: outcome.visitedNodes)
            }.value
        } onCancel: {
            cancelled.cancel()
        }
    }

    /// Pure post-walk composition: dedup → emission cap → no-silent-caps warnings → wire result.
    /// Split out of the detached walk for the same reason `AccessibilityWalkPolicy` was — every
    /// decision here is a plain function of the walk's raw stats, and none of it is testable while
    /// it sits inside a closure that first needs a live accessibility tree.
    ///
    /// The ORDER is load-bearing: dedup runs BEFORE the cap so nested duplicates don't consume
    /// emission slots (capping first would evict real targets to make room for the copies dedup is
    /// about to delete). `totalAfterDedup` and `webAreaEmpty` are therefore both judged on the
    /// deduped list — the list the model actually receives, which is what the warnings describe.
    static func finalize(
        elements: [AXElementInfo], sawWebArea: Bool, stoppedEarly: Bool, visitedNodes: Int
    ) -> AXCollectionResult {
        let deduped = dedupNested(elements)
        let capped = AccessibilityWalkPolicy.capEmission(
            deduped, limit: AccessibilityWalkPolicy.maxEmittedElements)
        let webAreaEmpty = sawWebArea && !deduped.contains(where: \.web)
        let warnings = AccessibilityWalkPolicy.collectionWarnings(
            stoppedEarly: stoppedEarly, webAreaEmpty: webAreaEmpty,
            visited: visitedNodes,
            kept: capped.kept.count, totalAfterDedup: deduped.count)
        return AXCollectionResult(
            elements: capped.kept, totalAfterDedup: deduped.count, warnings: warnings)
    }

    /// One walk attempt with a freshly-armed deadline. `internal`, not `private`, so a test can
    /// drive the traversal against a fixture tree and assert on every budget flag — the whole
    /// point of the seam.
    static func runWalk<R: AXNodeReading>(
        root: R.Node, reader: R, geom: Geometry, cancelled: WalkCancellationFlag,
        deadlineMilliseconds: Int = AccessibilityWalkPolicy.walkDeadlineMilliseconds
    ) -> AXWalkOutcome {
        var outcome = AXWalkOutcome()
        let deadline = ContinuousClock.now + .milliseconds(deadlineMilliseconds)
        walk(root, reader: reader, depth: 0, insideWebArea: false, deadline: deadline,
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
    static func enableWebAccessibility<R: AXNodeReading>(on appElement: R.Node, reader: R) {
        for attribute in webAXAttributes {
            if reader.boolValue(attribute, of: appElement) == true { continue }
            reader.setTrue(attribute, on: appElement)
        }
    }

    /// The app's AXWindow whose frame (global top-left points) mutually covers the captured
    /// region — i.e. the window the screenshot actually shows. nil when none matches
    /// (screen captures, moved/ambiguous frames); the caller falls back to the app root.
    static func windowMatchingRegion<R: AXNodeReading>(
        appElement: R.Node, reader: R, region: CGRect
    ) -> R.Node? {
        let windows = reader.elements(kAXWindowsAttribute as String, of: appElement)
        guard !windows.isEmpty else { return nil }
        let frames = windows.map { reader.frame(of: $0) ?? .null }
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
            // The overlap test above is pre-rounding; the RETURNED rect is the rounded one, and
            // rounding can push a marginal element off the image entirely (a corner half a pixel
            // inside the far edge rounds to `pixelWidth`). Such an element covers no pixel column,
            // yet `clampedCenter` still clamps its centre back INTO the image — advertising a
            // `cx`/`cy` that is not inside the element's own advertised `(x, w)` box, so the click
            // echo reports a miss for the exact coordinate the model was told to click. Restate the
            // contract on the integer rect the caller actually receives.
            //
            // The conversions are also total by construction rather than by assumption: AX geometry
            // comes from ANOTHER process, and `Int(_: Double)` TRAPS (uncatchable — it aborts the
            // app from inside the detached walk) for anything outside `Int`'s range, as do the
            // `w * h` area products in `dedupNested` / `elementContaining`. Unrepresentable geometry
            // is dropped exactly like a sub-pixel element: it has no clickable pixel either.
            let rx = corner.x.rounded(), ry = corner.y.rounded()
            let rw = iw.rounded(), rh = ih.rounded()
            guard rx < Double(pixelWidth), ry < Double(pixelHeight),
                  rx + rw > 0, ry + rh > 0,
                  let x = Int(exactly: rx), let y = Int(exactly: ry),
                  let w = Int(exactly: rw), let h = Int(exactly: rh),
                  !w.multipliedReportingOverflow(by: h).overflow
            else { return nil }
            return (x, y, w, h)
        }
    }

    // MARK: - Traversal

    /// Raw stats of one walk attempt — feeds the retry decision and the no-silent-caps
    /// warnings. Each `hit*` flag marks a place the walk abandoned a subtree; `stoppedEarly`
    /// folds them for the warning so no budget cut is silent (the incident's failure mode was a
    /// truncated list read as complete). Not `Task.isCancelled` — a cancelled result is discarded.
    struct AXWalkOutcome: Equatable {
        var elements: [AXElementInfo] = []
        var sawWebArea = false
        var visitedNodes = 0
        var hitNodeCap = false
        var hitDeadline = false
        var hitDepthCap = false

        var stoppedEarly: Bool { hitNodeCap || hitDeadline || hitDepthCap }
    }

    private static func walk<R: AXNodeReading>(
        _ element: R.Node, reader: R, depth: Int, insideWebArea: Bool,
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
        // Defense in depth, and currently unreachable by construction: the child loop below refuses
        // to recurse once the budget is spent, and the only other entry is `runWalk` with a fresh
        // outcome. It is kept — rather than deleted as dead — because it makes "no entry to `walk`
        // may exceed the node budget" a property of `walk` itself instead of an obligation on every
        // caller, and a third call site would otherwise inherit the obligation silently.
        guard outcome.visitedNodes < AccessibilityWalkPolicy.maxVisitedNodes else {
            outcome.hitNodeCap = true
            return
        }
        guard ContinuousClock.now < deadline else {
            outcome.hitDeadline = true
            return
        }
        outcome.visitedNodes += 1

        let role = reader.string(kAXRoleAttribute as String, of: element)
        let inWebArea = insideWebArea || role == "AXWebArea"
        if role == "AXWebArea" { outcome.sawWebArea = true }

        if let role,
           actionableRoles.contains(role),
           let frame = reader.frame(of: element),
           let mapped = geom.mapFrame(frame) {
            let center = clampedCenter(
                x: mapped.x, y: mapped.y, w: mapped.w, h: mapped.h,
                pixelWidth: geom.pixelWidth, pixelHeight: geom.pixelHeight)
            outcome.elements.append(AXElementInfo(
                role: role,
                label: label(of: element, reader: reader),
                x: mapped.x, y: mapped.y, w: mapped.w, h: mapped.h,
                cx: center.cx, cy: center.cy,
                web: inWebArea
            ))
        }

        for child in reader.children(of: element) {
            // Set the flag on the way out so the cap/deadline cut isn't silent — the child's own
            // entry guard would set it, but breaking here avoids O(children) no-op recursions.
            if outcome.hitDeadline || cancelled.isCancelled { break }
            if outcome.visitedNodes >= AccessibilityWalkPolicy.maxVisitedNodes {
                outcome.hitNodeCap = true
                break
            }
            walk(child, reader: reader, depth: depth + 1, insideWebArea: inWebArea,
                 deadline: deadline, cancelled: cancelled, outcome: &outcome, geom: geom)
        }
    }

    // MARK: - AX attribute helpers

    /// Title → value → description, first non-nil wins. The ORDER is the decision: a text field's
    /// `AXValue` is its live contents, so preferring it over `AXTitle` would label a search box by
    /// whatever the user has typed into it — a label that changes under the model between captures.
    static func label<R: AXNodeReading>(of element: R.Node, reader: R) -> String {
        normalizedLabel(
            reader.string(kAXTitleAttribute as String, of: element)
                ?? reader.string(kAXValueAttribute as String, of: element)
                ?? reader.string(kAXDescriptionAttribute as String, of: element))
    }

    /// Pure normalisation of a raw AX title/value/description into the label that ships on the
    /// wire: trim first, then cap at `maxLabelChars` with an ellipsis. Split out of `label(of:)`
    /// (which needs a live AX element) because this is the ONLY place the per-element label budget
    /// is enforced — `maxLabelChars` × the emission cap is the worst-case payload of a capture, and
    /// nothing else could pin that the cap is actually APPLIED rather than merely declared.
    /// Truncation is by `Character`, so a grapheme cluster (emoji, combining marks) is never split.
    static func normalizedLabel(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maxLabelChars ? String(trimmed.prefix(maxLabelChars)) + "…" : trimmed
    }

}

// MARK: - Live Accessibility conformance

/// The only code here that talks to `ApplicationServices`. Every method is a single framework
/// round-trip with its documented failure folded to nil/empty — there is no decision left in it,
/// which is exactly why the walk above was lifted out.
///
/// The `as!` casts are the sanctioned CF idiom (CLAUDE.md #35): `as?` on a CoreFoundation type is a
/// compiler error ("conditional downcast will always succeed"), and the framework guarantees the
/// type once the copy returned `.success`.
nonisolated struct SystemAXNodeReader: AXNodeReading {

    func applicationNode(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    func string(_ attribute: String, of node: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func boolValue(_ attribute: String, of node: AXUIElement) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    func frame(of node: AXUIElement) -> CGRect? {
        var posVal: AnyObject?
        var sizeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(node, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(node, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let posRef = posVal, let sizeRef = sizeVal else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    func children(of node: AXUIElement) -> [AXUIElement] {
        elements(kAXChildrenAttribute as String, of: node)
    }

    func element(_ attribute: String, of node: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
              let ref = value else { return nil }
        return (ref as! AXUIElement)
    }

    func elements(_ attribute: String, of node: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    func selectedRange(of node: AXUIElement) -> AXTextRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(node, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let ref = value else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return AXTextRange(location: range.location, length: range.length)
    }

    func setTrue(_ attribute: String, on node: AXUIElement) {
        _ = AXUIElementSetAttributeValue(node, attribute as CFString, kCFBooleanTrue)
    }

    func setMessagingTimeout(_ seconds: Double, on node: AXUIElement) {
        AXUIElementSetMessagingTimeout(node, Float(seconds))
    }
}

// MARK: - Computer-use facade seam

/// What the computer-use finalizer needs from this file: one call. Separate from `AXNodeReading`
/// on purpose — that seam exists so *this file's* budget state machine is testable, while this one
/// exists so the finalizer can be driven without an accessibility tree at all. A test of the
/// dispatcher has no business building AX nodes.
nonisolated protocol AXElementCollecting: Sendable {
    func collectElements(_ request: AXCollectionRequest) async -> AXCollectionResult
}

nonisolated struct SystemAXElementCollector: AXElementCollecting {
    func collectElements(_ request: AXCollectionRequest) async -> AXCollectionResult {
        await AccessibilityInspector.collectElements(request)
    }
}

/// No tree — the same answer an untrusted process gets. The inert default for
/// `ComputerUseEnvironment`; `AccessibilityInspector.emptyElementsNote` turns it into a warning
/// rather than a silently blank list, which is the behaviour under test.
nonisolated struct InertAXElementCollector: AXElementCollecting {
    func collectElements(_ request: AXCollectionRequest) async -> AXCollectionResult { .empty }
}
