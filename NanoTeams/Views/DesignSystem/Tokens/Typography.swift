import SwiftUI

/// Typography tokens — SF Mono on a fixed terminal cell grid.
///
/// The design language is "monospace everything": a real terminal has exactly
/// one font on a fixed grid, so every UI string uses the system monospaced
/// design (SF Mono). Sizes are the design's fixed cell scale (px ≈ pt), not
/// Dynamic Type — the grid is intentionally fixed.
///
/// A global `.fontDesign(.monospaced)` at each window root carries the mono
/// design to the many call sites that use bare `.font(.caption)` etc.; these
/// named tokens pin the exact size/weight for the call sites that go through
/// them. Back-compat token names (`subheadline`, `caption`, …) are preserved
/// and re-pointed to mono so existing views keep compiling.
enum Typography {
    // MARK: - Mono helper

    private static func term(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: - Terminal cell scale (10/11/12/13/14/16/20/26/34)

    /// 10px — micro tags, edge labels
    static let term2xs: Font = term(10)
    /// 11px — captions, secondary labels
    static let termXs: Font = term(11)
    /// 12px — dense rows, status bar
    static let termSm: Font = term(12)
    /// 13px — default cell / body text
    static let termBase: Font = term(13)
    /// 14px medium — emphasized text, pane titles
    static let termMd: Font = term(14, .medium)
    /// 16px semibold — headings
    static let termLg: Font = term(16, .semibold)
    /// 20px semibold — view titles
    static let termXl: Font = term(20, .semibold)
    /// 26px bold — big headings / ASCII banners
    static let term2xl: Font = term(26, .bold)
    /// 34px bold — hero numerals
    static let term3xl: Font = term(34, .bold)

    // MARK: - Back-compat semantic names (now mono)

    /// Subheadline — 13px regular mono
    static let subheadline: Font = term(13)
    /// Subheadline, medium — field labels, row titles
    static let subheadlineMedium: Font = term(13, .medium)
    /// Subheadline, semibold — section headers, emphasized labels
    static let subheadlineSemibold: Font = term(14, .semibold)
    /// Caption — 11px regular mono
    static let caption: Font = term(11)
    /// Caption, semibold — badges, tags, bold labels
    static let captionSemibold: Font = term(11, .semibold)
    /// Caption 2 — 10px mono
    static let caption2: Font = term(10)

    /// Monospaced body — technical content (URLs, tokens, ids, paths)
    static let mono: Font = term(13)
    /// Monospaced caption — small technical chips, dense identifiers
    static let monoCaption: Font = term(11)

    // MARK: - Signature uppercase-mono label tracking

    /// Tracking for UPPERCASE section labels (design `--nt-tracking-label` 0.12em ≈ 1.3pt)
    static let labelTracking: CGFloat = 1.3
    /// Wider tracking for spaced-out banner labels (design `--nt-tracking-wide` 0.22em)
    static let bannerTracking: CGFloat = 2.4
}
