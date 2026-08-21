import SwiftUI

/// Unified design tokens for Team Activity Feed cards.
nonisolated enum ActivityCardTokens {
    /// Avatar size for all card types
    static let avatarSize: CGFloat = 22
    /// Avatar icon glyph size — pinned to `Typography.termSm` (12pt) so every
    /// role avatar renders its SF Symbol at the same point size regardless of
    /// the glyph's intrinsic metrics.
    static let avatarIconSize: CGFloat = 12
    /// Card outer padding
    static let cardPadding: CGFloat = Spacing.m  // 12pt
    /// Spacing between content elements
    static let contentSpacing: CGFloat = Spacing.s  // 8pt
    /// Background opacity for dynamic-color tinted cards
    static let backgroundOpacity: Double = DynamicTintOpacity.background
    /// Card corner radius
    static let cornerRadius: CGFloat = CornerRadius.medium  // 10pt

    /// Gap ABOVE a status row (`Thinking`, `Waiting…`, `Processing 42%`) inside
    /// a message bubble — and zero below it, so the row attaches to the message
    /// it describes instead of floating equidistant between that message and
    /// whatever sits above. The bubble's `VStack` runs at `spacing: 0` so this
    /// is the whole gap, not an addition to one.
    static let statusRowTopSpacing: CGFloat = 2

    /// Gap between two feed rows of the SAME model turn — an assistant message
    /// and the tool calls / artifacts it emitted read as one block.
    static let turnHugSpacing: CGFloat = Spacing.xxs  // 2pt

    /// Gap before a row that OPENS a model turn.
    ///
    /// Before this there were two values and neither grouped anything: tool
    /// calls got a bare literal `2` and everything else `Spacing.xs` (4). A
    /// lone `Thinking` row therefore sat 4pt below the PREVIOUS turn's
    /// tool-call card and 2pt above its own, so it read as belonging to the
    /// card above — the model's reasoning attributed to the wrong action.
    ///
    /// Chosen against the measured optical gap, not by eye — two earlier
    /// guesses (10, then 2) were both wrong, in opposite directions.
    ///
    /// What matters is CONTRAST with the gap inside a message, and zero padding
    /// does not mean zero space: a status row is 11pt and the prose under it is
    /// 13pt, so the prose's ascent slack leaves ~5.7pt of ink-to-ink whitespace
    /// below `Thinking` that no padding can remove. Measured (SF Mono, `.medium`
    /// 11pt over regular 13pt): descender 2.32 + (ascender 12.57 − cap 9.16).
    ///
    /// At 2 the gap ABOVE the row came to ~7.2pt against ~5.7pt below — larger,
    /// but by 1.5pt, which reads as "the same" and left the row looking equally
    /// attached to the item above it. At 6 it is ~11.2pt against ~5.7pt: the
    /// bond below is visibly half the break above, which is the grouping.
    ///
    /// The 10 that read as a regression was not too large on its own — the row
    /// also carried 4pt BELOW it then, so it floated between two gaps instead
    /// of hugging one. With that at 0, the break above can do its job.
    static let turnGapSpacing: CGFloat = 6
}
