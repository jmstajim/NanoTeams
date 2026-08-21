import AppKit
import XCTest
@testable import NanoTeams

/// Regression pins for the same-scheme theme-switch staleness fix.
///
/// Before the fix the AppKit `Colors.ns*` accessors were module-load `static let`
/// dynamic NSColors. AppKit only re-invokes a dynamic provider on a dark↔light
/// appearance change, so switching between two themes of the SAME scheme (e.g.
/// Terminal→OLED, both dark) left already-rendered NSTextView text in the prior
/// theme's color until app relaunch. The fix routes the accessors through a
/// per-(theme, token, alpha) cache: a fresh instance per theme (empty per-appearance
/// cache → resolves the new palette), but a STABLE instance within a theme (so the
/// `ColorsNSIdentityTests` / CLAUDE.md #50 append-relayout contract still holds).
final class ColorsThemeResolutionTests: XCTestCase {

    private var savedThemeRaw: String?

    override func setUp() {
        super.setUp()
        savedThemeRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.activeTheme)
    }

    override func tearDown() {
        if let savedThemeRaw {
            UserDefaults.standard.set(savedThemeRaw, forKey: UserDefaultsKeys.activeTheme)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activeTheme)
        }
        super.tearDown()
    }

    private func setTheme(_ theme: Theme) {
        UserDefaults.standard.set(theme.rawValue, forKey: UserDefaultsKeys.activeTheme)
    }

    /// Resolve a (possibly dynamic) NSColor to sRGB components under a fixed
    /// effective appearance — the dynamic provider runs against `current`.
    private func rgba(_ color: NSColor, dark: Bool) -> [CGFloat] {
        var out: [CGFloat] = [-1, -1, -1, -1]
        let resolve = {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            out = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
        }
        if let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) {
            appearance.performAsCurrentDrawingAppearance(resolve)
        } else {
            resolve()
        }
        return out
    }

    private func expectedRGB(_ hex: UInt64) -> [CGFloat] {
        [CGFloat((hex >> 16) & 0xFF) / 255.0,
         CGFloat((hex >> 8) & 0xFF) / 255.0,
         CGFloat(hex & 0xFF) / 255.0,
         1.0]
    }

    private func assertClose(_ a: [CGFloat], _ b: [CGFloat], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, message, file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x, y, accuracy: 0.004, message, file: file, line: line)
        }
    }

    // MARK: - The fix: fresh instance per theme

    /// THE load-bearing pin. Two same-scheme themes must hand back DIFFERENT
    /// NSColor instances — a fresh instance has an empty per-appearance cache, so
    /// AppKit resolves the new palette instead of the stale one. Failed against
    /// the prior `static let` (one frozen instance for every theme).
    func testNSTextPrimary_differentInstancePerTheme() {
        setTheme(.terminal)
        let terminal = Colors.nsTextPrimary
        setTheme(.oled)
        let oled = Colors.nsTextPrimary
        XCTAssertFalse(terminal === oled,
                       "nsTextPrimary must return a fresh instance after a same-scheme theme switch (Terminal→OLED) so the new palette resolves immediately, not at next launch.")
    }

    func testNSSurfaceCard_differentInstancePerTheme() {
        setTheme(.terminal)
        let terminal = Colors.nsSurfaceCard
        setTheme(.oled)
        let oled = Colors.nsSurfaceCard
        XCTAssertFalse(terminal === oled,
                       "nsSurfaceCard must return a fresh instance per theme.")
    }

    // MARK: - Preserved contract: stable instance within a theme

    /// Guards the `ColorsNSIdentityTests` / CLAUDE.md #50 contract — within one
    /// theme the accessor must memoize so `NSAttributedString` equality + the
    /// append-only relayout short-circuit hold.
    func testNSTextPrimary_sameInstanceWithinTheme() {
        setTheme(.umber)
        XCTAssertTrue(Colors.nsTextPrimary === Colors.nsTextPrimary,
                      "nsTextPrimary must be a stable instance WITHIN a theme.")
        XCTAssertTrue(Colors.nsSurfaceCard === Colors.nsSurfaceCard)
        XCTAssertTrue(Colors.nsTextSecondary === Colors.nsTextSecondary)
    }

    // MARK: - Value freshness

    func testNSTextPrimary_resolvesActiveThemePalette() {
        setTheme(.oled)
        assertClose(rgba(Colors.nsTextPrimary, dark: true), expectedRGB(Theme.oledDark.textPrimary),
                    "nsTextPrimary under OLED must resolve oledDark.textPrimary")

        setTheme(.terminal)
        assertClose(rgba(Colors.nsTextPrimary, dark: true), expectedRGB(Theme.terminalDark.textPrimary),
                    "nsTextPrimary under Terminal must resolve terminalDark.textPrimary")
    }

    func testSwiftUIToken_resolvesFreshAcrossThemeSwitch() {
        setTheme(.terminal)
        let terminalAccent = ColorResolution.rgba(Colors.accent, dark: true)
        setTheme(.umber)
        let umberAccent = ColorResolution.rgba(Colors.accent, dark: true)
        XCTAssertNotEqual(terminalAccent, umberAccent,
                          "Colors.accent must resolve to the active theme's accent — Terminal (lavender) vs Umber (orange).")
        assertClose(umberAccent, expectedRGB(Theme.umberDark.accent), "Umber accent value")
    }

    // MARK: - Corner cases

    /// `.system` is dark-or-light by OS appearance — the dynamic provider must
    /// still branch on the resolved appearance, not the theme alone.
    func testSystemTheme_resolvesDarkAndLightVariants() {
        setTheme(.system)
        let dark = rgba(Colors.nsTextPrimary, dark: true)
        let light = rgba(Colors.nsTextPrimary, dark: false)
        assertClose(dark, expectedRGB(Theme.terminalDark.textPrimary), ".system dark → terminalDark.textPrimary")
        assertClose(light, expectedRGB(Theme.lightPaper.textPrimary), ".system light → lightPaper.textPrimary")
    }

    /// Alpha variants are keyed separately — a 1.0 token and a 0.5 token never
    /// collapse to one cache entry.
    func testAlphaVariants_cachedSeparately() {
        setTheme(.terminal)
        let opaque = Colors.nsThemed(\.accent, alpha: 1.0)
        let half = Colors.nsThemed(\.accent, alpha: 0.5)
        XCTAssertFalse(opaque === half, "Different alphas must not share a cache entry.")
        XCTAssertEqual(rgba(half, dark: true)[3], 0.5, accuracy: 0.001, "alpha 0.5 must round-trip")
    }
}
