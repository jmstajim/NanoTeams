import SwiftUI

// MARK: - NTMSLoader

/// The branded loading indicator — a **rotating stick** in the accent color
/// with occasional hacker-style **glitch bursts**.
///
/// One ticker at 80 ms runs two modes (matching the JS reference):
/// - **Rotation** — the glyph cycles `│ → ╱ → ─ → ╲` via `tickCount % 4`.
/// - **Glitch** — each idle tick rolls a ~2% chance to start a burst of 3–6
///   frames (≈ one burst every ~3 seconds).
///   While the burst is active a random glyph from the hacker set (`0 1 ⧄ ▒ ≡ ⌗ ₿ ｱ …`)
///   replaces the rotation char, the cell gets a 1px diagonal jitter, and an
///   RGB-split overlay paints a red copy +1px right and a cyan copy −1px left
///   (chromatic-aberration / "torn signal" effect). `tickCount` is *not*
///   advanced during the burst, so rotation resumes from the exact angle it
///   left off.
///
/// Rendered in SF Mono so the four rotation glyphs share an advance width.
/// Reduce Motion → frozen first frame (no rotation, no glitches), same as a
/// live window resize. The `Size`/`renderMode` API is preserved so the ~19
/// call sites and pinning tests keep working; only the visual changed.
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

    /// Tick cadence — 80 ms, drives both rotation and glitch bursts.
    private static let tickInterval: Duration = .milliseconds(80)
    /// Rotating stick using monospaced box-drawing glyphs (clockwise).
    ///
    /// Internal rather than `private` so `NTMSLoaderRenderModeTests` can assert
    /// every frame resolves INSIDE SF Mono. That is the precondition which makes
    /// `inlineCellFootprint` a metric-stable cell — a rotation frame served by a
    /// fallback face would size the cell differently per frame and defeat it.
    static let rotationFrames = ["│", "╱", "─", "╲"]
    /// Probability that an idle tick starts a glitch burst. Tuned so a burst
    /// happens roughly every ~3 seconds (~50 idle ticks × 80ms + burst).
    private static let glitchTriggerProbability: Double = 0.02
    /// Length of a glitch burst, in ticks.
    private static let glitchFrameRange: ClosedRange<Int> = 3...6
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

    // RGB-split channels for the chromatic-aberration overlay. NOT design-system
    // colors — the glitch effect demands the canonical full-saturation R / C
    // channels; muting them with `Colors.error` etc. kills the look. Cyan has
    // no semantic token equivalent either. Scoped to this file by design.
    private static let glitchChannelRed = Color(red: 1.0, green: 0.0, blue: 0.0)
    private static let glitchChannelCyan = Color(red: 0.0, green: 1.0, blue: 1.0)

    @State private var tickCount: Int = 0
    @State private var glitchFramesRemaining: Int = 0
    @State private var currentGlitchChar: String = "0"
    @State private var shakeOffset: CGSize = .zero
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
        /// Drive the spinner timeline.
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

    /// Pure decision: should an idle tick start a glitch burst? The glitch is the
    /// scramble + RGB-split + jitter overlay; `glitchEnabled == false` suppresses
    /// it entirely (rotation continues). Strict `<` so `roll == probability` never
    /// fires — matches the inline roll this replaced.
    static func shouldStartGlitchBurst(glitchEnabled: Bool, roll: Double, probability: Double) -> Bool {
        glitchEnabled && roll < probability
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
            glyph(Self.rotationFrames[0], glitching: false)
        case .live:
            glyph(currentDisplayChar, glitching: glitchEnabled && glitchFramesRemaining > 0)
                .offset(glitchEnabled ? shakeOffset : .zero)
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: Self.tickInterval)
                        if Task.isCancelled { return }
                        tick()
                    }
                }
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

    /// Character shown on the next render — glitch glyph during a burst,
    /// otherwise the rotation frame at the current angle.
    private var currentDisplayChar: String {
        if glitchEnabled && glitchFramesRemaining > 0 { return currentGlitchChar }
        return Self.rotationFrames[tickCount % Self.rotationFrames.count]
    }

    /// One ticker step. Matches the JS reference:
    /// - During a burst: swap to a fresh random glitch glyph, jitter 1px diag,
    ///   decrement the burst counter. `tickCount` is intentionally untouched
    ///   so rotation resumes from the exact angle when the burst ends.
    /// - Otherwise: advance rotation by one frame, clear jitter, then roll the
    ///   2% chance to start a new burst.
    private func tick() {
        if glitchFramesRemaining > 0 && glitchEnabled {
            currentGlitchChar = Self.glitchGlyphs.randomElement() ?? "0"
            shakeOffset = CGSize(
                width: Bool.random() ? 1 : -1,
                height: Bool.random() ? 1 : -1
            )
            glitchFramesRemaining -= 1
        } else {
            // Idle, or a burst cancelled mid-flight by toggling the effect off —
            // clear any leftover burst counter so it settles on this tick.
            glitchFramesRemaining = 0
            tickCount &+= 1
            shakeOffset = .zero
            let roll = Double.random(in: 0..<1)
            if Self.shouldStartGlitchBurst(
                glitchEnabled: glitchEnabled,
                roll: roll,
                probability: Self.glitchTriggerProbability
            ) {
                glitchFramesRemaining = Int.random(in: Self.glitchFrameRange)
                currentGlitchChar = Self.glitchGlyphs.randomElement() ?? "0"
            }
        }
    }

    @ViewBuilder
    private func glyph(_ s: String, glitching: Bool) -> some View {
        let stack = ZStack {
            if glitching {
                // RGB-split: red copy shifts +1px right, cyan copy −1px left.
                Text(s)
                    .font(glyphFont)
                    .foregroundStyle(Self.glitchChannelRed)
                    .offset(x: 1)
                Text(s)
                    .font(glyphFont)
                    .foregroundStyle(Self.glitchChannelCyan)
                    .offset(x: -1)
            }
            Text(s)
                .font(glyphFont)
                .foregroundStyle(color)
        }
        switch footprint {
        case .sized(let size):
            stack
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
        case .font(let font):
            // The DRAWN glyph must not drive the cell. 16 of the 35 entries in
            // `glitchGlyphs` resolve to a fallback face and change a metric —
            // at 11pt `≀`/`⁊` are Monaco (+1.713pt line height), `／`/`＼` are
            // PingFang SC (+4.136pt advance), the katakana are
            // CJKSymbolsFallback (−1.520pt). Returning the bare stack here let
            // each of those reflow the caption row and, through it, the whole
            // message bubble, several times a minute. `MonoCell` pins the cell
            // to the FONT's metrics and paints the glyph over it; a wide glyph
            // spills into the gutter, which is what a torn signal should do,
            // and moves nothing. Deliberately NOT clipped — clipping would
            // shave the ±1px RGB-split copies the effect is made of.
            MonoCell(font: font) { stack }
                .accessibilityHidden(true)
        }
    }

    /// Font used for every Text layer inside `glyph(...)`. Sized footprints
    /// derive an SF Mono size from the preset; font footprints pass through
    /// the caller-supplied font verbatim.
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
