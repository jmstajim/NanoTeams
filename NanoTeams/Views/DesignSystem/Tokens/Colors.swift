import AppKit
import SwiftUI

/// Semantic color palette — adaptive dark/light.
///
/// Each color is defined with a dark-mode variant (vibrant on black)
/// and a light-mode variant (darker for contrast on white).
/// Uses `NSColor(name:dynamicProvider:)` for automatic switching.
enum Colors {
    // MARK: - Adaptive Color Helper

    /// Creates an adaptive Color that switches between dark and light variants.
    /// Uses `NSColor(name:dynamicProvider:)` — macOS handles switching automatically.
    static func adaptive(dark: UInt64, light: UInt64, alpha: CGFloat = 1.0) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: alpha
            )
        })
    }

    // MARK: - Status Colors (unique per semantic meaning)

    /// Success/Done — green. Use for completed, approved, positive states
    static let success = adaptive(dark: 0x4FB985, light: 0x24885A)
    /// Warning/Paused — orange. Use for user-paused states
    static let warning = adaptive(dark: 0xD4974E, light: 0xB36B1E)
    /// Error/Failed — red. Use for failures, destructive actions
    static let error = adaptive(dark: 0xD96A7F, light: 0xB8465A)
    /// Info/Working — blue. Use for in-progress, active execution
    static let info = adaptive(dark: 0x5F87D9, light: 0x3E63BD)
    /// Neutral/Idle — gray. Use for idle, inactive, not started
    static let neutral = adaptive(dark: 0x645E5A, light: 0xC9C1BB)

    // MARK: - Extended Status Palette (each visually unique)

    /// Periwinkle — meetings, collaborative states
    static let purple = adaptive(dark: 0x8F82E6, light: 0x6957C7)
    /// Artifact — gaming epic purple, artifact deliverables
    static let artifact = adaptive(dark: 0xA86DE8, light: 0x7B3FC2)
    /// Teal — connected, linked, advisory roles
    static let teal = adaptive(dark: 0x3FB6AA, light: 0x25857D)
    /// Yellow — revision requested, changes needed
    static let yellow = adaptive(dark: 0xD5B455, light: 0xAD8425)
    /// Indigo — Supervisor/authority roles
    static let indigo = adaptive(dark: 0x6D76E2, light: 0x4E55BA)
    /// Pink — design-related content
    static let pink = adaptive(dark: 0xD887B2, light: 0xB6598A)
    /// Cyan — ready state, tech/engineering
    static let cyan = adaptive(dark: 0x46B8D0, light: 0x2588A1)
    /// Mint — ops/infra content
    static let mint = adaptive(dark: 0x56C999, light: 0x2D9368)
    /// Brown — lore/historical content
    static let brown = adaptive(dark: 0x9A795F, light: 0x765842)
    /// Emerald — accepted by Supervisor (distinct from done/green)
    static let emerald = adaptive(dark: 0x35BE81, light: 0x198A5B)
    /// Gold — waiting for Supervisor input/answer
    static let gold = adaptive(dark: 0xD6A64D, light: 0xB27A1F)
    /// Dim — skipped/observer, near-invisible
    static let dim = adaptive(dark: 0x433E3B, light: 0xDDD5CF)

    // MARK: - Surface Colors

    /// Deepest background — sidebar
    static let surfaceBackground = adaptive(dark: 0x0A0A0A, light: 0xFAFAFA)
    /// Primary content area — graph canvas, main content, window
    static let surfacePrimary = adaptive(dark: 0x111111, light: 0xFFFFFF)
    /// Cards, panels — activity feed, settings sections
    static let surfaceCard = adaptive(dark: 0x161616, light: 0xF8F8F8)
    /// Elevated — hover states, inputs, elevated cards
    static let surfaceElevated = adaptive(dark: 0x1E1E1E, light: 0xF0F0F0)
    /// Hover feedback on cards/timeline items
    static let surfaceHover = adaptive(dark: 0x1A1A1A, light: 0xEEEEEE)
    /// Overlay (dimmed window, code blocks)
    static let surfaceOverlay = adaptive(dark: 0x141414, light: 0xF0F0F0)

    /// Fade gradient — content fade-out above banners
    static let surfaceFadeClear = adaptive(dark: 0x111111, light: 0xFFFFFF, alpha: 0)

    // MARK: - Border Colors

    /// Subtle border — dividers, card outlines
    static let borderSubtle = adaptive(dark: 0x282321, light: 0xE7E0DA)
    // MARK: - Accent Color (interactive elements)

    /// Primary accent — sourced from AccentColor asset catalog (single source of truth)
    static let accent = Color.accentColor

    // MARK: - Status Tint Backgrounds
    // Pre-computed background tints for status-colored cards/banners.
    // These replace `statusColor.opacity(X)` patterns — each is a proper adaptive color.

    /// Green tint — success badges, completion indicators
    static let successTint = adaptive(dark: 0x16201C, light: 0xF2FAF6)
    /// Orange tint — warning banners, pause indicators
    static let warningTint = adaptive(dark: 0x211913, light: 0xFDF7F1)
    /// Red tint — error backgrounds
    static let errorTint = adaptive(dark: 0x211416, light: 0xFCF1F2)
    /// Blue tint — working/in-progress node backgrounds
    static let infoTint = adaptive(dark: 0x161B24, light: 0xF2F5FB)
    /// Periwinkle tint — meeting cards, acceptance cards
    static let purpleTint = adaptive(dark: 0x171726, light: 0xF3F1FB)
    /// Artifact tint — artifact cards, badges
    static let artifactTint = adaptive(dark: 0x191521, light: 0xF8F2FA)
    /// Cyan tint — ready state node backgrounds
    static let cyanTint = adaptive(dark: 0x141E21, light: 0xF0F8FA)
    /// Yellow tint — revision requested backgrounds
    static let yellowTint = adaptive(dark: 0x211C14, light: 0xFBF7ED)
    /// Neutral tint — idle node backgrounds
    static let neutralTint = adaptive(dark: 0x171514, light: 0xF4F1EE)
    /// Dim tint — skipped node backgrounds
    static let dimTint = adaptive(dark: 0x151312, light: 0xF5F2EF)
    /// Emerald tint — accepted node backgrounds
    static let emeraldTint = adaptive(dark: 0x14201B, light: 0xF0F9F4)

    // MARK: - Status Border Colors
    // Pre-computed border colors for status-tinted cards.

    /// Error border — error banner outlines
    static let errorBorder = adaptive(dark: 0x47282C, light: 0xEFCFD3)

    // MARK: - Accent Tint Colors

    /// Accent tint — subtle accent backgrounds (hover, selection highlight)
    static let accentTint = adaptive(dark: 0x241F36, light: 0xE4D8F3)
    /// Accent tint strong — selected template cards, team selector icons
    static let accentTintStrong = adaptive(dark: 0x201B31, light: 0xDED1F1)
    /// Accent border — accent-colored outlines
    static let accentBorder = adaptive(dark: 0x4D456F, light: 0xB8A3E3)

    // MARK: - Text Colors
    // Use SwiftUI .primary/.secondary/.tertiary for text in views.
    // These Color values exist for places that need a Color (not ShapeStyle),
    // e.g. Canvas drawing, NSColor contexts, or graph stroke colors.

    /// Primary text — main content text
    static let textPrimary = adaptive(dark: 0xFBF7F3, light: 0x221F1D)
    /// Secondary text — descriptions, metadata
    static let textSecondary = adaptive(dark: 0xC2B8B0, light: 0x746B65)
    /// Tertiary text — placeholders, hints, disabled
    static let textTertiary = adaptive(dark: 0x8A817B, light: 0x9E948D)

    // MARK: - NSColor Accessors (for AppKit contexts: NSTextView, NSAttributedString)

    /// Primary text as NSColor — for NSTextView, NSAttributedString
    static let nsTextPrimary = NSColor(textPrimary)
    /// Surface card as NSColor — for NSTextView backgrounds
    static let nsSurfaceCard = NSColor(surfaceCard)

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

private struct ColorPreviewSection: Identifiable {
    let title: String
    let items: [ColorPreviewItem]

    var id: String { title }
}

private extension Colors {
    static let previewSections: [ColorPreviewSection] = [
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
