import SwiftUI
import XCTest

@testable import NanoTeams

/// Every theme is reachable from four maps, and NONE of the four is checked by the compiler.
///
/// `Theme.palette(isDark:)` resolves through `darkPaletteMap`, `lightPaletteMap` and
/// `lightAccentMap`, each with a `??` fallback; `displayName` reads `displayNameMap` with a
/// `?? rawValue` fallback; and `preferredColorScheme` is a NON-exhaustive `switch` whose
/// `default` returns `.dark`. So a theme added to the enum and forgotten in a map still builds
/// — it just renders as Terminal, or shows its lowercase `rawValue` in Settings, or silently
/// becomes a dark theme when it was written as a light one.
///
/// These assertions are written over `Theme.allCases` rather than a list of names, so a theme
/// added tomorrow is covered by the same test — a pin whose population is an enumeration
/// reproduces the very defect it disproves (CLAUDE.md #236).
final class ThemeMapTotalityTests: XCTestCase {

    // MARK: - The instrument

    /// Guards against the whole suite passing vacuously if `allCases` ever stops enumerating.
    func testThereAreThemesToCheck() {
        XCTAssertGreaterThan(Theme.allCases.count, 20, "Theme.allCases stopped enumerating")
        XCTAssertEqual(Set(Theme.allCases.map(\.rawValue)).count, Theme.allCases.count,
                       "two themes share a rawValue — the maps would collide")
    }

    // MARK: - Totality

    func testEveryThemeHasADisplayName() {
        for theme in Theme.allCases {
            XCTAssertNotEqual(
                theme.displayName, theme.rawValue,
                "\(theme.rawValue): missing from displayNameMap — Settings will show the rawValue")
        }
    }

    func testEveryThemeHasADarkPalette() {
        for theme in Theme.allCases {
            XCTAssertNotNil(
                Theme.darkPaletteMap[theme],
                "\(theme.rawValue): missing from darkPaletteMap — falls back to Terminal")
        }
    }

    /// Both directions. A light theme left out of the `preferredColorScheme` list renders dark;
    /// a light theme left out of `lightPaletteMap` renders on the shared paper instead of its own.
    func testLightPaletteMembershipMatchesTheLightColorScheme() {
        for theme in Theme.allCases {
            let hasOwnLightPalette = Theme.lightPaletteMap[theme] != nil
            let isLight = theme.preferredColorScheme == .light
            XCTAssertEqual(
                hasOwnLightPalette, isLight,
                "\(theme.rawValue): lightPaletteMap says \(hasOwnLightPalette) but "
                    + "preferredColorScheme says \(isLight) — one of the two was forgotten")
        }
    }

    func testEveryDarkThemeHasALightAccent() {
        for theme in Theme.allCases where theme.preferredColorScheme == .dark {
            XCTAssertNotNil(
                Theme.lightAccentMap[theme],
                "\(theme.rawValue): missing from lightAccentMap — wears Terminal's accent in "
                    + "a light scheme")
        }
    }

    /// `.system` is the one theme that belongs to neither family: it follows the OS, so it has
    /// no scheme of its own, no dedicated light palette, and still needs an accent for the
    /// branch where the OS resolves to light.
    func testSystemIsTheOneThemeWithoutASchemeOfItsOwn() {
        XCTAssertNil(Theme.system.preferredColorScheme)
        XCTAssertNil(Theme.lightPaletteMap[.system])
        XCTAssertNotNil(Theme.lightAccentMap[.system])
        XCTAssertNotNil(Theme.darkPaletteMap[.system])
        let others = Theme.allCases.filter { $0 != .system && $0.preferredColorScheme == nil }
        XCTAssertTrue(others.isEmpty, "these follow the OS but are not .system: \(others)")
    }

    // MARK: - The palettes actually resolve

    func testCobaltResolvesToItsOwnDarkPalette() {
        assertSamePalette(Theme.cobalt.palette(isDark: true), Theme.cobaltDark, "cobalt/dark")
    }

    func testBlueprintResolvesToItsOwnLightPalette() {
        assertSamePalette(
            Theme.blueprint.palette(isDark: false), Theme.blueprintLight, "blueprint/light")
    }

    /// The pair is one family in both schemes: Blueprint's (unreachable) dark half is Cobalt's
    /// palette, not the global Terminal default, and Cobalt's light accent is Blueprint's ochre.
    func testThePairPointsAtItself() {
        assertSamePalette(Theme.blueprint.palette(isDark: true), Theme.cobaltDark, "blueprint/dark")
        XCTAssertEqual(Theme.lightAccentMap[.cobalt]?.accent, Theme.blueprintLight.accent)
    }

    // MARK: - A light theme is light, a dark theme is dark

    /// Catches a palette filed under the wrong scheme — the failure mode no map lookup can see,
    /// because a dark palette in `lightPaletteMap` resolves perfectly and renders unreadably.
    func testTextAndGroundSitOnTheExpectedSidesOfEveryPalette() {
        for theme in Theme.allCases {
            for isDark in [true, false] {
                let p = theme.palette(isDark: isDark)
                let ground = luminance(p.surfacePrimary), ink = luminance(p.textPrimary)
                if isDark {
                    XCTAssertLessThan(ground, ink, "\(theme.rawValue)/dark: ground is lighter than its text")
                } else {
                    XCTAssertGreaterThan(ground, ink, "\(theme.rawValue)/light: ground is darker than its text")
                }
                XCTAssertGreaterThan(
                    contrast(p.textPrimary, p.surfacePrimary), 4.5,
                    "\(theme.rawValue)/\(isDark ? "dark" : "light"): body text under WCAG AA")
            }
        }
    }

    // MARK: - Helpers

    /// Compares every stored field, so a palette that drifts in one of its ~50 values is caught
    /// without this test having to name them. `ThemePalette` is not `Equatable`.
    private func assertSamePalette(
        _ lhs: ThemePalette, _ rhs: ThemePalette, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let a = Mirror(reflecting: lhs).children.map { ($0.label ?? "?", $0.value as? UInt64) }
        let b = Mirror(reflecting: rhs).children.map { ($0.label ?? "?", $0.value as? UInt64) }
        XCTAssertGreaterThan(a.count, 40, "\(label): ThemePalette stopped reflecting its fields",
                             file: file, line: line)
        XCTAssertEqual(a.count, b.count, label, file: file, line: line)
        for (left, right) in zip(a, b) {
            XCTAssertEqual(left.0, right.0, "\(label): field order diverged", file: file, line: line)
            XCTAssertEqual(left.1, right.1, "\(label): \(left.0) differs", file: file, line: line)
        }
    }

    private func luminance(_ hex: UInt64) -> Double {
        func channel(_ raw: UInt64) -> Double {
            let c = Double(raw) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
            + 0.7152 * channel((hex >> 8) & 0xFF)
            + 0.0722 * channel(hex & 0xFF)
    }

    private func contrast(_ a: UInt64, _ b: UInt64) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }
}
