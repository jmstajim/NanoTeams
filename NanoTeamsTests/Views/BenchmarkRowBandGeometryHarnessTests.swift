import AppKit
import SwiftUI
import XCTest

@testable import NanoTeams

/// Renders the REAL `BenchmarkRowBandLayer` behind a Grid shaped like `historyTable` and asserts
/// that the band it DRAWS occupies the same strip its hit-testing promises.
///
/// The defect this pins: sibling bands emitted into `.background(alignment:) { }` are grouped by
/// an implicit stack that sizes to the TALLEST band and centers its children against each other —
/// the `alignment:` parameter places only the composite. `.offset(y:)` then applies from a
/// centered origin, so with rows of unequal heights (one wrapped model name) every shorter band
/// drew (maxH − h)/2 pt below its own hit-test range: the highlight clipped its row's text and
/// leaked into the next row's territory while clicks resolved correctly. Equal-height rows show
/// zero shift, which is how it survived the first harness pass. The drawn position is measured
/// from PIXELS — a diff of two offscreen renders, hover off vs on — because no frame API sees
/// where a background child actually rendered.
@MainActor
final class BenchmarkRowBandGeometryHarnessTests: XCTestCase, @unchecked Sendable {

    static let ids = [UUID(), UUID(), UUID()]

    /// Written by the fixture's Grid via `onGeometryChange`; read by the test to map grid-space
    /// bands into fixture-root (= bitmap) coordinates.
    final class GridFrameBox {
        var frame: CGRect = .zero
    }

    struct Fixture: View {
        let interaction: BenchmarkRowInteractionState<UUID>
        let gridFrame: GridFrameBox
        nonisolated static let space = "harness-table"
        nonisolated static let rootSpace = "harness-root"

        // Row 0 wraps at narrow width (tall row); rows 1–2 stay short — the height inequality
        // the defect needs.
        private let models = [
            "qwythos-9b-claude-mythos-5-1m", "qwen3.8-4b", "ornith-1.0-35b",
        ]

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    table
                }
                .padding(Spacing.l)
            }
            .background(Colors.surfacePrimary)
            .coordinateSpace(.named(Self.rootSpace))
        }

        private var table: some View {
            let ids = BenchmarkRowBandGeometryHarnessTests.ids
            return Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
                GridRow {
                    Image(systemName: "chevron.right").font(Typography.caption2).hidden()
                    Text("Date").font(Typography.caption)
                    Text("Model").font(Typography.caption)
                    Text("Format").font(Typography.caption)
                    Text("Generation").font(Typography.caption)
                    Color.clear.frame(width: 1, height: 1)
                }
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    GridRow {
                        Image(systemName: "chevron.right").font(Typography.caption2)
                        Text("Aug 21 at 20:4\(index)").font(Typography.subheadlineMedium)
                        HStack(spacing: Spacing.xs) {
                            Text(models[index]).font(Typography.subheadlineMedium)
                        }
                        .frame(maxHeight: .infinity)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named(Self.space))
                        } action: {
                            interaction.reportFrame($0, for: id, orderedIDs: ids)
                        }
                        Text("GGUF").font(Typography.subheadlineMedium)
                        Text("44").font(Typography.subheadlineMedium)
                        Image(systemName: "trash").font(Typography.caption)
                    }
                }
            }
            .background(alignment: .topLeading) {
                BenchmarkRowBandLayer(ids: ids, interaction: interaction)
            }
            .coordinateSpace(.named(Self.space))
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.rootSpace))
            } action: {
                gridFrame.frame = $0
            }
        }
    }

    /// The production wiring inside the REAL `SettingsCard`, with the full-width stretch — the
    /// leaderboard/Runs shape as the app composes it. `gridFrame` measures the STRETCHED frame,
    /// which is what the band layer's `.background` is granted.
    struct CardFixture: View {
        let interaction: BenchmarkRowInteractionState<UUID>
        let gridFrame: GridFrameBox

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    SettingsCard(header: "Leaderboard", systemImage: "list.number") {
                        table
                    }
                }
                .padding(Spacing.l)
            }
            .background(Colors.surfacePrimary)
            .coordinateSpace(.named(Fixture.rootSpace))
        }

        private var table: some View {
            let ids = BenchmarkRowBandGeometryHarnessTests.ids
            return Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    GridRow {
                        Text("\(index + 1)").font(Typography.caption)
                        HStack(spacing: Spacing.xs) {
                            Text("model-\(index)").font(Typography.subheadlineMedium)
                        }
                        .frame(maxHeight: .infinity)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named(Fixture.space))
                        } action: {
                            interaction.reportFrame($0, for: id, orderedIDs: ids)
                        }
                        Text("MLX").font(Typography.subheadlineMedium)
                        Text("\(90 - index)").font(Typography.subheadlineMedium)
                        Image(systemName: "trash").font(Typography.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                BenchmarkRowBandLayer(
                    ids: ids, interaction: interaction, horizontalOutset: Spacing.standard)
            }
            .coordinateSpace(.named(Fixture.space))
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Fixture.rootSpace))
            } action: {
                gridFrame.frame = $0
            }
        }
    }

    var window: NSWindow!
    var host: NSHostingView<Fixture>!
    var cardHost: NSHostingView<CardFixture>!
    var interaction: BenchmarkRowInteractionState<UUID>!
    var gridFrame: GridFrameBox!

    override func tearDown() async throws {
        window?.close()
        window = nil
        host = nil
        cardHost = nil
        interaction = nil
        gridFrame = nil
    }

    /// The band must run the full stretched Grid frame PLUS the card's `contentPadding` outset on
    /// each side — a full-bleed row that stops only at the card's border, not at the padding.
    /// RED against a Grid whose `.frame(maxWidth: .infinity)` is removed, and against a band
    /// layer that ignores its `horizontalOutset`.
    func testBandSpansTheStretchedGridWidthInsideTheCard() async throws {
        interaction = BenchmarkRowInteractionState<UUID>()
        gridFrame = GridFrameBox()
        cardHost = NSHostingView(
            rootView: CardFixture(interaction: interaction, gridFrame: gridFrame))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = cardHost
        cardHost.layoutSubtreeIfNeeded()
        spinRunLoop()

        // Premise: the stretch really widened the Grid far past its hugged columns — the narrow
        // fixture columns guarantee a wide margin, so a hugged Grid cannot sneak past this.
        XCTAssertGreaterThan(
            gridFrame.frame.width, 400,
            "the Grid frame did not stretch — the fixture no longer mirrors the production stack")

        let before = try XCTUnwrap(cardHost.bitmapImageRepForCachingDisplay(in: cardHost.bounds))
        cardHost.cacheDisplay(in: cardHost.bounds, to: before)
        let short = try XCTUnwrap(interaction.frames[Self.ids[1]])
        interaction.pointerMoved(to: CGPoint(x: 60, y: short.midY), orderedIDs: Self.ids)
        spinRunLoop()
        let after = try XCTUnwrap(cardHost.bitmapImageRepForCachingDisplay(in: cardHost.bounds))
        cardHost.cacheDisplay(in: cardHost.bounds, to: after)

        let scale = CGFloat(before.pixelsHigh) / cardHost.bounds.height
        let extent = try XCTUnwrap(
            changedExtent(before, after), "hovering drew nothing — the band layer is inert")
        let drawnMinX = CGFloat(extent.cols.lowerBound) / scale
        let drawnMaxX = CGFloat(extent.cols.upperBound + 1) / scale

        let tolerance: CGFloat = 2
        let expectedMinX = gridFrame.frame.minX - Spacing.standard
        let expectedMaxX = gridFrame.frame.maxX + Spacing.standard
        if abs(drawnMinX - expectedMinX) > tolerance
            || abs(drawnMaxX - expectedMaxX) > tolerance {
            try? after.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/band_harness_card_after.png"))
            XCTFail(
                "drawn band x [\(drawnMinX), \(drawnMaxX)] ≠ full-bleed x "
                    + "[\(expectedMinX), \(expectedMaxX)] — the highlight stops short of the "
                    + "card's edges; render in /tmp/band_harness_card_after.png")
        }
    }

    private func spinRunLoop(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func bitmap() throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The extent (in bitmap pixels) of every pixel that differs between the two renders — with
    /// only the hover fill toggled between them, that IS the drawn band.
    private func changedExtent(
        _ a: NSBitmapImageRep, _ b: NSBitmapImageRep
    ) -> (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
        var minRow = Int.max, maxRow = Int.min
        var minCol = Int.max, maxCol = Int.min
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                if abs(ca.redComponent - cb.redComponent) > 0.01
                    || abs(ca.greenComponent - cb.greenComponent) > 0.01
                    || abs(ca.blueComponent - cb.blueComponent) > 0.01 {
                    minRow = min(minRow, y)
                    maxRow = max(maxRow, y)
                    minCol = min(minCol, x)
                    maxCol = max(maxCol, x)
                }
            }
        }
        guard minRow <= maxRow else { return nil }
        return (minRow...maxRow, minCol...maxCol)
    }

    private func changedRowRange(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> ClosedRange<Int>? {
        changedExtent(a, b)?.rows
    }

    func testDrawnBandMatchesItsHitTestRange() async throws {
        interaction = BenchmarkRowInteractionState<UUID>()
        gridFrame = GridFrameBox()
        host = NSHostingView(
            rootView: Fixture(interaction: interaction, gridFrame: gridFrame))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spinRunLoop()

        // Premise: the wrapped row really is taller than the hovered one, else the defect is
        // structurally invisible and this test is vacuous (CLAUDE.md #56 reading 3).
        let tall = try XCTUnwrap(interaction.frames[Self.ids[0]])
        let short = try XCTUnwrap(interaction.frames[Self.ids[1]])
        XCTAssertGreaterThan(
            tall.height, short.height + 8,
            "fixture no longer has unequal row heights — the shift this pins cannot manifest")

        let before = try bitmap()
        interaction.pointerMoved(
            to: CGPoint(x: 60, y: short.midY), orderedIDs: Self.ids)
        XCTAssertEqual(interaction.hoveredRowID, Self.ids[1], "hit-test missed its own frame")
        spinRunLoop()
        let after = try bitmap()

        let scale = CGFloat(before.pixelsHigh) / host.bounds.height
        let drawnRows = try XCTUnwrap(
            changedRowRange(before, after), "hovering drew nothing — the band layer is inert")
        let drawn = (CGFloat(drawnRows.lowerBound) / scale)...(CGFloat(drawnRows.upperBound + 1) / scale)

        let band = try XCTUnwrap(BenchmarkRowInteractionState<UUID>.rowBand(around: short))
        let expected = (gridFrame.frame.minY + band.lowerBound)...(gridFrame.frame.minY + band.upperBound)

        let tolerance: CGFloat = 2
        if abs(drawn.lowerBound - expected.lowerBound) > tolerance
            || abs(drawn.upperBound - expected.upperBound) > tolerance {
            // Postmortem artifacts only on failure.
            try? before.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/band_harness_before.png"))
            try? after.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/band_harness_after.png"))
            XCTFail(
                "drawn band \(drawn) ≠ hit-test band \(expected) (grid at \(gridFrame.frame)): "
                    + "the highlight promises a different strip than a click opens; "
                    + "renders in /tmp/band_harness_{before,after}.png")
        }
    }
}
