import SwiftUI

// MARK: - NTMSLoader

/// The branded loading indicator — a **rotating stick** in the accent color
/// with occasional hacker-style **glitch bursts**.
///
/// One 80 ms frame sequence carries two modes (matching the JS reference):
/// - **Rotation** — the glyph cycles `│ → ╱ → ─ → ╲`.
/// - **Glitch** — each idle frame rolls a ~2% chance to start a burst of 3–6
///   frames (≈ one burst every ~3 seconds).
///   While the burst is active a random glyph from the hacker set (`0 1 ⧄ ▒ ≡ ⌗ ₿ ｱ …`)
///   replaces the rotation char, the cell gets a 1px diagonal jitter, and an
///   RGB-split overlay paints a red copy +1px right and a cyan copy −1px left
///   (chromatic-aberration / "torn signal" effect). Rotation does not advance
///   during the burst, so it resumes from the exact angle it left off.
///
/// **The animation never touches SwiftUI state.** The sequence is generated once
/// (`NTMSLoaderAnimationScript`) and played by Core Animation (`NTMSLoaderLayerView`).
/// A per-tick view-state write is a transaction on the whole window, and a window with a
/// long activity feed pays for it in full; the script's doc comment carries the measurement.
/// Pinned by `Ratchet/LoaderAnimationTickPinTests`.
///
/// Rendered in SF Mono so the four rotation glyphs share an advance width.
/// Reduce Motion → frozen first frame (no rotation, no glitches), same as a
/// live window resize.
///
/// Two construction shapes:
/// - **Sized** (`NTMSLoader(.small)`) — fixed `width × height` footprint from
///   a `Size` preset. Used for standalone loaders inside cards / panels.
/// - **Font-based** (`NTMSLoader(font: Typography.termXs)`) — inline-with-text
///   rendering in a `MonoCell` sized by the supplied font, so no glyph it draws
///   can resize the row or shift the caption beside it. Used for the "Working"
///   / "Thinking" / "Processing" caption rows next to a `Text`. Replaces the
///   legacy `BrailleSpinner` (now removed) so the glitch effect is uniform
///   across every spinner in the app.
///
/// ```swift
/// NTMSLoader()                              // .regular
/// NTMSLoader(.small)                        // compact controls / buttons
/// NTMSLoader(.inline)                       // matches a 14×14 inline icon
/// NTMSLoader(font: Typography.termXs)       // inline beside a small caption
/// ```
struct NTMSLoader: View {
    /// Pre-defined size presets mirroring ControlSize semantics.
    enum Size {
        /// Matches system icon size for inline status indicators (14×14).
        case inline
        case mini
        case small
        case regular
        case large
        case extraLarge

        var width: CGFloat {
            switch self {
            case .inline:     return 14
            case .mini:       return 24
            case .small:      return 36
            case .regular:    return 60
            case .large:      return 100
            case .extraLarge: return 200
            }
        }

        var height: CGFloat {
            switch self {
            case .inline: return 14
            default:      return width / 2
            }
        }

        /// Mono glyph point size that fills the footprint.
        var glyphSize: CGFloat {
            switch self {
            case .inline:     return 12
            case .mini:       return 17
            case .small:      return 24
            case .regular:    return 32
            case .large:      return 54
            case .extraLarge: return 108
            }
        }
    }

    /// Two ways to size the spinner: a fixed-frame `Size` preset, or an
    /// inline-with-text `Font` (no frame — caller's layout drives the cell).
    private enum Footprint {
        case sized(Size)
        case font(Font)
    }

    private let footprint: Footprint
    private let isVisible: Bool
    private let color: Color

    init(_ size: Size = .regular, isVisible: Bool = true, color: Color = Colors.accent) {
        self.footprint = .sized(size)
        self.isVisible = isVisible
        self.color = color
    }

    /// Inline-with-text spinner. Baseline-aligned to `font`, no fixed frame —
    /// fits beside a sibling `Text` in an `HStack` exactly like the legacy
    /// `BrailleSpinner` did.
    init(font: Font, isVisible: Bool = true, color: Color = Colors.accent) {
        self.footprint = .font(font)
        self.isVisible = isVisible
        self.color = color
    }

    /// Rotating stick using monospaced box-drawing glyphs (clockwise).
    ///
    /// Internal rather than `private` so `NTMSLoaderRenderModeTests` can assert
    /// every frame resolves INSIDE SF Mono. That is the precondition which makes
    /// `inlineCellFootprint` a metric-stable cell — a rotation frame served by a
    /// fallback face would size the cell differently per frame and defeat it.
    static let rotationFrames = ["│", "╱", "─", "╲"]
    /// Hacker-style glyph pool used during a glitch burst.
    ///
    /// Internal rather than `private` so the metrics test can measure it. 16 of
    /// these 35 do NOT resolve inside SF Mono — see `inlineCellFootprint` for
    /// what that used to cost and why the cell exists.
    static let glitchGlyphs: [String] = [
        "0", "1", "⧄", "▒", "≡", "⌗", "█", "▓", "░",
        "≀", "⍰", "⏦", "⁊", "⸮", "／", "＼",
        "ｱ", "ｲ", "ｳ", "ｴ", "ｵ", "ﾊ", "ｶ", "ﾐ",
        "@", "#", "%", "&", "$", "/", "\\", "{", "}", "<", ">"
    ]

    @Environment(\.windowResizeMonitor) private var resizeMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// User toggle (Settings → Theme → Effects). `false` suppresses the glitch
    /// flourish (scramble + RGB-split + jitter) while the spinner keeps rotating.
    /// `@AppStorage` (not `StoreConfiguration`) so this design-system primitive
    /// works in previews and the standalone QuickCapture panel without an
    /// injected environment. Default on (absent key ⇒ `true`).
    @AppStorage(UserDefaultsKeys.spinnerGlitchEnabled) private var glitchEnabled: Bool = true

    /// Render branches driven by `renderMode(isVisible:isResizing:reduceMotion:)`.
    enum RenderMode: Equatable {
        /// Don't render — `isVisible == false`. Zero-cost `Color.clear`.
        case hidden
        /// One frozen frame — Reduce Motion or a live resize.
        case frozen
        /// Play the frame sequence on Core Animation.
        case live
    }

    /// Pure decision: which render branch should `body` take? Reduce Motion
    /// trumps the live branch (accessibility contract). Resize-suppression and
    /// Reduce-Motion both map to `.frozen` — both want a single static frame.
    static func renderMode(
        isVisible: Bool,
        isResizing: Bool,
        reduceMotion: Bool
    ) -> RenderMode {
        if !isVisible { return .hidden }
        if reduceMotion || isResizing { return .frozen }
        return .live
    }

    var body: some View {
        switch Self.renderMode(
            isVisible: isVisible,
            isResizing: resizeMonitor.isResizing,
            reduceMotion: reduceMotion
        ) {
        case .hidden:
            hiddenPlaceholder
        case .frozen:
            // First rotation frame — a single steady glyph.
            inCell(Text(Self.rotationFrames[0]).font(glyphFont).foregroundStyle(color))
        case .live:
            inCell(NTMSLoaderLayerView(font: glyphFont, color: color, glitchEnabled: glitchEnabled))
        }
    }

    /// Zero-cost invisible placeholder that preserves the spinner's footprint.
    /// Sized variant uses an explicit frame; the font variant uses an empty
    /// `MonoCell` — the SAME cell the visible branch draws into, so toggling
    /// `isVisible` cannot change the row's height or slide its sibling caption.
    @ViewBuilder
    private var hiddenPlaceholder: some View {
        switch footprint {
        case .sized(let size):
            Color.clear.frame(width: size.width, height: size.height)
        case .font(let font):
            MonoCell(font: font)
        }
    }

    /// The footprint both visible branches draw into.
    @ViewBuilder
    private func inCell<Content: View>(_ content: Content) -> some View {
        switch footprint {
        case .sized(let size):
            content
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
        case .font(let font):
            // The DRAWN glyph must not drive the cell. 16 of the 35 entries in
            // `glitchGlyphs` resolve to a fallback face and change a metric —
            // at 11pt `≀`/`⁊` are Monaco (+1.713pt line height), `／`/`＼` are
            // PingFang SC (+4.136pt advance), the katakana are
            // CJKSymbolsFallback (−1.520pt). Returning the bare glyph here let
            // each of those reflow the caption row and, through it, the whole
            // message bubble, several times a minute. `MonoCell` pins the cell
            // to the FONT's metrics and paints the glyph over it; a wide glyph
            // spills into the gutter, which is what a torn signal should do,
            // and moves nothing. Deliberately NOT clipped — clipping would
            // shave the ±1px RGB-split copies the effect is made of.
            MonoCell(font: font) { content }
                .accessibilityHidden(true)
        }
    }

    /// Font used for every glyph. Sized footprints derive an SF Mono size from
    /// the preset; font footprints pass through the caller-supplied font verbatim.
    private var glyphFont: Font {
        switch footprint {
        case .sized(let size):
            return .system(size: size.glyphSize, weight: .regular, design: .monospaced)
        case .font(let font):
            return font
        }
    }
}

// MARK: - Previews

#Preview("NTMSLoader — All Sizes") {
    VStack(spacing: 24) {
        ForEach(
            [NTMSLoader.Size.inline, .mini, .small, .regular, .large, .extraLarge],
            id: \.width
        ) { size in
            HStack {
                Text(String(describing: size))
                    .font(Typography.monoCaption)
                    .frame(width: 80, alignment: .trailing)
                    .foregroundStyle(Colors.textSecondary)
                NTMSLoader(size)
            }
        }
    }
    .padding(40)
    .background(Colors.surfacePrimary)
}
