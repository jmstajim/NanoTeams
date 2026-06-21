import AppKit
import XCTest
@testable import NanoTeams

@MainActor
final class ScrollBounceDisablerTests: XCTestCase {

    /// Happy path: a probe inside a scroll view's document subtree pins both
    /// axes' elasticity to `.none`.
    func testDisableBounce_insideScrollView_pinsBothAxesToNone() async {
        let scrollView = NSScrollView()
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .allowed
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 1000))
        scrollView.documentView = document

        let probe = ScrollBounceProbeView()
        document.addSubview(probe)
        probe.disableBounce()

        XCTAssertEqual(scrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
    }

    /// No enclosing scroll view (probe detached) → no-op, no crash.
    func testDisableBounce_noEnclosingScrollView_isNoOp() async {
        let probe = ScrollBounceProbeView()
        probe.disableBounce()  // must not crash
        XCTAssertNil(probe.enclosingScrollView)
    }

    /// The probe must be transparent to hit-testing so a full-size background
    /// view never swallows clicks / scroll-wheel events meant for the feed.
    func testProbe_isTransparentToHitTesting() async {
        let probe = ScrollBounceProbeView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertNil(probe.hitTest(NSPoint(x: 100, y: 100)))
    }

    /// THE FINDING-#4 CASE: under SwiftUI hosting a `.background(...)` lands as a
    /// DESCENDANT of the document view but NOT a direct child — it sits inside one
    /// or more hosting views. The probe must still resolve the scroll view by
    /// walking up multiple superviews. (The happy-path test above only covers a
    /// direct child of the document view.)
    func testDisableBounce_nestedDeepInDocumentView_stillResolves() async {
        let scrollView = NSScrollView()
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .allowed
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 1000))
        scrollView.documentView = document

        // document → hostA → hostB → probe (mimics SwiftUI's nested hosting views).
        let hostA = NSView()
        let hostB = NSView()
        document.addSubview(hostA)
        hostA.addSubview(hostB)
        let probe = ScrollBounceProbeView()
        hostB.addSubview(probe)

        probe.disableBounce()

        XCTAssertEqual(scrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
    }

    /// `disableBounce` is re-invoked on every `updateNSView` AND by the deferred
    /// next-runloop retry — re-calling must be idempotent (stays `.none`, no crash).
    func testDisableBounce_calledRepeatedly_isIdempotent() async {
        let scrollView = NSScrollView()
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 1000))
        scrollView.documentView = document
        let probe = ScrollBounceProbeView()
        document.addSubview(probe)

        probe.disableBounce()
        probe.disableBounce()
        probe.disableBounce()

        XCTAssertEqual(scrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
    }
}
