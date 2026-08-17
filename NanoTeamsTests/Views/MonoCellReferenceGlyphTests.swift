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
    func testCellReference_isTheLoadersFirstRotationFrame() {
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
    func testEveryRotationFrame_isCoveredByTheMonoFace() {
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
    func testGlitchPool_stillContainsGlyphsThatEscapeTheMonoFace() {
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
    func testSomeGlitchGlyphs_areTallerThanTheReferenceCell() {
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
