import AppKit
import CoreText
import XCTest

@testable import NanoTeams

/// Pins the measured facts behind `MonoCell`, and the source shape that applies
/// them.
///
/// The bug: `NTMSLoader`'s font footprint had no frame, so whatever glyph it
/// drew sized the row. 16 of the 35 entries in its glitch pool are not covered
/// by SF Mono and CoreText silently substitutes a fallback face with different
/// metrics, so a caption row carrying a spinner grew and shrank several times a
/// minute — and with it the message bubble containing it. `TerminalGlyph`'s
/// status set has the same exposure on three of its glyphs.
///
/// These tests measure the real font rather than restating the numbers, so the
/// day macOS changes its fallback chain they report it instead of going quietly
/// stale.
///
/// The four tests that read `NTMSLoader`'s pools are `@MainActor` because those statics
/// are — and `async` with it: a SYNC main-actor test method enters through a
/// protocol-witness path that does not re-establish isolation, which is the shape that
/// has aborted this process on CI before. The class itself stays nonisolated so the
/// remaining tests, which touch no main-actor state, never acquire that shape.
final class MonoCellReferenceGlyphTests: XCTestCase {

    /// The sizes `Typography` actually uses for cells: `term2xs` 10, `termXs`
    /// 11, `termSm` 12 (the `StatusGlyph` default).
    private static let cellSizes: [CGFloat] = [10, 11, 12]

    private func monoFont(_ size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// True when every character of `s` has a glyph in `font` itself — i.e. no
    /// fallback face is consulted.
    private func isCovered(_ s: String, by font: NSFont) -> Bool {
        var chars = Array(s.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs, chars.count)
    }

    /// `(lineHeight, advance)` as laid out — this is what actually drives a row.
    private func metrics(_ s: String, _ size: CGFloat) -> (height: CGFloat, advance: CGFloat) {
        let attributed = NSAttributedString(string: s, attributes: [.font: monoFont(size)])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (ascent + descent + leading, advance)
    }

    // MARK: - The reference glyph

    /// RED: change `TerminalGlyph.cellReference` to a glyph outside SF Mono such
    /// as `"⁊"` → this fails, and every `MonoCell` in the app is then sized by
    /// Monaco's 14.668pt line height instead of SF Mono's 12.955pt, so the cell
    /// meant to hold the grid is the thing breaking it.
    func testCellReference_isCoveredByTheMonoFace() {
        for size in Self.cellSizes {
            XCTAssertTrue(
                isCovered(TerminalGlyph.cellReference, by: monoFont(size)),
                "MonoCell's reference glyph must resolve inside SF Mono at \(size)pt — it is the yardstick every cell is measured with."
            )
        }
    }

    /// RED: set `TerminalGlyph.cellReference` to `"M"` → this fails; the cell
    /// and the spinner it wraps stop agreeing on their source glyph, so a future
    /// font whose `M` and `│` differ in advance would silently off-centre every
    /// spinner in its own cell.
    @MainActor
    func testCellReference_isTheLoadersFirstRotationFrame() async {
        XCTAssertEqual(
            TerminalGlyph.cellReference,
            NTMSLoader.rotationFrames.first,
            "The cell reference and the loader's resting frame must be the same character."
        )
    }

    /// RED: add a glyph outside SF Mono (e.g. `"≀"`) to `NTMSLoader.rotationFrames`
    /// → this fails, and the steady non-glitch spinner starts resizing its own
    /// row 12.5 times a second, which the cell cannot absorb because the cell is
    /// sized from a rotation frame.
    @MainActor
    func testEveryRotationFrame_isCoveredByTheMonoFace() async {
        for size in Self.cellSizes {
            for frame in NTMSLoader.rotationFrames {
                XCTAssertTrue(
                    isCovered(frame, by: monoFont(size)),
                    "Rotation frame \(frame) must resolve inside SF Mono at \(size)pt."
                )
            }
        }
    }

    // MARK: - Why the cell exists (the hazard, measured)

    /// RED: prune every non-mono glyph from `NTMSLoader.glitchGlyphs` → this
    /// fails, which is the intended signal: the pool would then be metric-safe
    /// on its own and the reader should be told the cell's stated justification
    /// no longer matches the data, rather than left with a stale comment.
    @MainActor
    func testGlitchPool_stillContainsGlyphsThatEscapeTheMonoFace() async {
        let mono = monoFont(11)
        let escapers = NTMSLoader.glitchGlyphs.filter { !isCovered($0, by: mono) }
        XCTAssertFalse(
            escapers.isEmpty,
            "MonoCell's doc comment justifies itself with the glitch pool's fallback glyphs. If none are left, update that comment."
        )
    }

    /// The specific measurement the fix was designed around: some glitch frames
    /// are TALLER than the row, which is the only direction that can grow it
    /// (row height is `max(cell, caption)`).
    ///
    /// RED: remove `≀` and `⁊` from `NTMSLoader.glitchGlyphs` → this fails,
    /// because those two are the only pool members that exceed the reference
    /// line height and therefore the only ones that could ever grow the row.
    @MainActor
    func testSomeGlitchGlyphs_areTallerThanTheReferenceCell() async {
        let reference = metrics(TerminalGlyph.cellReference, 11).height
        let taller = NTMSLoader.glitchGlyphs.filter { metrics($0, 11).height > reference + 0.001 }
        XCTAssertFalse(
            taller.isEmpty,
            "At 11pt at least one glitch glyph must exceed the reference line height of \(reference) — that overflow is what used to grow the row."
        )
    }

    /// RED: replace `TerminalGlyph.paused`, `.review` and `.revision` with
    /// mono-covered characters → this fails, which is the signal that
    /// `StatusGlyph`'s static branch no longer needs its cell and the reasoning
    /// in that view's doc comment has gone stale.
    func testSomeTerminalStatusGlyphs_escapeTheMonoFace() {
        let mono = monoFont(11)
        let statusSet = [
            TerminalGlyph.idle, TerminalGlyph.working, TerminalGlyph.done,
            TerminalGlyph.review, TerminalGlyph.revision, TerminalGlyph.failed,
            TerminalGlyph.skipped, TerminalGlyph.paused, TerminalGlyph.prompt,
        ]
        let escapers = statusSet.filter { !isCovered($0, by: mono) }
        XCTAssertFalse(
            escapers.isEmpty,
            "StatusGlyph routes its static branch through MonoCell because part of this vocabulary falls back. If nothing falls back any more, revisit that."
        )
    }

    // MARK: - The progress bar's two layers

    /// The two fonts `TerminalProgressBar` is actually drawn with: `Typography.termXs` (11pt
    /// regular — the composer's role chip) and `Typography.termMd` (14pt medium — the settings
    /// card). Both, because a metric fact that holds at one size and not the other is not a
    /// fact about the font.
    private static let barFonts: [(size: CGFloat, weight: NSFont.Weight)] = [
        (11, .regular), (14, .medium),
    ]

    private func barFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// `(advance, ink)` for a single glyph, in points at the given size.
    private func glyphMetrics(_ s: String, _ font: NSFont) -> (advance: CGFloat, ink: CGRect) {
        var chars = Array(s.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs, chars.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyphs, &advances, glyphs.count)
        var rects = [CGRect](repeating: .zero, count: glyphs.count)
        CTFontGetBoundingRectsForGlyphs(font as CTFont, .default, &glyphs, &rects, glyphs.count)
        return (advances[0].width, rects[0])
    }

    /// RED: add a glyph outside SF Mono to the partial table → this fails, and the bar's fill
    /// layer starts drawing at a fallback face's advance while the track underneath keeps SF
    /// Mono's, so the two layers walk apart along the bar.
    ///
    /// The whole table, not a sample: every entry is reachable — an eighth is 1/8 of a cell and
    /// the fill lands on each of them in ordinary use.
    @MainActor
    func testEveryProgressBarGlyph_isCoveredByTheMonoFace() async {
        for (size, weight) in Self.barFonts {
            let font = barFont(size, weight)
            for glyph in TerminalProgressBar.partials + [TerminalProgressBar.block]
                where !glyph.isEmpty {
                XCTAssertTrue(
                    isCovered(glyph, by: font),
                    "\(glyph) must resolve inside SF Mono at \(size)pt \(weight) — the progress bar draws its two layers on one grid and a fallback face breaks the grid."
                )
            }
        }
    }

    /// Why the bar carries a `.offset` at all: the block glyph's INK is not centred in the LINE
    /// BOX that lays it out, so a parent centring the bar centres the box and the paint lands
    /// low. `█` runs from below the baseline to above the cap height, and the line box adds a
    /// descender's worth of empty space above it that has no counterpart below.
    ///
    /// RED: change `TerminalProgressBar.blockInkCentringRatio` → this fails naming the size it
    /// no longer describes. RED: drop the `.offset` from the bar → this still passes, and the
    /// bar sits 1.15pt low inside every composer chip; the constant is what the pin protects,
    /// the `#Preview` is where the correction itself is seen.
    @MainActor
    func testTheBlockGlyphsInkSitsLowInItsLineBox_byTheRatioTheBarCorrectsFor() async {
        for (size, weight) in Self.barFonts {
            let nsFont = barFont(size, weight)
            let font = nsFont as CTFont
            let ascent = CTFontGetAscent(font)
            let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
            // Both measured downwards from the top of the line, so they are comparable.
            let inkCentre = ascent - glyphMetrics(TerminalProgressBar.block, nsFont).ink.midY
            XCTAssertEqual(
                (inkCentre - lineHeight / 2) / lineHeight,
                TerminalProgressBar.blockInkCentringRatio, accuracy: 0.0005,
                "at \(size)pt \(weight) the ink sits somewhere else in its line")
        }
    }

    /// The claim that lets ONE constant serve every size: the offset is a fraction of the line
    /// height, not a fixed number of points. Measured 1.1494pt at 11pt and 1.4629pt at 14pt —
    /// different distances, the same fraction.
    ///
    /// RED: express the correction in points instead → it is right at one size and wrong at the
    /// other, and the settings card and the chip cannot both be centred.
    @MainActor
    func testTheInkCentringRatio_isTheSameAtEverySizeTheBarUses() async {
        var ratios: [CGFloat] = []
        for (size, weight) in Self.barFonts {
            let nsFont = barFont(size, weight)
            let font = nsFont as CTFont
            let ascent = CTFontGetAscent(font)
            let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
            let inkCentre = ascent - glyphMetrics(TerminalProgressBar.block, nsFont).ink.midY
            ratios.append((inkCentre - lineHeight / 2) / lineHeight)
        }
        XCTAssertEqual(ratios.count, 2)
        XCTAssertEqual(
            ratios[0], ratios[1], accuracy: 0.0002,
            "the ink's seat in its line is no longer scale-invariant — the bar needs a per-size "
                + "correction, not a ratio")
        XCTAssertGreaterThan(ratios[0], 0, "the ink sits BELOW the box centre, or the sign of "
            + "the bar's offset is now backwards")
    }

    /// The layering contract, measured: every glyph the fill can draw shares the track glyph's
    /// advance, starts flush at the cell's left edge, and has exactly `█`'s ink height.
    ///
    /// RED: put `"▒"` in place of any entry of `TerminalProgressBar.partials` → the ink-height
    /// assertions fail. That vertical half is what disqualified `▒` as a track glyph, and it is
    /// the half that had gone unmeasured until 2026-09-08.
    @MainActor
    func testEveryProgressBarGlyph_sharesTheBlocksCellAndInkHeight() async {
        for (size, weight) in Self.barFonts {
            let font = barFont(size, weight)
            let reference = glyphMetrics(TerminalProgressBar.block, font)
            for glyph in TerminalProgressBar.partials where !glyph.isEmpty {
                let m = glyphMetrics(glyph, font)
                XCTAssertEqual(
                    m.advance, reference.advance, accuracy: 0.0001,
                    "\(glyph) at \(size)pt does not share the cell width")
                XCTAssertEqual(
                    m.ink.minX, 0, accuracy: 0.0001,
                    "\(glyph) at \(size)pt has a left side bearing — the fill would start inset from the cell it is filling")
                XCTAssertEqual(
                    m.ink.maxY, reference.ink.maxY, accuracy: 0.0001,
                    "\(glyph) at \(size)pt is not as tall as the block it is drawn over")
                XCTAssertEqual(
                    m.ink.minY, reference.ink.minY, accuracy: 0.0001,
                    "\(glyph) at \(size)pt does not sit on the block's baseline edge")
            }
        }
    }

    /// Why the track is `█` and not a shade character — stated as the measurement that decides
    /// it, so a future "the track should look lighter" change fails here rather than shipping a
    /// bar whose fill stands proud of its own groove.
    ///
    /// `░` additionally carries a left side bearing (0.569pt at 11pt), which is the second
    /// source of the gap this bar used to show. `▒` fixes that one and still fails the vertical
    /// test — which is the point: only the same glyph matches on both axes.
    ///
    /// RED: swap `TerminalProgressBar.block` for `"▒"` → the assertions below stop describing
    /// the code, and the bar regains a hairline of unpainted background along its top edge.
    @MainActor
    func testShadeGlyphs_doNotMatchTheBlockAndSoCannotBeTheTrack() async {
        for (size, weight) in Self.barFonts {
            let font = barFont(size, weight)
            let reference = glyphMetrics(TerminalProgressBar.block, font)
            for shade in ["░", "▒"] {
                let m = glyphMetrics(shade, font)
                XCTAssertNotEqual(
                    m.ink.maxY, reference.ink.maxY, accuracy: 0.0001,
                    "\(shade) at \(size)pt now matches the block's ink height. If the font changed, the track may finally be drawn with a shade — reread TerminalProgressBar's doc comment before doing it."
                )
            }
            XCTAssertGreaterThan(
                glyphMetrics("░", font).ink.minX, 0.1,
                "░'s left side bearing at \(size)pt was the other half of the old gap.")
        }
        XCTAssertEqual(
            TerminalProgressBar.block, "█",
            "The track is drawn with the fill's own glyph — the only one that matches it on both axes.")
    }

    /// The hazard the layering exists to absorb, as an exact relationship: a partial glyph is
    /// left-aligned and paints only `i/8` of its cell, so `(8 - i)/8` of that cell is bare.
    /// Subtracting the whole cell from the track — the pre-2026-09-08 arithmetic — left that
    /// remainder painted with nothing: up to 5.951pt at 11pt, in a bar 27pt wide.
    ///
    /// RED: `TerminalProgressBar.blocks` returning a track shorter than `cells` → the bar shows
    /// it, and `TerminalProgressBarTests` fails alongside this.
    @MainActor
    func testAPartialGlyph_leavesMostOfItsCellUnpainted() async {
        for (size, weight) in Self.barFonts {
            let font = barFont(size, weight)
            for (index, glyph) in TerminalProgressBar.partials.enumerated() where !glyph.isEmpty {
                let m = glyphMetrics(glyph, font)
                let unpainted = m.advance - m.ink.maxX
                XCTAssertEqual(
                    unpainted, m.advance * Double(8 - index) / 8, accuracy: 0.01,
                    "\(glyph) (\(index)/8) at \(size)pt paints an unexpected share of its cell")
            }
        }
    }

    // MARK: - Source shape

    private func source(_ relativePath: String) throws -> String {
        // NanoTeamsTests/Views/<this file> → repo root → production file.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Views/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // repo root
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The cell's whole mechanism is one modifier, and dropping it produces a
    /// subtle wrong rendering rather than a crash: `.overlay` proposes the
    /// BASE's size to its content, and a `Text` wider than the proposal
    /// truncates to `…` instead of overflowing. The wide fallback glyphs — the
    /// ones the cell exists to contain — would render as an ellipsis.
    ///
    /// RED: delete `.fixedSize()` from `MonoCell.body` → this fails, and every
    /// PingFang-width glitch frame draws `…` where the spinner should be.
    func testMonoCell_fixesTheOverlayContentSize() throws {
        let text = try source("NanoTeams/Views/DesignSystem/MonoCell.swift")
        XCTAssertTrue(
            text.contains("content.fixedSize()"),
            "MonoCell must overlay its content at ideal size, or glyphs wider than the cell truncate to an ellipsis."
        )
    }

    /// RED: revert `glyph(_:glitching:)`'s `.font` arm to returning the bare
    /// `stack` → this fails, and the 16 metric-changing glitch glyphs resume
    /// reflowing every caption row that carries a spinner.
    func testLoaderFontFootprint_goesThroughTheCell() throws {
        let text = try source("NanoTeams/Views/DesignSystem/NTMSLoader.swift")
        XCTAssertTrue(
            text.contains("MonoCell(font: font) { stack }"),
            "NTMSLoader's font footprint must draw into a MonoCell so the drawn glyph cannot size the row."
        )
    }

    /// Clipping is the tempting "tidy" follow-up to a fixed cell and it would
    /// silently delete the effect: the RGB-split copies are drawn at ±1px and
    /// live outside the cell by construction.
    ///
    /// RED: add `.clipped()` to the loader's glyph stack → this fails, and the
    /// chromatic-aberration copies the file's own comment calls non-negotiable
    /// get shaved off.
    func testLoader_doesNotClipItsGlyph() throws {
        let text = try source("NanoTeams/Views/DesignSystem/NTMSLoader.swift")
        XCTAssertFalse(
            text.contains(".clipped(" + ")"),
            "NTMSLoader must not clip: the ±1px RGB-split copies are drawn outside the cell on purpose."
        )
    }
}
