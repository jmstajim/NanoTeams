import XCTest

@testable import NanoTeams

/// The colours of the context-fill bar, measured against every ground it can land on.
///
/// The bar sits INSIDE the recipient chip, and the chip is one colour: `surfaceElevated` (or
/// `surfaceHover`) when it is not the selected recipient, `Colors.accent` when it is, and — on
/// an Answer chip — whatever hex the role carries, which the user can edit in the role editor.
/// So "does this token read here" has no single answer, and prose cannot hold it: `Colors.warning`
/// is BYTE-IDENTICAL to `Colors.accent` in 24 of the 36 effective palettes, and `Colors.borderStrong`
/// is byte-identical to `Colors.surfaceElevated` in `umberDark` and `lilacDark` — a track that
/// simply was not there, in a control whose empty state is a claim ("the window was never probed").
/// Both were shipped, both read fine in the theme they were written in.
///
/// Distances are CIE ΔE (Lab, 1976). Contrast RATIO is the wrong instrument here — it is a
/// text-legibility metric and it reports 1.00 for two saturated blocks of equal lightness, which
/// are trivially told apart. These are solid glyph cells; ΔE ≥ 10 is the separation the eye reads
/// as "a different colour" on a patch this size.
///
/// `nonisolated`: `Theme`, `ThemePalette` and `RoleColorDefaults` are all value-in / value-out.
final class ContextFillBarPaletteTests: XCTestCase {

    /// Below this two solid cells read as one colour. Every assertion here has margin: the
    /// tightest real separation in the shipped scheme measures 13.9.
    private static let distinguishable = 10.0

    // MARK: - The palettes and the grounds

    private static let palettes: [(name: String, palette: ThemePalette)] =
        Theme.allCases.flatMap { theme in
            [("\(theme.rawValue)/dark", theme.palette(isDark: true)),
             ("\(theme.rawValue)/light", theme.palette(isDark: false))]
        }

    /// The role tints an Answer chip can be filled with. Defaults only — the field is editable,
    /// which is the whole reason no tier hue can be guaranteed on a selected chip.
    private static let roleTints: [UInt64] =
        ([RoleColorDefaults.defaultHex] + RoleColorDefaults.backgroundHex.values)
            .compactMap { UInt64($0.replacingOccurrences(of: "#", with: ""), radix: 16) }

    /// What an UNSELECTED chip is filled with.
    private func plainGrounds(_ p: ThemePalette) -> [(String, UInt64)] {
        [("surfaceElevated", p.surfaceElevated), ("surfaceHover", p.surfaceHover)]
    }

    /// What a SELECTED chip is filled with: the accent, or a role's own colour.
    private func filledGrounds(_ p: ThemePalette) -> [(String, UInt64)] {
        [("accent", p.accent)] + Self.roleTints.map { (String(format: "role #%06X", $0), $0) }
    }

    // MARK: - ΔE

    private func deltaE(_ a: UInt64, _ b: UInt64) -> Double {
        let (l1, a1, b1) = lab(a), (l2, a2, b2) = lab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    private func lab(_ hex: UInt64) -> (Double, Double, Double) {
        func linear(_ channel: UInt64) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear((hex >> 16) & 0xFF), g = linear((hex >> 8) & 0xFF), b = linear(hex & 0xFF)
        // sRGB → XYZ (D65), then normalised by the D65 white point.
        let x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
        let y = r * 0.2126 + g * 0.7152 + b * 0.0722
        let z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        let (fx, fy, fz) = (f(x), f(y), f(z))
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Sanity on the instrument itself, before anything is measured with it: identical colours
    /// are zero apart, and the two ends of the ramp are far apart.
    func testTheMetricAgreesWithItself() {
        XCTAssertEqual(deltaE(0x123456, 0x123456), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(deltaE(0x000000, 0xFFFFFF), 99)
        XCTAssertLessThan(deltaE(0x808080, 0x818181), 1)
    }

    func testThereAreThemesAndRoleTintsToMeasureAgainst() {
        XCTAssertGreaterThan(Self.palettes.count, 30, "Theme.allCases stopped enumerating")
        XCTAssertGreaterThan(Self.roleTints.count, 10, "role tint defaults stopped parsing")
    }

    // MARK: - The track

    /// RED: put `borderStrong` back as the chip's track → `umberDark` and `lilacDark` fail with
    /// ΔE 0.000, because there the token IS `surfaceElevated`.
    ///
    /// The track has to be visible on EVERY ground, selected and not: it is what says how long
    /// the whole bar is, and without it a 10%-full bar is a speck rather than a reading.
    func testTheTrackSeparatesFromEveryGroundAChipCanHave() {
        for (name, p) in Self.palettes {
            for (label, ground) in plainGrounds(p) + filledGrounds(p) {
                XCTAssertGreaterThanOrEqual(
                    deltaE(p.textTertiary, ground), Self.distinguishable,
                    "\(name): the track vanishes on \(label)")
            }
        }
    }

    /// The evidence for the line above, kept as a measurement rather than a claim in a comment:
    /// the token the bar used until 2026-09-08 is not merely close to the unselected chip's own
    /// fill in those two themes — it is the same 24 bits.
    func testTheTrackTheBarUsedToUse_isTheUnselectedChipsOwnFill() {
        let collisions = Self.palettes.filter { deltaE($0.palette.borderStrong, $0.palette.surfaceElevated) < 2 }
        XCTAssertFalse(
            collisions.isEmpty,
            "borderStrong no longer collides with surfaceElevated anywhere — if the palettes were "
                + "fixed, the track can go back to it and this test should be deleted")
        XCTAssertTrue(
            collisions.contains { $0.name.hasPrefix("umber") },
            "expected umber among \(collisions.map(\.name))")
    }

    // MARK: - The ink

    /// On a filled chip the only guaranteed ink is the one the chip already draws its NAME with.
    func testTheOnAccentInkSeparatesFromEveryFilledGround() {
        for (name, p) in Self.palettes {
            for (label, ground) in filledGrounds(p) {
                XCTAssertGreaterThanOrEqual(
                    deltaE(p.textOnAccent, ground), Self.distinguishable,
                    "\(name): the selected chip's bar vanishes on \(label)")
            }
        }
    }

    /// RED: paint a tier hue on a selected chip → this test names the ground it disappears on.
    /// This is the measurement behind `ContextFillIndicator.isOnAccent`: there is no third
    /// option, because the ground can be a hex the user typed.
    func testNoTierHueSurvivesEveryFilledGround() {
        for token in ["accent", "gold", "error"] {
            let survives = Self.palettes.allSatisfy { entry in
                let ink = value(of: token, in: entry.palette)
                return filledGrounds(entry.palette).allSatisfy {
                    deltaE(ink, $0.1) >= Self.distinguishable
                }
            }
            XCTAssertFalse(survives, "\(token) now survives every filled ground — re-measure the "
                + "selected chip's ink, it may be able to carry the tier again")
        }
    }

    /// Off an accent fill the tier IS a hue, and the three have to be told apart.
    func testTheTierHuesSeparateOnAnUnselectedChip() {
        for (name, p) in Self.palettes {
            for (label, ground) in plainGrounds(p) {
                for token in ["accent", "gold", "error"] {
                    XCTAssertGreaterThanOrEqual(
                        deltaE(value(of: token, in: p), ground), Self.distinguishable,
                        "\(name): \(token) vanishes on \(label)")
                }
            }
            XCTAssertGreaterThanOrEqual(deltaE(p.accent, p.error), Self.distinguishable, name)
            XCTAssertGreaterThanOrEqual(deltaE(p.gold, p.error), Self.distinguishable, name)
        }
    }

    /// The one seam in the scheme, stated rather than discovered: this design system is
    /// Monochrome+1 — a neutral ramp, one accent, and terracotta reserved for failure — so in the
    /// BASE palettes (`terminalDark`, `oledDark`, `lightPaper`) every warm token, `gold` included,
    /// IS the accent. There is no third hue to be had there, and `comfortable` and `approaching`
    /// therefore share a colour in 15 of the 46 theme-and-scheme combinations. The bar's LENGTH
    /// separates them; the themed palettes give them separate hues on top.
    ///
    /// What this pins is that `gold` STRICTLY DOMINATES `Colors.warning`, the semantic token the
    /// bar used until 2026-09-08: it merges with the accent in a subset of the same places, never
    /// anywhere warning does not, and in fewer of them (15 against 34).
    ///
    /// RED: move `approaching` back to `Colors.warning` → the subset still holds but the count
    /// stops improving, and the second assertion names it.
    func testTheApproachingHueIsStrictlyBetterThanTheSemanticToken() {
        let goldMerges = Set(Self.palettes.filter { deltaE($0.palette.accent, $0.palette.gold) < 2 }.map(\.name))
        let warningMerges = Set(Self.palettes.filter { deltaE($0.palette.accent, $0.palette.warning) < 2 }.map(\.name))
        XCTAssertTrue(
            goldMerges.isSubset(of: warningMerges),
            "gold now merges where warning does not: \(goldMerges.subtracting(warningMerges).sorted())")
        XCTAssertLessThan(
            goldMerges.count, warningMerges.count,
            "gold is no better than warning any more — re-measure before choosing the tier hue")
        XCTAssertFalse(
            goldMerges.isEmpty,
            "gold separates from the accent everywhere now — the caveat in ContextFillIndicator "
                + "about the base palettes can be deleted")
    }

    /// Ink on track: the boundary between the lit run and the rest is the reading.
    func testEveryInkSeparatesFromTheTrack() {
        for (name, p) in Self.palettes {
            for token in ["accent", "gold", "error", "textOnAccent"] {
                XCTAssertGreaterThanOrEqual(
                    deltaE(value(of: token, in: p), p.textTertiary), Self.distinguishable,
                    "\(name): \(token) is indistinguishable from the track")
            }
        }
    }

    /// The compacting ink is deliberately the QUIETEST of them — it must still not be the ground.
    func testTheCompactingInkIsVisibleButNotLoud() {
        for (name, p) in Self.palettes {
            for (label, ground) in plainGrounds(p) + filledGrounds(p) {
                XCTAssertGreaterThanOrEqual(
                    deltaE(p.textSecondary, ground), Self.distinguishable,
                    "\(name): the compacting bar vanishes on \(label)")
            }
        }
    }

    private func value(of token: String, in p: ThemePalette) -> UInt64 {
        switch token {
        case "accent": return p.accent
        case "gold": return p.gold
        case "error": return p.error
        case "textOnAccent": return p.textOnAccent
        default: XCTFail("unknown token \(token)"); return 0
        }
    }
}
