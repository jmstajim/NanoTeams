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
enum MessageComposerLayout {

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
    static let paneAnchoredFieldChrome: CGFloat = 56
}
