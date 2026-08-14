import ApplicationServices
import CoreGraphics
import XCTest

@testable import NanoTeams

/// `AccessibilityInspector`'s traversal, against the `AXNodeReading` seam. Nothing here touches a
/// live accessibility tree.
///
/// The walk is a **budget state machine** — a depth cap, a node cap, a wall-clock deadline, a
/// cancellation poll, web-area propagation down the recursion, and a deliberate
/// set-the-flag-on-the-way-out so no budget cut is silent. Its no-silent-caps contract was written
/// in prose and enforced nowhere, because an AX tree belongs to another process and could not be
/// constructed; the incident it exists to prevent is a truncated element list that the model reads
/// as a complete one.
///
/// `AccessibilityInspectorFinalizationTests` covers the pure tail (dedup → cap → warnings); this
/// file covers everything that produces the input to it.
final class AccessibilityWalkCoverageTests: XCTestCase {

    /// A 100×100-point region captured at 100×100 pixels, so element frames map 1:1 and the
    /// coordinates in these tests read as the frames themselves.
    private var geom: AccessibilityInspector.Geometry {
        AccessibilityInspector.Geometry(
            originX: 0, originY: 0, regionWidthPt: 100, regionHeightPt: 100,
            pixelWidth: 100, pixelHeight: 100)
    }

    private func walk(_ root: FakeAXNode, reader: FakeAXReader,
                      deadlineMilliseconds: Int = 5_000,
                      cancelled: WalkCancellationFlag = WalkCancellationFlag())
        -> AccessibilityInspector.AXWalkOutcome {
        AccessibilityInspector.runWalk(
            root: root, reader: reader, geom: geom, cancelled: cancelled,
            deadlineMilliseconds: deadlineMilliseconds)
    }

    // MARK: - Emission

    func testWalk_actionableElement_isEmittedWithMappedFrameAndClampedCenter() {
        let root = FakeAXNode(role: "AXGroup")
            .adding(.button("OK", x: 10, y: 20, w: 30, h: 40))
        let reader = FakeAXReader()

        let outcome = walk(root, reader: reader)

        XCTAssertEqual(outcome.elements.count, 1)
        let element = outcome.elements[0]
        XCTAssertEqual(element.role, "AXButton")
        XCTAssertEqual(element.label, "OK")
        XCTAssertEqual([element.x, element.y, element.w, element.h], [10, 20, 30, 40])
        XCTAssertEqual([element.cx, element.cy], [25, 40], "centre of the visible part")
        XCTAssertFalse(element.web)
    }

    /// Container roles are traversed but never advertised — a click target list full of `AXGroup`
    /// is a list the model cannot use.
    func testWalk_nonActionableRole_isTraversedButNotEmitted() {
        let root = FakeAXNode(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
            .adding(FakeAXNode(role: "AXUnknown", frame: CGRect(x: 0, y: 0, width: 5, height: 5))
                .adding(.button("Deep", x: 1, y: 1)))
        let reader = FakeAXReader()

        let outcome = walk(root, reader: reader)

        XCTAssertEqual(outcome.elements.map(\.label), ["Deep"])
        XCTAssertEqual(outcome.visitedNodes, 3, "every node is still visited")
    }

    func testWalk_actionableElementWithNoFrame_isSkipped() {
        let root = FakeAXNode(role: "AXGroup")
            .adding(FakeAXNode(role: "AXButton", title: "Ghost", frame: nil))
        let reader = FakeAXReader()

        XCTAssertTrue(walk(root, reader: reader).elements.isEmpty)
    }

    /// An element whose frame lies outside the captured region has no pixel the model could click.
    func testWalk_elementOutsideTheCapturedRegion_isSkipped() {
        let root = FakeAXNode(role: "AXGroup")
            .adding(.button("Offscreen", x: 500, y: 500))
            .adding(.button("Onscreen", x: 5, y: 5))
        let reader = FakeAXReader()

        XCTAssertEqual(walk(root, reader: reader).elements.map(\.label), ["Onscreen"])
    }

    // MARK: - Labels

    /// Title beats value, and that ORDER matters: a text field's `AXValue` is its live contents, so
    /// preferring it would label a search box by whatever the user has typed — a label that changes
    /// under the model between captures.
    ///
    /// RED: swap the first two terms of the `??` chain → the label becomes "typed so far".
    func testWalk_labelPrefersTitleOverLiveValue() {
        let field = FakeAXNode(
            role: "AXSearchField", title: "Search", value: "typed so far",
            frame: CGRect(x: 0, y: 0, width: 20, height: 10))
        let reader = FakeAXReader()

        XCTAssertEqual(walk(field, reader: reader).elements.first?.label, "Search")
    }

    func testWalk_labelFallsBackThroughValueThenDescription() {
        let reader = FakeAXReader()
        let valueOnly = FakeAXNode(
            role: "AXButton", value: "from value", frame: CGRect(x: 0, y: 0, width: 9, height: 9))
        XCTAssertEqual(walk(valueOnly, reader: reader).elements.first?.label, "from value")

        let descOnly = FakeAXNode(
            role: "AXButton", desc: "from desc", frame: CGRect(x: 0, y: 0, width: 9, height: 9))
        XCTAssertEqual(walk(descOnly, reader: FakeAXReader()).elements.first?.label, "from desc")
    }

    /// `maxLabelChars` × the emission cap is the worst-case payload of a capture, so the cap has to
    /// be APPLIED on the walk's own path, not merely declared.
    func testWalk_overlongLabel_isTruncatedOnTheWalkPath() {
        let long = String(repeating: "x", count: AccessibilityInspector.maxLabelChars + 40)
        let node = FakeAXNode(
            role: "AXButton", title: long, frame: CGRect(x: 0, y: 0, width: 9, height: 9))

        let label = walk(node, reader: FakeAXReader()).elements.first?.label
        XCTAssertEqual(label?.count, AccessibilityInspector.maxLabelChars + 1, "cap plus the ellipsis")
        XCTAssertTrue(label?.hasSuffix("…") == true)
    }

    // MARK: - Web-area propagation

    /// `web` marks page content as opposed to browser chrome, and it must propagate to the WHOLE
    /// subtree — the model prefers page targets over look-alike chrome controls, and the emission
    /// cap retains labeled web elements first.
    ///
    /// RED: pass `insideWebArea: false` to the recursion → the nested button loses its `web` flag
    /// and can be evicted by chrome under the cap.
    func testWalk_webAreaFlagPropagatesToTheWholeSubtree() {
        let root = FakeAXNode(role: "AXWindow")
            .adding(.button("Chrome", x: 0, y: 0))
            .adding(FakeAXNode(role: "AXWebArea")
                .adding(FakeAXNode(role: "AXGroup")
                    .adding(.button("Page", x: 20, y: 20))))
        let reader = FakeAXReader()

        let outcome = walk(root, reader: reader)

        XCTAssertTrue(outcome.sawWebArea)
        let byLabel = Dictionary(uniqueKeysWithValues: outcome.elements.map { ($0.label, $0.web) })
        XCTAssertEqual(byLabel["Chrome"], false)
        XCTAssertEqual(byLabel["Page"], true, "two levels below the web area")
    }

    /// `sawWebArea` drives the settle-and-retry decision, so it must be set even when the area is
    /// still empty — that is precisely the state the retry exists for.
    func testWalk_emptyWebArea_stillSetsSawWebArea() {
        let root = FakeAXNode(role: "AXWindow").adding(FakeAXNode(role: "AXWebArea"))

        let outcome = walk(root, reader: FakeAXReader())

        XCTAssertTrue(outcome.sawWebArea)
        XCTAssertTrue(outcome.elements.isEmpty)
        XCTAssertFalse(outcome.stoppedEarly, "an empty page is not a budget cut")
    }

    // MARK: - Budget cuts (no-silent-caps)

    /// RED: drop `outcome.hitDepthCap = true` from the depth guard → a page control nested deeper
    /// than the cap reads as "not on screen", with no warning attached to the capture.
    func testWalk_depthCap_dropsTheSubtreeAndSaysSo() {
        var deepest = FakeAXNode(role: "AXButton", title: "TooDeep",
                                 frame: CGRect(x: 1, y: 1, width: 5, height: 5))
        for _ in 0...AccessibilityWalkPolicy.maxDepth {
            deepest = FakeAXNode(role: "AXGroup").adding(deepest)
        }

        let outcome = walk(deepest, reader: FakeAXReader())

        XCTAssertTrue(outcome.hitDepthCap)
        XCTAssertTrue(outcome.stoppedEarly)
        XCTAssertTrue(outcome.elements.isEmpty, "the button sat past the cap")
    }

    func testWalk_exactlyAtTheDepthCap_isNotCut() {
        var node = FakeAXNode(role: "AXButton", title: "AtLimit",
                              frame: CGRect(x: 1, y: 1, width: 5, height: 5))
        for _ in 0..<AccessibilityWalkPolicy.maxDepth {
            node = FakeAXNode(role: "AXGroup").adding(node)
        }

        let outcome = walk(node, reader: FakeAXReader())

        XCTAssertFalse(outcome.hitDepthCap, "the guard is `depth <= maxDepth`, so the last level counts")
        XCTAssertEqual(outcome.elements.map(\.label), ["AtLimit"])
    }

    /// RED: drop `outcome.hitNodeCap = true` from either the entry guard or the child-loop break →
    /// a browser tree truncated at 3000 nodes is reported as a complete list.
    func testWalk_nodeCap_stopsAndSaysSo() {
        let root = FakeAXNode(role: "AXGroup")
        for i in 0...AccessibilityWalkPolicy.maxVisitedNodes {
            root.children.append(.button("b\(i)", x: 0, y: 0, w: 2, h: 2))
        }

        let outcome = walk(root, reader: FakeAXReader())

        XCTAssertTrue(outcome.hitNodeCap)
        XCTAssertTrue(outcome.stoppedEarly)
        XCTAssertEqual(outcome.visitedNodes, AccessibilityWalkPolicy.maxVisitedNodes)
    }

    /// The child loop breaks on the node cap rather than recursing into children that would each
    /// bail at their own entry guard — the flag has to be set at the BREAK, or the break makes the
    /// child's guard unreachable and the cut goes unreported.
    ///
    /// RED: remove `outcome.hitNodeCap = true` from the child-loop break → false, because the
    /// break stops the only code that would have set it.
    func testWalk_nodeCapReachedMidChildren_flagsAtTheBreak() {
        let cap = AccessibilityWalkPolicy.maxVisitedNodes
        // A root whose children exactly exhaust the budget, plus one more.
        let root = FakeAXNode(role: "AXGroup")
        for i in 0..<cap {
            root.children.append(FakeAXNode(role: "AXUnknown", title: "n\(i)"))
        }

        let outcome = walk(root, reader: FakeAXReader())

        XCTAssertEqual(outcome.visitedNodes, cap)
        XCTAssertTrue(outcome.hitNodeCap)
    }

    /// The deadline is checked BETWEEN nodes. A reader that burns wall clock inside `children(of:)`
    /// models a beachballing target app: the root is visited, the first child's entry guard trips
    /// the deadline, and the loop breaks before the rest.
    ///
    /// RED: drop `outcome.hitDeadline = true` from the deadline guard → a walk abandoned halfway
    /// through a slow app is reported as complete.
    func testWalk_deadlineExpiringMidWalk_stopsAndSaysSo() {
        let root = FakeAXNode(role: "AXGroup")
            .adding(.button("a", x: 0, y: 0))
            .adding(.button("b", x: 10, y: 10))
            .adding(.button("c", x: 20, y: 20))
        let reader = FakeAXReader()
        reader.onChildren = { _ in Thread.sleep(forTimeInterval: 0.05) }

        let outcome = walk(root, reader: reader, deadlineMilliseconds: 10)

        XCTAssertTrue(outcome.hitDeadline)
        XCTAssertTrue(outcome.stoppedEarly)
        XCTAssertEqual(outcome.visitedNodes, 1, "only the root got in before the clock ran out")
    }

    func testWalk_deadlineAlreadyExpired_stopsAtTheRoot() {
        let outcome = walk(FakeAXNode(role: "AXGroup").adding(.button("x", x: 0, y: 0)),
                           reader: FakeAXReader(), deadlineMilliseconds: 0)

        XCTAssertTrue(outcome.hitDeadline)
        XCTAssertEqual(outcome.visitedNodes, 0)
    }

    // MARK: - Cancellation

    /// A cancelled walk's result is DISCARDED, so it must not masquerade as a budget cut — that
    /// would attach a "your element list is truncated" warning to a capture that was simply paused.
    ///
    /// RED: set any `hit*` flag on the cancellation bail → `stoppedEarly` becomes true.
    func testWalk_cancelledBeforeStarting_bailsWithoutClaimingATruncation() {
        let flag = WalkCancellationFlag()
        flag.cancel()

        let outcome = walk(FakeAXNode(role: "AXGroup").adding(.button("x", x: 0, y: 0)),
                           reader: FakeAXReader(), cancelled: flag)

        XCTAssertTrue(outcome.elements.isEmpty)
        XCTAssertEqual(outcome.visitedNodes, 0)
        XCTAssertFalse(outcome.stoppedEarly, "cancellation is not a budget cut")
    }

    /// Pause landing mid-walk must stop it — `Task.detached` does not inherit the caller's
    /// cancellation, which is why the shared atomic flag exists at all.
    ///
    /// RED: drop the `cancelled.isCancelled` term from the child-loop break → the walk runs to
    /// completion and the caller waits past its bounded budget.
    func testWalk_cancelledMidChildren_stopsImmediately() {
        let root = FakeAXNode(role: "AXGroup")
        for i in 0..<20 { root.children.append(.button("b\(i)", x: 0, y: 0, w: 2, h: 2)) }
        let flag = WalkCancellationFlag()
        let reader = FakeAXReader()
        reader.onChildren = { node in if node === root { flag.cancel() } }

        let outcome = walk(root, reader: reader, cancelled: flag)

        XCTAssertTrue(outcome.elements.isEmpty, "cancelled before the first child was walked")
        XCTAssertFalse(outcome.stoppedEarly)
    }

    /// `Task.detached` does NOT inherit the caller's cancellation, which is the entire reason the
    /// shared atomic flag exists — a Pause landing mid-walk would otherwise block the caller for the
    /// full 1.2 s deadline against a busy browser, past the bounded-wait budget.
    ///
    /// The margin is deliberate and one-sided: ~300 nodes at 2 ms of simulated AX IPC each is ~600 ms
    /// of walk against a 30 ms cancel, so the cancel lands mid-walk by a factor of ~20. A machine
    /// slow enough to break that would cancel EARLIER, not later.
    ///
    /// RED: drop the `onCancel:` block from `withTaskCancellationHandler` → the flag is never
    /// flipped, the walk runs every node, and `childrenReads` reaches the full 301.
    func testCollectElements_cancellingTheCaller_stopsTheWalkEarly() async {
        let app = FakeAXNode(role: "AXApplication")
        for i in 0..<300 {
            app.children.append(
                FakeAXNode(role: "AXGroup").adding(.button("b\(i)", x: 0, y: 0, w: 2, h: 2)))
        }
        let reader = FakeAXReader(root: app)
        reader.onChildren = { _ in Thread.sleep(forTimeInterval: 0.002) }
        let req = request()

        let task = Task { await AccessibilityInspector.collectElements(req, reader: reader) }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let result = await task.value

        XCTAssertLessThan(
            reader.childrenReads, 301,
            "cancellation must reach the detached walk; it does not inherit it")
        XCTAssertLessThan(result.elements.count, 300)
    }

    func testWalkCancellationFlag_startsClearAndLatches() {
        let flag = WalkCancellationFlag()
        XCTAssertFalse(flag.isCancelled)
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
        flag.cancel()
        XCTAssertTrue(flag.isCancelled, "idempotent")
    }

    // MARK: - collectElements

    private func request(pid: pid_t = 42, matchWindow: Bool = false) -> AXCollectionRequest {
        AXCollectionRequest(
            pid: pid, regionOriginX: 0, regionOriginY: 0,
            regionWidthPt: 100, regionHeightPt: 100,
            pixelWidth: 100, pixelHeight: 100, matchWindowToRegion: matchWindow)
    }

    func testCollectElements_degenerateRequest_neverTouchesTheTree() async {
        let reader = FakeAXReader(root: FakeAXNode(role: "AXGroup").adding(.button("x", x: 0, y: 0)))
        let degenerate = AXCollectionRequest(
            pid: 1, regionOriginX: 0, regionOriginY: 0, regionWidthPt: 0, regionHeightPt: 100,
            pixelWidth: 100, pixelHeight: 100, matchWindowToRegion: false)

        let result = await AccessibilityInspector.collectElements(degenerate, reader: reader)

        XCTAssertEqual(result.elements.count, 0)
        XCTAssertTrue(reader.applicationNodeRequests.isEmpty, "the guard runs before any AX traffic")
    }

    /// The walk's deadline is only checked BETWEEN nodes, so a single hung
    /// `AXUIElementCopyAttributeValue` would block ~6 s at the framework default. The per-request
    /// timeout is what bounds it.
    ///
    /// RED: drop the `setMessagingTimeout` call → `messagingTimeouts` is empty.
    func testCollectElements_boundsEveryIPCRoundTrip() async {
        let reader = FakeAXReader(root: FakeAXNode(role: "AXGroup"))

        _ = await AccessibilityInspector.collectElements(request(), reader: reader)

        XCTAssertEqual(reader.messagingTimeouts, [AccessibilityWalkPolicy.axMessagingTimeoutSeconds])
        XCTAssertEqual(reader.applicationNodeRequests, [42])
    }

    /// Both attributes are announced — WebKit keys off `AXEnhancedUserInterface`, Chromium off
    /// `AXManualAccessibility`, and setting only one leaves the other family reporting a web area
    /// with no children (the chrome-only capture incident).
    ///
    /// RED: announce only the first attribute → Chromium/Electron page content stays invisible.
    func testCollectElements_announcesBothAssistiveAttributes() async {
        let reader = FakeAXReader(root: FakeAXNode(role: "AXGroup"))

        _ = await AccessibilityInspector.collectElements(request(), reader: reader)

        XCTAssertEqual(
            Set(reader.setTrueCalls.map(\.attribute)),
            ["AXEnhancedUserInterface", "AXManualAccessibility"])
    }

    /// Read-before-set: a second capture of the same app must skip the write, so the web tree stays
    /// populated and no settle+retry is re-paid.
    ///
    /// RED: drop the `boolValue(...) == true` short-circuit → the attribute is rewritten every
    /// capture, which is what tore the tree down under a concurrent capture.
    func testCollectElements_alreadyAnnounced_doesNotRewrite() async {
        let root = FakeAXNode(role: "AXGroup")
        root.flags["AXEnhancedUserInterface"] = true
        root.flags["AXManualAccessibility"] = true
        let reader = FakeAXReader(root: root)

        _ = await AccessibilityInspector.collectElements(request(), reader: reader)

        XCTAssertTrue(reader.setTrueCalls.isEmpty)
    }

    /// A window capture must root at the window the screenshot SHOWS. Rooting at the app instead is
    /// how elements of the app's other windows got advertised with valid-looking coordinates over
    /// pixels showing something else entirely.
    ///
    /// RED: drop the `matchWindowToRegion` branch → "Other" appears in the list.
    func testCollectElements_windowCapture_rootsAtTheMatchingWindow() async {
        let matching = FakeAXNode(role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            .adding(.button("InFrame", x: 5, y: 5))
        let other = FakeAXNode(role: "AXWindow", frame: CGRect(x: 400, y: 400, width: 100, height: 100))
            .adding(.button("Other", x: 10, y: 10))
        let app = FakeAXNode(role: "AXApplication")
        app.related[kAXWindowsAttribute as String] = [matching, other]
        app.children = [matching, other]

        let result = await AccessibilityInspector.collectElements(
            request(matchWindow: true), reader: FakeAXReader(root: app))

        XCTAssertEqual(result.elements.map(\.label), ["InFrame"])
    }

    /// No window mutually covers the region (a screen capture, or a window that moved) — fall back
    /// to the app root rather than returning nothing.
    func testCollectElements_windowCaptureWithNoMatch_fallsBackToTheAppRoot() async {
        let far = FakeAXNode(role: "AXWindow", frame: CGRect(x: 900, y: 900, width: 10, height: 10))
        let app = FakeAXNode(role: "AXApplication").adding(.button("AppLevel", x: 3, y: 3))
        app.related[kAXWindowsAttribute as String] = [far]

        let result = await AccessibilityInspector.collectElements(
            request(matchWindow: true), reader: FakeAXReader(root: app))

        XCTAssertEqual(result.elements.map(\.label), ["AppLevel"])
    }

    func testCollectElements_screenCapture_neverAsksForWindows() async {
        let app = FakeAXNode(role: "AXApplication").adding(.button("x", x: 1, y: 1))
        let reader = FakeAXReader(root: app)

        _ = await AccessibilityInspector.collectElements(request(matchWindow: false), reader: reader)

        XCTAssertFalse(reader.elementsReads.contains(kAXWindowsAttribute as String))
    }

    func testWindowMatchingRegion_appWithNoWindows_returnsNil() {
        let app = FakeAXNode(role: "AXApplication")
        let match: FakeAXNode? = AccessibilityInspector.windowMatchingRegion(
            appElement: app, reader: FakeAXReader(),
            region: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(match)
    }

    // MARK: - The settle-and-retry

    /// WebKit/Chromium build the web AX tree lazily AFTER we announce ourselves, so a web area that
    /// walked empty is retried once.
    ///
    /// RED: drop the retry → the page's own controls never reach the model, which is the incident.
    func testCollectElements_emptyWebArea_retriesOnce() async {
        let app = FakeAXNode(role: "AXApplication").adding(FakeAXNode(role: "AXWebArea"))
        let reader = FakeAXReader(root: app)
        var walks = 0
        reader.onChildren = { node in
            if node === app {
                walks += 1
                // Populate the page on the second walk, as a browser would.
                if walks == 2 {
                    app.children[0].children = [.button("Page", x: 10, y: 10)]
                }
            }
        }

        let result = await AccessibilityInspector.collectElements(request(), reader: reader)

        XCTAssertEqual(walks, 2, "exactly one retry")
        XCTAssertEqual(result.elements.map(\.label), ["Page"])
    }

    /// A retry that hits its deadline deep in a now-huge web subtree can return FEWER elements than
    /// the first attempt, and the model must not end up with neither the chrome nor the page.
    ///
    /// RED: replace the `second.elements.count >= first.elements.count` choice with an unconditional
    /// `outcome = second` → the chrome the first walk found is thrown away for nothing.
    func testCollectElements_retryYieldingFewer_keepsTheFirstAttempt() async {
        let webArea = FakeAXNode(role: "AXWebArea")
        let app = FakeAXNode(role: "AXApplication")
            .adding(.button("Chrome1", x: 0, y: 0))
            .adding(.button("Chrome2", x: 20, y: 0))
            .adding(webArea)
        let reader = FakeAXReader(root: app)
        var walks = 0
        reader.onChildren = { node in
            guard node === app else { return }
            walks += 1
            if walks == 2 { app.children = [webArea] }   // the retry finds less
        }

        let result = await AccessibilityInspector.collectElements(request(), reader: reader)

        XCTAssertEqual(walks, 2)
        XCTAssertEqual(result.elements.map(\.label), ["Chrome1", "Chrome2"])
    }

    /// No web area at all: no reason to pay the settle, and no reason to walk twice.
    ///
    /// RED: retry unconditionally → `walks == 2` and every native-app capture costs an extra walk
    /// plus the settle delay.
    func testCollectElements_noWebArea_doesNotRetry() async {
        let app = FakeAXNode(role: "AXApplication").adding(.button("Native", x: 1, y: 1))
        let reader = FakeAXReader(root: app)
        var walks = 0
        reader.onChildren = { node in if node === app { walks += 1 } }

        let result = await AccessibilityInspector.collectElements(request(), reader: reader)

        XCTAssertEqual(walks, 1)
        XCTAssertEqual(result.elements.map(\.label), ["Native"])
    }

    /// A web area that already yielded content is not retried either.
    func testCollectElements_populatedWebArea_doesNotRetry() async {
        let app = FakeAXNode(role: "AXApplication")
            .adding(FakeAXNode(role: "AXWebArea").adding(.button("Page", x: 5, y: 5)))
        let reader = FakeAXReader(root: app)
        var walks = 0
        reader.onChildren = { node in if node === app { walks += 1 } }

        _ = await AccessibilityInspector.collectElements(request(), reader: reader)

        XCTAssertEqual(walks, 1)
    }

    /// The walk feeds `finalize`, so a truncated walk must arrive at the capture envelope as a
    /// warning — end-to-end, not just as a flag on an internal struct.
    func testCollectElements_truncatedWalk_surfacesAWarning() async {
        let app = FakeAXNode(role: "AXApplication")
        for i in 0...AccessibilityWalkPolicy.maxVisitedNodes {
            app.children.append(FakeAXNode(role: "AXUnknown", title: "n\(i)"))
        }

        let result = await AccessibilityInspector.collectElements(
            request(), reader: FakeAXReader(root: app))

        XCTAssertFalse(result.warnings.isEmpty, "no budget cut may be silent")
    }

    // MARK: - Wiring

    /// The live reader is named at exactly one place. Without this, every test above would still
    /// pass if `collectElements(_:)` had been quietly pointed at an inert reader — which in
    /// production means "this app has no accessibility tree", i.e. the chrome-only incident,
    /// silently.
    func testProductionEntryPoint_usesTheLiveReader() {
        XCTAssertTrue(SystemAXNodeReader() is any AXNodeReading)
        let source = try? String(
            contentsOf: Self.repoRoot
                .appendingPathComponent("NanoTeams/Services/Platform/AccessibilityInspector.swift"),
            encoding: .utf8)
        let body = try? XCTUnwrap(source)
        XCTAssertEqual(
            body?.components(separatedBy: "SystemAXNodeReader()").count, 2,
            "exactly one construction site of the live reader in the inspector")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Platform
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // NanoTeamsTests
            .deletingLastPathComponent()   // repo root
    }
}
