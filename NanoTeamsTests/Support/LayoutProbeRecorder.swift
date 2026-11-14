import AppKit
import SwiftUI
import XCTest

@testable import NanoTeams

/// Collects what `LayoutProbe` reports while a test lays out a real surface: the last frame, in
/// window coordinates, of every view marked `.layoutProbe(_:)`. Installed for the length of one
/// hosting and removed straight after — a recorder left installed would collect another suite's
/// layouts (`LayoutProbe.record` is process-wide).
@MainActor
final class LayoutProbeRecorder {

    private(set) var frames: [String: CGRect] = [:]

    /// Hosts `view` in an offscreen window `width` points wide, lays it out until every id in
    /// `awaiting` has reported (or 30 passes), and returns what was reported.
    func layOut<V: View>(
        _ view: V, windowWidth width: CGFloat, height: CGFloat = 900, awaiting: [String] = []
    ) async -> [String: CGRect] {
        frames = [:]
        // A geometry change is delivered after the layout that produced it, so an earlier
        // hosting's last reports can still be in flight: let them land with nobody listening.
        await Self.drain()
        LayoutProbe.record = { [weak self] id, frame in self?.frames[id] = frame }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for pass in 0..<30 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            if pass >= 3, awaiting.allSatisfy({ frames[$0] != nil }) { break }
        }
        LayoutProbe.record = nil
        window.contentView = nil
        window.close()
        await Self.drain()
        return frames
    }

    /// Lets pending geometry reports land while no recorder is installed.
    private static func drain() async {
        LayoutProbe.record = nil
        for _ in 0..<5 { await Task.yield() }
    }
}

/// A view's own size, laid out alone at its ideal size — what a probed view inside a surface is
/// compared against ("no taller than it is alone": a label that broke is about twice as tall).
@MainActor
func idealSize<V: View>(of view: V) async throws -> CGSize {
    let recorder = LayoutProbeRecorder()
    let frames = await recorder.layOut(
        view.fixedSize().layoutProbe("alone"), windowWidth: 2000, height: 400, awaiting: ["alone"])
    return try XCTUnwrap(frames["alone"], "the view was never laid out alone").size
}

/// The first text baseline of `view` laid out alone at its ideal size, measured from its top.
@MainActor
func firstBaselineOffset<V: View>(of view: V) async throws -> CGFloat {
    let box = BaselineBox()
    let recorder = LayoutProbeRecorder()
    // A baseline-aligned row asks the view for its first text baseline; the guard reports it.
    let probe = HStack(alignment: .firstTextBaseline, spacing: 0) {
        view.alignmentGuide(.firstTextBaseline) { dimensions in
            let baseline = dimensions[.firstTextBaseline]
            box.value = baseline
            return baseline
        }
        Text("x").font(.system(size: 1))
    }
    .fixedSize()
    _ = await recorder.layOut(probe, windowWidth: 2000, height: 400)
    return try XCTUnwrap(box.value, "the view reported no first text baseline")
}

/// Written from the alignment-guide closure SwiftUI calls during layout, read after it — both on
/// the main thread, in one test.
private final class BaselineBox: @unchecked Sendable {
    var value: CGFloat?
}
