import SwiftUI
import XCTest

@testable import NanoTeams

/// The measurement contract through real SwiftUI layout: a feed laid out again at a width it has
/// already been laid out at measures no text again.
///
/// `MessageTextLayoutCacheTests` pins what the cache does with a sequence of widths it is handed;
/// this pins it against the widths SwiftUI actually asks — probe widths included — through the
/// bubble's own layout chain (`HStack` of an avatar column and a `VStack`, the text
/// `fixedSize(horizontal: false, vertical: true)` inside `frame(maxWidth: .infinity)`) inside the
/// feed's non-lazy `ScrollView { VStack }`.
///
/// The window alternates between two widths a point apart: the controllable stand-in for the
/// alternation the 2026-09-15 trace of an idle run showed — 65–110 ms/s of main thread in
/// `MessageTextLayoutCache.measure → ensureLayout` with `-[NSTextContainer setSize:]` under it,
/// which only a width change calls, while no text changed. A cache that remembers one width
/// recomputes on every alternation; one that remembers `widthMemoCapacity` computes each width
/// once — unless a pass asks more distinct widths than that, which this test catches as well.
///
/// The first version drove passes by changing a sibling `Text` in an unwindowed host; its
/// anti-vacuum reported 0 text queries in 6 passes, so it asserted nothing.
///
/// On failure the message prints every width each cache measured at, which is the diagnosis.
@MainActor
final class MessageTextLayoutPassTests: XCTestCase {

    private struct Feed: View {
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(alignment: .top, spacing: 12) {
                            Color.clear.frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Role \(index)")
                                SelectableMessageText(content: String(
                                    repeating: "A bubble long enough to wrap across several lines. ",
                                    count: 6 + index))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }

    private var window: NSWindow!
    private var host: NSHostingView<Feed>!

    override func setUp() async throws {
        try await super.setUp()
        SelfSizingTextView.resetFallbackWidthForTesting()
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        host = nil
        SelfSizingTextView.resetFallbackWidthForTesting()
        try await super.tearDown()
    }

    private func textViews(in view: NSView) -> [SelfSizingTextView] {
        view.subviews.flatMap { subview -> [SelfSizingTextView] in
            ((subview as? SelfSizingTextView).map { [$0] } ?? []) + textViews(in: subview)
        }
    }

    private func layOut(width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 480))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    func testRelayoutAtWidthsAlreadyMeasured_measuresNoTextAgain() async throws {
        host = NSHostingView(rootView: Feed())
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        layOut(width: 640)

        let caches = textViews(in: host).compactMap(\.fallbackMeasureCache)
        XCTAssertEqual(caches.count, 3, "anti-vacuum: the three bubbles were not realized with their caches")

        // Visit both widths twice first, so every width a pass at either one asks is measured.
        for width in [641, 640, 641, 640] as [CGFloat] { layOut(width: width) }
        let settledComputes = caches.map(\.computeCount)
        let settledHits = caches.map(\.hitCount).reduce(0, +)

        for width in [641, 640, 641, 640, 641, 640] as [CGFloat] { layOut(width: width) }
        XCTAssertEqual(
            caches.map(\.computeCount), settledComputes,
            "A relayout at widths already measured re-measured text. Widths measured per bubble: "
                + "\(caches.map(\.computedWidthsForTesting))")
        XCTAssertGreaterThan(
            caches.map(\.hitCount).reduce(0, +), settledHits,
            "anti-vacuum: the width changes never reached the text's sizeThatFits, so this asserted nothing. "
                + "Widths measured per bubble: \(caches.map(\.computedWidthsForTesting))")
    }
}
