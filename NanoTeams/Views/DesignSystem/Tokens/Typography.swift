import SwiftUI

/// Typography tokens — semantic font presets.
/// Point sizes depend on the user's Dynamic Type setting and platform defaults;
/// these tokens select the semantic role, not absolute metrics.
enum Typography {
    /// Subheadline — system subheadline, regular
    static let subheadline: Font = .subheadline
    /// Subheadline, medium weight (field labels, row titles)
    static let subheadlineMedium: Font = .subheadline.weight(.medium)
    /// Subheadline, semibold (section headers, emphasized labels)
    static let subheadlineSemibold: Font = .subheadline.weight(.semibold)
    /// Caption — system caption, regular
    static let caption: Font = .caption
    /// Caption, semibold (badges, tags, bold labels)
    static let captionSemibold: Font = .caption.weight(.semibold)
    /// Caption 2 — smaller than caption
    static let caption2: Font = .caption2
}
