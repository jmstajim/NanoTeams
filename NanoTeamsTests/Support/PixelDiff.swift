import AppKit
import SwiftUI
import XCTest

/// Where a view DRAWS something, read from its pixels: two offscreen renders that differ in one
/// input, and the extent of every pixel that changed between them.
///
/// The one probe that sees what no frame API reports — a background a layer paints behind its
/// row (`BenchmarkRowBandGeometryHarnessTests`), an overlay that takes no layout space, such as
/// the `┤ STATUS ├` chip of a settings card (`MCPServersSettingsViewTests`), where a frame probe
/// sees the card's width unchanged whatever was drawn into the chip. One home: it was a private
/// helper of the band harness until a second suite needed it.
enum PixelDiff {

    /// One render: the bitmap, and how many of its pixels make one of the view's points.
    struct Render {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat
    }

    /// `view` hosted in an offscreen window `width` × `height` points — never ordered front — laid
    /// out until the view itself reports the layout it will be drawn at, and drawn into a bitmap
    /// whose rows run from the top, as the view's own coordinates do.
    ///
    /// The report is the root's geometry, delivered after the layout that produced it and in the
    /// same run-loop pass as every other geometry report in the hierarchy — a caller's frame probe
    /// included — so a render never draws, nor a probe reads, a layout the view has not reported.
    /// `settleCeiling` is a FAILURE, never a silent proceed: a view that does not report its layout
    /// by then is recorded as a failure and nothing is drawn. Until 2026-10-28 every render spun
    /// the run loop a fixed 0.2 s and drew whatever was there (15 renders, ~3 s, in the suites).
    @MainActor
    static func render<V: View>(
        _ view: V, width: CGFloat, height: CGFloat, appearance: NSAppearance.Name = .darkAqua,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Render? {
        let reported = LayoutReport()
        let host = NSHostingView(rootView: view.onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            reported.size = size
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let ceiling = Date().addingTimeInterval(settleCeiling)
        while reported.size == nil {
            guard Date() < ceiling else {
                XCTFail("the view never reported its layout within \(settleCeiling) s — nothing was drawn",
                        file: file, line: line)
                return nil
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            host.layoutSubtreeIfNeeded()
        }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return Render(bitmap: bitmap, scale: CGFloat(bitmap.pixelsHigh) / host.bounds.height)
    }

    /// How long a render waits for the view to report its layout before it fails.
    static let settleCeiling: TimeInterval = 0.2

    /// The root's laid-out size, once the view has reported one.
    @MainActor
    private final class LayoutReport {
        var size: CGSize?
    }

    /// The extent (in bitmap pixels, rows from the top) of every pixel whose colour differs by
    /// more than 0.01 in a channel between the two renders — with only one input changed between
    /// them, that IS where that input is drawn. `nil` when nothing differs. Alpha is not compared.
    ///
    /// Two renders in one format are compared byte by byte — 8 bits a sample, so "more than 0.01"
    /// is "at least 3 of 255", the same pixels `colorAt` would name — because `colorAt` builds an
    /// `NSColor` per pixel and a settings page at 2× is two million of them; any other pair goes
    /// through `colorAt`.
    static func changedExtent(
        _ a: NSBitmapImageRep, _ b: NSBitmapImageRep
    ) -> (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
        var minRow = Int.max, maxRow = Int.min
        var minCol = Int.max, maxCol = Int.min
        func mark(_ x: Int, _ y: Int) {
            minRow = min(minRow, y)
            maxRow = max(maxRow, y)
            minCol = min(minCol, x)
            maxCol = max(maxCol, x)
        }
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        if let bytesA = a.bitmapData, let bytesB = b.bitmapData, sameByteLayout(a, b) {
            let stride = a.bitsPerPixel / 8
            let alpha = a.hasAlpha ? (a.bitmapFormat.contains(.alphaFirst) ? 0 : a.samplesPerPixel - 1) : -1
            let rowBytes = width * stride
            for y in 0..<height {
                let rowA = bytesA + y * a.bytesPerRow
                let rowB = bytesB + y * b.bytesPerRow
                // A row whose bytes are identical holds no pixel that differs — whatever the
                // channel order — so it is skipped whole; only the rows that differ are walked.
                if memcmp(rowA, rowB, rowBytes) == 0 { continue }
                for x in 0..<width {
                    for channel in 0..<a.samplesPerPixel where channel != alpha {
                        let offset = x * stride + channel
                        if abs(Int(rowA[offset]) - Int(rowB[offset])) > 2 {
                            mark(x, y)
                            break
                        }
                    }
                }
            }
        } else {
            for y in 0..<height {
                for x in 0..<width {
                    guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                    if abs(ca.redComponent - cb.redComponent) > 0.01
                        || abs(ca.greenComponent - cb.greenComponent) > 0.01
                        || abs(ca.blueComponent - cb.blueComponent) > 0.01 {
                        mark(x, y)
                    }
                }
            }
        }
        guard minRow <= maxRow else { return nil }
        return (minRow...maxRow, minCol...maxCol)
    }

    /// Two renders whose bytes mean the same thing at the same offsets: 8-bit samples, one plane,
    /// the same samples, alpha placement and row length.
    private static func sameByteLayout(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        a.bitsPerSample == 8 && b.bitsPerSample == 8 && !a.isPlanar && !b.isPlanar
            && a.samplesPerPixel == b.samplesPerPixel && a.bitsPerPixel == b.bitsPerPixel
            && a.bytesPerRow == b.bytesPerRow && a.hasAlpha == b.hasAlpha
            && a.bitmapFormat == b.bitmapFormat && a.bitsPerPixel == a.samplesPerPixel * 8
            && a.colorSpace == b.colorSpace
    }

    /// The rows two renders differ in, in the view's points.
    static func changedPoints(_ a: Render, _ b: Render) -> ClosedRange<CGFloat>? {
        guard let extent = changedExtent(a.bitmap, b.bitmap) else { return nil }
        return CGFloat(extent.rows.lowerBound) / a.scale...CGFloat(extent.rows.upperBound + 1) / a.scale
    }
}
