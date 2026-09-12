import XCTest

@testable import NanoTeams

/// Two properties of a palette that no other test could see, and that a palette can lose while
/// every existing assertion stays green.
///
/// `ContextFillBarPaletteTests` measures whether tokens can be told APART. That is a question
/// about pairs, and a palette can answer it perfectly while being unusable: separation says
/// nothing about how loud the thing you are separating from is. On 2026-09-09 a palette shipped
/// whose `surfacePrimary` measured **C\* 97** — the hardware blue of a 1981 text mode, transcribed
/// faithfully. Every ΔE assertion passed, because saturated grounds are if anything EASIER to
/// separate from. What it looked like was a wall: the value was drawn for a 640×350 CRT and this
/// one covers a 27-inch panel, edge to edge, behind every word of body text.
///
/// So the missing measurements are absolute rather than relative. There are three.
///
/// `nonisolated`: `Theme` and `ThemePalette` are value-in / value-out.
final class ThemeSurfaceRestraintTests: XCTestCase {

    // MARK: - The three bounds

    /// A ceiling on how colourful the surfaces the eye RESTS on may be.
    ///
    /// Not a round number: 97 is the value that failed, and the palette that replaced it sits at
    /// 50.3 with the hue still unmistakable. Everything else in the file is at or under 18. The
    /// bound is placed above the working palette and well under the failure, which is the only
    /// honest place for it — tighten it to 20 and the deliberately saturated theme becomes
    /// illegal; loosen it past 70 and it stops describing anything.
    private static let loudestRestingSurface = 60.0

    /// A floor under the panel edge. `borderStrong` is what draws a card as a card; below this the
    /// frame is a claim in the palette rather than a line on the screen.
    ///
    /// The tightest real margin in the shipped scheme is 11.0 (`forestDark`), so this bound is
    /// satisfied by every palette that has ever shipped — it exists to catch the NEXT one.
    private static let visibleEdge = 10.0

    /// WCAG AA for normal text. Body copy is the one thing a palette may not get wrong, and until
    /// 2026-09-09 nothing measured it: `parchmentLight` shipped `textSecondary` at 4.24:1 on its own
    /// ground, and the first `blueprintLight` at 4.15:1 — the two worst of the nine light palettes,
    /// against a median of 6.3. Both were found by hand, which is the argument for the assertion.
    private static let readableText = 4.5

    /// The surfaces a window is mostly made of. `surfaceElevated` and `surfaceHover` are excluded
    /// deliberately: they are small, brief, and MEANT to be the livelier end of the ladder.
    private func restingSurfaces(_ p: ThemePalette) -> [(String, UInt64)] {
        [("surfaceBackground", p.surfaceBackground),
         ("surfacePrimary", p.surfacePrimary),
         ("surfaceCard", p.surfaceCard)]
    }

    private static let palettes: [(name: String, palette: ThemePalette)] =
        Theme.allCases.flatMap { theme in
            [("\(theme.rawValue)/dark", theme.palette(isDark: true)),
             ("\(theme.rawValue)/light", theme.palette(isDark: false))]
        }

    // MARK: - The instrument

    /// CIE 1976 chroma — distance from the neutral axis in Lab. This is the "how colourful",
    /// held apart from "how light", which is why lightness cannot stand in for it: `#0A14B4`
    /// and `#182669` are 5 apart in L\* and 52 apart in C\*, and only the second is habitable.
    private func chroma(_ hex: UInt64) -> Double {
        let (_, a, b) = lab(hex)
        return (a * a + b * b).squareRoot()
    }

    private func deltaE(_ x: UInt64, _ y: UInt64) -> Double {
        let (l1, a1, b1) = lab(x), (l2, a2, b2) = lab(y)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    /// WCAG relative-luminance contrast ratio. A different question from ΔE — that one asks
    /// "are these two blocks different colours", this one asks "can a glyph stroke be read".
    private func contrast(_ x: UInt64, _ y: UInt64) -> Double {
        func luminance(_ hex: UInt64) -> Double {
            func linear(_ channel: UInt64) -> Double {
                let c = Double(channel) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear((hex >> 16) & 0xFF)
                + 0.7152 * linear((hex >> 8) & 0xFF)
                + 0.0722 * linear(hex & 0xFF)
        }
        let (a, b) = (luminance(x), luminance(y))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func lab(_ hex: UInt64) -> (Double, Double, Double) {
        func linear(_ channel: UInt64) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear((hex >> 16) & 0xFF), g = linear((hex >> 8) & 0xFF), b = linear(hex & 0xFF)
        let x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
        let y = r * 0.2126 + g * 0.7152 + b * 0.0722
        let z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        let (fx, fy, fz) = (f(x), f(y), f(z))
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Sanity on the instrument before anything is measured with it: grey has no chroma, a
    /// saturated primary has a great deal, and lightness does not leak into the reading.
    func testChromaAgreesWithItself() {
        XCTAssertEqual(chroma(0x808080), 0, accuracy: 0.5)
        XCTAssertEqual(chroma(0xFFFFFF), 0, accuracy: 0.5)
        XCTAssertGreaterThan(chroma(0x0000FF), 100)
        // Two blues an octave apart in lightness, both saturated: chroma is not brightness.
        XCTAssertGreaterThan(chroma(0x0A14B4), 90)
        XCTAssertGreaterThan(chroma(0x6E7BE8), 50)
    }

    func testThereArePalettesToMeasure() {
        XCTAssertGreaterThan(Self.palettes.count, 30, "Theme.allCases stopped enumerating")
    }

    // MARK: - The bounds, over the whole population

    /// RED: put `surfacePrimary: 0x0A14B4` back into any palette → this names it at 97.2.
    func testNoRestingSurfaceIsLouderThanTheCeiling() {
        for (name, p) in Self.palettes {
            for (label, surface) in restingSurfaces(p) {
                let c = chroma(surface)
                XCTAssertLessThanOrEqual(
                    c, Self.loudestRestingSurface,
                    "\(name): \(label) is a saturated field at C*\(String(format: "%.1f", c)) — "
                        + "this is a whole-window fill, not an accent")
            }
        }
    }

    /// The edge that makes a card a card, on every palette and both schemes.
    func testEveryPanelEdgeIsDrawable() {
        for (name, p) in Self.palettes {
            let d = deltaE(p.borderStrong, p.surfaceCard)
            XCTAssertGreaterThanOrEqual(
                d, Self.visibleEdge,
                "\(name): borderStrong is \(String(format: "%.1f", d)) from surfaceCard — the "
                    + "frame is in the palette but not on the screen")
        }
    }

    /// Body text on the surface it actually sits on, for both text tiers and both grounds a
    /// paragraph lands on.
    ///
    /// RED: restore `parchmentLight.textSecondary` to `0x5C7077` → this names it at 4.24.
    func testBodyTextIsReadableOnItsOwnSurface() {
        for (name, p) in Self.palettes {
            for (groundLabel, ground) in [("surfacePrimary", p.surfacePrimary), ("surfaceCard", p.surfaceCard)] {
                for (inkLabel, ink) in [("textPrimary", p.textPrimary), ("textSecondary", p.textSecondary)] {
                    let ratio = contrast(ink, ground)
                    XCTAssertGreaterThanOrEqual(
                        ratio, Self.readableText,
                        "\(name): \(inkLabel) on \(groundLabel) is "
                            + "\(String(format: "%.2f", ratio)):1 — below AA for normal text")
                }
            }
        }
    }

    /// `textTertiary` is deliberately quieter — it is the track, the timestamp, the gutter index —
    /// so it answers to the large-text bound instead. Pinning it at all is what keeps "quiet" from
    /// drifting into "gone".
    func testTheQuietTierIsStillPresent() {
        for (name, p) in Self.palettes {
            let ratio = contrast(p.textTertiary, p.surfaceCard)
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "\(name): textTertiary on surfaceCard is \(String(format: "%.2f", ratio)):1")
        }
    }

    /// The floor, like the ceiling, is only worth having while something sits near it: the tightest
    /// margin in the shipped scheme is `dawnLight` at 4.73:1.
    func testTheReadabilityFloorIsStillLoadBearing() {
        let tightest = Self.palettes
            .flatMap { e in [contrast(e.palette.textSecondary, e.palette.surfacePrimary),
                             contrast(e.palette.textPrimary, e.palette.surfacePrimary)] }
            .min() ?? 0
        XCTAssertLessThan(
            tightest, Self.readableText * 1.5,
            "every palette now clears the readability floor by 50% — tighten it to the population "
                + "it describes (tightest is \(String(format: "%.2f", tightest)))")
    }

    /// The ceiling is only worth having while something approaches it. If every palette drifted
    /// down to near-neutral this test would say so, and the bound could be tightened to match —
    /// a silent ceiling nothing touches is a number nobody re-derives.
    func testTheCeilingIsStillLoadBearing() {
        let loudest = Self.palettes
            .flatMap { entry in restingSurfaces(entry.palette).map { chroma($0.1) } }
            .max() ?? 0
        XCTAssertGreaterThan(
            loudest, Self.loudestRestingSurface / 2,
            "no palette comes near the chroma ceiling any more (loudest is "
                + "\(String(format: "%.1f", loudest))) — tighten it to the population it describes")
        XCTAssertLessThanOrEqual(loudest, Self.loudestRestingSurface)
    }
}
