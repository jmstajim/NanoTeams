import SwiftUI

/// Layout tokens for `MessageComposer` and the surfaces that wrap it
/// (`TeamActivityComposer`, `QuickCaptureFormView`).
///
/// Single source of truth for the pixel-cap-mode constants — keeps the
/// default cap, the floor for pane-anchored caps, and the chrome subtraction
/// in lock-step across all composer sites. A drift between any of these
/// (e.g. one surface raising the floor without the others) would cause
/// inconsistent feel between the activity-feed dock, the QuickCapture
/// overlay, and any future composer surface.
nonisolated enum MessageComposerLayout {

    /// Default `maxTextFieldHeight` for `MessageComposer` — applied when no
    /// caller-supplied override is provided. Picked to match the legacy
    /// `1...6`-line footprint while still bounding extreme-length pastes.
    /// Past this height the inner TextField scrolls internally with the
    /// cursor pinned to the bottom (iMessage-style chat input).
    ///
    /// Pinned by `MessageComposerDefaultsTests`.
    static let defaultMaxTextFieldHeight: CGFloat = 220

    /// Floor for pane-anchored caps. Surfaces that derive a cap from a
    /// measured pane/panel height (`TeamActivityComposer`, `QuickCaptureFormView`)
    /// clamp to at least this value so a heavily-collapsed host still leaves a
    /// few lines of usable typing room. Without the floor, very small panes
    /// would clamp the field below one usable line height.
    static let minPaneAnchoredFieldHeight: CGFloat = 88

    /// Approximate fixed vertical chrome subtracted from a half-pane allowance
    /// when computing a pane-anchored cap (action bar + content spacing +
    /// bottom padding + immediate siblings of the field). Slightly conservative
    /// so the field's top edge lines up with the host's vertical midline at
    /// maximum growth rather than overshooting it.
    ///
    /// The "action bar" term is `actionButtonSize.height` below plus the VStack's
    /// `Spacing.xs`. Until the cell became a token that term was a literal written out
    /// at seven sites across five view files, so this estimate could not be checked
    /// against it at all; `MessageComposerDefaultsTests` now asserts the relation.
    static let paneAnchoredFieldChrome: CGFloat = 56

    /// The composer action bar's icon cell — `+`, `/`, gear, improve, revert, dictate
    /// and send all measure exactly this, via `ComposerIconButtonStyle`.
    ///
    /// A named constant rather than `Spacing` arithmetic, though `Spacing.l + Spacing.s`
    /// would give 28 and `Spacing.xl` is 24. `NavbarIconButtonStyle` derives its 28 from
    /// `.terminalSecondary`'s `minHeight` because baseline parity with that button is a
    /// stated constraint in the navbar row; the composer bar sits under a text field with
    /// no such neighbour, so borrowing the spelling would import a reason that is false
    /// here (CLAUDE.md #119). A grid retune must also not silently resize a control and
    /// invalidate `paneAnchoredFieldChrome` at its two consumers.
    ///
    /// `CGSize` rather than two scalars so width and height cannot be swapped at a call
    /// site, and so `IconButtonHitAreaPinTests` has one identifier to police.
    static let actionButtonSize = CGSize(width: 28, height: 24)

    // MARK: - Question preview card

    /// Vertical chrome subtracted from `TeamActivityComposer`'s pane allowance before the
    /// pending-question preview gets its height cap: the chip row, the "Role asks:" header,
    /// the message field at its floor, and the composer's own padding.
    ///
    /// Larger than `paneAnchoredFieldChrome` by construction — that one accounts for the
    /// field's own chrome, this one additionally has to leave room for the whole field.
    /// Asserted as that relation by `MessageComposerDefaultsTests`.
    static let questionPreviewChrome: CGFloat = 120

    /// Floor for the preview cap in a heavily-collapsed pane, so a short pane still shows a
    /// few lines of the question rather than a sliver. Must stay well above `EdgeFade.standard`
    /// or the smallest preview is mostly fade — the failure this floor exists to bound.
    static let minQuestionPreviewHeight: CGFloat = 80

    /// Cap used when the pane height is not a usable number: `TeamActivityFeedView` seeds its
    /// measured `paneHeight` with `.infinity` and fills it from `onGeometryChange`, so the
    /// first frame of every panel — and every preview that passes `maxHeight: .infinity` —
    /// lands here, as does a `.nan` from a speculative layout pass.
    static let defaultQuestionPreviewHeight: CGFloat = 200

    /// Height cap for the pending-question preview body, derived from the composer's pane
    /// allowance. Lives beside its constants rather than in the view body: a `let` inside
    /// `some View` is unreachable from XCTest, and `NanoTeams/Views/` is outside the measured
    /// coverage denominator, so arithmetic spelled there cannot be checked at all.
    static func questionPreviewMaxHeight(maxHeight: CGFloat) -> CGFloat {
        guard maxHeight.isFinite else { return defaultQuestionPreviewHeight }
        return max(minQuestionPreviewHeight, maxHeight - questionPreviewChrome)
    }
}
