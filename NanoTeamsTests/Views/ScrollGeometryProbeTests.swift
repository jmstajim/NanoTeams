import AppKit
import SwiftUI
import XCTest

@testable import NanoTeams

/// What does `ScrollGeometry` actually report under a `.safeAreaInset`?
///
/// Any consumer of `ScrollGeometry` on an inset surface has to know whether `containerSize`
/// includes the inset region or not — the sign of the whole answer turns on it. The activity feed
/// depends on it directly: `TeamActivityFeedViewModel.bottomTargetY` is
/// `contentHeight + bottomInset - containerHeight`, and `distanceFromBottom` subtracts
/// `contentInsets.top`, both under the ~79pt `TeamBoardTopBar` safe-area inset. Reasoning about it
/// from memory is what CLAUDE.md #82 forbids; this measures it.
///
/// Kept in the tree as a pin: it is the only thing that can catch those formulas drifting away
/// from what the platform reports.
@MainActor
final class ScrollGeometryProbeTests: XCTestCase, @unchecked Sendable {

    /// Every field `ScrollGeometry` carries, flattened to the vertical axis.
    nonisolated struct Sample: Equatable {
        var contentHeight: CGFloat
        var containerHeight: CGFloat
        var insetTop: CGFloat
        var insetBottom: CGFloat
        var visibleHeight: CGFloat
        var boundsHeight: CGFloat
        var offsetY: CGFloat

        var line: String {
            "content=\(contentHeight) container=\(containerHeight) insetTop=\(insetTop) "
                + "insetBottom=\(insetBottom) visible=\(visibleHeight) bounds=\(boundsHeight) "
                + "offsetY=\(offsetY)"
        }
    }

    final class Box {
        var last: Sample?
    }

    struct Fixture: View {
        let contentHeight: CGFloat
        /// `nil` = no `safeAreaInset` at all. A zero-height inset is NOT the same thing, and the
        /// control has to be the genuine absence.
        let headerHeight: CGFloat?
        let box: Box

        private var scroller: some View {
            ScrollView {
                Color.clear.frame(height: contentHeight)
            }
            .onScrollGeometryChange(for: Sample.self) { geo in
                Sample(
                    contentHeight: geo.contentSize.height,
                    containerHeight: geo.containerSize.height,
                    insetTop: geo.contentInsets.top,
                    insetBottom: geo.contentInsets.bottom,
                    visibleHeight: geo.visibleRect.height,
                    boundsHeight: geo.bounds.height,
                    offsetY: geo.contentOffset.y)
            } action: { _, new in
                box.last = new
            }
        }

        @ViewBuilder
        var body: some View {
            if let headerHeight {
                scroller.safeAreaInset(edge: .top) {
                    Color.gray.frame(height: headerHeight)
                }
            } else {
                scroller
            }
        }
    }

    static let frameHeight: CGFloat = 400
    static let dumpPath = "/tmp/nanoteams_scrollgeometry_probe.txt"

    var window: NSWindow!
    var host: NSHostingView<Fixture>!
    var box: Box!

    override func tearDown() async throws {
        window?.close()
        window = nil
        host = nil
        box = nil
    }

    private func sample(content: CGFloat, header: CGFloat?) throws -> Sample {
        box = Box()
        host = NSHostingView(
            rootView: Fixture(contentHeight: content, headerHeight: header, box: box))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: Self.frameHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let geometry = try XCTUnwrap(
            box.last,
            "onScrollGeometryChange never fired offscreen — the probe cannot see its subject")
        return geometry
    }

    /// Records every fixture to a file. The test host's stdout does not reach `xcodebuild`
    /// (already recorded for the headless runner), so a file is the only way a measurement
    /// survives the run.
    private func dump(_ rows: [(String, Sample)]) {
        let text = rows
            .map { "\($0.0)\n    \($0.1.line)" }
            .joined(separator: "\n")
        try? text.write(toFile: Self.dumpPath, atomically: true, encoding: .utf8)
    }

    /// One test, not five: the fixtures have to be compared against EACH OTHER, and the control
    /// is only a control if it ran in the same process and the same window shape.
    func testWhatTheScrollViewReportsWithAndWithoutASafeAreaInset() throws {
        let header: CGFloat = 150
        let frame = Self.frameHeight

        let plainShort = try sample(content: 200, header: nil)
        let plainLong = try sample(content: 800, header: nil)
        let insetShort = try sample(content: 200, header: header)
        let insetExact = try sample(content: frame - header, header: header)
        let insetLong = try sample(content: 800, header: header)

        dump([
            ("A no inset, content 200, frame 400", plainShort),
            ("B no inset, content 800, frame 400", plainLong),
            ("C inset 150, content 200, frame 400", insetShort),
            ("D inset 150, content 250, frame 400", insetExact),
            ("E inset 150, content 800, frame 400", insetLong),
        ])

        // Anti-vacuum (#57): if the inset fixtures reported the same insets as the control, the
        // probe would not be measuring a safe-area inset at all and every number below is noise.
        // `>=` rather than `==` because a borderless window contributes its own few points on top
        // of the header — measured 158 for a 150pt header, and the surplus is not the subject.
        XCTAssertEqual(plainShort.insetTop, 0, "control: no inset means no content inset")
        XCTAssertGreaterThanOrEqual(
            insetShort.insetTop, header,
            "the safe-area inset did not reach contentInsets — the fixture does not reproduce "
                + "the sidebar's shape, so nothing measured here transfers. Dump: \(Self.dumpPath)")

        // THE finding. `containerSize` is the visible area: the content insets are SUBTRACTED
        // from it, not included in it. Measured 2026-08-23: a 400pt frame with a 158pt inset
        // reports containerSize 242.
        XCTAssertEqual(
            insetShort.containerHeight, frame - insetShort.insetTop, accuracy: 0.5,
            "containerSize is expected to EXCLUDE the content insets. If this flips, "
                + "`TeamActivityFeedViewModel.bottomTargetY` must flip with it — it subtracts "
                + "containerSize from the content height, and would silently aim short by the "
                + "height of the inset. Dump: \(Self.dumpPath)")
        XCTAssertEqual(
            plainShort.containerHeight, frame, accuracy: 0.5,
            "control: with no insets, containerSize is the whole frame")

        // Which makes `contentSize + contentInsets > containerSize` a FALSE overflow test: it
        // declares a 200pt list inside a 242pt visible area to be scrollable by the height of the
        // header. Any consumer that adds the insets back onto the content side double-counts them.
        XCTAssertGreaterThan(
            insetShort.contentHeight + insetShort.insetTop, insetShort.containerHeight,
            "premise of the defect: the OLD formula calls this fixture scrollable")
        XCTAssertLessThan(
            insetShort.contentHeight, insetShort.containerHeight,
            "…while the content plainly fits the visible area. The two disagree, and the second "
                + "one is the truth.")

        // The rest position, which is what makes `contentOffset.y + insets.top` the right
        // normalisation: at rest the offset is exactly minus the top inset, so normalised zero.
        XCTAssertEqual(
            insetLong.offsetY + insetLong.insetTop, 0, accuracy: 0.5,
            "a scroll view at rest under a top inset sits at -insetTop")

    }
}
