import AppKit
import SwiftUI

/// Semantic color palette — theme-aware adaptive dark/light.
///
/// Every token below is sourced from `Theme.current` (the user-selected theme
/// in UserDefaults) via the `themed(_:)` helper. The dynamic `NSColor` provider
/// inside `themed` resolves the dark / light variant per system color scheme,
/// and the `static var` access pattern means SwiftUI view bodies re-pull fresh
/// values whenever the root `@AppStorage(UserDefaultsKeys.activeTheme)`
/// observer is invalidated.
///
/// To add a new theme: drop a new `ThemePalette` into `Theme.swift` and add it
/// to the `Theme` enum + `darkPaletteMap`. No edits required here.
nonisolated enum Colors {
    // MARK: - Per-theme color cache
    //
    // Keyed by (active theme, token keyPath, alpha). Buys two properties at once:
    //   1. Identity stability WITHIN a theme — repeated `Colors.nsTextPrimary`
    //      (or `Colors.success`) accesses return the SAME instance, so
    //      `NSAttributedString` equality + the NSTextView append / appearance-
    //      restamp short-circuits hold (`ColorsNSIdentityTests`, CLAUDE.md #50),
    //      and SwiftUI view-equality short-circuits aren't defeated by a fresh
    //      `Color` per body read.
    //   2. Freshness ACROSS themes — a SAME-SCHEME theme switch (e.g. Terminal→OLED,
    //      both dark) yields a NEW instance whose AppKit per-appearance resolution
    //      cache is empty, so it resolves the new palette immediately instead of
    //      serving the pre-switch hex until the next app launch (AppKit only
    //      re-invokes a dynamic provider on a dark↔light appearance change, never
    //      on a palette swap within one scheme). The root `.id(activeTheme)`
    //      rebuild re-pulls these accessors, so on-screen AppKit text re-stamps
    //      the fresh color.
    // The dynamic provider captures the theme at creation so a cached entry can't
    // drift if `Theme.current` advances between lookup and a later draw.
    private struct ThemeColorKey: Hashable {
        let theme: String
        let keyPath: AnyKeyPath
        let alphaBits: UInt   // CGFloat.bitPattern is platform-width UInt
    }
    private nonisolated(unsafe) static var nsColorCache: [ThemeColorKey: NSColor] = [:]
    private nonisolated(unsafe) static var colorCache: [ThemeColorKey: Color] = [:]
    // NSLock in a SYNCHRONOUS context (these helpers are non-async) — allowed by
    // Swift 6 (the ban is async-only). The provider closure runs on AppKit's
    // appearance thread but never touches the cache, so the lock only guards the
    // dict mutations on the (mostly-main) accessor thread.
    private static let colorCacheLock = NSLock()

    // MARK: - Themed Color Helpers

    /// Resolves a token from the active theme as a SwiftUI `Color`, memoized per
    /// (theme, token, alpha). Reading the same token repeatedly in a body returns
    /// one stable value; switching themes returns a fresh value (and the
    /// `.id(activeTheme)` root rebuild re-pulls it).
    nonisolated static func themed(_ keyPath: KeyPath<ThemePalette, UInt64>, alpha: CGFloat = 1.0) -> Color {
        let ns = nsThemed(keyPath, alpha: alpha)
        let key = ThemeColorKey(theme: Theme.current.rawValue, keyPath: keyPath, alphaBits: alpha.bitPattern)
        return colorCacheLock.withLock {
            if let cached = colorCache[key] { return cached }
            let color = Color(nsColor: ns)
            colorCache[key] = color
            return color
        }
    }

    /// Like `themed`, but returns the underlying dynamic NSColor so AppKit
    /// consumers (NSTextView, NSAttributedString) don't have to bounce through
    /// the SwiftUI `Color → NSColor` converter (which is `@MainActor`). Memoized
    /// per (theme, token, alpha) — see the cache note above.
    nonisolated static func nsThemed(_ keyPath: KeyPath<ThemePalette, UInt64>, alpha: CGFloat = 1.0) -> NSColor {
        let theme = Theme.current
        let key = ThemeColorKey(theme: theme.rawValue, keyPath: keyPath, alphaBits: alpha.bitPattern)
        return colorCacheLock.withLock {
            if let cached = nsColorCache[key] { return cached }
            let color = NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return Self.makeNSColor(hex: theme.palette(isDark: isDark)[keyPath: keyPath], alpha: alpha)
            }
            nsColorCache[key] = color
            return color
        }
    }

    // MARK: - Adaptive Color Helper (theme-independent overrides)


    private nonisolated static func makeNSColor(hex: UInt64, alpha: CGFloat) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    // MARK: - Status Colors (unique per semantic meaning)

    /// Success/Done — neutral "done" gray. Monochrome+1: completion is told by
    /// the ✓ glyph + brightness, not by green.
    static var success: Color { themed(\.success) }
    /// Warning/Paused — lavender signal (the design's `--nt-warning` aliases the accent)
    static var warning: Color { themed(\.warning) }
    /// Error/Failed — muted terracotta. The sole 2nd accent, reserved for failure.
    static var error: Color { themed(\.error) }
    /// Info/Working — lavender signal. Alive / executing.
    static var info: Color { themed(\.info) }
    /// Neutral/Idle — mid gray. Visible but inactive.
    static var neutral: Color { themed(\.neutral) }

    // MARK: - Extended Status Palette (each visually unique)

    // Token names are kept stable across themes so every call site compiles;
    // each theme remaps the hexes to match its hue family.

    /// Meetings, collaborative states — meeting gray (◆)
    static var purple: Color { themed(\.purple) }
    /// Artifact deliverables — neutral "done" gray
    static var artifact: Color { themed(\.artifact) }
    /// Advisory / connected roles — ready gray
    static var teal: Color { themed(\.teal) }
    /// Revision requested — lavender signal (attention)
    static var yellow: Color { themed(\.yellow) }
    /// Supervisor / authority — bright "review" neutral
    static var indigo: Color { themed(\.indigo) }
    /// Design-related content — mid gray
    static var pink: Color { themed(\.pink) }
    /// Ready state, tech/engineering — ready gray
    static var cyan: Color { themed(\.cyan) }
    /// Ops/infra content — done gray
    static var mint: Color { themed(\.mint) }
    /// Lore/historical content — meeting gray
    static var brown: Color { themed(\.brown) }
    /// Accepted by Supervisor — brightest neutral (✓✓)
    static var emerald: Color { themed(\.emerald) }
    /// Waiting for Supervisor input/answer — lavender signal (attention)
    static var gold: Color { themed(\.gold) }
    /// Skipped/observer — idle, near-invisible
    static var dim: Color { themed(\.dim) }

    // MARK: - Surface Colors

    /// Deepest background — sidebar / window chrome (void)
    static var surfaceBackground: Color { themed(\.surfaceBackground) }
    /// Primary content area — graph canvas, main content, window (terminal bg)
    static var surfacePrimary: Color { themed(\.surfacePrimary) }
    /// Cards, panels — activity feed, settings sections (surface)
    static var surfaceCard: Color { themed(\.surfaceCard) }
    /// Elevated — inputs, popovers, selected row (elevated)
    static var surfaceElevated: Color { themed(\.surfaceElevated) }
    /// Subtler elevated tint — used by inheritance/disabled rows that need
    /// to read as "less prominent than an editable field" without falling
    /// to plain background. Pre-computed so callers don't apply
    /// `surfaceElevated.opacity(0.5)` (forbidden by Color Rule #2).
    static var surfaceElevatedSubtle: Color { themed(\.surfaceElevatedSubtle) }
    /// Hover feedback on cards/timeline items (hover)
    static var surfaceHover: Color { themed(\.surfaceHover) }
    /// Overlay (dimmed window inset, code blocks)
    static var surfaceOverlay: Color { themed(\.surfaceOverlay) }
    /// Strong overlay for blocking content (loading/failure overlays atop the canvas)
    static var surfaceOverlayStrong: Color { themed(\.surfaceOverlayStrong) }

    /// Fade gradient — transparent variant of `surfacePrimary` for fade-out
    /// gradients above banners. Uses `themed(...)` with explicit alpha so it
    /// tracks the active theme's primary surface.
    static var surfaceFadeClear: Color { themed(\.surfacePrimary, alpha: 0) }

    // MARK: - Border Colors

    /// Subtle border — box-drawing pane separators, dividers, card outlines
    static var borderSubtle: Color { themed(\.borderSubtle) }
    /// Strong border — interactive outlines (secondary buttons, focused
    /// inputs). 1:1 with `--nt-border-strong` in `tokens/colors.css`.
    static var borderStrong: Color { themed(\.borderStrong) }

    // MARK: - Accent Color (interactive elements)

    /// Primary accent — sourced from the active theme palette so custom UI
    /// (buttons, focus rings, status pills) swaps with the theme. Native
    /// AppKit controls (NSColorWell etc.) still resolve through the
    /// `AccentColor` asset catalog — that asset is the system-wide fallback
    /// and is not theme-aware on purpose.
    static var accent: Color { themed(\.accent) }

    // MARK: - Status Tint Backgrounds
    // Pre-computed background tints for status-colored cards/banners.
    // These replace `statusColor.opacity(X)` patterns — each is a proper adaptive color.

    /// Done tint — success badges, completion indicators
    static var successTint: Color { themed(\.successTint) }
    /// Signal tint — paused/warning banners (lavender wash)
    static var warningTint: Color { themed(\.warningTint) }
    /// Terracotta tint — error/failure backgrounds
    static var errorTint: Color { themed(\.errorTint) }
    /// Signal tint — working/in-progress node backgrounds (lavender wash)
    static var infoTint: Color { themed(\.infoTint) }
    /// Meeting tint — meeting cards, acceptance cards
    static var purpleTint: Color { themed(\.purpleTint) }
    /// Neutral tint — artifact cards, badges
    static var artifactTint: Color { themed(\.artifactTint) }
    /// Ready tint — ready state node backgrounds
    static var cyanTint: Color { themed(\.cyanTint) }
    /// Signal tint — revision requested backgrounds (lavender wash)
    static var yellowTint: Color { themed(\.yellowTint) }
    /// Idle tint — idle node backgrounds
    static var neutralTint: Color { themed(\.neutralTint) }
    /// Idle tint — skipped node backgrounds
    static var dimTint: Color { themed(\.dimTint) }
    /// Accepted tint — accepted node backgrounds (brightest neutral wash)
    static var emeraldTint: Color { themed(\.emeraldTint) }

    // MARK: - Status Border Colors
    // Pre-computed border colors for status-tinted cards.

    /// Error border — terracotta failure outlines
    static var errorBorder: Color { themed(\.errorBorder) }
    /// Neutral border — info banner outlines (border-strong)
    static var neutralBorder: Color { themed(\.neutralBorder) }

    // MARK: - Accent Tint Colors

    /// Accent tint — subtle backgrounds (hover, selection highlight)
    static var accentTint: Color { themed(\.accentTint) }
    /// Accent tint strong — selected template cards, team selector icons
    static var accentTintStrong: Color { themed(\.accentTintStrong) }
    /// Accent border — outlines / focus ring
    static var accentBorder: Color { themed(\.accentBorder) }

    // MARK: - Text Colors
    // Use SwiftUI .primary/.secondary/.tertiary for text in views.
    // These Color values exist for places that need a Color (not ShapeStyle),
    // e.g. Canvas drawing, NSColor contexts, or graph stroke colors.

    /// Primary text — main content text (terminal foreground)
    static var textPrimary: Color { themed(\.textPrimary) }
    /// Secondary text — descriptions, metadata
    static var textSecondary: Color { themed(\.textSecondary) }
    /// Tertiary text — placeholders, hints, comments, disabled
    static var textTertiary: Color { themed(\.textTertiary) }
    /// Quaternary / watermark text — the faintest legible tone, for decorative
    /// terminal sigils (`$`, `task/`, `›`). Maps to the design's `text-faint`.
    static var textQuaternary: Color { themed(\.textQuaternary) }
    /// Text/icon on an accent fill. Theme-determined contrast — light text on
    /// dark themes, deep text on paper.
    static var textOnAccent: Color { themed(\.textOnAccent) }

    // MARK: - NSColor Accessors (for AppKit contexts: NSTextView, NSAttributedString)

    // These feed `NSAttributedString` foreground/background attributes and
    // NSTextView stamping, where instance IDENTITY is load-bearing:
    // `NSAttributedString.isEqual` and the append-only / appearance-restamp
    // short-circuits (`SelectableMessageText`, `ResolvedPromptView`,
    // `PlaceholderParser`) compare attribute VALUES by reference — so each must
    // return a STABLE instance within a theme (`ColorsNSIdentityTests`,
    // CLAUDE.md #50). Routing through `nsThemed`'s per-theme cache gives exactly
    // that, while ALSO returning a fresh instance after a same-scheme theme
    // switch — so the prior `static let` staleness (pre-switch hex lingered until
    // app relaunch) is gone: the `.id(activeTheme)` root rebuild re-pulls these
    // and the AppKit text re-stamps the fresh color.

    /// Primary text as NSColor — for NSTextView, NSAttributedString.
    nonisolated static var nsTextPrimary: NSColor { nsThemed(\.textPrimary) }
    /// Surface card as NSColor — for NSTextView backgrounds.
    nonisolated static var nsSurfaceCard: NSColor { nsThemed(\.surfaceCard) }
    /// Secondary text as NSColor — for NSTextAttachment fallbacks etc.
    nonisolated static var nsTextSecondary: NSColor { nsThemed(\.textSecondary) }

    // MARK: - Picker Palette

    /// Curated picker colors for role icon customization (used in RoleEditorGeneralTab).
    static let pickerPalette: [(name: String, hex: String)] = [
        ("White",    "#FFFFFF"),
        ("Rose",     "#D96A7F"),
        ("Apricot",  "#D4974E"),
        ("Honey",    "#D5B455"),
        ("Sage",     "#4FB985"),
        ("Emerald",  "#35BE81"),
        ("Teal",     "#3FB6AA"),
        ("Mist",     "#46B8D0"),
        ("Sky",      "#5F87D9"),
        ("Indigo",   "#6D76E2"),
        ("Lavender", "#8F82E6"),
        ("Orchid",   "#A86DE8"),
        ("Berry",    "#CF6EAA"),
        ("Blush",    "#D887B2"),
        ("Mocha",    "#9A795F"),
        ("Stone",    "#9F9790"),
        ("Slate",    "#645E5A"),
    ]

    /// Palette hex values that need dark checkmark contrast (light colors).
    static let lightPaletteHexColors: Set<String> = ["#FFFFFF", "#D5B455", "#D4974E", "#46B8D0", "#D887B2", "#9F9790"]

}

// MARK: - Preview Support

private struct ColorPreviewItem: Identifiable {
    let name: String
    let color: Color

    var id: String { name }
}

// periphery:ignore - used in #Preview macros (color catalog)
private struct ColorPreviewSection: Identifiable {
    let title: String
    let items: [ColorPreviewItem]

    var id: String { title }
}

private extension Colors {
    // periphery:ignore - used in #Preview macros (color catalog)
    static var previewSections: [ColorPreviewSection] {
        [
            ColorPreviewSection(
                title: "Status",
                items: [
                    ColorPreviewItem(name: "success", color: success),
                    ColorPreviewItem(name: "warning", color: warning),
                    ColorPreviewItem(name: "error", color: error),
                    ColorPreviewItem(name: "info", color: info),
                    ColorPreviewItem(name: "neutral", color: neutral)
                ]
            ),
            ColorPreviewSection(
                title: "Extended Status",
                items: [
                    ColorPreviewItem(name: "purple", color: purple),
                    ColorPreviewItem(name: "artifact", color: artifact),
                    ColorPreviewItem(name: "teal", color: teal),
                    ColorPreviewItem(name: "yellow", color: yellow),
                    ColorPreviewItem(name: "indigo", color: indigo),
                    ColorPreviewItem(name: "pink", color: pink),
                    ColorPreviewItem(name: "cyan", color: cyan),
                    ColorPreviewItem(name: "mint", color: mint),
                    ColorPreviewItem(name: "brown", color: brown),
                    ColorPreviewItem(name: "emerald", color: emerald),
                    ColorPreviewItem(name: "gold", color: gold),
                    ColorPreviewItem(name: "dim", color: dim)
                ]
            ),
            ColorPreviewSection(
                title: "Surfaces",
                items: [
                    ColorPreviewItem(name: "surfaceBackground", color: surfaceBackground),
                    ColorPreviewItem(name: "surfacePrimary", color: surfacePrimary),
                    ColorPreviewItem(name: "surfaceCard", color: surfaceCard),
                    ColorPreviewItem(name: "surfaceElevated", color: surfaceElevated),
                    ColorPreviewItem(name: "surfaceElevatedSubtle", color: surfaceElevatedSubtle),
                    ColorPreviewItem(name: "surfaceHover", color: surfaceHover),
                    ColorPreviewItem(name: "surfaceOverlay", color: surfaceOverlay),
                    ColorPreviewItem(name: "surfaceFadeClear", color: surfaceFadeClear)
                ]
            ),
            ColorPreviewSection(
                title: "Borders",
                items: [
                    ColorPreviewItem(name: "borderSubtle", color: borderSubtle),
                    ColorPreviewItem(name: "errorBorder", color: errorBorder),
                    ColorPreviewItem(name: "accentBorder", color: accentBorder)
                ]
            ),
            ColorPreviewSection(
                title: "Tints",
                items: [
                    ColorPreviewItem(name: "successTint", color: successTint),
                    ColorPreviewItem(name: "warningTint", color: warningTint),
                    ColorPreviewItem(name: "errorTint", color: errorTint),
                    ColorPreviewItem(name: "infoTint", color: infoTint),
                    ColorPreviewItem(name: "purpleTint", color: purpleTint),
                    ColorPreviewItem(name: "artifactTint", color: artifactTint),
                    ColorPreviewItem(name: "cyanTint", color: cyanTint),
                    ColorPreviewItem(name: "yellowTint", color: yellowTint),
                    ColorPreviewItem(name: "neutralTint", color: neutralTint),
                    ColorPreviewItem(name: "dimTint", color: dimTint),
                    ColorPreviewItem(name: "emeraldTint", color: emeraldTint),
                    ColorPreviewItem(name: "accentTint", color: accentTint),
                    ColorPreviewItem(name: "accentTintStrong", color: accentTintStrong)
                ]
            ),
            ColorPreviewSection(
                title: "Text & Accent",
                items: [
                    ColorPreviewItem(name: "accent", color: accent),
                    ColorPreviewItem(name: "textPrimary", color: textPrimary),
                    ColorPreviewItem(name: "textSecondary", color: textSecondary),
                    ColorPreviewItem(name: "textTertiary", color: textTertiary)
                ]
            )
        ]
    }
}

// periphery:ignore - used in #Preview macros (color catalog)
private struct ColorsCatalogPreview: View {
    private let columns = [
        GridItem(.adaptive(minimum: 92, maximum: 120), spacing: Spacing.s)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(Colors.previewSections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.s) {
                            ForEach(section.items) { item in
                                ColorPreviewCard(item: item)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.m)
        }
        .frame(width: 860, height: 680)
        .background(Colors.surfaceBackground)
    }
}

// periphery:ignore - used in #Preview macros (color catalog)
private struct ColorPreviewCard: View {
    let item: ColorPreviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ZStack {
                RoundedRectangle.squircle(CornerRadius.medium)
                    .fill(item.color)

                Text("Aa")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Colors.textPrimary)
            }
            .frame(height: 38)
            .overlay(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .stroke(Colors.borderSubtle, lineWidth: 1)
            )

            Text(item.name)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(6)
        .background(Colors.surfaceCard, in: RoundedRectangle.squircle(CornerRadius.large))
        .overlay(
            RoundedRectangle.squircle(CornerRadius.large)
                .stroke(Colors.borderSubtle, lineWidth: 1)
        )
    }
}

#Preview("Colors Light") {
    ColorsCatalogPreview()
        .preferredColorScheme(.light)
}

#Preview("Colors Dark") {
    ColorsCatalogPreview()
        .preferredColorScheme(.dark)
}
