import SwiftUI

// MARK: - Theme Settings View

/// Dedicated Settings tab that owns the single unified theme picker
/// (System / Light / Dark / OLED / Arctic / Indigo / Umber / Lilac / Marine /
/// Steel / Plum / Forest / Amber / Amethyst / Neon).
///
/// Selecting a theme writes to `UserDefaultsKeys.activeTheme`; the
/// `@AppStorage(activeTheme)` at the app root forces a tree rebuild so
/// `Colors.*` returns fresh palette values everywhere — and
/// `Theme.preferredColorScheme` swings the system color scheme through the
/// `.preferredColorScheme(_:)` modifier in `NanoTeamsApp`.
struct ThemeSettingsView: View {
    @AppStorage(UserDefaultsKeys.activeTheme) private var activeThemeRaw: String = Theme.defaultTheme.rawValue
    @AppStorage(UserDefaultsKeys.spinnerGlitchEnabled) private var spinnerGlitchEnabled: Bool = true
    /// Drives the Effects-card preview spinner's ticker on/off as the card
    /// scrolls in/out of the viewport (it sits below the tall theme grid, so
    /// it's usually off-screen). Starts `true` so an on-screen card animates
    /// immediately and an off-screen one never shows a blank frame — it only
    /// flips `false` once the scroll viewport reports the card hidden.
    @State private var isPreviewVisible = true

    private var activeTheme: Theme {
        Theme(rawValue: activeThemeRaw) ?? Theme.defaultTheme
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                pickerCard
                effectsCard
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }

    // MARK: - Picker Card

    private var pickerCard: some View {
        SettingsCard(
            header: "Theme",
            systemImage: "paintbrush.pointed",
            footer: "System follows your macOS appearance setting."
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: Spacing.m)],
                alignment: .leading,
                spacing: Spacing.m
            ) {
                ForEach(Theme.allCases) { theme in
                    ThemeTile(
                        theme: theme,
                        isSelected: activeTheme == theme
                    ) {
                        withAnimation(Animations.quick) {
                            activeThemeRaw = theme.rawValue
                        }
                    }
                }
            }
        }
    }

    // MARK: - Effects Card

    private var effectsCard: some View {
        SettingsCard(
            header: "Effects",
            systemImage: "sparkles"
        ) {
            VStack(spacing: 0) {
                HStack(spacing: Spacing.m) {
                    SettingsToggleRow(
                        title: "Spinner glitch effect",
                        icon: "waveform.path",
                        isOn: $spinnerGlitchEnabled
                    )
                    // Live preview so the user sees the effect while toggling.
                    // Gated on scroll visibility so its 80ms ticker doesn't run
                    // while the card is scrolled out of view below the grid.
                    NTMSLoader(.small, isVisible: isPreviewVisible)
                        .padding(.trailing, Spacing.s)
                        .onScrollVisibilityChange(threshold: 0.1) { isPreviewVisible = $0 }
                }

                Text("Occasional hacker-style glitch bursts on the loading spinner. The spinner keeps rotating either way.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)
            }
        }
    }
}

// MARK: - Theme Tile

/// Live preview of a `Theme` showing its surfaces + accent stripe. `.system`
/// gets a split swatch (paper-left / Terminal-dark-right) so the user sees
/// what "follow the OS" means visually. Every other tile renders the theme's
/// concrete dark palette (or paper, for `.light`).
private struct ThemeTile: View {
    let theme: Theme
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @ScaledMetric(relativeTo: .body) private var tileHeight: CGFloat = 64

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                preview
                Text(theme.displayName)
                    .font(Typography.caption)
                    .foregroundStyle(isSelected ? Colors.textPrimary : Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .trackHover($isHovered)
        .animation(Animations.quick, value: isSelected)
        .animation(Animations.quick, value: isHovered)
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            previewSurface
                .frame(height: tileHeight)
                .clipShape(RoundedRectangle.squircle(CornerRadius.medium))

            RoundedRectangle.squircle(CornerRadius.medium)
                .strokeBorder(
                    isSelected ? Colors.accent : (isHovered ? Colors.borderStrong : Colors.borderSubtle),
                    lineWidth: isSelected ? 2 : 1
                )
                .frame(height: tileHeight)
        }
        .shadow(.ui)
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch theme.preferredColorScheme {
        case .none:
            // System — split preview: left = paper light (Terminal light
            // accent), right = Terminal dark.
            HStack(spacing: 0) {
                paletteStripe(theme.palette(isDark: false))
                paletteStripe(theme.palette(isDark: true))
            }
        case .some(.light):
            // Every light theme (paper, parchment, mist, sand, dawn, cream,
            // daylight, blush) renders its own light palette.
            paletteStripe(theme.palette(isDark: false))
        default:
            // Every dark theme — render its dark palette.
            paletteStripe(theme.palette(isDark: true))
        }
    }

    /// Renders a palette's surfaces ramp + accent stripe inside the tile.
    private func paletteStripe(_ palette: ThemePalette) -> some View {
        ZStack {
            hexColor(palette.surfacePrimary)

            HStack(spacing: 4) {
                hexColor(palette.surfaceCard)
                hexColor(palette.surfaceElevated)
                hexColor(palette.accent)
            }
            .mask {
                HStack(spacing: 4) {
                    RoundedRectangle.squircle(CornerRadius.small)
                    RoundedRectangle.squircle(CornerRadius.small)
                    RoundedRectangle.squircle(CornerRadius.small)
                }
            }
            .padding(Spacing.s)
        }
    }

    private func hexColor(_ hex: UInt64) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - Previews

#Preview("Theme Settings") {
    ThemeSettingsView()
        .frame(width: 720, height: 600)
}
