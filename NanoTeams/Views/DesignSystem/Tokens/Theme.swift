import SwiftUI

// MARK: - Theme

/// One unified theme choice combining color-scheme intent and palette pick.
///
/// `system` / `light` / `dark` cover the classic appearance modes (dark = the
/// original Terminal palette). The other 11 cases are dark-only palette
/// variants. Light Mode (whether picked explicitly or via `.system` resolving
/// to light) always uses the shared paper surfaces; each theme contributes
/// its own contrast-corrected accent so the pick stays visible.
///
/// Storage: persisted via `@AppStorage(UserDefaultsKeys.activeTheme)`. The
/// `nonisolated` storage helpers below let the dynamic `NSColor` providers in
/// `Colors.swift` read the active theme without taking the main actor — they
/// run on AppKit's appearance-resolution thread.
nonisolated enum Theme: String, CaseIterable, Identifiable, Sendable {
    case system
    // MARK: Light themes
    case light
    case parchment
    case mist
    case sand
    case dawn
    case cream
    case daylight
    case blush
    // MARK: Dark themes
    case terminal
    case oled
    case arctic
    case indigo
    case umber
    case lilac
    case marine
    case steel
    case plum
    case forest
    case amber
    case amethyst
    case neon
    case rose

    var id: String { rawValue }

    /// Default theme for fresh installs — follow the system appearance.
    static let defaultTheme: Theme = .system

    private static let displayNameMap: [Theme: String] = [
        .system: "System",
        .light: "Light",
        .parchment: "Parchment",
        .mist: "Mist",
        .sand: "Sand",
        .dawn: "Dawn",
        .cream: "Cream",
        .daylight: "Daylight",
        .blush: "Blush",
        .terminal: "Dark",
        .oled: "OLED",
        .arctic: "Arctic",
        .indigo: "Indigo",
        .umber: "Umber",
        .lilac: "Lilac",
        .marine: "Marine",
        .steel: "Steel",
        .plum: "Plum",
        .forest: "Forest",
        .amber: "Amber",
        .amethyst: "Amethyst",
        .neon: "Neon",
        .rose: "Rose"
    ]

    var displayName: String { Self.displayNameMap[self] ?? rawValue }

    /// Returns the SwiftUI `.preferredColorScheme` argument: `nil` for `.system`
    /// (follow the OS), `.light` for every light theme, `.dark` for every dark
    /// theme (Terminal + the 13 themed dark variants).
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .parchment, .mist, .sand, .dawn, .cream, .daylight, .blush:
            return .light
        default:
            return .dark
        }
    }

    // MARK: - Active theme storage

    /// Where the active theme is read from. `UserDefaults.standard` in production.
    ///
    /// A SLOT rather than a parameter, because `current` is a static read with no caller
    /// context — it is reached from AppKit's appearance-resolution thread through
    /// `Colors.nsThemed`, which has nowhere to thread an argument from. The neighbouring
    /// `migrateLegacyAppearanceIfNeeded(defaults:)` already takes its store as an argument;
    /// this is the same idea where an argument is not available.
    ///
    /// It exists because `UserDefaults.standard` is a CROSS-PROCESS channel and the test target
    /// runs parallel host processes that share one bundle-identifier defaults domain. A suite
    /// flipping the theme to assert colour resolution was therefore visible to every other
    /// worker, and `Colors.nsThemed` memoizes on a key containing `Theme.current` while minting
    /// a fresh dynamic `NSColor` per miss — instances that compare unequal at identical RGB. A
    /// flip landing between two lookups made two "identical" attributed strings differ, with no
    /// visible cause. See `DEBTS.md` D-4.
    ///
    /// Guarded by a lock rather than left as `nonisolated(unsafe)`: the appearance thread is a
    /// real concurrent reader.
    private static let storageLock = NSLock()
    nonisolated(unsafe) private static var _storage: any ConfigurationStorage = UserDefaults.standard

    private static var storage: any ConfigurationStorage {
        storageLock.withLock { _storage }
    }

    /// Reads the active theme. Safe to call from any thread.
    static var current: Theme {
        let raw = storage.string(forKey: UserDefaultsKeys.activeTheme) ?? defaultTheme.rawValue
        return Theme(rawValue: raw) ?? defaultTheme
    }

    #if DEBUG
    /// Points `current` at a per-process store so a test can flip the theme without the write
    /// reaching another worker. Pair with `_testResetStorage()` in `tearDown`.
    static func _testUseIsolatedStorage(_ store: any ConfigurationStorage) {
        storageLock.withLock { _storage = store }
    }

    static func _testResetStorage() {
        storageLock.withLock { _storage = UserDefaults.standard }
    }
    #endif

    /// One-shot migration of legacy `appAppearance` UserDefaults value
    /// ("system" / "light" / "dark") into the unified `activeTheme` key.
    /// Called from `NanoTeamsApp.init` so the user's prior pick survives the
    /// AppAppearance → Theme consolidation. Idempotent: no-op once
    /// `activeTheme` is set.
    ///
    /// Takes `any ConfigurationStorage` rather than `UserDefaults` for the reason the
    /// `_storage` slot above exists: the test target runs parallel host processes sharing
    /// one defaults domain, so a test that wrote through `UserDefaults.standard` here
    /// would be visible to every other worker (DEBTS.md D-4). The production call site
    /// passes nothing and still gets `UserDefaults.standard`.
    ///
    /// Shipped 2026-06-21; carried no date until 2026-09-05, which is why the scan that
    /// guards dated obligations could not see it (DEBTS.md D-32).
    /// TODO(2026-Q4): remove once all live installs have migrated.
    @discardableResult
    static func migrateLegacyAppearanceIfNeeded(
        defaults: any ConfigurationStorage = UserDefaults.standard
    ) -> Bool {
        guard defaults.string(forKey: UserDefaultsKeys.activeTheme) == nil else { return false }
        guard let legacy = defaults.string(forKey: UserDefaultsKeys.appAppearance) else { return false }
        let mapped: Theme?
        switch legacy {
        case "system": mapped = .system
        case "light": mapped = .light
        case "dark": mapped = .terminal
        default: mapped = nil
        }
        guard let mapped else { return false }
        defaults.set(mapped.rawValue, forKey: UserDefaultsKeys.activeTheme)
        return true
    }

    /// Returns the palette to use for the given effective color scheme.
    /// - Dark scheme: returns this theme's full dark palette (System falls
    ///   through to Terminal as the canonical dark default).
    /// - Light scheme:
    ///   1. If the theme is itself a light theme (Parchment / Mist / Sand /
    ///      Dawn / Cream / Daylight / Blush / Light), return its dedicated
    ///      palette with its own surfaces + status colours.
    ///   2. Otherwise (a dark theme rendered in light scheme), start from the
    ///      shared `lightPaper` palette and overlay this theme's accent so the
    ///      user's pick remains visible through interactive elements.
    func palette(isDark: Bool) -> ThemePalette {
        if isDark {
            return Self.darkPaletteMap[self] ?? Self.terminalDark
        }
        if let explicit = Self.lightPaletteMap[self] {
            return explicit
        }
        return Self.lightPaper.withAccent(Self.lightAccentMap[self] ?? Self.terminalLightAccent)
    }
}

// MARK: - LightAccent

/// Override bundle for the accent-family tokens used by `palette(isDark: false)`.
/// Paper surfaces + text are shared across every theme (white-on-white would
/// fail contrast — only Terminal has a dedicated paper spec in the CSS), but
/// the accent + its tints + the on-accent foreground swap per theme so the
/// user's pick remains visible in Light Mode.
nonisolated struct LightAccent: Sendable {
    /// Saturated accent colour for buttons, focus rings, selected chips.
    /// Contrast-corrected (~darkened ~30%) so it reads on `#E9EAEC` paper.
    let accent: UInt64
    /// Subtle wash for hover / selection backgrounds.
    let accentTint: UInt64
    /// Stronger wash for selected template cards / team selector icons.
    let accentTintStrong: UInt64
    /// Outline / focus ring color.
    let accentBorder: UInt64
    /// Text or icon laid OVER an accent-fill (light-on-accent in Light Mode).
    let textOnAccent: UInt64
}

// MARK: - ThemePalette

/// One concrete palette: every hex value Colors.swift needs to render the UI.
/// Modelled directly on the `--nt-*` custom properties in
/// `DesignSystem/tokens/colors.css`.
nonisolated struct ThemePalette: Sendable {
    // Status core
    let success: UInt64
    let warning: UInt64
    let error: UInt64
    let info: UInt64
    let neutral: UInt64

    // Extended status palette
    let purple: UInt64
    let artifact: UInt64
    let teal: UInt64
    let yellow: UInt64
    let indigo: UInt64
    let pink: UInt64
    let cyan: UInt64
    let mint: UInt64
    let brown: UInt64
    let emerald: UInt64
    let gold: UInt64
    let dim: UInt64

    // Surfaces
    let surfaceBackground: UInt64
    let surfacePrimary: UInt64
    let surfaceCard: UInt64
    let surfaceElevated: UInt64
    let surfaceElevatedSubtle: UInt64
    let surfaceHover: UInt64
    let surfaceOverlay: UInt64
    let surfaceOverlayStrong: UInt64

    // Borders
    let borderSubtle: UInt64
    let borderStrong: UInt64

    // Accent / signal
    let accent: UInt64

    // Tints
    let successTint: UInt64
    let warningTint: UInt64
    let errorTint: UInt64
    let infoTint: UInt64
    let purpleTint: UInt64
    let artifactTint: UInt64
    let cyanTint: UInt64
    let yellowTint: UInt64
    let neutralTint: UInt64
    let dimTint: UInt64
    let emeraldTint: UInt64

    // Status borders
    let errorBorder: UInt64
    let neutralBorder: UInt64

    // Accent tints
    let accentTint: UInt64
    let accentTintStrong: UInt64
    let accentBorder: UInt64

    // Text
    let textPrimary: UInt64
    let textSecondary: UInt64
    let textTertiary: UInt64
    let textQuaternary: UInt64
    let textOnAccent: UInt64

    /// Returns a copy of this palette with the accent family replaced.
    /// Used by `Theme.palette(isDark: false)` to layer a theme-specific accent
    /// on top of the shared paper surfaces.
    func withAccent(_ override: LightAccent) -> ThemePalette {
        ThemePalette(
            success: success, warning: warning, error: error, info: info, neutral: neutral,
            purple: purple, artifact: artifact, teal: teal, yellow: yellow, indigo: indigo,
            pink: pink, cyan: cyan, mint: mint, brown: brown, emerald: emerald, gold: gold,
            dim: dim,
            surfaceBackground: surfaceBackground, surfacePrimary: surfacePrimary,
            surfaceCard: surfaceCard, surfaceElevated: surfaceElevated,
            surfaceElevatedSubtle: surfaceElevatedSubtle, surfaceHover: surfaceHover,
            surfaceOverlay: surfaceOverlay, surfaceOverlayStrong: surfaceOverlayStrong,
            borderSubtle: borderSubtle, borderStrong: borderStrong,
            accent: override.accent,
            successTint: successTint, warningTint: warningTint, errorTint: errorTint,
            infoTint: infoTint, purpleTint: purpleTint, artifactTint: artifactTint,
            cyanTint: cyanTint, yellowTint: yellowTint, neutralTint: neutralTint,
            dimTint: dimTint, emeraldTint: emeraldTint,
            errorBorder: errorBorder, neutralBorder: neutralBorder,
            accentTint: override.accentTint,
            accentTintStrong: override.accentTintStrong,
            accentBorder: override.accentBorder,
            textPrimary: textPrimary, textSecondary: textSecondary,
            textTertiary: textTertiary, textQuaternary: textQuaternary,
            textOnAccent: override.textOnAccent
        )
    }
}

// MARK: - Palette data
// Values transcribed from `DesignSystem/tokens/colors.css`. Each theme block in
// the CSS maps 1:1 to one entry below. The original `Colors.swift` literals
// (which seeded this file) live in `terminalDark` + `lightPaper`.

// `nonisolated` because the app target's default actor isolation is `@MainActor`;
// without this, every `static let` palette below becomes main-actor-isolated and
// the `nsThemed` provider closure (called from AppKit's appearance thread) can't
// read them.
nonisolated extension Theme {

    // MARK: Light paper (shared)

    /// Warm paper light — shared by every theme when the effective scheme is light.
    static let lightPaper = ThemePalette(
        success: 0x505357,
        warning: 0x5B568A,
        error: 0xA8503F,
        info: 0x5B568A,
        neutral: 0x6C6F73,
        purple: 0x7C7F83,
        artifact: 0x505357,
        teal: 0x6C6F73,
        yellow: 0x5B568A,
        indigo: 0x505357,
        pink: 0x6C6F73,
        cyan: 0x6C6F73,
        mint: 0x505357,
        brown: 0x7C7F83,
        emerald: 0x2A2C2E,
        gold: 0x5B568A,
        dim: 0xA8ABAF,
        surfaceBackground: 0xDEDFE1,
        surfacePrimary: 0xE9EAEC,
        surfaceCard: 0xF4F5F6,
        surfaceElevated: 0xFFFFFF,
        surfaceElevatedSubtle: 0xECEDEF,
        surfaceHover: 0xE2E3E6,
        surfaceOverlay: 0xECEDEF,
        surfaceOverlayStrong: 0xF4F5F6,
        borderSubtle: 0xD5D7DA,
        borderStrong: 0xB5B7BA,
        accent: 0x5B568A,
        successTint: 0xE4E5E8,
        warningTint: 0xE7E6F0,
        errorTint: 0xF2DED8,
        infoTint: 0xE7E6F0,
        purpleTint: 0xE4E5E8,
        artifactTint: 0xECEDEF,
        cyanTint: 0xE4E5E8,
        yellowTint: 0xE7E6F0,
        neutralTint: 0xE8E9EB,
        dimTint: 0xEAEBED,
        emeraldTint: 0xDEDFE2,
        errorBorder: 0xE7C9C1,
        neutralBorder: 0xBBBEC2,
        accentTint: 0xE7E6F0,
        accentTintStrong: 0xDED9F0,
        accentBorder: 0xC7C4DE,
        textPrimary: 0x2A2C2E,
        textSecondary: 0x505357,
        textTertiary: 0x7C7F83,
        textQuaternary: 0xA8ABAF,
        textOnAccent: 0xF4F5F6
    )

    // MARK: Parchment

    static let parchmentLight = ThemePalette(
        success: 0x6B7A0E,
        warning: 0x1E73AE,
        error: 0xC5302D,
        info: 0x1E73AE,
        neutral: 0x2A857C,
        purple: 0x5A5FB0,
        artifact: 0x6B7A0E,
        teal: 0x2A857C,
        yellow: 0x98700E,
        indigo: 0x2A857C,
        pink: 0x5A5FB0,
        cyan: 0x2A857C,
        mint: 0x6B7A0E,
        brown: 0x5A5FB0,
        emerald: 0x6B7A0E,
        gold: 0x98700E,
        dim: 0x9AA8A6,
        surfaceBackground: 0xE4DCC4,
        surfacePrimary: 0xEEE8D5,
        surfaceCard: 0xF7F1DE,
        surfaceElevated: 0xFDF6E3,
        surfaceElevatedSubtle: 0xEFE9D6,
        surfaceHover: 0xE8E1CB,
        surfaceOverlay: 0xEFE9D6,
        surfaceOverlayStrong: 0xF7F1DE,
        borderSubtle: 0xDDD5BD,
        borderStrong: 0xC7BE9F,
        accent: 0x1E73AE,
        successTint: 0xE8ECC8,
        warningTint: 0xDCEAF3,
        errorTint: 0xF4DAD3,
        infoTint: 0xDCEAF3,
        purpleTint: 0xE0E1F0,
        artifactTint: 0xE8ECC8,
        cyanTint: 0xD4EAE5,
        yellowTint: 0xEEE6C2,
        neutralTint: 0xE4E2D4,
        dimTint: 0xE4E2D4,
        emeraldTint: 0xE2E8BC,
        errorBorder: 0xE6BFB4,
        neutralBorder: 0xC7BE9F,
        accentTint: 0xDCEAF3,
        accentTintStrong: 0xC8DDEB,
        accentBorder: 0xB6D2E6,
        textPrimary: 0x4A5C62,
        textSecondary: 0x5C7077,
        textTertiary: 0x7C8E8E,
        textQuaternary: 0x9AA8A6,
        textOnAccent: 0xFDF6E3
    )

    // MARK: Mist

    static let mistLight = ThemePalette(
        success: 0x5E7A3E,
        warning: 0x4C6E97,
        error: 0xB04650,
        info: 0x4C6E97,
        neutral: 0x3F7E84,
        purple: 0x8A5C82,
        artifact: 0x5E7A3E,
        teal: 0x3F7E84,
        yellow: 0xA06D1E,
        indigo: 0x3F7E84,
        pink: 0x8A5C82,
        cyan: 0x3F7E84,
        mint: 0x5E7A3E,
        brown: 0x8A5C82,
        emerald: 0x5E7A3E,
        gold: 0xA06D1E,
        dim: 0x99A2B2,
        surfaceBackground: 0xD2D8E4,
        surfacePrimary: 0xE5E9F0,
        surfaceCard: 0xF1F3F8,
        surfaceElevated: 0xFAFBFD,
        surfaceElevatedSubtle: 0xE9EDF3,
        surfaceHover: 0xDCE2EC,
        surfaceOverlay: 0xE9EDF3,
        surfaceOverlayStrong: 0xF1F3F8,
        borderSubtle: 0xD2D8E4,
        borderStrong: 0xB7C0D0,
        accent: 0x4C6E97,
        successTint: 0xE2EAD3,
        warningTint: 0xDCE4F0,
        errorTint: 0xF2DDE0,
        infoTint: 0xDCE4F0,
        purpleTint: 0xEEDFEB,
        artifactTint: 0xE2EAD3,
        cyanTint: 0xD6EAEC,
        yellowTint: 0xF0E4CC,
        neutralTint: 0xE4E7EE,
        dimTint: 0xE4E7EE,
        emeraldTint: 0xDCE8C9,
        errorBorder: 0xE5C1C7,
        neutralBorder: 0xB7C0D0,
        accentTint: 0xDCE4F0,
        accentTintStrong: 0xC8D4E5,
        accentBorder: 0xBAC8DE,
        textPrimary: 0x2E3440,
        textSecondary: 0x434C5E,
        textTertiary: 0x606A7B,
        textQuaternary: 0x99A2B2,
        textOnAccent: 0xFAFBFD
    )

    // MARK: Sand

    static let sandLight = ThemePalette(
        success: 0x79740E,
        warning: 0xAF6712,
        error: 0x9D0006,
        info: 0xAF6712,
        neutral: 0x427B58,
        purple: 0x8F3F71,
        artifact: 0x79740E,
        teal: 0x427B58,
        yellow: 0xB57614,
        indigo: 0x427B58,
        pink: 0x8F3F71,
        cyan: 0x427B58,
        mint: 0x79740E,
        brown: 0x8F3F71,
        emerald: 0x79740E,
        gold: 0xB57614,
        dim: 0xA89984,
        surfaceBackground: 0xECE2C0,
        surfacePrimary: 0xF4E8C8,
        surfaceCard: 0xFAF1D7,
        surfaceElevated: 0xFBF1D5,
        surfaceElevatedSubtle: 0xF3E9CC,
        surfaceHover: 0xEFE3C0,
        surfaceOverlay: 0xF3E9CC,
        surfaceOverlayStrong: 0xFAF1D7,
        borderSubtle: 0xE2D4AC,
        borderStrong: 0xCFBE8F,
        accent: 0xAF6712,
        successTint: 0xEBE9BE,
        warningTint: 0xF1E0C0,
        errorTint: 0xF2D4CE,
        infoTint: 0xF1E0C0,
        purpleTint: 0xF0DAE6,
        artifactTint: 0xEBE9BE,
        cyanTint: 0xDCEAD2,
        yellowTint: 0xF1E4BE,
        neutralTint: 0xECE3CE,
        dimTint: 0xECE3CE,
        emeraldTint: 0xE6E6B2,
        errorBorder: 0xE5B5AC,
        neutralBorder: 0xCFBE8F,
        accentTint: 0xF1E0C0,
        accentTintStrong: 0xE5CDA0,
        accentBorder: 0xDEC79A,
        textPrimary: 0x3C3836,
        textSecondary: 0x5A524C,
        textTertiary: 0x7C6F64,
        textQuaternary: 0xA89984,
        textOnAccent: 0xFBF1D5
    )

    // MARK: Dawn

    static let dawnLight = ThemePalette(
        success: 0x56949F,
        warning: 0x7059A8,
        error: 0xB4637A,
        info: 0x7059A8,
        neutral: 0x56949F,
        purple: 0xA8517A,
        artifact: 0x56949F,
        teal: 0x56949F,
        yellow: 0xB07A1E,
        indigo: 0x286983,
        pink: 0xA8517A,
        cyan: 0x286983,
        mint: 0x56949F,
        brown: 0xA8517A,
        emerald: 0x56949F,
        gold: 0xB07A1E,
        dim: 0xB3AEC6,
        surfaceBackground: 0xEFE4DF,
        surfacePrimary: 0xFAF4ED,
        surfaceCard: 0xFFFAF3,
        surfaceElevated: 0xFFFCF7,
        surfaceElevatedSubtle: 0xFBF0E8,
        surfaceHover: 0xF4E9E0,
        surfaceOverlay: 0xFBF0E8,
        surfaceOverlayStrong: 0xFFFAF3,
        borderSubtle: 0xE9DDD3,
        borderStrong: 0xD7C7BA,
        accent: 0x7059A8,
        successTint: 0xD6EAEC,
        warningTint: 0xE9E2F2,
        errorTint: 0xF4DEE4,
        infoTint: 0xE9E2F2,
        purpleTint: 0xF4DCE6,
        artifactTint: 0xD6EAEC,
        cyanTint: 0xD4E6EC,
        yellowTint: 0xF2E6CC,
        neutralTint: 0xECE7F0,
        dimTint: 0xECE7F0,
        emeraldTint: 0xD0E8EA,
        errorBorder: 0xE6BFC9,
        neutralBorder: 0xD7C7BA,
        accentTint: 0xE9E2F2,
        accentTintStrong: 0xD8CCE8,
        accentBorder: 0xD3C8E6,
        textPrimary: 0x575279,
        textSecondary: 0x6E6A86,
        textTertiary: 0x908CAA,
        textQuaternary: 0xB3AEC6,
        textOnAccent: 0xFFFCF7
    )

    // MARK: Cream

    static let creamLight = ThemePalette(
        success: 0x40A02B,
        warning: 0x8839EF,
        error: 0xD20F39,
        info: 0x8839EF,
        neutral: 0x1E66F5,
        purple: 0xEA76CB,
        artifact: 0x40A02B,
        teal: 0x179299,
        yellow: 0xDF8E1D,
        indigo: 0x179299,
        pink: 0xEA76CB,
        cyan: 0x179299,
        mint: 0x40A02B,
        brown: 0xEA76CB,
        emerald: 0x40A02B,
        gold: 0xDF8E1D,
        dim: 0x9CA0B0,
        surfaceBackground: 0xDCE0E8,
        surfacePrimary: 0xEFF1F5,
        surfaceCard: 0xF7F8FB,
        surfaceElevated: 0xFFFFFF,
        surfaceElevatedSubtle: 0xEBEDF2,
        surfaceHover: 0xE4E7EE,
        surfaceOverlay: 0xEBEDF2,
        surfaceOverlayStrong: 0xF7F8FB,
        borderSubtle: 0xDDE0E8,
        borderStrong: 0xC4C8D4,
        accent: 0x8839EF,
        successTint: 0xDAEED2,
        warningTint: 0xEBE0FB,
        errorTint: 0xF6D6DC,
        infoTint: 0xEBE0FB,
        purpleTint: 0xF6DCF0,
        artifactTint: 0xDAEED2,
        cyanTint: 0xD2EBEC,
        yellowTint: 0xF6E7C8,
        neutralTint: 0xE6E8EE,
        dimTint: 0xE6E8EE,
        emeraldTint: 0xD2EBC8,
        errorBorder: 0xE5B5BF,
        neutralBorder: 0xC4C8D4,
        accentTint: 0xEBE0FB,
        accentTintStrong: 0xDDC9F7,
        accentBorder: 0xD8C6F5,
        textPrimary: 0x4C4F69,
        textSecondary: 0x5C5F77,
        textTertiary: 0x6C6F85,
        textQuaternary: 0x9CA0B0,
        textOnAccent: 0xFFFFFF
    )

    // MARK: Daylight

    static let daylightLight = ThemePalette(
        success: 0x50A14F,
        warning: 0x4078F2,
        error: 0xE45649,
        info: 0x4078F2,
        neutral: 0x0184BC,
        purple: 0xA626A4,
        artifact: 0x50A14F,
        teal: 0x0184BC,
        yellow: 0xC18401,
        indigo: 0x0184BC,
        pink: 0xA626A4,
        cyan: 0x0184BC,
        mint: 0x50A14F,
        brown: 0xA626A4,
        emerald: 0x50A14F,
        gold: 0xC18401,
        dim: 0xA0A1A7,
        surfaceBackground: 0xE4E6E9,
        surfacePrimary: 0xFAFAFA,
        surfaceCard: 0xFFFFFF,
        surfaceElevated: 0xFFFFFF,
        surfaceElevatedSubtle: 0xF2F3F5,
        surfaceHover: 0xECEDEF,
        surfaceOverlay: 0xF2F3F5,
        surfaceOverlayStrong: 0xFFFFFF,
        borderSubtle: 0xDCDEE2,
        borderStrong: 0xC2C5CB,
        accent: 0x4078F2,
        successTint: 0xDCEDD9,
        warningTint: 0xDCE6FC,
        errorTint: 0xF8DCD8,
        infoTint: 0xDCE6FC,
        purpleTint: 0xF0D8EF,
        artifactTint: 0xDCEDD9,
        cyanTint: 0xD2E8F2,
        yellowTint: 0xF2E6C8,
        neutralTint: 0xE8E9EB,
        dimTint: 0xE8E9EB,
        emeraldTint: 0xD4EAD0,
        errorBorder: 0xE7BFBA,
        neutralBorder: 0xC2C5CB,
        accentTint: 0xDCE6FC,
        accentTintStrong: 0xC8D5F7,
        accentBorder: 0xBFD2F8,
        textPrimary: 0x383A42,
        textSecondary: 0x50535B,
        textTertiary: 0x717480,
        textQuaternary: 0xA0A1A7,
        textOnAccent: 0xFFFFFF
    )

    // MARK: Blush

    static let blushLight = ThemePalette(
        success: 0x4FA05A,
        warning: 0xE84D94,
        error: 0xD63A4E,
        info: 0xE84D94,
        neutral: 0x2E8BC0,
        purple: 0xA85BC0,
        artifact: 0x4FA05A,
        teal: 0x2E8BC0,
        yellow: 0xC5851E,
        indigo: 0x2E8BC0,
        pink: 0xA85BC0,
        cyan: 0x2E8BC0,
        mint: 0x4FA05A,
        brown: 0xA85BC0,
        emerald: 0x4FA05A,
        gold: 0xC5851E,
        dim: 0xC2A0B2,
        surfaceBackground: 0xF2D9E4,
        surfacePrimary: 0xFDEEF4,
        surfaceCard: 0xFFF6FA,
        surfaceElevated: 0xFFFFFF,
        surfaceElevatedSubtle: 0xFCEAF1,
        surfaceHover: 0xF8E2EC,
        surfaceOverlay: 0xFCEAF1,
        surfaceOverlayStrong: 0xFFF6FA,
        borderSubtle: 0xF0D6E1,
        borderStrong: 0xE0B8CB,
        accent: 0xE84D94,
        successTint: 0xDBEDD9,
        warningTint: 0xFBDDEC,
        errorTint: 0xF8DCDF,
        infoTint: 0xFBDDEC,
        purpleTint: 0xEEDDF2,
        artifactTint: 0xDBEDD9,
        cyanTint: 0xD6EAF4,
        yellowTint: 0xF2E6C8,
        neutralTint: 0xF2E4EA,
        dimTint: 0xF2E4EA,
        emeraldTint: 0xD2EAD0,
        errorBorder: 0xEABEC1,
        neutralBorder: 0xE0B8CB,
        accentTint: 0xFBDDEC,
        accentTintStrong: 0xF6C2DC,
        accentBorder: 0xF2C2DC,
        textPrimary: 0x5A3247,
        textSecondary: 0x784A60,
        textTertiary: 0x9E7488,
        textQuaternary: 0xC2A0B2,
        textOnAccent: 0xFFFFFF
    )

    // MARK: Terminal (default dark)

    static let terminalDark = ThemePalette(
        success: 0xA8AAAE,
        warning: 0xA29DCE,
        error: 0xC76E5E,
        info: 0xA8A9B1,
        neutral: 0x8E9094,
        purple: 0x76787F,
        artifact: 0xA8AAAE,
        teal: 0x8E9094,
        yellow: 0xA29DCE,
        indigo: 0xBFC0C4,
        pink: 0x8E9094,
        cyan: 0x8E9094,
        mint: 0xA8AAAE,
        brown: 0x76787F,
        emerald: 0xDEDEE3,
        gold: 0xA29DCE,
        dim: 0x4E4F57,
        surfaceBackground: 0x141319,
        surfacePrimary: 0x1A191F,
        surfaceCard: 0x201F27,
        surfaceElevated: 0x2E2D38,
        surfaceElevatedSubtle: 0x27262F,
        surfaceHover: 0x34323F,
        surfaceOverlay: 0x100F15,
        surfaceOverlayStrong: 0x0A090E,
        borderSubtle: 0x2A2934,
        borderStrong: 0x3C3A49,
        accent: 0xA29DCE,
        successTint: 0x26282D,
        warningTint: 0x211E31,
        errorTint: 0x2D1B17,
        infoTint: 0x25262C,
        purpleTint: 0x232229,
        artifactTint: 0x26282D,
        cyanTint: 0x25262C,
        yellowTint: 0x211E31,
        neutralTint: 0x25262C,
        dimTint: 0x1E1D24,
        emeraldTint: 0x2A2933,
        errorBorder: 0x4D2B22,
        neutralBorder: 0x3C3A49,
        accentTint: 0x211E31,
        accentTintStrong: 0x2A2640,
        accentBorder: 0x3E3A59,
        textPrimary: 0xDEDEE3,
        textSecondary: 0xA8A9B1,
        textTertiary: 0x76787F,
        textQuaternary: 0x4E4F57,
        textOnAccent: 0x1A191F
    )

    // MARK: OLED

    static let oledDark = ThemePalette(
        success: 0xA6A8AB,
        warning: 0xA6A2CF,
        error: 0xC96F5F,
        info: 0x9A9C9F,
        neutral: 0x8E9092,
        purple: 0x75787C,
        artifact: 0xA6A8AB,
        teal: 0x8E9092,
        yellow: 0xA6A2CF,
        indigo: 0xBDBFC1,
        pink: 0x8E9092,
        cyan: 0x8E9092,
        mint: 0xA6A8AB,
        brown: 0x75787C,
        emerald: 0xECEDEE,
        gold: 0xA6A2CF,
        dim: 0x46484C,
        surfaceBackground: 0x000000,
        surfacePrimary: 0x000000,
        surfaceCard: 0x000000,
        surfaceElevated: 0x000000,
        surfaceElevatedSubtle: 0x000000,
        surfaceHover: 0x0C0C0F,
        surfaceOverlay: 0x000000,
        surfaceOverlayStrong: 0x000000,
        borderSubtle: 0x1E1E23,
        borderStrong: 0x33333A,
        accent: 0xA6A2CF,
        successTint: 0x141416,
        warningTint: 0x14121C,
        errorTint: 0x1E120E,
        infoTint: 0x131315,
        purpleTint: 0x121214,
        artifactTint: 0x141416,
        cyanTint: 0x131315,
        yellowTint: 0x14121C,
        neutralTint: 0x131315,
        dimTint: 0x0C0C0E,
        emeraldTint: 0x161618,
        errorBorder: 0x322521,
        neutralBorder: 0x33333A,
        accentTint: 0x14121C,
        accentTintStrong: 0x1B1828,
        accentBorder: 0x322F47,
        textPrimary: 0xECEDEE,
        textSecondary: 0x9A9C9F,
        textTertiary: 0x6A6D71,
        textQuaternary: 0x3A3C40,
        textOnAccent: 0x000000
    )

    // MARK: Arctic

    static let arcticDark = ThemePalette(
        success: 0xA3BE8C,
        warning: 0x88C0D0,
        error: 0xBF616A,
        info: 0x88C0D0,
        neutral: 0x81A1C1,
        purple: 0xB48EAD,
        artifact: 0xA3BE8C,
        teal: 0x88C0D0,
        yellow: 0xEBCB8B,
        indigo: 0xB48EAD,
        pink: 0xB48EAD,
        cyan: 0x88C0D0,
        mint: 0xA3BE8C,
        brown: 0xB48EAD,
        emerald: 0xECEFF4,
        gold: 0xEBCB8B,
        dim: 0x4C566A,
        surfaceBackground: 0x2B303B,
        surfacePrimary: 0x2E3440,
        surfaceCard: 0x353C49,
        surfaceElevated: 0x434C5E,
        surfaceElevatedSubtle: 0x3B4252,
        surfaceHover: 0x4C566A,
        surfaceOverlay: 0x252A33,
        surfaceOverlayStrong: 0x1E2229,
        borderSubtle: 0x3B4252,
        borderStrong: 0x4C566A,
        accent: 0x88C0D0,
        successTint: 0x2E3A2C,
        warningTint: 0x2A3A42,
        errorTint: 0x3A2226,
        infoTint: 0x2A3A42,
        purpleTint: 0x342B34,
        artifactTint: 0x2E3A2C,
        cyanTint: 0x2C3744,
        yellowTint: 0x3A3528,
        neutralTint: 0x2A303B,
        dimTint: 0x242931,
        emeraldTint: 0x33402F,
        errorBorder: 0x553334,
        neutralBorder: 0x4C566A,
        accentTint: 0x2A3A42,
        accentTintStrong: 0x2F4754,
        accentBorder: 0x3E5560,
        textPrimary: 0xECEFF4,
        textSecondary: 0xD8DEE9,
        textTertiary: 0x9AA3B2,
        textQuaternary: 0x66707F,
        textOnAccent: 0x2E3440
    )

    // MARK: Indigo

    static let indigoDark = ThemePalette(
        success: 0x9ECE6A,
        warning: 0x7AA2F7,
        error: 0xF7768E,
        info: 0x7AA2F7,
        neutral: 0x7DCFFF,
        purple: 0xBB9AF7,
        artifact: 0x9ECE6A,
        teal: 0x7DCFFF,
        yellow: 0xFF9E64,
        indigo: 0x7DCFFF,
        pink: 0xBB9AF7,
        cyan: 0x7DCFFF,
        mint: 0x9ECE6A,
        brown: 0xBB9AF7,
        emerald: 0xC0CAF5,
        gold: 0xFF9E64,
        dim: 0x414868,
        surfaceBackground: 0x16161E,
        surfacePrimary: 0x1A1B26,
        surfaceCard: 0x1F2335,
        surfaceElevated: 0x292E42,
        surfaceElevatedSubtle: 0x24283B,
        surfaceHover: 0x343A52,
        surfaceOverlay: 0x131420,
        surfaceOverlayStrong: 0x0E0E17,
        borderSubtle: 0x232741,
        borderStrong: 0x3B4261,
        accent: 0x7AA2F7,
        successTint: 0x243321,
        warningTint: 0x1B2540,
        errorTint: 0x3A1D27,
        infoTint: 0x1B2540,
        purpleTint: 0x2C2440,
        artifactTint: 0x283A24,
        cyanTint: 0x14303E,
        yellowTint: 0x382617,
        neutralTint: 0x1C2031,
        dimTint: 0x16182A,
        emeraldTint: 0x283A24,
        errorBorder: 0x5A2D3B,
        neutralBorder: 0x3B4261,
        accentTint: 0x1B2540,
        accentTintStrong: 0x21305A,
        accentBorder: 0x2E3E63,
        textPrimary: 0xC0CAF5,
        textSecondary: 0x9AA5CE,
        textTertiary: 0x565F89,
        textQuaternary: 0x3B4261,
        textOnAccent: 0x16161E
    )

    // MARK: Umber

    static let umberDark = ThemePalette(
        success: 0xB8BB26,
        warning: 0xFE8019,
        error: 0xFB4934,
        info: 0xFE8019,
        neutral: 0x83A598,
        purple: 0xD3869B,
        artifact: 0xB8BB26,
        teal: 0x83A598,
        yellow: 0xFABD2F,
        indigo: 0xD3869B,
        pink: 0xD3869B,
        cyan: 0x83A598,
        mint: 0xB8BB26,
        brown: 0xD3869B,
        emerald: 0xEBDBB2,
        gold: 0xFABD2F,
        dim: 0x665C54,
        surfaceBackground: 0x1D2021,
        surfacePrimary: 0x282828,
        surfaceCard: 0x32302F,
        surfaceElevated: 0x504945,
        surfaceElevatedSubtle: 0x3C3836,
        surfaceHover: 0x5A524C,
        surfaceOverlay: 0x1F1F1F,
        surfaceOverlayStrong: 0x161717,
        borderSubtle: 0x3C3836,
        borderStrong: 0x504945,
        accent: 0xFE8019,
        successTint: 0x30310F,
        warningTint: 0x3A2811,
        errorTint: 0x3C1A14,
        infoTint: 0x3A2811,
        purpleTint: 0x352630,
        artifactTint: 0x30310F,
        cyanTint: 0x243029,
        yellowTint: 0x393012,
        neutralTint: 0x2A2724,
        dimTint: 0x23211E,
        emeraldTint: 0x353611,
        errorBorder: 0x582822,
        neutralBorder: 0x504945,
        accentTint: 0x3A2811,
        accentTintStrong: 0x4A3618,
        accentBorder: 0x5E3D17,
        textPrimary: 0xEBDBB2,
        textSecondary: 0xD5C4A1,
        textTertiary: 0xA89984,
        textQuaternary: 0x7C6F64,
        textOnAccent: 0x1D2021
    )

    // MARK: Lilac

    static let lilacDark = ThemePalette(
        success: 0xA6E3A1,
        warning: 0xCBA6F7,
        error: 0xF38BA8,
        info: 0xCBA6F7,
        neutral: 0x89B4FA,
        purple: 0xF5C2E7,
        artifact: 0xA6E3A1,
        teal: 0x89DCEB,
        yellow: 0xFAB387,
        indigo: 0xCBA6F7,
        pink: 0xF5C2E7,
        cyan: 0x89DCEB,
        mint: 0xA6E3A1,
        brown: 0xF5C2E7,
        emerald: 0xCDD6F4,
        gold: 0xFAB387,
        dim: 0x45475A,
        surfaceBackground: 0x181825,
        surfacePrimary: 0x1E1E2E,
        surfaceCard: 0x24243A,
        surfaceElevated: 0x45475A,
        surfaceElevatedSubtle: 0x313244,
        surfaceHover: 0x51526A,
        surfaceOverlay: 0x16162A,
        surfaceOverlayStrong: 0x101020,
        borderSubtle: 0x2C2C42,
        borderStrong: 0x45475A,
        accent: 0xCBA6F7,
        successTint: 0x243A26,
        warningTint: 0x2E2740,
        errorTint: 0x3A1F2A,
        infoTint: 0x2E2740,
        purpleTint: 0x3A2C38,
        artifactTint: 0x243A26,
        cyanTint: 0x1F2C40,
        yellowTint: 0x3A2A1D,
        neutralTint: 0x20212F,
        dimTint: 0x1A1B27,
        emeraldTint: 0x28402A,
        errorBorder: 0x582F3D,
        neutralBorder: 0x45475A,
        accentTint: 0x2E2740,
        accentTintStrong: 0x3A2F54,
        accentBorder: 0x4A3E66,
        textPrimary: 0xCDD6F4,
        textSecondary: 0xBAC2DE,
        textTertiary: 0xA6ADC8,
        textQuaternary: 0x6C7086,
        textOnAccent: 0x1E1E2E
    )

    // MARK: Marine

    static let marineDark = ThemePalette(
        success: 0x859900,
        warning: 0x268BD2,
        error: 0xDC322F,
        info: 0x268BD2,
        neutral: 0x2AA198,
        purple: 0x6C71C4,
        artifact: 0x859900,
        teal: 0x2AA198,
        yellow: 0xB58900,
        indigo: 0x6C71C4,
        pink: 0xD33682,
        cyan: 0x2AA198,
        mint: 0x859900,
        brown: 0x6C71C4,
        emerald: 0x93A1A1,
        gold: 0xB58900,
        dim: 0x586E75,
        surfaceBackground: 0x00252E,
        surfacePrimary: 0x002B36,
        surfaceCard: 0x073642,
        surfaceElevated: 0x0E4C5C,
        surfaceElevatedSubtle: 0x0A4250,
        surfaceHover: 0x145667,
        surfaceOverlay: 0x002028,
        surfaceOverlayStrong: 0x001820,
        borderSubtle: 0x0B404E,
        borderStrong: 0x1A5B6B,
        accent: 0x268BD2,
        successTint: 0x1E2C00,
        warningTint: 0x042F40,
        errorTint: 0x340F0E,
        infoTint: 0x042F40,
        purpleTint: 0x1C1F3A,
        artifactTint: 0x1E2C00,
        cyanTint: 0x053634,
        yellowTint: 0x2E2400,
        neutralTint: 0x042830,
        dimTint: 0x031F26,
        emeraldTint: 0x243300,
        errorBorder: 0x4D1B1A,
        neutralBorder: 0x1A5B6B,
        accentTint: 0x042F40,
        accentTintStrong: 0x093F55,
        accentBorder: 0x11506B,
        textPrimary: 0x93A1A1,
        textSecondary: 0x839496,
        textTertiary: 0x657B83,
        textQuaternary: 0x586E75,
        textOnAccent: 0x002B36
    )

    // MARK: Steel

    static let steelDark = ThemePalette(
        success: 0x98C379,
        warning: 0x61AFEF,
        error: 0xE06C75,
        info: 0x61AFEF,
        neutral: 0x56B6C2,
        purple: 0xC678DD,
        artifact: 0x98C379,
        teal: 0x56B6C2,
        yellow: 0xD19A66,
        indigo: 0xC678DD,
        pink: 0xC678DD,
        cyan: 0x56B6C2,
        mint: 0x98C379,
        brown: 0xC678DD,
        emerald: 0xABB2BF,
        gold: 0xD19A66,
        dim: 0x4B5263,
        surfaceBackground: 0x21252B,
        surfacePrimary: 0x282C34,
        surfaceCard: 0x2C313A,
        surfaceElevated: 0x3A4048,
        surfaceElevatedSubtle: 0x31363F,
        surfaceHover: 0x3E4451,
        surfaceOverlay: 0x1E2228,
        surfaceOverlayStrong: 0x171A1F,
        borderSubtle: 0x353B45,
        borderStrong: 0x4B5263,
        accent: 0x61AFEF,
        successTint: 0x243522,
        warningTint: 0x1A2C3C,
        errorTint: 0x341C20,
        infoTint: 0x1A2C3C,
        purpleTint: 0x2E1F38,
        artifactTint: 0x243522,
        cyanTint: 0x143033,
        yellowTint: 0x33271A,
        neutralTint: 0x23272F,
        dimTint: 0x1C1F26,
        emeraldTint: 0x283A24,
        errorBorder: 0x5A2B30,
        neutralBorder: 0x4B5263,
        accentTint: 0x1A2C3C,
        accentTintStrong: 0x223A4F,
        accentBorder: 0x2C4660,
        textPrimary: 0xABB2BF,
        textSecondary: 0x9098A4,
        textTertiary: 0x6B727D,
        textQuaternary: 0x5C6370,
        textOnAccent: 0x282C34
    )

    // MARK: Plum

    static let plumDark = ThemePalette(
        success: 0x9CCFD8,
        warning: 0xC4A7E7,
        error: 0xEB6F92,
        info: 0xC4A7E7,
        neutral: 0x9CCFD8,
        purple: 0xEBBCBA,
        artifact: 0x9CCFD8,
        teal: 0x9CCFD8,
        yellow: 0xF6C177,
        indigo: 0x31748F,
        pink: 0xEBBCBA,
        cyan: 0x9CCFD8,
        mint: 0x9CCFD8,
        brown: 0xEBBCBA,
        emerald: 0xE0DEF4,
        gold: 0xF6C177,
        dim: 0x524F67,
        surfaceBackground: 0x16141F,
        surfacePrimary: 0x191724,
        surfaceCard: 0x1F1D2E,
        surfaceElevated: 0x2A273F,
        surfaceElevatedSubtle: 0x26233A,
        surfaceHover: 0x403D52,
        surfaceOverlay: 0x14121C,
        surfaceOverlayStrong: 0x0E0D16,
        borderSubtle: 0x2A2837,
        borderStrong: 0x403D52,
        accent: 0xC4A7E7,
        successTint: 0x163A40,
        warningTint: 0x2A2440,
        errorTint: 0x381A26,
        infoTint: 0x2A2440,
        purpleTint: 0x382C2E,
        artifactTint: 0x163A40,
        cyanTint: 0x14333A,
        yellowTint: 0x3A2C14,
        neutralTint: 0x211F2E,
        dimTint: 0x1A1925,
        emeraldTint: 0x1A4047,
        errorBorder: 0x55293A,
        neutralBorder: 0x403D52,
        accentTint: 0x2A2440,
        accentTintStrong: 0x352D52,
        accentBorder: 0x443B63,
        textPrimary: 0xE0DEF4,
        textSecondary: 0x908CAA,
        textTertiary: 0x6E6A86,
        textQuaternary: 0x524F67,
        textOnAccent: 0x191724
    )

    // MARK: Forest

    static let forestDark = ThemePalette(
        success: 0x83C092,
        warning: 0xA7C080,
        error: 0xE67E80,
        info: 0xA7C080,
        neutral: 0x7FBBB3,
        purple: 0xD699B6,
        artifact: 0x83C092,
        teal: 0x7FBBB3,
        yellow: 0xDBBC7F,
        indigo: 0x7FBBB3,
        pink: 0xD699B6,
        cyan: 0x7FBBB3,
        mint: 0x83C092,
        brown: 0xD699B6,
        emerald: 0xD3C6AA,
        gold: 0xDBBC7F,
        dim: 0x4F585E,
        surfaceBackground: 0x272E33,
        surfacePrimary: 0x2D353B,
        surfaceCard: 0x343F44,
        surfaceElevated: 0x475258,
        surfaceElevatedSubtle: 0x3D484D,
        surfaceHover: 0x4F585E,
        surfaceOverlay: 0x232A2E,
        surfaceOverlayStrong: 0x1B2125,
        borderSubtle: 0x3D484D,
        borderStrong: 0x4F585E,
        accent: 0xA7C080,
        successTint: 0x213829,
        warningTint: 0x2E3826,
        errorTint: 0x381F20,
        infoTint: 0x2E3826,
        purpleTint: 0x342530,
        artifactTint: 0x213829,
        cyanTint: 0x223633,
        yellowTint: 0x382F1C,
        neutralTint: 0x2A3236,
        dimTint: 0x232A2D,
        emeraldTint: 0x25402E,
        errorBorder: 0x552E2F,
        neutralBorder: 0x4F585E,
        accentTint: 0x2E3826,
        accentTintStrong: 0x394A2C,
        accentBorder: 0x455039,
        textPrimary: 0xD3C6AA,
        textSecondary: 0x9DA9A0,
        textTertiary: 0x859289,
        textQuaternary: 0x7A8478,
        textOnAccent: 0x2D353B
    )

    // MARK: Amber

    static let amberDark = ThemePalette(
        success: 0xBAE67E,
        warning: 0xFFCC66,
        error: 0xFF6666,
        info: 0xFFCC66,
        neutral: 0x5CCFE6,
        purple: 0xDABAFA,
        artifact: 0xBAE67E,
        teal: 0x5CCFE6,
        yellow: 0xFFA759,
        indigo: 0x5CCFE6,
        pink: 0xDABAFA,
        cyan: 0x5CCFE6,
        mint: 0xBAE67E,
        brown: 0xDABAFA,
        emerald: 0xCCCAC2,
        gold: 0xFFA759,
        dim: 0x3E4654,
        surfaceBackground: 0x1A1F29,
        surfacePrimary: 0x1F2430,
        surfaceCard: 0x232834,
        surfaceElevated: 0x343A47,
        surfaceElevatedSubtle: 0x2A303C,
        surfaceHover: 0x34455A,
        surfaceOverlay: 0x171C26,
        surfaceOverlayStrong: 0x11151D,
        borderSubtle: 0x2A2F3A,
        borderStrong: 0x3E4654,
        accent: 0xFFCC66,
        successTint: 0x2C3A1A,
        warningTint: 0x3A300F,
        errorTint: 0x3A1C1C,
        infoTint: 0x3A300F,
        purpleTint: 0x2E2540,
        artifactTint: 0x2C3A1A,
        cyanTint: 0x103138,
        yellowTint: 0x382615,
        neutralTint: 0x20252F,
        dimTint: 0x191D27,
        emeraldTint: 0x31401F,
        errorBorder: 0x582B2B,
        neutralBorder: 0x3E4654,
        accentTint: 0x3A300F,
        accentTintStrong: 0x4D3F17,
        accentBorder: 0x5E4D1B,
        textPrimary: 0xCCCAC2,
        textSecondary: 0xA6A8A0,
        textTertiary: 0x707A8C,
        textQuaternary: 0x5C6773,
        textOnAccent: 0x1F2430
    )

    // MARK: Amethyst

    static let amethystDark = ThemePalette(
        success: 0x50FA7B,
        warning: 0xBD93F9,
        error: 0xFF5555,
        info: 0xBD93F9,
        neutral: 0x8BE9FD,
        purple: 0xFF79C6,
        artifact: 0x50FA7B,
        teal: 0x8BE9FD,
        yellow: 0xFFB86C,
        indigo: 0xBD93F9,
        pink: 0xFF79C6,
        cyan: 0x8BE9FD,
        mint: 0x50FA7B,
        brown: 0xFF79C6,
        emerald: 0xF8F8F2,
        gold: 0xFFB86C,
        dim: 0x565973,
        surfaceBackground: 0x21222C,
        surfacePrimary: 0x282A36,
        surfaceCard: 0x2D2F3D,
        surfaceElevated: 0x3C3F51,
        surfaceElevatedSubtle: 0x343746,
        surfaceHover: 0x44475A,
        surfaceOverlay: 0x1E1F28,
        surfaceOverlayStrong: 0x16171F,
        borderSubtle: 0x383A4A,
        borderStrong: 0x4A4D63,
        accent: 0xBD93F9,
        successTint: 0x16321F,
        warningTint: 0x2C2742,
        errorTint: 0x3A1A1C,
        infoTint: 0x2C2742,
        purpleTint: 0x381F30,
        artifactTint: 0x16321F,
        cyanTint: 0x173138,
        yellowTint: 0x332512,
        neutralTint: 0x232532,
        dimTint: 0x1B1D27,
        emeraldTint: 0x1A3B25,
        errorBorder: 0x562628,
        neutralBorder: 0x4A4D63,
        accentTint: 0x2C2742,
        accentTintStrong: 0x39305A,
        accentBorder: 0x4C3E6E,
        textPrimary: 0xF8F8F2,
        textSecondary: 0xC9CAD6,
        textTertiary: 0x8A8DA3,
        textQuaternary: 0x5C5F76,
        textOnAccent: 0x21222C
    )

    // MARK: Neon

    static let neonDark = ThemePalette(
        success: 0xA6E22E,
        warning: 0x66D9EF,
        error: 0xF92672,
        info: 0x66D9EF,
        neutral: 0x66D9EF,
        purple: 0xAE81FF,
        artifact: 0xA6E22E,
        teal: 0x66D9EF,
        yellow: 0xFD971F,
        indigo: 0x66D9EF,
        pink: 0xAE81FF,
        cyan: 0x66D9EF,
        mint: 0xA6E22E,
        brown: 0xAE81FF,
        emerald: 0xF8F8F2,
        gold: 0xFD971F,
        dim: 0x57584D,
        surfaceBackground: 0x1E1F1C,
        surfacePrimary: 0x272822,
        surfaceCard: 0x2D2E28,
        surfaceElevated: 0x3E3F36,
        surfaceElevatedSubtle: 0x34352E,
        surfaceHover: 0x49483E,
        surfaceOverlay: 0x1B1C18,
        surfaceOverlayStrong: 0x131410,
        borderSubtle: 0x3B3C34,
        borderStrong: 0x57584D,
        accent: 0x66D9EF,
        successTint: 0x2C3A0D,
        warningTint: 0x103138,
        errorTint: 0x3A0F22,
        infoTint: 0x103138,
        purpleTint: 0x271B3C,
        artifactTint: 0x2C3A0D,
        cyanTint: 0x123138,
        yellowTint: 0x382209,
        neutralTint: 0x2B2C25,
        dimTint: 0x21221C,
        emeraldTint: 0x313F12,
        errorBorder: 0x55193D,
        neutralBorder: 0x57584D,
        accentTint: 0x103138,
        accentTintStrong: 0x174450,
        accentBorder: 0x1E4954,
        textPrimary: 0xF8F8F2,
        textSecondary: 0xCFD0C2,
        textTertiary: 0x908E79,
        textQuaternary: 0x75715E,
        textOnAccent: 0x272822
    )

    // MARK: Rose

    static let roseDark = ThemePalette(
        success: 0x8FD89A,
        warning: 0xFF7FB6,
        error: 0xFF6B7D,
        info: 0xFF7FB6,
        neutral: 0x6FB5E8,
        purple: 0xC792E8,
        artifact: 0x8FD89A,
        teal: 0x6FB5E8,
        yellow: 0xF2B36C,
        indigo: 0x6FB5E8,
        pink: 0xC792E8,
        cyan: 0x6FB5E8,
        mint: 0x8FD89A,
        brown: 0xC792E8,
        emerald: 0x8FD89A,
        gold: 0xF2B36C,
        dim: 0x6E5666,
        surfaceBackground: 0x1A1118,
        surfacePrimary: 0x20151F,
        surfaceCard: 0x271A28,
        surfaceElevated: 0x38273B,
        surfaceElevatedSubtle: 0x2F2031,
        surfaceHover: 0x43304A,
        surfaceOverlay: 0x1C1018,
        surfaceOverlayStrong: 0x140B12,
        borderSubtle: 0x33233A,
        borderStrong: 0x4C3654,
        accent: 0xFF7FB6,
        successTint: 0x1E3624,
        warningTint: 0x3A1F30,
        errorTint: 0x3A1C24,
        infoTint: 0x3A1F30,
        purpleTint: 0x2E2440,
        artifactTint: 0x1E3624,
        cyanTint: 0x16303E,
        yellowTint: 0x382816,
        neutralTint: 0x241A22,
        dimTint: 0x1F1620,
        emeraldTint: 0x223A28,
        errorBorder: 0x582833,
        neutralBorder: 0x4C3654,
        accentTint: 0x3A1F30,
        accentTintStrong: 0x4A2940,
        accentBorder: 0x5E3450,
        textPrimary: 0xF8E6EF,
        textSecondary: 0xD7B9CB,
        textTertiary: 0x9E8090,
        textQuaternary: 0x6E5666,
        textOnAccent: 0x20151F
    )

    // MARK: Light accent overrides

    // Accent + tints + on-accent foreground that each theme contributes when
    // the effective color scheme is light. Surfaces / text stay paper. Accent
    // hexes are darkened ~30–40% from each theme's dark-mode signal so they
    // hold contrast on `#E9EAEC` paper. Tints are subtle washes of the accent
    // that read as "tinted gray" on light backgrounds; borders are a step
    // darker for outline visibility.

    /// Terminal — the original paper deepened-lavender (unchanged from prior CSS spec).
    static let terminalLightAccent = LightAccent(
        accent: 0x5B568A,
        accentTint: 0xE7E6F0,
        accentTintStrong: 0xDED9F0,
        accentBorder: 0xC7C4DE,
        textOnAccent: 0xF4F5F6
    )

    static let oledLightAccent = LightAccent(
        accent: 0x5B568A,
        accentTint: 0xE7E6F0,
        accentTintStrong: 0xDED9F0,
        accentBorder: 0xC7C4DE,
        textOnAccent: 0xF4F5F6
    )

    static let arcticLightAccent = LightAccent(
        accent: 0x4F8CA1,
        accentTint: 0xDDE9EE,
        accentTintStrong: 0xCBDDE5,
        accentBorder: 0xA7C5D1,
        textOnAccent: 0xF4F5F6
    )

    static let indigoLightAccent = LightAccent(
        accent: 0x3D6BD0,
        accentTint: 0xDDE2F2,
        accentTintStrong: 0xC7D2EC,
        accentBorder: 0xA0B0E0,
        textOnAccent: 0xF4F5F6
    )

    static let umberLightAccent = LightAccent(
        accent: 0xCC5500,
        accentTint: 0xF4DCC8,
        accentTintStrong: 0xEDC9A8,
        accentBorder: 0xDDA77F,
        textOnAccent: 0xF4F5F6
    )

    static let lilacLightAccent = LightAccent(
        accent: 0x8A5DCF,
        accentTint: 0xE6DCF2,
        accentTintStrong: 0xD8C7EB,
        accentBorder: 0xBFA4DE,
        textOnAccent: 0xF4F5F6
    )

    static let marineLightAccent = LightAccent(
        accent: 0x1565A0,
        accentTint: 0xD6E3EE,
        accentTintStrong: 0xBED1E2,
        accentBorder: 0x91B3CE,
        textOnAccent: 0xF4F5F6
    )

    static let steelLightAccent = LightAccent(
        accent: 0x2E7DC5,
        accentTint: 0xDAE6F2,
        accentTintStrong: 0xC1D4EA,
        accentBorder: 0x97B5D8,
        textOnAccent: 0xF4F5F6
    )

    static let plumLightAccent = LightAccent(
        accent: 0x8466B0,
        accentTint: 0xE3DBED,
        accentTintStrong: 0xD2C5E2,
        accentBorder: 0xB6A3D1,
        textOnAccent: 0xF4F5F6
    )

    static let forestLightAccent = LightAccent(
        accent: 0x6E8A4D,
        accentTint: 0xE0E7D5,
        accentTintStrong: 0xCED9BE,
        accentBorder: 0xAEBE94,
        textOnAccent: 0xF4F5F6
    )

    static let amberLightAccent = LightAccent(
        accent: 0xB07A00,
        accentTint: 0xF1E5C0,
        accentTintStrong: 0xE8D49A,
        accentBorder: 0xD3B864,
        textOnAccent: 0xF4F5F6
    )

    static let amethystLightAccent = LightAccent(
        accent: 0x7F4FC4,
        accentTint: 0xE0D4F0,
        accentTintStrong: 0xCEBBE7,
        accentBorder: 0xAE92D5,
        textOnAccent: 0xF4F5F6
    )

    static let neonLightAccent = LightAccent(
        accent: 0x1F8FA8,
        accentTint: 0xD4E8ED,
        accentTintStrong: 0xBCDBE3,
        accentBorder: 0x8DBCC8,
        textOnAccent: 0xF4F5F6
    )

    static let roseLightAccent = LightAccent(
        accent: 0xC2376A,
        accentTint: 0xF4DCE6,
        accentTintStrong: 0xEDC2D8,
        accentBorder: 0xDC9DC0,
        textOnAccent: 0xF4F5F6
    )

    // MARK: Lookup maps

    /// Theme → dark palette. Built once at module load (constant data).
    /// `.system` and every explicit light theme map to Terminal dark — for
    /// `.system` it's the dark-mode fallback when the OS resolves to dark;
    /// for light themes it's a defensive default never actually hit
    /// (`.preferredColorScheme(.light)` forces `isDark = false`).
    static let darkPaletteMap: [Theme: ThemePalette] = [
        .system: terminalDark,
        .light: terminalDark,
        .parchment: terminalDark,
        .mist: terminalDark,
        .sand: terminalDark,
        .dawn: terminalDark,
        .cream: terminalDark,
        .daylight: terminalDark,
        .blush: terminalDark,
        .terminal: terminalDark,
        .oled: oledDark,
        .arctic: arcticDark,
        .indigo: indigoDark,
        .umber: umberDark,
        .lilac: lilacDark,
        .marine: marineDark,
        .steel: steelDark,
        .plum: plumDark,
        .forest: forestDark,
        .amber: amberDark,
        .amethyst: amethystDark,
        .neon: neonDark,
        .rose: roseDark
    ]

    /// Theme → full light palette. Only themes with their OWN explicit light
    /// surfaces appear here; consulted by `palette(isDark: false)` BEFORE the
    /// `lightPaper.withAccent(...)` fallback used by dark-only themes.
    static let lightPaletteMap: [Theme: ThemePalette] = [
        .light: lightPaper,
        .parchment: parchmentLight,
        .mist: mistLight,
        .sand: sandLight,
        .dawn: dawnLight,
        .cream: creamLight,
        .daylight: daylightLight,
        .blush: blushLight
    ]

    /// Theme → light-mode accent override for dark-only themes rendered under a
    /// light scheme (e.g. Terminal forced into light, or stray transitions).
    /// Surfaces + text come from `lightPaper`. Light themes (with dedicated
    /// surfaces in `lightPaletteMap`) bypass this map entirely.
    static let lightAccentMap: [Theme: LightAccent] = [
        .system: terminalLightAccent,
        .terminal: terminalLightAccent,
        .oled: oledLightAccent,
        .arctic: arcticLightAccent,
        .indigo: indigoLightAccent,
        .umber: umberLightAccent,
        .lilac: lilacLightAccent,
        .marine: marineLightAccent,
        .steel: steelLightAccent,
        .plum: plumLightAccent,
        .forest: forestLightAccent,
        .amber: amberLightAccent,
        .amethyst: amethystLightAccent,
        .neon: neonLightAccent,
        .rose: roseLightAccent
    ]
}
